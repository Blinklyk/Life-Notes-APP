import Foundation
import SwiftData

@Model
final class JournalRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var scopeKey: String
    var userID: UUID
    var dayKeyRawValue: Int
    var currentVersionID: UUID
    var currentVersionNumber: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        scopeKey: String,
        userID: UUID,
        dayKeyRawValue: Int,
        currentVersionID: UUID,
        currentVersionNumber: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.userID = userID
        self.dayKeyRawValue = dayKeyRawValue
        self.currentVersionID = currentVersionID
        self.currentVersionNumber = currentVersionNumber
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func validate(expectedUserID: UUID, expectedDayKey: DayKey) throws {
        let expectedScopeKey = Self.makeScopeKey(
            userID: expectedUserID,
            dayKey: expectedDayKey
        )
        guard
            scopeKey == expectedScopeKey,
            userID == expectedUserID,
            dayKeyRawValue == expectedDayKey.storageValue
        else {
            throw JournalPersistenceError.invalidJournalScope(scopeKey)
        }
        guard currentVersionNumber > 0 else {
            throw JournalPersistenceError.invalidVersionNumber(currentVersionNumber)
        }
    }

    static func makeScopeKey(userID: UUID, dayKey: DayKey) -> String {
        "\(userID.uuidString.lowercased()):\(dayKey.storageValue)"
    }
}
