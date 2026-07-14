import Foundation

enum EntryValidationError: LocalizedError, Equatable {
    case emptyEntry

    var errorDescription: String? {
        switch self {
        case .emptyEntry:
            return "写下一点内容或选择图片后再保存。"
        }
    }
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

struct NewEntry: Equatable, Sendable {
    let sourceDraftID: UUID?
    let text: String
    let photos: [NewPhotoAttachment]

    init(
        sourceDraftID: UUID? = nil,
        text rawText: String,
        photos: [NewPhotoAttachment] = []
    ) throws {
        let normalizedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty || !photos.isEmpty else {
            throw EntryValidationError.emptyEntry
        }

        self.sourceDraftID = sourceDraftID
        text = normalizedText
        self.photos = photos
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
}
