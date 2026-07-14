import Foundation
import SwiftData

enum PersistenceMappingError: LocalizedError {
    case invalidDayKey(Int)

    var errorDescription: String? {
        switch self {
        case let .invalidDayKey(value):
            return "本地记录包含无效的日期键：\(value)。"
        }
    }
}

@Model
final class EntryRecord {
    @Attribute(.unique) var id: UUID
    var userID: UUID
    var sourceDraftID: UUID? = nil
    var dayKeyRawValue: Int
    var createdAt: Date
    var updatedAt: Date
    var creationTimeZoneIdentifier: String
    var text: String

    init(
        id: UUID,
        userID: UUID,
        sourceDraftID: UUID? = nil,
        dayKeyRawValue: Int,
        createdAt: Date,
        updatedAt: Date,
        creationTimeZoneIdentifier: String,
        text: String
    ) {
        self.id = id
        self.userID = userID
        self.sourceDraftID = sourceDraftID
        self.dayKeyRawValue = dayKeyRawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.creationTimeZoneIdentifier = creationTimeZoneIdentifier
        self.text = text
    }

    func domainEntry(photos: [PhotoAttachment]) throws -> Entry {
        guard let dayKey = DayKey(storageValue: dayKeyRawValue) else {
            throw PersistenceMappingError.invalidDayKey(dayKeyRawValue)
        }

        return Entry(
            id: id,
            userID: userID,
            sourceDraftID: sourceDraftID,
            dayKey: dayKey,
            createdAt: createdAt,
            updatedAt: updatedAt,
            creationTimeZoneIdentifier: creationTimeZoneIdentifier,
            text: text,
            photos: photos
        )
    }
}
