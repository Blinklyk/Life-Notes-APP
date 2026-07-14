import Foundation
import SwiftData

enum PersistenceMappingError: LocalizedError {
    case invalidDayKey(Int)
    case invalidVoiceTranscriptionStatus(String)
    case invalidVoiceTranscriptionSource(String)
    case invalidVoiceStorageReference(String)
    case invalidDailyFeeling(Int)
    case invalidDayRecordScope(String)

    var errorDescription: String? {
        switch self {
        case let .invalidDayKey(value):
            return "本地记录包含无效的日期键：\(value)。"
        case let .invalidVoiceTranscriptionStatus(value):
            return "本地记录包含无效的语音转写状态：\(value)。"
        case let .invalidVoiceTranscriptionSource(value):
            return "本地记录包含无效的语音转写来源：\(value)。"
        case let .invalidVoiceStorageReference(value):
            return "本地记录包含无效的语音文件引用：\(value)。"
        case let .invalidDailyFeeling(value):
            return "本地记录包含无效的每日感受：\(value)。"
        case let .invalidDayRecordScope(value):
            return "本地记录包含无效的每日状态范围：\(value)。"
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

    func domainEntry(
        photos: [PhotoAttachment],
        voices: [VoiceAttachment] = []
    ) throws -> Entry {
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
            photos: photos,
            voices: voices
        )
    }
}
