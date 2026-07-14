import Foundation

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
}
