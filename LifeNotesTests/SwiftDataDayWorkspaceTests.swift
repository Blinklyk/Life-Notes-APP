import Foundation
import XCTest
@testable import LifeNotes

final class SwiftDataDayWorkspaceTests: XCTestCase {
    private let userID = UUID(uuidString: "68BDB82A-B998-4DD0-B844-8FE1C9539B9B")!

    func testTextEntrySavesAndReadsForItsOriginalDay() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let createdAt = try instant("2026-07-12T16:30:00Z")
        let draft = try NewTextEntry("  夜里忽然想起一件小事。  ")

        let saved = try await workspace.createText(
            draft,
            userID: userID,
            context: RecordingContext(instant: createdAt, timeZone: shanghai)
        )
        let entries = try await workspace.entries(for: saved.dayKey, userID: userID)
        let utcDay = DayKey(containing: createdAt, in: TimeZone(identifier: "UTC")!)
        let entriesForUTCDay = try await workspace.entries(for: utcDay, userID: userID)
        let entriesForAnotherUser = try await workspace.entries(
            for: saved.dayKey,
            userID: UUID()
        )

        XCTAssertEqual(saved.text, "夜里忽然想起一件小事。")
        XCTAssertEqual(saved.creationTimeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(saved.dayKey, DayKey(year: 2026, month: 7, day: 13))
        XCTAssertEqual(entries, [saved])
        XCTAssertTrue(entriesForUTCDay.isEmpty)
        XCTAssertTrue(entriesForAnotherUser.isEmpty)
    }

    func testEntriesAreReadNewestFirst() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

        _ = try await workspace.createText(
            NewTextEntry("较早的记录"),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T01:00:00Z"),
                timeZone: shanghai
            )
        )
        _ = try await workspace.createText(
            NewTextEntry("较晚的记录"),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T08:00:00Z"),
                timeZone: shanghai
            )
        )

        let day = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 13))
        let entries = try await workspace.entries(for: day, userID: userID)

        XCTAssertEqual(entries.map(\.text), ["较晚的记录", "较早的记录"])
    }

    func testWhitespaceOnlyDraftIsRejected() {
        XCTAssertThrowsError(try NewTextEntry(" \n\t ")) { error in
            XCTAssertEqual(error as? EntryValidationError, .emptyText)
        }
    }

    func testPersistentStoreCanBeReopened() async throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeNotesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let storeURL = storeDirectory.appendingPathComponent("test.store")
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let createdAt = try instant("2026-07-13T04:00:00Z")

        try await writePersistentEntry(
            storeURL: storeURL,
            text: "重启后还在这里",
            createdAt: createdAt,
            timeZone: shanghai
        )

        let reopenedContainer = try ModelContainerFactory.make(
            configurationName: "PersistenceRestart",
            storeURL: storeURL
        )
        let reopenedWorkspace = SwiftDataDayWorkspace(modelContainer: reopenedContainer)
        let day = DayKey(containing: createdAt, in: shanghai)
        let entries = try await reopenedWorkspace.entries(for: day, userID: userID)

        XCTAssertEqual(entries.map(\.text), ["重启后还在这里"])
    }

    private func writePersistentEntry(
        storeURL: URL,
        text: String,
        createdAt: Date,
        timeZone: TimeZone
    ) async throws {
        let container = try ModelContainerFactory.make(
            configurationName: "PersistenceRestart",
            storeURL: storeURL
        )
        let workspace = SwiftDataDayWorkspace(modelContainer: container)

        _ = try await workspace.createText(
            NewTextEntry(text),
            userID: userID,
            context: RecordingContext(instant: createdAt, timeZone: timeZone)
        )
    }

    private func instant(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}
