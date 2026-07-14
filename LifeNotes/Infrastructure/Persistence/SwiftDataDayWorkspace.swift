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
        let requestedUserID = userID
        let requestedDayKey = day.storageValue
        let entryDescriptor = FetchDescriptor<EntryRecord>(
            predicate: #Predicate<EntryRecord> { record in
                record.userID == requestedUserID && record.dayKeyRawValue == requestedDayKey
            },
            sortBy: [SortDescriptor(\EntryRecord.createdAt, order: .reverse)]
        )
        let photoDescriptor = FetchDescriptor<PhotoAttachmentRecord>(
            predicate: #Predicate<PhotoAttachmentRecord> { record in
                record.userID == requestedUserID && record.dayKeyRawValue == requestedDayKey
            }
        )
        let voiceDescriptor = FetchDescriptor<VoiceAttachmentRecord>(
            predicate: #Predicate<VoiceAttachmentRecord> { record in
                record.userID == requestedUserID && record.dayKeyRawValue == requestedDayKey
            }
        )

        let entryRecords = try modelContext.fetch(entryDescriptor)
        let photoRecords = try modelContext.fetch(photoDescriptor)
        let voiceRecords = try modelContext.fetch(voiceDescriptor)
        let photosByEntryID = Dictionary(grouping: photoRecords, by: \PhotoAttachmentRecord.entryID)
        let voicesByEntryID = Dictionary(grouping: voiceRecords, by: \VoiceAttachmentRecord.entryID)

        let entries = try entryRecords.map { record in
            let photos = sortedPhotoRecords(photosByEntryID[record.id, default: []])
                .map { $0.domainAttachment() }
            let voices = try sortedVoiceRecords(voicesByEntryID[record.id, default: []])
                .map { try $0.domainAttachment() }
            return try record.domainEntry(photos: photos, voices: voices)
        }

        return entries.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id.uuidString > rhs.id.uuidString
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

        let days = Set(entryCounts.keys).union(states.keys).sorted()
        return days.compactMap { dayKey in
            let entryCount = entryCounts[dayKey, default: 0]
            let state = states[dayKey] ?? DayState(dayKey: dayKey)
            guard entryCount > 0 || state.feeling != nil || state.isImportant else {
                return nil
            }
            return CalendarDaySummary(
                dayKey: dayKey,
                entryCount: entryCount,
                hasJournal: false,
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
        let requestedUserID = userID
        let descriptor = FetchDescriptor<PhotoAttachmentRecord>(
            predicate: #Predicate<PhotoAttachmentRecord> { record in
                record.userID == requestedUserID
            }
        )
        return Set(try modelContext.fetch(descriptor).map(\.id))
    }

    func allPhotoIDs() async throws -> Set<UUID> {
        let descriptor = FetchDescriptor<PhotoAttachmentRecord>()
        return Set(try modelContext.fetch(descriptor).map(\.id))
    }

    func retainedVoiceIDs(userID: UUID) async throws -> Set<UUID> {
        let requestedUserID = userID
        let descriptor = FetchDescriptor<VoiceAttachmentRecord>(
            predicate: #Predicate<VoiceAttachmentRecord> { record in
                record.userID == requestedUserID
            }
        )
        return retainedVoiceIDs(in: try modelContext.fetch(descriptor))
    }

    func allRetainedVoiceIDs() async throws -> Set<UUID> {
        let descriptor = FetchDescriptor<VoiceAttachmentRecord>()
        return retainedVoiceIDs(in: try modelContext.fetch(descriptor))
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

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if voiceRecord.originalRelativePath == nil, normalizedText.isEmpty {
            throw EntryValidationError.transcriptOnlyVoiceRequiresTranscript
        }

        voiceRecord.transcriptText = normalizedText
        voiceRecord.transcriptionStatusRawValue = status.rawValue
        voiceRecord.transcriptionSourceRawValue = source?.rawValue
        voiceRecord.isTranscriptUserEdited = isUserEdited
        voiceRecord.sourceLocaleIdentifier = sourceLocaleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        entryRecord.updatedAt = updatedAt

        do {
            try modelContext.save()
            return try voiceRecord.domainAttachment()
        } catch {
            modelContext.rollback()
            throw error
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

        return try record.domainEntry(
            photos: sortedPhotoRecords(photos).map { $0.domainAttachment() },
            voices: sortedVoiceRecords(voices).map { try $0.domainAttachment() }
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

    private func sortedPhotoRecords(
        _ records: [PhotoAttachmentRecord]
    ) -> [PhotoAttachmentRecord] {
        records.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex {
                return lhs.sortIndex < rhs.sortIndex
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func sortedVoiceRecords(
        _ records: [VoiceAttachmentRecord]
    ) -> [VoiceAttachmentRecord] {
        records.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex {
                return lhs.sortIndex < rhs.sortIndex
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func retainedVoiceIDs(
        in records: [VoiceAttachmentRecord]
    ) -> Set<UUID> {
        records.reduce(into: Set<UUID>()) { result, record in
            guard let relativePath = record.originalRelativePath else {
                return
            }
            result.insert(record.id)
            if let pathID = VoiceAudioStoragePath.audioID(from: relativePath) {
                result.insert(pathID)
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
