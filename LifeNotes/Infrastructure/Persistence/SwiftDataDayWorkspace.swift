import CryptoKit
import Foundation
import SwiftData

@ModelActor
actor SwiftDataDayWorkspace: DayWorkspace {
    private static let dayStateMutationLock = NSLock()

    func create(
        _ draft: NewEntry,
        userID: UUID,
        context: RecordingContext
    ) async throws -> Entry {
        try JournalPersistenceCoordinator.withLock {
            try createLocked(draft, userID: userID, context: context)
        }
    }

    private func createLocked(
        _ draft: NewEntry,
        userID: UUID,
        context: RecordingContext
    ) throws -> Entry {
        if let sourceDraftID = draft.sourceDraftID,
           let committedEntry = try committedEntry(
               sourceDraftID: sourceDraftID,
               userID: userID
           ) {
            return committedEntry
        }

        let dayKey = DayKey(containing: context.instant, in: context.timeZone)
        let entryID = makeEntryID(userID: userID, sourceDraftID: draft.sourceDraftID)
        let record = EntryRecord(
            id: entryID,
            userID: userID,
            sourceDraftID: draft.sourceDraftID,
            dayKeyRawValue: dayKey.storageValue,
            createdAt: context.instant,
            updatedAt: context.instant,
            creationTimeZoneIdentifier: context.timeZone.identifier,
            text: draft.text
        )
        let photoRecords = draft.photos.enumerated().map { sortIndex, photo in
            PhotoAttachmentRecord(
                id: photo.id,
                entryID: entryID,
                userID: userID,
                dayKeyRawValue: dayKey.storageValue,
                sortIndex: sortIndex,
                annotationText: photo.annotationText,
                contentTypeIdentifier: photo.contentTypeIdentifier,
                pixelWidth: photo.pixelWidth,
                pixelHeight: photo.pixelHeight,
                byteCount: photo.byteCount,
                originalRelativePath: photo.originalRelativePath,
                thumbnailRelativePath: photo.thumbnailRelativePath
            )
        }
        let voiceRecords = draft.voices.enumerated().map { sortIndex, voice in
            VoiceAttachmentRecord(
                id: voice.id,
                entryID: entryID,
                userID: userID,
                dayKeyRawValue: dayKey.storageValue,
                targetPhotoID: voice.targetPhotoID,
                sortIndex: sortIndex,
                durationMilliseconds: voice.durationMilliseconds,
                contentTypeIdentifier: voice.contentTypeIdentifier,
                byteCount: voice.byteCount,
                originalRelativePath: voice.originalRelativePath,
                transcriptText: voice.transcriptText,
                transcriptionStatusRawValue: voice.transcriptionStatus.rawValue,
                transcriptionSourceRawValue: voice.transcriptionSource?.rawValue,
                isTranscriptUserEdited: voice.isTranscriptUserEdited,
                sourceLocaleIdentifier: voice.sourceLocaleIdentifier
            )
        }

        modelContext.insert(record)
        for photoRecord in photoRecords {
            modelContext.insert(photoRecord)
        }
        for voiceRecord in voiceRecords {
            modelContext.insert(voiceRecord)
        }

        do {
            try modelContext.save()
            return try record.domainEntry(
                photos: photoRecords.map { $0.domainAttachment() },
                voices: voiceRecords.map { try $0.domainAttachment() }
            )
        } catch {
            modelContext.rollback()
            if let sourceDraftID = draft.sourceDraftID,
               let committedEntry = try? committedEntry(
                   sourceDraftID: sourceDraftID,
                   userID: userID
               ) {
                return committedEntry
            }
            throw error
        }
    }

    func entries(for day: DayKey, userID: UUID) async throws -> [Entry] {
        try JournalPersistenceCoordinator.withLock {
            try entriesLocked(for: day, userID: userID)
        }
    }

    func updateEntry(
        id: UUID,
        userID: UUID,
        edit: EntryEdit,
        updatedAt: Date
    ) async throws -> Entry {
        try JournalPersistenceCoordinator.withLock {
            guard let record = try entryRecord(id: id, userID: userID) else {
                throw DayWorkspaceError.entryNotFound
            }
            guard let day = DayKey(storageValue: record.dayKeyRawValue) else {
                throw PersistenceMappingError.invalidDayKey(record.dayKeyRawValue)
            }
            guard let original = try entriesLocked(
                for: day,
                userID: userID
            ).first(where: { $0.id == id }) else {
                throw DayWorkspaceError.entryNotFound
            }
            let photoRecords = try photoRecords(entryID: id, userID: userID)
            let voiceRecords = try voiceRecords(entryID: id, userID: userID)
            guard original.revision == edit.expectedRevision else {
                throw DayWorkspaceError.entryRevisionConflict(
                    expected: edit.expectedRevision,
                    actual: original.revision
                )
            }

            let photoEdits = try validatedPhotoEdits(
                edit.photoAnnotations,
                records: photoRecords
            )
            let voiceEdits = try canonicalVoiceEdits(
                edit.voiceTranscripts,
                records: voiceRecords
            )
            guard !edit.text.isEmpty || !photoRecords.isEmpty || !voiceRecords.isEmpty else {
                throw EntryValidationError.emptyEntry
            }

            var hasChanges = record.text != edit.text
            for photoRecord in photoRecords {
                guard let annotation = photoEdits[photoRecord.id] else {
                    throw DayWorkspaceError.invalidPhotoAnnotationSet
                }
                hasChanges = hasChanges || photoRecord.annotationText != annotation.annotationText
            }
            for voiceRecord in voiceRecords {
                guard let transcript = voiceEdits[voiceRecord.id] else {
                    throw DayWorkspaceError.invalidVoiceTranscriptSet
                }
                if voiceRecord.originalRelativePath == nil, transcript.transcriptText.isEmpty {
                    throw EntryValidationError.transcriptOnlyVoiceRequiresTranscript
                }
                hasChanges = hasChanges || !voiceRecord.matches(transcript)
            }

            guard hasChanges else {
                return original
            }

            record.text = edit.text
            record.updatedAt = updatedAt
            record.revision = try nextRevision(after: original.revision)
            for photoRecord in photoRecords {
                photoRecord.annotationText = photoEdits[photoRecord.id]?.annotationText ?? ""
            }
            for voiceRecord in voiceRecords {
                guard let transcript = voiceEdits[voiceRecord.id] else {
                    throw DayWorkspaceError.invalidVoiceTranscriptSet
                }
                voiceRecord.apply(transcript)
            }

            do {
                try modelContext.save()
                return try domainEntry(
                    record: record,
                    photoRecords: photoRecords,
                    voiceRecords: voiceRecords
                )
            } catch {
                modelContext.rollback()
                throw error
            }
        }
    }

    func deleteEntry(
        id: UUID,
        userID: UUID,
        expectedRevision: Int,
        deletedAt: Date
    ) async throws -> Entry {
        try JournalPersistenceCoordinator.withLock {
            guard let record = try entryRecord(id: id, userID: userID) else {
                throw DayWorkspaceError.entryNotFound
            }
            guard let day = DayKey(storageValue: record.dayKeyRawValue) else {
                throw PersistenceMappingError.invalidDayKey(record.dayKeyRawValue)
            }
            guard let snapshot = try entriesLocked(
                for: day,
                userID: userID
            ).first(where: { $0.id == id }) else {
                throw DayWorkspaceError.entryNotFound
            }
            let photoRecords = try photoRecords(entryID: id, userID: userID)
            let voiceRecords = try voiceRecords(entryID: id, userID: userID)
            guard snapshot.revision == expectedRevision else {
                throw DayWorkspaceError.entryRevisionConflict(
                    expected: expectedRevision,
                    actual: snapshot.revision
                )
            }

            for photoRecord in photoRecords {
                modelContext.delete(photoRecord)
            }
            for voiceRecord in voiceRecords {
                modelContext.delete(voiceRecord)
            }
            modelContext.delete(record)

            do {
                try modelContext.save()
                return snapshot
            } catch {
                modelContext.rollback()
                throw error
            }
        }
    }

    func searchEntries(matching query: String, userID: UUID) async throws -> [Entry] {
        let terms = EntrySearch.terms(in: query)
        guard !terms.isEmpty else {
            return []
        }

        return try JournalPersistenceCoordinator.withLock {
            let requestedUserID = userID
            let entryDescriptor = FetchDescriptor<EntryRecord>(
                predicate: #Predicate<EntryRecord> { record in
                    record.userID == requestedUserID
                }
            )
            let entryRecords = try modelContext.fetch(entryDescriptor)
            let entryIDs = Set(entryRecords.map(\.id))
            let photoRecords = try modelContext.fetch(
                FetchDescriptor<PhotoAttachmentRecord>()
            ).filter {
                $0.userID == userID || entryIDs.contains($0.entryID)
            }
            let voiceRecords = try modelContext.fetch(
                FetchDescriptor<VoiceAttachmentRecord>()
            ).filter {
                $0.userID == userID || entryIDs.contains($0.entryID)
            }
            let entries = try domainEntries(
                entryRecords: entryRecords,
                photoRecords: photoRecords,
                voiceRecords: voiceRecords
            )

            return sortedEntriesDescending(
                entries.filter { EntrySearch.matches($0, terms: terms) }
            )
        }
    }

    func daySummaries(
        from startDay: DayKey,
        through endDay: DayKey,
        userID: UUID
    ) async throws -> [CalendarDaySummary] {
        guard startDay <= endDay else {
            throw DayWorkspaceError.invalidDayRange
        }

        let requestedUserID = userID
        let lowerDayKey = startDay.storageValue
        let upperDayKey = endDay.storageValue
        let entryDescriptor = FetchDescriptor<EntryRecord>(
            predicate: #Predicate<EntryRecord> { record in
                record.userID == requestedUserID
                    && record.dayKeyRawValue >= lowerDayKey
                    && record.dayKeyRawValue <= upperDayKey
            }
        )
        let stateDescriptor = FetchDescriptor<DayRecord>(
            predicate: #Predicate<DayRecord> { record in
                record.userID == requestedUserID
                    && record.dayKeyRawValue >= lowerDayKey
                    && record.dayKeyRawValue <= upperDayKey
            }
        )
        let entryRecords = try modelContext.fetch(entryDescriptor)
        let stateRecords = try modelContext.fetch(stateDescriptor)
        var entryCounts: [DayKey: Int] = [:]
        var states: [DayKey: DayState] = [:]

        for record in entryRecords {
            guard let dayKey = DayKey(storageValue: record.dayKeyRawValue) else {
                throw PersistenceMappingError.invalidDayKey(record.dayKeyRawValue)
            }
            entryCounts[dayKey, default: 0] += 1
        }

        for record in stateRecords {
            guard let dayKey = DayKey(storageValue: record.dayKeyRawValue) else {
                throw PersistenceMappingError.invalidDayKey(record.dayKeyRawValue)
            }
            states[dayKey] = try record.domainState(
                expectedUserID: userID,
                expectedDayKey: dayKey
            )
        }

        let journalDays = try JournalPersistenceCoordinator.withLock {
            try validJournalDays(
                from: startDay,
                through: endDay,
                userID: userID
            )
        }

        let days = Set(entryCounts.keys)
            .union(states.keys)
            .union(journalDays)
            .sorted()
        return days.compactMap { dayKey in
            let entryCount = entryCounts[dayKey, default: 0]
            let state = states[dayKey] ?? DayState(dayKey: dayKey)
            let hasJournal = journalDays.contains(dayKey)
            guard entryCount > 0 || hasJournal || state.feeling != nil || state.isImportant else {
                return nil
            }
            return CalendarDaySummary(
                dayKey: dayKey,
                entryCount: entryCount,
                hasJournal: hasJournal,
                feeling: state.feeling,
                isImportant: state.isImportant
            )
        }
    }

    func dayDetail(for day: DayKey, userID: UUID) async throws -> DayDetail {
        async let loadedEntries = entries(for: day, userID: userID)
        async let loadedState = dayState(for: day, userID: userID)
        let (entries, state) = try await (loadedEntries, loadedState)
        return DayDetail(dayKey: day, entries: entries, state: state)
    }

    func dayState(for day: DayKey, userID: UUID) async throws -> DayState {
        guard let record = try dayRecord(for: day, userID: userID) else {
            return DayState(dayKey: day)
        }
        return try record.domainState(
            expectedUserID: userID,
            expectedDayKey: day
        )
    }

    func setFeeling(
        _ feeling: DailyFeeling?,
        for day: DayKey,
        userID: UUID,
        updatedAt: Date
    ) async throws -> DayState {
        try Self.dayStateMutationLock.withLock {
            try mutateDayRecord(for: day, userID: userID) { record in
                record.feelingRawValue = feeling?.rawValue
                record.feelingUpdatedAt = updatedAt
            }
        }
    }

    func setImportant(
        _ isImportant: Bool,
        for day: DayKey,
        userID: UUID,
        updatedAt: Date
    ) async throws -> DayState {
        try Self.dayStateMutationLock.withLock {
            try mutateDayRecord(for: day, userID: userID) { record in
                record.isImportant = isImportant
                record.importantUpdatedAt = updatedAt
            }
        }
    }

    func hasCommittedDraft(id: UUID, userID: UUID) async throws -> Bool {
        let requestedDraftID = id
        let requestedUserID = userID
        var descriptor = FetchDescriptor<EntryRecord>(
            predicate: #Predicate<EntryRecord> { record in
                record.userID == requestedUserID && record.sourceDraftID == requestedDraftID
            }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    func photoIDs(userID: UUID) async throws -> Set<UUID> {
        try JournalPersistenceCoordinator.withLock {
            let entryPhotoIDs = Set(
                try persistedEntries(userID: userID).flatMap(\.photos).map(\.id)
            )
            return try entryPhotoIDs.union(journalPhotoIDs(userID: userID))
        }
    }

    func allPhotoIDs() async throws -> Set<UUID> {
        try JournalPersistenceCoordinator.withLock {
            let entryPhotoIDs = Set(
                try persistedEntries(userID: nil).flatMap(\.photos).map(\.id)
            )
            return try entryPhotoIDs.union(allJournalPhotoIDs())
        }
    }

    func retainedVoiceIDs(userID: UUID) async throws -> Set<UUID> {
        try JournalPersistenceCoordinator.withLock {
            retainedVoiceIDs(
                in: try persistedEntries(userID: userID).flatMap(\.voices)
            )
        }
    }

    func allRetainedVoiceIDs() async throws -> Set<UUID> {
        try JournalPersistenceCoordinator.withLock {
            retainedVoiceIDs(
                in: try persistedEntries(userID: nil).flatMap(\.voices)
            )
        }
    }

    func updateVoiceTranscript(
        id: UUID,
        userID: UUID,
        text: String,
        status: VoiceTranscriptionStatus,
        source: VoiceTranscriptionSource?,
        isUserEdited: Bool,
        sourceLocaleIdentifier: String,
        updatedAt: Date
    ) async throws -> VoiceAttachment {
        try JournalPersistenceCoordinator.withLock {
            try updateVoiceTranscriptLocked(
                id: id,
                userID: userID,
                text: text,
                status: status,
                source: source,
                isUserEdited: isUserEdited,
                sourceLocaleIdentifier: sourceLocaleIdentifier,
                updatedAt: updatedAt
            )
        }
    }

    private func updateVoiceTranscriptLocked(
        id: UUID,
        userID: UUID,
        text: String,
        status: VoiceTranscriptionStatus,
        source: VoiceTranscriptionSource?,
        isUserEdited: Bool,
        sourceLocaleIdentifier: String,
        updatedAt: Date
    ) throws -> VoiceAttachment {
        let requestedVoiceID = id
        let requestedUserID = userID
        var voiceDescriptor = FetchDescriptor<VoiceAttachmentRecord>(
            predicate: #Predicate<VoiceAttachmentRecord> { record in
                record.id == requestedVoiceID && record.userID == requestedUserID
            }
        )
        voiceDescriptor.fetchLimit = 1
        guard let voiceRecord = try modelContext.fetch(voiceDescriptor).first else {
            throw DayWorkspaceError.voiceAttachmentNotFound
        }

        let requestedEntryID = voiceRecord.entryID
        var entryDescriptor = FetchDescriptor<EntryRecord>(
            predicate: #Predicate<EntryRecord> { record in
                record.id == requestedEntryID && record.userID == requestedUserID
            }
        )
        entryDescriptor.fetchLimit = 1
        guard let entryRecord = try modelContext.fetch(entryDescriptor).first else {
            throw DayWorkspaceError.voiceAttachmentNotFound
        }
        guard let day = DayKey(storageValue: entryRecord.dayKeyRawValue) else {
            throw PersistenceMappingError.invalidDayKey(entryRecord.dayKeyRawValue)
        }
        _ = try entriesLocked(for: day, userID: userID)

        if voiceRecord.isTranscriptUserEdited, !isUserEdited {
            return try voiceRecord.domainAttachment()
        }

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if voiceRecord.originalRelativePath == nil, normalizedText.isEmpty {
            throw EntryValidationError.transcriptOnlyVoiceRequiresTranscript
        }

        let normalizedLocaleIdentifier = sourceLocaleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let hasChanges = voiceRecord.transcriptText != normalizedText
            || voiceRecord.transcriptionStatusRawValue != status.rawValue
            || voiceRecord.transcriptionSourceRawValue != source?.rawValue
            || voiceRecord.isTranscriptUserEdited != isUserEdited
            || voiceRecord.sourceLocaleIdentifier != normalizedLocaleIdentifier
        guard hasChanges else {
            return try voiceRecord.domainAttachment()
        }

        voiceRecord.transcriptText = normalizedText
        voiceRecord.transcriptionStatusRawValue = status.rawValue
        voiceRecord.transcriptionSourceRawValue = source?.rawValue
        voiceRecord.isTranscriptUserEdited = isUserEdited
        voiceRecord.sourceLocaleIdentifier = normalizedLocaleIdentifier
        entryRecord.updatedAt = updatedAt
        entryRecord.revision = try nextRevision(after: entryRecord.revision)

        do {
            try modelContext.save()
            return try voiceRecord.domainAttachment()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func entriesLocked(for day: DayKey, userID: UUID) throws -> [Entry] {
        let requestedUserID = userID
        let requestedDayKey = day.storageValue
        let entryDescriptor = FetchDescriptor<EntryRecord>(
            predicate: #Predicate<EntryRecord> { record in
                record.userID == requestedUserID && record.dayKeyRawValue == requestedDayKey
            }
        )
        let entryRecords = try modelContext.fetch(entryDescriptor)
        let entryIDs = Set(entryRecords.map(\.id))
        let photoRecords = try modelContext.fetch(
            FetchDescriptor<PhotoAttachmentRecord>()
        ).filter {
            entryIDs.contains($0.entryID)
                || ($0.userID == userID && $0.dayKeyRawValue == requestedDayKey)
        }
        let voiceRecords = try modelContext.fetch(
            FetchDescriptor<VoiceAttachmentRecord>()
        ).filter {
            entryIDs.contains($0.entryID)
                || ($0.userID == userID && $0.dayKeyRawValue == requestedDayKey)
        }
        return try sortedEntriesDescending(
            domainEntries(
                entryRecords: entryRecords,
                photoRecords: photoRecords,
                voiceRecords: voiceRecords
            )
        )
    }

    private func domainEntries(
        entryRecords: [EntryRecord],
        photoRecords: [PhotoAttachmentRecord],
        voiceRecords: [VoiceAttachmentRecord]
    ) throws -> [Entry] {
        try EntryPersistenceSnapshot.entries(
            entryRecords: entryRecords,
            photoRecords: photoRecords,
            voiceRecords: voiceRecords
        )
    }

    private func domainEntry(
        record: EntryRecord,
        photoRecords: [PhotoAttachmentRecord],
        voiceRecords: [VoiceAttachmentRecord]
    ) throws -> Entry {
        try EntryPersistenceSnapshot.entry(
            record: record,
            photoRecords: photoRecords,
            voiceRecords: voiceRecords
        )
    }

    private func entryRecord(id: UUID, userID: UUID) throws -> EntryRecord? {
        let requestedEntryID = id
        let requestedUserID = userID
        var descriptor = FetchDescriptor<EntryRecord>(
            predicate: #Predicate<EntryRecord> { record in
                record.id == requestedEntryID && record.userID == requestedUserID
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func photoRecords(
        entryID: UUID,
        userID: UUID
    ) throws -> [PhotoAttachmentRecord] {
        let requestedEntryID = entryID
        let descriptor = FetchDescriptor<PhotoAttachmentRecord>(
            predicate: #Predicate<PhotoAttachmentRecord> { record in
                record.entryID == requestedEntryID
            }
        )
        return try modelContext.fetch(descriptor)
    }

    private func voiceRecords(
        entryID: UUID,
        userID: UUID
    ) throws -> [VoiceAttachmentRecord] {
        let requestedEntryID = entryID
        let descriptor = FetchDescriptor<VoiceAttachmentRecord>(
            predicate: #Predicate<VoiceAttachmentRecord> { record in
                record.entryID == requestedEntryID
            }
        )
        return try modelContext.fetch(descriptor)
    }

    private func validatedPhotoEdits(
        _ edits: [EntryPhotoAnnotationEdit],
        records: [PhotoAttachmentRecord]
    ) throws -> [UUID: EntryPhotoAnnotationEdit] {
        let editIDs = edits.map(\.photoID)
        guard
            Set(editIDs).count == edits.count,
            Set(editIDs) == Set(records.map(\.id))
        else {
            throw DayWorkspaceError.invalidPhotoAnnotationSet
        }
        return Dictionary(uniqueKeysWithValues: edits.map { ($0.photoID, $0) })
    }

    private func canonicalVoiceEdits(
        _ edits: [EntryVoiceTranscriptEdit],
        records: [VoiceAttachmentRecord]
    ) throws -> [UUID: EntryVoiceTranscriptEdit] {
        let editIDs = edits.map(\.voiceID)
        guard
            Set(editIDs).count == edits.count,
            Set(editIDs) == Set(records.map(\.id))
        else {
            throw DayWorkspaceError.invalidVoiceTranscriptSet
        }
        let requestedEdits = Dictionary(
            uniqueKeysWithValues: edits.map { ($0.voiceID, $0) }
        )
        var canonicalEdits: [UUID: EntryVoiceTranscriptEdit] = [:]
        for record in records {
            guard let requested = requestedEdits[record.id] else {
                throw DayWorkspaceError.invalidVoiceTranscriptSet
            }
            let current = try record.domainAttachment()
            if requested.transcriptText == current.transcriptText {
                canonicalEdits[record.id] = EntryVoiceTranscriptEdit(
                    voiceID: current.id,
                    transcriptText: current.transcriptText,
                    transcriptionStatus: current.transcriptionStatus,
                    transcriptionSource: current.transcriptionSource,
                    isTranscriptUserEdited: current.isTranscriptUserEdited,
                    sourceLocaleIdentifier: current.sourceLocaleIdentifier
                )
                continue
            }
            if requested.transcriptText.isEmpty, current.originalRelativePath == nil {
                throw EntryValidationError.transcriptOnlyVoiceRequiresTranscript
            }
            let keepsTranscript = !requested.transcriptText.isEmpty
            canonicalEdits[record.id] = EntryVoiceTranscriptEdit(
                voiceID: requested.voiceID,
                transcriptText: requested.transcriptText,
                transcriptionStatus: keepsTranscript ? .completed : .notRequested,
                transcriptionSource: keepsTranscript ? .manual : nil,
                isTranscriptUserEdited: keepsTranscript,
                sourceLocaleIdentifier: requested.sourceLocaleIdentifier
            )
        }
        return canonicalEdits
    }

    private func nextRevision(after revision: Int) throws -> Int {
        guard revision >= 0, revision < Int.max else {
            throw PersistenceMappingError.invalidEntryRevision(revision)
        }
        return revision + 1
    }

    private func sortedEntriesDescending(_ entries: [Entry]) -> [Entry] {
        entries.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    private func committedEntry(
        sourceDraftID: UUID,
        userID: UUID
    ) throws -> Entry? {
        let requestedDraftID = sourceDraftID
        let requestedUserID = userID
        var descriptor = FetchDescriptor<EntryRecord>(
            predicate: #Predicate<EntryRecord> { record in
                record.userID == requestedUserID && record.sourceDraftID == requestedDraftID
            },
            sortBy: [SortDescriptor(\EntryRecord.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else {
            return nil
        }

        let requestedEntryID = record.id
        let photoDescriptor = FetchDescriptor<PhotoAttachmentRecord>(
            predicate: #Predicate<PhotoAttachmentRecord> { photo in
                photo.entryID == requestedEntryID
            }
        )
        let voiceDescriptor = FetchDescriptor<VoiceAttachmentRecord>(
            predicate: #Predicate<VoiceAttachmentRecord> { voice in
                voice.entryID == requestedEntryID
            }
        )
        let photos = try modelContext.fetch(photoDescriptor)
        let voices = try modelContext.fetch(voiceDescriptor)

        return try domainEntry(
            record: record,
            photoRecords: photos,
            voiceRecords: voices
        )
    }

    private func dayRecord(
        for day: DayKey,
        userID: UUID
    ) throws -> DayRecord? {
        let requestedScopeKey = DayRecord.makeScopeKey(userID: userID, dayKey: day)
        var descriptor = FetchDescriptor<DayRecord>(
            predicate: #Predicate<DayRecord> { record in
                record.scopeKey == requestedScopeKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func existingOrNewDayRecord(
        for day: DayKey,
        userID: UUID
    ) throws -> (record: DayRecord, isNew: Bool) {
        if let existingRecord = try dayRecord(for: day, userID: userID) {
            return (existingRecord, false)
        }

        let record = DayRecord(
            scopeKey: DayRecord.makeScopeKey(userID: userID, dayKey: day),
            userID: userID,
            dayKeyRawValue: day.storageValue
        )
        modelContext.insert(record)
        return (record, true)
    }

    private func mutateDayRecord(
        for day: DayKey,
        userID: UUID,
        mutation: (DayRecord) -> Void
    ) throws -> DayState {
        for attempt in 0..<2 {
            let result = try existingOrNewDayRecord(for: day, userID: userID)
            _ = try result.record.domainState(
                expectedUserID: userID,
                expectedDayKey: day
            )
            mutation(result.record)
            let state = try result.record.domainState(
                expectedUserID: userID,
                expectedDayKey: day
            )

            do {
                try modelContext.save()
                return state
            } catch {
                modelContext.rollback()
                guard
                    attempt == 0,
                    result.isNew,
                    try dayRecord(for: day, userID: userID) != nil
                else {
                    throw error
                }
            }
        }
        preconditionFailure("每日状态更新重试次数异常")
    }

    private func persistedEntries(userID: UUID?) throws -> [Entry] {
        let entryRecords: [EntryRecord]
        if let userID {
            let requestedUserID = userID
            let descriptor = FetchDescriptor<EntryRecord>(
                predicate: #Predicate<EntryRecord> { record in
                    record.userID == requestedUserID
                }
            )
            entryRecords = try modelContext.fetch(descriptor)
        } else {
            entryRecords = try modelContext.fetch(FetchDescriptor<EntryRecord>())
        }

        let entryIDs = Set(entryRecords.map(\.id))
        let photoRecords = try modelContext.fetch(
            FetchDescriptor<PhotoAttachmentRecord>()
        ).filter { record in
            guard let userID else {
                return true
            }
            return record.userID == userID || entryIDs.contains(record.entryID)
        }
        let voiceRecords = try modelContext.fetch(
            FetchDescriptor<VoiceAttachmentRecord>()
        ).filter { record in
            guard let userID else {
                return true
            }
            return record.userID == userID || entryIDs.contains(record.entryID)
        }
        return try domainEntries(
            entryRecords: entryRecords,
            photoRecords: photoRecords,
            voiceRecords: voiceRecords
        )
    }

    private func retainedVoiceIDs(
        in voices: [VoiceAttachment]
    ) -> Set<UUID> {
        voices.reduce(into: Set<UUID>()) { result, voice in
            guard let relativePath = voice.originalRelativePath else {
                return
            }
            result.insert(voice.id)
            if let pathID = VoiceAudioStoragePath.audioID(from: relativePath) {
                result.insert(pathID)
            }
        }
    }

    private func validJournalDays(
        from startDay: DayKey,
        through endDay: DayKey,
        userID: UUID
    ) throws -> Set<DayKey> {
        let requestedUserID = userID
        let lowerDayKey = startDay.storageValue
        let upperDayKey = endDay.storageValue
        let journalDescriptor = FetchDescriptor<JournalRecord>(
            predicate: #Predicate<JournalRecord> { record in
                record.userID == requestedUserID
                    && record.dayKeyRawValue >= lowerDayKey
                    && record.dayKeyRawValue <= upperDayKey
            }
        )
        let versionDescriptor = FetchDescriptor<JournalVersionRecord>(
            predicate: #Predicate<JournalVersionRecord> { record in
                record.userID == requestedUserID
                    && record.dayKeyRawValue >= lowerDayKey
                    && record.dayKeyRawValue <= upperDayKey
            }
        )
        let journalRecords = try modelContext.fetch(journalDescriptor)
        let versionRecords = try modelContext.fetch(versionDescriptor)
        let versionsByJournalID = Dictionary(
            grouping: versionRecords,
            by: \JournalVersionRecord.journalID
        )
        let versionsByScopeKey = Dictionary(
            grouping: versionRecords,
            by: \JournalVersionRecord.scopeKey
        )

        return try journalRecords.reduce(into: Set<DayKey>()) { days, record in
            guard let dayKey = DayKey(storageValue: record.dayKeyRawValue) else {
                return
            }
            var relatedVersionsByID: [UUID: JournalVersionRecord] = [:]
            for version in versionsByJournalID[record.id, default: []] {
                relatedVersionsByID[version.id] = version
            }
            for version in versionsByScopeKey[record.scopeKey, default: []] {
                relatedVersionsByID[version.id] = version
            }

            do {
                _ = try JournalPersistenceSnapshot.makeJournal(
                    record: record,
                    versionRecords: Array(relatedVersionsByID.values),
                    day: dayKey,
                    userID: userID
                )
                days.insert(dayKey)
            } catch is JournalPersistenceError {
                // 日记损坏只隐藏当天标记，其他日期摘要仍可回看。
            }
        }
    }

    private func journalPhotoIDs(userID: UUID) throws -> Set<UUID> {
        let requestedUserID = userID
        let descriptor = FetchDescriptor<JournalVersionRecord>(
            predicate: #Predicate<JournalVersionRecord> { record in
                record.userID == requestedUserID
            }
        )
        return try journalPhotoIDs(in: modelContext.fetch(descriptor))
    }

    private func allJournalPhotoIDs() throws -> Set<UUID> {
        try journalPhotoIDs(
            in: modelContext.fetch(FetchDescriptor<JournalVersionRecord>())
        )
    }

    private func journalPhotoIDs(
        in records: [JournalVersionRecord]
    ) throws -> Set<UUID> {
        try records.reduce(into: Set<UUID>()) { result, record in
            for photoID in try JournalBlockCodec.decode(record.blocksData)
                .compactMap(\.photo)
                .map(\.id) {
                result.insert(photoID)
            }
        }
    }

    private func makeEntryID(userID: UUID, sourceDraftID: UUID?) -> UUID {
        guard let sourceDraftID else {
            return UUID()
        }
        let input = Data(
            "\(userID.uuidString):\(sourceDraftID.uuidString)".utf8
        )
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }
}

enum EntryPersistenceSnapshot {
    static func entries(
        entryRecords: [EntryRecord],
        photoRecords: [PhotoAttachmentRecord],
        voiceRecords: [VoiceAttachmentRecord]
    ) throws -> [Entry] {
        let grouped = try validatedAttachmentGroups(
            entryRecords: entryRecords,
            photoRecords: photoRecords,
            voiceRecords: voiceRecords
        )

        return try entryRecords.map { record in
            let photos = sortedPhotos(
                grouped.photosByEntryID[record.id, default: []]
            ).map { $0.domainAttachment() }
            let voices = try sortedVoices(
                grouped.voicesByEntryID[record.id, default: []]
            ).map { try $0.domainAttachment() }
            return try record.domainEntry(photos: photos, voices: voices)
        }
    }

    private static func validatedAttachmentGroups(
        entryRecords: [EntryRecord],
        photoRecords: [PhotoAttachmentRecord],
        voiceRecords: [VoiceAttachmentRecord]
    ) throws -> (
        photosByEntryID: [UUID: [PhotoAttachmentRecord]],
        voicesByEntryID: [UUID: [VoiceAttachmentRecord]]
    ) {
        let entriesByID = Dictionary(
            uniqueKeysWithValues: entryRecords.map { ($0.id, $0) }
        )
        var photosByEntryID: [UUID: [PhotoAttachmentRecord]] = [:]
        var photoOwnerByID: [UUID: UUID] = [:]

        for photo in photoRecords {
            guard
                let entry = entriesByID[photo.entryID],
                photo.userID == entry.userID,
                photo.dayKeyRawValue == entry.dayKeyRawValue
            else {
                throw PersistenceMappingError.invalidPhotoAttachmentScope(photo.id)
            }
            photosByEntryID[entry.id, default: []].append(photo)
            photoOwnerByID[photo.id] = entry.id
        }

        var voicesByEntryID: [UUID: [VoiceAttachmentRecord]] = [:]
        for voice in voiceRecords {
            guard
                let entry = entriesByID[voice.entryID],
                voice.userID == entry.userID,
                voice.dayKeyRawValue == entry.dayKeyRawValue
            else {
                throw PersistenceMappingError.invalidVoiceAttachmentScope(voice.id)
            }
            if let targetPhotoID = voice.targetPhotoID,
               photoOwnerByID[targetPhotoID] != entry.id {
                throw PersistenceMappingError.invalidVoiceTargetPhoto(voice.id)
            }
            voicesByEntryID[entry.id, default: []].append(voice)
        }
        return (photosByEntryID, voicesByEntryID)
    }

    static func entry(
        record: EntryRecord,
        photoRecords: [PhotoAttachmentRecord],
        voiceRecords: [VoiceAttachmentRecord]
    ) throws -> Entry {
        guard let entry = try entries(
            entryRecords: [record],
            photoRecords: photoRecords,
            voiceRecords: voiceRecords
        ).first else {
            preconditionFailure("单条随心记录快照缺少主记录")
        }
        return entry
    }

    private static func sortedPhotos(
        _ records: [PhotoAttachmentRecord]
    ) -> [PhotoAttachmentRecord] {
        records.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex {
                return lhs.sortIndex < rhs.sortIndex
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func sortedVoices(
        _ records: [VoiceAttachmentRecord]
    ) -> [VoiceAttachmentRecord] {
        records.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex {
                return lhs.sortIndex < rhs.sortIndex
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

private extension VoiceAttachmentRecord {
    func matches(_ edit: EntryVoiceTranscriptEdit) -> Bool {
        transcriptText == edit.transcriptText
            && transcriptionStatusRawValue == edit.transcriptionStatus.rawValue
            && transcriptionSourceRawValue == edit.transcriptionSource?.rawValue
            && isTranscriptUserEdited == edit.isTranscriptUserEdited
            && sourceLocaleIdentifier == edit.sourceLocaleIdentifier
    }

    func apply(_ edit: EntryVoiceTranscriptEdit) {
        transcriptText = edit.transcriptText
        transcriptionStatusRawValue = edit.transcriptionStatus.rawValue
        transcriptionSourceRawValue = edit.transcriptionSource?.rawValue
        isTranscriptUserEdited = edit.isTranscriptUserEdited
        sourceLocaleIdentifier = edit.sourceLocaleIdentifier
    }
}
