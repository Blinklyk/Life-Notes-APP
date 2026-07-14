import Foundation

struct CaptureDraftSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let photos: [CaptureDraftPhotoSnapshot]
    let voices: [CaptureDraftVoiceSnapshot]

    init(
        id: UUID = UUID(),
        text: String,
        photos: [CaptureDraftPhotoSnapshot],
        voices: [CaptureDraftVoiceSnapshot] = []
    ) {
        self.id = id
        self.text = text
        self.photos = photos
        self.voices = voices
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case photos
        case voices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        photos = try container.decode([CaptureDraftPhotoSnapshot].self, forKey: .photos)
        voices = try container.decodeIfPresent(
            [CaptureDraftVoiceSnapshot].self,
            forKey: .voices
        ) ?? []
    }
}

struct CaptureDraftVoiceSnapshot: Codable, Equatable, Sendable {
    enum CaptureState: String, Codable, Equatable, Sendable {
        case recording
        case paused
        case ready
        case failed
    }

    let id: UUID
    let targetPhotoID: UUID?
    let captureState: CaptureState
    let keepOriginalAudio: Bool
    let transcriptText: String
    let transcriptionStatus: VoiceTranscriptionStatus
    let transcriptionSource: VoiceTranscriptionSource?
    let sourceLocaleIdentifier: String
    let isTranscriptUserEdited: Bool

    init(
        id: UUID,
        targetPhotoID: UUID? = nil,
        captureState: CaptureState,
        keepOriginalAudio: Bool = true,
        transcriptText: String = "",
        transcriptionStatus: VoiceTranscriptionStatus = .notRequested,
        transcriptionSource: VoiceTranscriptionSource? = nil,
        sourceLocaleIdentifier: String = "",
        isTranscriptUserEdited: Bool = false
    ) {
        self.id = id
        self.targetPhotoID = targetPhotoID
        self.captureState = captureState
        self.keepOriginalAudio = keepOriginalAudio
        self.transcriptText = transcriptText
        self.transcriptionStatus = transcriptionStatus
        self.transcriptionSource = transcriptionSource
        self.sourceLocaleIdentifier = sourceLocaleIdentifier
        self.isTranscriptUserEdited = isTranscriptUserEdited
    }
}

struct CaptureDraftPhotoSnapshot: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case importing
        case ready
        case failed
    }

    struct MediaMetadata: Codable, Equatable, Sendable {
        let contentTypeIdentifier: String
        let pixelWidth: Int
        let pixelHeight: Int
        let byteCount: Int64
        let originalRelativePath: String
        let thumbnailRelativePath: String

        init(
            contentTypeIdentifier: String,
            pixelWidth: Int,
            pixelHeight: Int,
            byteCount: Int64,
            originalRelativePath: String,
            thumbnailRelativePath: String
        ) {
            self.contentTypeIdentifier = contentTypeIdentifier
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.byteCount = byteCount
            self.originalRelativePath = originalRelativePath
            self.thumbnailRelativePath = thumbnailRelativePath
        }
    }

    let id: UUID
    let status: Status
    let annotationText: String
    let mediaMetadata: MediaMetadata?

    init(
        id: UUID,
        status: Status,
        annotationText: String,
        mediaMetadata: MediaMetadata? = nil
    ) {
        self.id = id
        self.status = status
        self.annotationText = annotationText
        self.mediaMetadata = mediaMetadata
    }
}

protocol CaptureDraftStore: Sendable {
    func load() async throws -> CaptureDraftSnapshot?
    func save(_ snapshot: CaptureDraftSnapshot) async throws
    func clear() async throws
}
