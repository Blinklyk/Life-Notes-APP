import Foundation

enum EntryValidationError: LocalizedError, Equatable {
    case emptyEntry
    case invalidVoiceDuration
    case invalidVoiceTargetPhoto
    case transcriptOnlyVoiceRequiresTranscript
    case retainedVoiceRequiresMetadata
    case invalidVoiceStorageReference

    var errorDescription: String? {
        switch self {
        case .emptyEntry:
            return "写下一点内容、选择图片或录制语音后再保存。"
        case .invalidVoiceDuration:
            return "录音时长无效，请重新录制后再保存。"
        case .invalidVoiceTargetPhoto:
            return "照片语音批注找不到对应图片。"
        case .transcriptOnlyVoiceRequiresTranscript:
            return "仅保留转写时，转写文字不能为空。"
        case .retainedVoiceRequiresMetadata:
            return "原始录音信息不完整，请重新录制后再保存。"
        case .invalidVoiceStorageReference:
            return "原始录音引用无效，请重新录制后再保存。"
        }
    }
}

enum VoiceTranscriptionStatus: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case notRequested
    case pending
    case completed
    case failed
    case permissionDenied
}

enum VoiceTranscriptionSource: String, Codable, Equatable, Hashable, Sendable {
    case onDevice
    case appleNetwork
    case manual
}

struct NewPhotoAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let annotationText: String
    let contentTypeIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64
    let originalRelativePath: String
    let thumbnailRelativePath: String

    init(
        id: UUID = UUID(),
        annotationText: String = "",
        contentTypeIdentifier: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int64,
        originalRelativePath: String,
        thumbnailRelativePath: String
    ) {
        self.id = id
        self.annotationText = annotationText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contentTypeIdentifier = contentTypeIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.originalRelativePath = originalRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
    }
}

struct NewVoiceAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let targetPhotoID: UUID?
    let durationMilliseconds: Int
    let contentTypeIdentifier: String?
    let byteCount: Int64
    let originalRelativePath: String?
    let transcriptText: String
    let transcriptionStatus: VoiceTranscriptionStatus
    let transcriptionSource: VoiceTranscriptionSource?
    let isTranscriptUserEdited: Bool
    let sourceLocaleIdentifier: String

    init(
        id: UUID = UUID(),
        targetPhotoID: UUID? = nil,
        durationMilliseconds: Int,
        contentTypeIdentifier: String? = nil,
        byteCount: Int64 = 0,
        originalRelativePath: String? = nil,
        transcriptText: String = "",
        transcriptionStatus: VoiceTranscriptionStatus = .notRequested,
        transcriptionSource: VoiceTranscriptionSource? = nil,
        sourceLocaleIdentifier: String = "",
        isTranscriptUserEdited: Bool = false
    ) {
        let normalizedContentTypeIdentifier = contentTypeIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOriginalRelativePath = originalRelativePath?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        self.id = id
        self.targetPhotoID = targetPhotoID
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.contentTypeIdentifier = normalizedContentTypeIdentifier?.isEmpty == false
            ? normalizedContentTypeIdentifier
            : nil
        self.byteCount = max(0, byteCount)
        self.originalRelativePath = normalizedOriginalRelativePath?.isEmpty == false
            ? normalizedOriginalRelativePath
            : nil
        self.transcriptText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transcriptionStatus = transcriptionStatus
        self.transcriptionSource = transcriptionSource
        self.sourceLocaleIdentifier = sourceLocaleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.isTranscriptUserEdited = isTranscriptUserEdited
    }
}

struct NewEntry: Equatable, Sendable {
    let sourceDraftID: UUID?
    let text: String
    let photos: [NewPhotoAttachment]
    let voices: [NewVoiceAttachment]

    init(
        sourceDraftID: UUID? = nil,
        text rawText: String,
        photos: [NewPhotoAttachment] = [],
        voices: [NewVoiceAttachment] = []
    ) throws {
        let normalizedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty || !photos.isEmpty || !voices.isEmpty else {
            throw EntryValidationError.emptyEntry
        }
        let photoIDs = Set(photos.map(\.id))
        for voice in voices {
            guard voice.durationMilliseconds > 0 else {
                throw EntryValidationError.invalidVoiceDuration
            }
            if let targetPhotoID = voice.targetPhotoID,
               !photoIDs.contains(targetPhotoID) {
                throw EntryValidationError.invalidVoiceTargetPhoto
            }
            if voice.originalRelativePath == nil {
                guard !voice.transcriptText.isEmpty else {
                    throw EntryValidationError.transcriptOnlyVoiceRequiresTranscript
                }
            } else {
                guard voice.contentTypeIdentifier != nil, voice.byteCount > 0 else {
                    throw EntryValidationError.retainedVoiceRequiresMetadata
                }
                guard VoiceAudioStoragePath.audioID(
                    from: voice.originalRelativePath ?? ""
                ) == voice.id else {
                    throw EntryValidationError.invalidVoiceStorageReference
                }
            }
        }

        self.sourceDraftID = sourceDraftID
        text = normalizedText
        self.photos = photos
        self.voices = voices
    }
}

struct RecordingContext: Sendable {
    let instant: Date
    let timeZone: TimeZone
}

struct PhotoAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let entryID: UUID
    let sortIndex: Int
    let annotationText: String
    let contentTypeIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64
    let originalRelativePath: String
    let thumbnailRelativePath: String
}

struct VoiceAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let entryID: UUID
    let targetPhotoID: UUID?
    let sortIndex: Int
    let durationMilliseconds: Int
    let contentTypeIdentifier: String?
    let byteCount: Int64
    let originalRelativePath: String?
    let transcriptText: String
    let transcriptionStatus: VoiceTranscriptionStatus
    let transcriptionSource: VoiceTranscriptionSource?
    let isTranscriptUserEdited: Bool
    let sourceLocaleIdentifier: String

    init(
        id: UUID,
        entryID: UUID,
        targetPhotoID: UUID? = nil,
        sortIndex: Int,
        durationMilliseconds: Int,
        contentTypeIdentifier: String? = nil,
        byteCount: Int64 = 0,
        originalRelativePath: String? = nil,
        transcriptText: String = "",
        transcriptionStatus: VoiceTranscriptionStatus = .notRequested,
        transcriptionSource: VoiceTranscriptionSource? = nil,
        sourceLocaleIdentifier: String = "",
        isTranscriptUserEdited: Bool = false
    ) {
        self.id = id
        self.entryID = entryID
        self.targetPhotoID = targetPhotoID
        self.sortIndex = sortIndex
        self.durationMilliseconds = durationMilliseconds
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.originalRelativePath = originalRelativePath
        self.transcriptText = transcriptText
        self.transcriptionStatus = transcriptionStatus
        self.transcriptionSource = transcriptionSource
        self.sourceLocaleIdentifier = sourceLocaleIdentifier
        self.isTranscriptUserEdited = isTranscriptUserEdited
    }
}

struct Entry: Identifiable, Hashable, Sendable {
    let id: UUID
    let userID: UUID
    let sourceDraftID: UUID?
    let dayKey: DayKey
    let createdAt: Date
    let updatedAt: Date
    let creationTimeZoneIdentifier: String
    let text: String
    let photos: [PhotoAttachment]
    let voices: [VoiceAttachment]

    init(
        id: UUID,
        userID: UUID,
        sourceDraftID: UUID? = nil,
        dayKey: DayKey,
        createdAt: Date,
        updatedAt: Date,
        creationTimeZoneIdentifier: String,
        text: String,
        photos: [PhotoAttachment] = [],
        voices: [VoiceAttachment] = []
    ) {
        self.id = id
        self.userID = userID
        self.sourceDraftID = sourceDraftID
        self.dayKey = dayKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.creationTimeZoneIdentifier = creationTimeZoneIdentifier
        self.text = text
        self.photos = photos
        self.voices = voices
    }
}
