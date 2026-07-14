import Foundation
import SwiftData

@Model
final class DayRecord {
    @Attribute(.unique) var scopeKey: String
    var userID: UUID
    var dayKeyRawValue: Int
    var feelingRawValue: Int?
    var isImportant: Bool
    var feelingUpdatedAt: Date?
    var importantUpdatedAt: Date?

    init(
        scopeKey: String,
        userID: UUID,
        dayKeyRawValue: Int,
        feelingRawValue: Int? = nil,
        isImportant: Bool = false,
        feelingUpdatedAt: Date? = nil,
        importantUpdatedAt: Date? = nil
    ) {
        self.scopeKey = scopeKey
        self.userID = userID
        self.dayKeyRawValue = dayKeyRawValue
        self.feelingRawValue = feelingRawValue
        self.isImportant = isImportant
        self.feelingUpdatedAt = feelingUpdatedAt
        self.importantUpdatedAt = importantUpdatedAt
    }

    func domainState(
        expectedUserID: UUID,
        expectedDayKey: DayKey
    ) throws -> DayState {
        let expectedScopeKey = Self.makeScopeKey(
            userID: expectedUserID,
            dayKey: expectedDayKey
        )
        guard
            scopeKey == expectedScopeKey,
            userID == expectedUserID,
            dayKeyRawValue == expectedDayKey.storageValue
        else {
            throw PersistenceMappingError.invalidDayRecordScope(scopeKey)
        }

        let feeling: DailyFeeling?
        if let feelingRawValue {
            guard let parsedFeeling = DailyFeeling(rawValue: feelingRawValue) else {
                throw PersistenceMappingError.invalidDailyFeeling(feelingRawValue)
            }
            feeling = parsedFeeling
        } else {
            feeling = nil
        }

        return DayState(
            dayKey: expectedDayKey,
            feeling: feeling,
            isImportant: isImportant,
            feelingUpdatedAt: feelingUpdatedAt,
            importantUpdatedAt: importantUpdatedAt
        )
    }

    static func makeScopeKey(userID: UUID, dayKey: DayKey) -> String {
        "\(userID.uuidString.lowercased()):\(dayKey.storageValue)"
    }
}
