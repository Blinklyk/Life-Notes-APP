import Foundation
import SwiftData

enum JournalPersistenceCoordinator {
    private static let lock = NSLock()

    static func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        try lock.withLock(operation)
    }
}

@ModelActor
actor SwiftDataJournalWorkspace: JournalWorkspace {
    func journal(for day: DayKey, userID: UUID) async throws -> JournalDay? {
        try JournalPersistenceCoordinator.withLock {
            try journalLocked(for: day, userID: userID)
        }
    }

    private func journalLocked(for day: DayKey, userID: UUID) throws -> JournalDay? {
        let scopeKey = JournalRecord.makeScopeKey(userID: userID, dayKey: day)
        guard let record = try journalRecord(scopeKey: scopeKey) else {
            guard try versionRecords(scopeKey: scopeKey).isEmpty else {
                throw JournalPersistenceError.orphanedVersions(scopeKey)
            }
            return nil
        }
        return try loadJournal(record: record, day: day, userID: userID)
    }

    func append(
        _ draft: NewJournalVersion,
        for day: DayKey,
        userID: UUID
    ) async throws -> JournalDay {
        try JournalPersistenceCoordinator.withLock {
            try appendLocked(draft, for: day, userID: userID)
        }
    }

    private func appendLocked(
        _ draft: NewJournalVersion,
        for day: DayKey,
        userID: UUID
    ) throws -> JournalDay {
        let scopeKey = JournalRecord.makeScopeKey(userID: userID, dayKey: day)
        let blocksData = try JournalBlockCodec.encode(draft.blocks)
        _ = try JournalVersionRecord.validatedFingerprint(
            draft.sourceFingerprint.rawValue
        )
        guard draft.sourceEntryCount >= 0 else {
            throw JournalPersistenceError.invalidSourceEntryCount(
                draft.sourceEntryCount
            )
        }

        if let existingVersion = try versionRecord(id: draft.id) {
            guard
                existingVersion.scopeKey == scopeKey,
                existingVersion.userID == userID,
                existingVersion.dayKeyRawValue == day.storageValue
            else {
                throw JournalPersistenceError.invalidVersionScope(draft.id)
            }
            guard let record = try journalRecord(scopeKey: scopeKey) else {
                throw JournalPersistenceError.orphanedVersions(scopeKey)
            }
            let loaded = try loadJournal(record: record, day: day, userID: userID)
            guard
                let version = loaded.allVersions.first(where: { $0.id == draft.id }),
                Self.matches(version: version, draft: draft)
            else {
                throw JournalPersistenceError.conflictingVersionID(draft.id)
            }
            return loaded
        }

        let targetJournal: JournalRecord
        let nextVersionNumber: Int
        if let existingJournal = try journalRecord(scopeKey: scopeKey) {
            let loaded = try loadJournal(
                record: existingJournal,
                day: day,
                userID: userID
            )
            if let baseVersionID = draft.baseVersionID,
               !loaded.allVersions.contains(where: { $0.id == baseVersionID }) {
                throw JournalPersistenceError.missingBaseVersion(baseVersionID)
            }
            targetJournal = existingJournal
            nextVersionNumber = existingJournal.currentVersionNumber + 1
        } else {
            guard try versionRecords(scopeKey: scopeKey).isEmpty else {
                throw JournalPersistenceError.orphanedVersions(scopeKey)
            }
            if let baseVersionID = draft.baseVersionID {
                throw JournalPersistenceError.missingBaseVersion(baseVersionID)
            }
            let journalID = UUID()
            targetJournal = JournalRecord(
                id: journalID,
                scopeKey: scopeKey,
                userID: userID,
                dayKeyRawValue: day.storageValue,
                currentVersionID: draft.id,
                currentVersionNumber: 1,
                createdAt: draft.createdAt,
                updatedAt: draft.createdAt
            )
            modelContext.insert(targetJournal)
            nextVersionNumber = 1
        }

        let versionRecord = JournalVersionRecord(
            id: draft.id,
            versionScopeKey: JournalVersionRecord.makeVersionScopeKey(
                journalID: targetJournal.id,
                versionNumber: nextVersionNumber
            ),
            journalID: targetJournal.id,
            scopeKey: scopeKey,
            userID: userID,
            dayKeyRawValue: day.storageValue,
            versionNumber: nextVersionNumber,
            title: draft.title,
            blocksData: blocksData,
            originRawValue: draft.origin.rawValue,
            sourceFingerprintRawValue: draft.sourceFingerprint.rawValue,
            sourceEntryCount: draft.sourceEntryCount,
            baseVersionID: draft.baseVersionID,
            generatorIdentifier: draft.generatorIdentifier,
            createdAt: draft.createdAt
        )
        modelContext.insert(versionRecord)
        targetJournal.currentVersionID = draft.id
        targetJournal.currentVersionNumber = nextVersionNumber
        targetJournal.updatedAt = draft.createdAt

        do {
            try modelContext.save()
            return try loadJournal(record: targetJournal, day: day, userID: userID)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func loadJournal(
        record: JournalRecord,
        day: DayKey,
        userID: UUID
    ) throws -> JournalDay {
        try record.validate(expectedUserID: userID, expectedDayKey: day)

        var recordsByID: [UUID: JournalVersionRecord] = [:]
        for version in try versionRecords(journalID: record.id) {
            recordsByID[version.id] = version
        }
        for version in try versionRecords(scopeKey: record.scopeKey) {
            recordsByID[version.id] = version
        }
        return try JournalPersistenceSnapshot.makeJournal(
            record: record,
            versionRecords: Array(recordsByID.values),
            day: day,
            userID: userID
        )
    }

    private func journalRecord(scopeKey: String) throws -> JournalRecord? {
        let requestedScopeKey = scopeKey
        var descriptor = FetchDescriptor<JournalRecord>(
            predicate: #Predicate<JournalRecord> { record in
                record.scopeKey == requestedScopeKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func versionRecord(id: UUID) throws -> JournalVersionRecord? {
        let requestedID = id
        var descriptor = FetchDescriptor<JournalVersionRecord>(
            predicate: #Predicate<JournalVersionRecord> { record in
                record.id == requestedID
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func versionRecords(scopeKey: String) throws -> [JournalVersionRecord] {
        let requestedScopeKey = scopeKey
        let descriptor = FetchDescriptor<JournalVersionRecord>(
            predicate: #Predicate<JournalVersionRecord> { record in
                record.scopeKey == requestedScopeKey
            }
        )
        return try modelContext.fetch(descriptor)
    }

    private func versionRecords(journalID: UUID) throws -> [JournalVersionRecord] {
        let requestedJournalID = journalID
        let descriptor = FetchDescriptor<JournalVersionRecord>(
            predicate: #Predicate<JournalVersionRecord> { record in
                record.journalID == requestedJournalID
            }
        )
        return try modelContext.fetch(descriptor)
    }

    private static func matches(
        version: JournalVersion,
        draft: NewJournalVersion
    ) -> Bool {
        version.id == draft.id
            && version.title == draft.title
            && version.blocks == draft.blocks
            && version.origin == draft.origin
            && version.sourceFingerprint == draft.sourceFingerprint
            && version.sourceEntryCount == draft.sourceEntryCount
            && version.baseVersionID == draft.baseVersionID
            && version.generatorIdentifier == draft.generatorIdentifier
            && version.createdAt == draft.createdAt
    }
}

enum JournalPersistenceSnapshot {
    static func makeJournal(
        record: JournalRecord,
        versionRecords: [JournalVersionRecord],
        day: DayKey,
        userID: UUID
    ) throws -> JournalDay {
        try record.validate(expectedUserID: userID, expectedDayKey: day)

        let records = versionRecords
        guard !records.isEmpty else {
            throw JournalPersistenceError.invalidCurrentVersion(
                record.currentVersionID
            )
        }

        let versions = try records.map {
            try $0.domainVersion(
                expectedJournalID: record.id,
                expectedScopeKey: record.scopeKey,
                expectedUserID: userID,
                expectedDayKey: day
            )
        }
        let versionsByID = Dictionary(
            uniqueKeysWithValues: versions.map { ($0.id, $0) }
        )
        let numbers = versions.map(\.versionNumber).sorted()
        let expectedNumbers = Array(1...versions.count)
        guard
            versions.count == record.currentVersionNumber,
            numbers == expectedNumbers
        else {
            let firstInvalid = numbers.first ?? record.currentVersionNumber
            throw JournalPersistenceError.invalidVersionNumber(firstInvalid)
        }

        for version in versions {
            if let baseVersionID = version.baseVersionID {
                guard
                    let baseVersion = versionsByID[baseVersionID],
                    baseVersion.versionNumber < version.versionNumber
                else {
                    throw JournalPersistenceError.missingBaseVersion(baseVersionID)
                }
            }
        }

        guard
            let currentVersion = versionsByID[record.currentVersionID],
            currentVersion.versionNumber == record.currentVersionNumber
        else {
            throw JournalPersistenceError.invalidCurrentVersion(
                record.currentVersionID
            )
        }
        let history = versions
            .filter { $0.id != currentVersion.id }
            .sorted { $0.versionNumber > $1.versionNumber }
        return JournalDay(
            dayKey: day,
            currentVersion: currentVersion,
            historyVersions: history
        )
    }
}
