import Foundation

protocol DayWorkspace: Sendable {
    func createText(
        _ draft: NewTextEntry,
        userID: UUID,
        context: RecordingContext
    ) async throws -> Entry

    func entries(for day: DayKey, userID: UUID) async throws -> [Entry]
}
