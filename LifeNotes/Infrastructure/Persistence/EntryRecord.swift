import Foundation
import SwiftData

enum PersistenceMappingError: LocalizedError {
    case invalidDayKey(Int)
    case invalidVoiceTranscriptionStatus(String)
    case invalidVoiceTranscriptionSource(String)
    case invalidVoiceStorageReference(String)
    case invalidDailyFeeling(Int)
    case invalidDayRecordScope(String)
    case invalidEntryRevision(Int)
    case invalidPhotoAttachmentScope(UUID)
    case invalidVoiceAttachmentScope(UUID)
    case invalidVoiceTargetPhoto(UUID)

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
        case let .invalidEntryRevision(value):
            return "本地记录包含无效的随心记录版本：\(value)。"
        case let .invalidPhotoAttachmentScope(id):
            return "本地图片附件属于错误的随心记录范围：\(id)。"
        case let .invalidVoiceAttachmentScope(id):
            return "本地语音附件属于错误的随心记录范围：\(id)。"
        case let .invalidVoiceTargetPhoto(id):
            return "本地语音附件引用了其他随心记录的图片：\(id)。"
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
    var revision: Int = 0
    var creationTimeZoneIdentifier: String
    var text: String

    init(
        id: UUID,
        userID: UUID,
        sourceDraftID: UUID? = nil,
        dayKeyRawValue: Int,
        createdAt: Date,
        updatedAt: Date,
        revision: Int = 0,
        creationTimeZoneIdentifier: String,
        text: String
    ) {
        self.id = id
        self.userID = userID
        self.sourceDraftID = sourceDraftID
        self.dayKeyRawValue = dayKeyRawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
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
        guard revision >= 0 else {
            throw PersistenceMappingError.invalidEntryRevision(revision)
        }

        return Entry(
            id: id,
            userID: userID,
            sourceDraftID: sourceDraftID,
            dayKey: dayKey,
            createdAt: createdAt,
            updatedAt: updatedAt,
            revision: revision,
            creationTimeZoneIdentifier: creationTimeZoneIdentifier,
            text: text,
            photos: photos,
            voices: voices
        )
    }
}
