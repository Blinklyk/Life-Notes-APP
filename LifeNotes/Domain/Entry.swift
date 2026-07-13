import Foundation

enum EntryValidationError: LocalizedError, Equatable {
    case emptyText

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "写下一点内容后再保存。"
        }
    }
}

struct NewTextEntry: Equatable, Sendable {
    let text: String

    init(_ rawText: String) throws {
        let normalizedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            throw EntryValidationError.emptyText
        }
        text = normalizedText
    }
}

struct RecordingContext: Sendable {
    let instant: Date
    let timeZone: TimeZone
}

struct Entry: Identifiable, Hashable, Sendable {
    let id: UUID
    let userID: UUID
    let dayKey: DayKey
    let createdAt: Date
    let updatedAt: Date
    let creationTimeZoneIdentifier: String
    let text: String
}
