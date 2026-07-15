import CryptoKit
import Foundation

enum JournalGenerationError: LocalizedError, Equatable, Sendable {
    case emptyEntries

    var errorDescription: String? {
        switch self {
        case .emptyEntries:
            return "这一天还没有可用于生成随心日记的记录。"
        }
    }
}

struct JournalGenerationRequest: Equatable, Sendable {
    let dayKey: DayKey
    let entries: [Entry]
    let style: WritingStyle

    init(dayKey: DayKey, entries: [Entry], style: WritingStyle) {
        self.dayKey = dayKey
        self.entries = entries
        self.style = style
    }
}

struct GeneratedJournalDraft: Equatable, Sendable {
    let title: String
    let blocks: [JournalBlock]
    let sourceFingerprint: JournalSourceFingerprint
    let sourceEntryCount: Int
    let generatorIdentifier: String
}

protocol JournalGenerator: Sendable {
    var identifier: String { get }

    func generate(_ request: JournalGenerationRequest) async throws -> GeneratedJournalDraft
}

extension JournalSourceFingerprint {
    static func make(entries: [Entry]) throws -> JournalSourceFingerprint {
        let snapshots = JournalSourceOrdering.entries(entries).map(JournalEntrySnapshot.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshots)
        let digest = SHA256.hash(data: data)
        let rawValue = digest.map { String(format: "%02x", $0) }.joined()
        return JournalSourceFingerprint(rawValue: rawValue)
    }
}

enum JournalSourceOrdering {
    static func entries(_ entries: [Entry]) -> [Entry] {
        entries.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func photos(_ photos: [PhotoAttachment]) -> [PhotoAttachment] {
        photos.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex {
                return lhs.sortIndex < rhs.sortIndex
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func voices(_ voices: [VoiceAttachment]) -> [VoiceAttachment] {
        voices.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex {
                return lhs.sortIndex < rhs.sortIndex
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

private struct JournalEntrySnapshot: Codable {
    let id: UUID
    let userID: UUID
    let sourceDraftID: UUID?
    let dayKey: Int
    let createdAt: Date
    let updatedAt: Date
    let creationTimeZoneIdentifier: String
    let text: String
    let photos: [JournalPhotoSnapshot]
    let voices: [JournalVoiceSnapshot]

    init(_ entry: Entry) {
        id = entry.id
        userID = entry.userID
        sourceDraftID = entry.sourceDraftID
        dayKey = entry.dayKey.storageValue
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        creationTimeZoneIdentifier = entry.creationTimeZoneIdentifier
        text = entry.text
        photos = JournalSourceOrdering.photos(entry.photos).map(JournalPhotoSnapshot.init)
        voices = JournalSourceOrdering.voices(entry.voices).map(JournalVoiceSnapshot.init)
    }
}

private struct JournalPhotoSnapshot: Codable {
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

    init(_ photo: PhotoAttachment) {
        id = photo.id
        entryID = photo.entryID
        sortIndex = photo.sortIndex
        annotationText = photo.annotationText
        contentTypeIdentifier = photo.contentTypeIdentifier
        pixelWidth = photo.pixelWidth
        pixelHeight = photo.pixelHeight
        byteCount = photo.byteCount
        originalRelativePath = photo.originalRelativePath
        thumbnailRelativePath = photo.thumbnailRelativePath
    }
}

private struct JournalVoiceSnapshot: Codable {
    let id: UUID
    let entryID: UUID
    let targetPhotoID: UUID?
    let sortIndex: Int
    let durationMilliseconds: Int
    let contentTypeIdentifier: String?
    let byteCount: Int64
    let originalRelativePath: String?
    let transcriptText: String
    let transcriptionStatus: String
    let transcriptionSource: String?
    let isTranscriptUserEdited: Bool
    let sourceLocaleIdentifier: String

    init(_ voice: VoiceAttachment) {
        id = voice.id
        entryID = voice.entryID
        targetPhotoID = voice.targetPhotoID
        sortIndex = voice.sortIndex
        durationMilliseconds = voice.durationMilliseconds
        contentTypeIdentifier = voice.contentTypeIdentifier
        byteCount = voice.byteCount
        originalRelativePath = voice.originalRelativePath
        transcriptText = voice.transcriptText
        transcriptionStatus = voice.transcriptionStatus.rawValue
        transcriptionSource = voice.transcriptionSource?.rawValue
        isTranscriptUserEdited = voice.isTranscriptUserEdited
        sourceLocaleIdentifier = voice.sourceLocaleIdentifier
    }
}
