import Foundation
import SwiftData

@Model
final class JournalVersionRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var versionScopeKey: String
    var journalID: UUID
    var scopeKey: String
    var userID: UUID
    var dayKeyRawValue: Int
    var versionNumber: Int
    var title: String
    var blocksData: Data
    var originRawValue: String
    var sourceFingerprintRawValue: String
    var sourceEntryCount: Int
    var baseVersionID: UUID?
    var generatorIdentifier: String?
    var createdAt: Date

    init(
        id: UUID,
        versionScopeKey: String,
        journalID: UUID,
        scopeKey: String,
        userID: UUID,
        dayKeyRawValue: Int,
        versionNumber: Int,
        title: String,
        blocksData: Data,
        originRawValue: String,
        sourceFingerprintRawValue: String,
        sourceEntryCount: Int,
        baseVersionID: UUID? = nil,
        generatorIdentifier: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.versionScopeKey = versionScopeKey
        self.journalID = journalID
        self.scopeKey = scopeKey
        self.userID = userID
        self.dayKeyRawValue = dayKeyRawValue
        self.versionNumber = versionNumber
        self.title = title
        self.blocksData = blocksData
        self.originRawValue = originRawValue
        self.sourceFingerprintRawValue = sourceFingerprintRawValue
        self.sourceEntryCount = sourceEntryCount
        self.baseVersionID = baseVersionID
        self.generatorIdentifier = generatorIdentifier
        self.createdAt = createdAt
    }

    func domainVersion(
        expectedJournalID: UUID,
        expectedScopeKey: String,
        expectedUserID: UUID,
        expectedDayKey: DayKey
    ) throws -> JournalVersion {
        try validateScope(
            expectedJournalID: expectedJournalID,
            expectedScopeKey: expectedScopeKey,
            expectedUserID: expectedUserID,
            expectedDayKey: expectedDayKey
        )
        guard let origin = JournalVersionOrigin(rawValue: originRawValue) else {
            throw JournalPersistenceError.invalidVersionOrigin(originRawValue)
        }
        let fingerprint = try Self.validatedFingerprint(sourceFingerprintRawValue)
        guard sourceEntryCount >= 0 else {
            throw JournalPersistenceError.invalidSourceEntryCount(sourceEntryCount)
        }

        return JournalVersion(
            id: id,
            versionNumber: versionNumber,
            title: title,
            blocks: try JournalBlockCodec.decode(blocksData),
            origin: origin,
            sourceFingerprint: fingerprint,
            sourceEntryCount: sourceEntryCount,
            baseVersionID: baseVersionID,
            generatorIdentifier: generatorIdentifier,
            createdAt: createdAt
        )
    }

    func validateScope(
        expectedJournalID: UUID,
        expectedScopeKey: String,
        expectedUserID: UUID,
        expectedDayKey: DayKey
    ) throws {
        guard
            journalID == expectedJournalID,
            scopeKey == expectedScopeKey,
            userID == expectedUserID,
            dayKeyRawValue == expectedDayKey.storageValue
        else {
            throw JournalPersistenceError.invalidVersionScope(id)
        }
        guard versionNumber > 0 else {
            throw JournalPersistenceError.invalidVersionNumber(versionNumber)
        }
        guard versionScopeKey == Self.makeVersionScopeKey(
            journalID: expectedJournalID,
            versionNumber: versionNumber
        ) else {
            throw JournalPersistenceError.invalidVersionScope(id)
        }
    }

    static func makeVersionScopeKey(journalID: UUID, versionNumber: Int) -> String {
        "\(journalID.uuidString.lowercased()):\(versionNumber)"
    }

    static func validatedFingerprint(
        _ rawValue: String
    ) throws -> JournalSourceFingerprint {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized == rawValue, normalized.count <= 512 else {
            throw JournalPersistenceError.invalidSourceFingerprint
        }
        return JournalSourceFingerprint(rawValue: rawValue)
    }
}
