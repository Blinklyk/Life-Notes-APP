import Foundation

enum DayWorkspaceError: LocalizedError, Equatable {
    case voiceAttachmentNotFound

    var errorDescription: String? {
        switch self {
        case .voiceAttachmentNotFound:
            return "找不到要更新的语音记录。"
        }
    }
}

protocol DayWorkspace: Sendable {
    func create(
        _ draft: NewEntry,
        userID: UUID,
        context: RecordingContext
    ) async throws -> Entry

    func entries(for day: DayKey, userID: UUID) async throws -> [Entry]

    func hasCommittedDraft(id: UUID, userID: UUID) async throws -> Bool

    func photoIDs(userID: UUID) async throws -> Set<UUID>

    func allPhotoIDs() async throws -> Set<UUID>

    func retainedVoiceIDs(userID: UUID) async throws -> Set<UUID>

    func allRetainedVoiceIDs() async throws -> Set<UUID>

    func updateVoiceTranscript(
        id: UUID,
        userID: UUID,
        text: String,
        status: VoiceTranscriptionStatus,
        source: VoiceTranscriptionSource?,
        isUserEdited: Bool,
        sourceLocaleIdentifier: String,
        updatedAt: Date
    ) async throws -> VoiceAttachment
}
