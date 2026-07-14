import Foundation
import SwiftData
import XCTest
@testable import LifeNotes

final class SwiftDataDayWorkspaceTests: XCTestCase {
    private let userID = UUID(uuidString: "68BDB82A-B998-4DD0-B844-8FE1C9539B9B")!

    func testTextEntrySavesAndReadsForItsOriginalDay() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let createdAt = try instant("2026-07-12T16:30:00Z")
        let draft = try NewEntry(text: "  夜里忽然想起一件小事。  ")

        let saved = try await workspace.create(
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
        XCTAssertTrue(saved.photos.isEmpty)
        XCTAssertEqual(saved.creationTimeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(saved.dayKey, DayKey(year: 2026, month: 7, day: 13))
        XCTAssertEqual(entries, [saved])
        XCTAssertTrue(entriesForUTCDay.isEmpty)
        XCTAssertTrue(entriesForAnotherUser.isEmpty)
    }

    func testSourceDraftIDPersistsAndOnlyMatchesItsOwner() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let sourceDraftID = UUID(uuidString: "C6AB1CB1-7C16-46E7-B4BF-A6664488A56E")!
        let draft = try NewEntry(
            sourceDraftID: sourceDraftID,
            text: "带提交来源的记录"
        )

        let saved = try await workspace.create(
            draft,
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T04:00:00Z"),
                timeZone: shanghai
            )
        )
        let entries = try await workspace.entries(for: saved.dayKey, userID: userID)
        let reloaded = try XCTUnwrap(entries.first)
        let isCommittedForOwner = try await workspace.hasCommittedDraft(
            id: sourceDraftID,
            userID: userID
        )
        let isCommittedForAnotherUser = try await workspace.hasCommittedDraft(
            id: sourceDraftID,
            userID: UUID()
        )
        let isAnotherDraftCommitted = try await workspace.hasCommittedDraft(
            id: UUID(),
            userID: userID
        )

        XCTAssertEqual(saved.sourceDraftID, sourceDraftID)
        XCTAssertEqual(reloaded.sourceDraftID, sourceDraftID)
        XCTAssertTrue(isCommittedForOwner)
        XCTAssertFalse(isCommittedForAnotherUser)
        XCTAssertFalse(isAnotherDraftCommitted)
    }

    func testImageOnlyEntrySavesWithoutGlobalText() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let photoID = UUID(uuidString: "32922104-33B5-4A6A-91EF-14278117DB83")!
        let photo = makePhoto(
            id: photoID,
            annotationText: "  窗边的光  ",
            originalRelativePath: "original/one.heic",
            thumbnailRelativePath: "thumbnail/one.jpg"
        )
        let draft = try NewEntry(text: " \n ", photos: [photo])

        let saved = try await workspace.create(
            draft,
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T04:00:00Z"),
                timeZone: shanghai
            )
        )
        let entries = try await workspace.entries(for: saved.dayKey, userID: userID)

        XCTAssertEqual(saved.text, "")
        XCTAssertEqual(saved.photos.count, 1)
        XCTAssertEqual(saved.photos.first?.id, photoID)
        XCTAssertEqual(saved.photos.first?.entryID, saved.id)
        XCTAssertEqual(saved.photos.first?.sortIndex, 0)
        XCTAssertEqual(saved.photos.first?.annotationText, "窗边的光")
        XCTAssertEqual(entries, [saved])
    }

    func testTextAndTwoPhotosPreservePhotoOrderAndAnnotations() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let firstID = UUID(uuidString: "DD718CD7-0A92-4605-9744-D3C6A7F0F3D7")!
        let secondID = UUID(uuidString: "F42BF1D4-5296-45EB-B72C-8494D4E9A301")!
        let draft = try NewEntry(
            text: "  今天走了很远。  ",
            photos: [
                makePhoto(
                    id: firstID,
                    annotationText: "  第一站  ",
                    originalRelativePath: "original/first.heic",
                    thumbnailRelativePath: "thumbnail/first.jpg"
                ),
                makePhoto(
                    id: secondID,
                    annotationText: "\n第二站\n",
                    originalRelativePath: "original/second.png",
                    thumbnailRelativePath: "thumbnail/second.jpg"
                )
            ]
        )

        let saved = try await workspace.create(
            draft,
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T05:00:00Z"),
                timeZone: shanghai
            )
        )
        let entries = try await workspace.entries(for: saved.dayKey, userID: userID)
        let reloaded = try XCTUnwrap(entries.first)

        XCTAssertEqual(reloaded.text, "今天走了很远。")
        XCTAssertEqual(reloaded.photos.map(\.id), [firstID, secondID])
        XCTAssertEqual(reloaded.photos.map(\.sortIndex), [0, 1])
        XCTAssertEqual(reloaded.photos.map(\.annotationText), ["第一站", "第二站"])
        XCTAssertEqual(
            reloaded.photos.map(\.originalRelativePath),
            ["original/first.heic", "original/second.png"]
        )
        XCTAssertTrue(reloaded.photos.allSatisfy { $0.entryID == reloaded.id })
    }

    func testEntriesRemainIsolatedAndAreReadNewestFirst() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

        _ = try await workspace.create(
            NewEntry(text: "较早的记录"),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T01:00:00Z"),
                timeZone: shanghai
            )
        )
        _ = try await workspace.create(
            NewEntry(
                text: "较晚的记录",
                photos: [makePhoto(originalRelativePath: "late.heic", thumbnailRelativePath: "late.jpg")]
            ),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T08:00:00Z"),
                timeZone: shanghai
            )
        )
        _ = try await workspace.create(
            NewEntry(text: "另一天"),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-14T08:00:00Z"),
                timeZone: shanghai
            )
        )
        _ = try await workspace.create(
            NewEntry(text: "其他用户"),
            userID: UUID(),
            context: RecordingContext(
                instant: try instant("2026-07-13T06:00:00Z"),
                timeZone: shanghai
            )
        )

        let day = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 13))
        let entries = try await workspace.entries(for: day, userID: userID)

        XCTAssertEqual(entries.map(\.text), ["较晚的记录", "较早的记录"])
        XCTAssertEqual(entries.first?.photos.count, 1)
        XCTAssertTrue(entries.last?.photos.isEmpty == true)
    }

    func testPhotoIDsReturnOnlyRequestedUsersPhotosAcrossAllDays() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let firstPhotoID = UUID(uuidString: "5D4C5A26-981D-4EDF-BD9F-F48A1B55F814")!
        let secondPhotoID = UUID(uuidString: "34B0BA94-9C95-4A7B-B3AF-C68A516D88B0")!
        let otherUsersPhotoID = UUID(uuidString: "29420D12-70DF-4EE5-9472-8C52EE94F51B")!
        let otherUserID = UUID(uuidString: "52590590-9270-4276-B8E7-79E5427AFD80")!

        _ = try await workspace.create(
            NewEntry(
                text: "第一天",
                photos: [
                    makePhoto(
                        id: firstPhotoID,
                        originalRelativePath: "original/first-day.heic",
                        thumbnailRelativePath: "thumbnail/first-day.jpg"
                    )
                ]
            ),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-13T04:00:00Z"),
                timeZone: shanghai
            )
        )
        _ = try await workspace.create(
            NewEntry(
                text: "第二天",
                photos: [
                    makePhoto(
                        id: secondPhotoID,
                        originalRelativePath: "original/second-day.heic",
                        thumbnailRelativePath: "thumbnail/second-day.jpg"
                    )
                ]
            ),
            userID: userID,
            context: RecordingContext(
                instant: try instant("2026-07-14T04:00:00Z"),
                timeZone: shanghai
            )
        )
        _ = try await workspace.create(
            NewEntry(
                text: "其他用户",
                photos: [
                    makePhoto(
                        id: otherUsersPhotoID,
                        originalRelativePath: "original/other-user.heic",
                        thumbnailRelativePath: "thumbnail/other-user.jpg"
                    )
                ]
            ),
            userID: otherUserID,
            context: RecordingContext(
                instant: try instant("2026-07-15T04:00:00Z"),
                timeZone: shanghai
            )
        )

        let photoIDs = try await workspace.photoIDs(userID: userID)
        let allPhotoIDs = try await workspace.allPhotoIDs()

        XCTAssertEqual(photoIDs, [firstPhotoID, secondPhotoID])
        XCTAssertFalse(photoIDs.contains(otherUsersPhotoID))
        XCTAssertEqual(allPhotoIDs, [firstPhotoID, secondPhotoID, otherUsersPhotoID])
    }

    func testEntriesWithSameCreationTimeUseStableIDDescendingOrder() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let createdAt = try instant("2026-07-13T04:00:00Z")
        let context = RecordingContext(instant: createdAt, timeZone: shanghai)

        let firstEntry = try await workspace.create(
            NewEntry(text: "第一条"),
            userID: userID,
            context: context
        )
        let secondEntry = try await workspace.create(
            NewEntry(text: "第二条"),
            userID: userID,
            context: context
        )
        let thirdEntry = try await workspace.create(
            NewEntry(text: "第三条"),
            userID: userID,
            context: context
        )
        let createdEntries = [firstEntry, secondEntry, thirdEntry]
        let day = DayKey(containing: createdAt, in: shanghai)
        let expectedIDs = createdEntries.map(\.id).sorted {
            $0.uuidString > $1.uuidString
        }

        let firstRead = try await workspace.entries(for: day, userID: userID)
        let secondRead = try await workspace.entries(for: day, userID: userID)

        XCTAssertEqual(firstRead.map(\.id), expectedIDs)
        XCTAssertEqual(secondRead.map(\.id), expectedIDs)
    }

    func testEmptyDraftIsRejected() {
        XCTAssertThrowsError(try NewEntry(text: " \n\t ")) { error in
            XCTAssertEqual(error as? EntryValidationError, .emptyEntry)
        }
    }

    func testPersistentStoreWithPhotosCanBeReopened() async throws {
        let storeDirectory = temporaryStoreDirectory()
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let storeURL = storeDirectory.appendingPathComponent("test.store")
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let createdAt = try instant("2026-07-13T04:00:00Z")
        let photoID = UUID(uuidString: "DA88B311-0DD4-4C56-BD49-1758A48BB956")!

        try await writePersistentEntry(
            storeURL: storeURL,
            draft: NewEntry(
                text: "重启后还在这里",
                photos: [
                    makePhoto(
                        id: photoID,
                        annotationText: "原图也在",
                        originalRelativePath: "original/reopen.heic",
                        thumbnailRelativePath: "thumbnail/reopen.jpg"
                    )
                ]
            ),
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
        XCTAssertEqual(entries.first?.photos.map(\.id), [photoID])
        XCTAssertEqual(entries.first?.photos.first?.annotationText, "原图也在")
    }

    func testLegacyTextStoreOpensWithExpandedSchema() async throws {
        let storeDirectory = temporaryStoreDirectory()
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let storeURL = storeDirectory.appendingPathComponent("legacy.store")
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let createdAt = try instant("2026-07-13T04:00:00Z")
        try writeLegacyEntry(
            storeURL: storeURL,
            text: "旧版本的文字记录",
            createdAt: createdAt,
            timeZone: shanghai
        )

        let migratedContainer = try ModelContainerFactory.make(
            configurationName: "LegacyMigration",
            storeURL: storeURL
        )
        let workspace = SwiftDataDayWorkspace(modelContainer: migratedContainer)
        let day = DayKey(containing: createdAt, in: shanghai)
        let entries = try await workspace.entries(for: day, userID: userID)

        XCTAssertEqual(entries.map(\.text), ["旧版本的文字记录"])
        XCTAssertTrue(entries.first?.photos.isEmpty == true)
    }

    private func writePersistentEntry(
        storeURL: URL,
        draft: NewEntry,
        createdAt: Date,
        timeZone: TimeZone
    ) async throws {
        let container = try ModelContainerFactory.make(
            configurationName: "PersistenceRestart",
            storeURL: storeURL
        )
        let workspace = SwiftDataDayWorkspace(modelContainer: container)

        _ = try await workspace.create(
            draft,
            userID: userID,
            context: RecordingContext(instant: createdAt, timeZone: timeZone)
        )
    }

    private func writeLegacyEntry(
        storeURL: URL,
        text: String,
        createdAt: Date,
        timeZone: TimeZone
    ) throws {
        let schema = Schema([EntryRecord.self])
        let configuration = ModelConfiguration(
            "LegacyMigration",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let day = DayKey(containing: createdAt, in: timeZone)
        context.insert(
            EntryRecord(
                id: UUID(),
                userID: userID,
                dayKeyRawValue: day.storageValue,
                createdAt: createdAt,
                updatedAt: createdAt,
                creationTimeZoneIdentifier: timeZone.identifier,
                text: text
            )
        )
        try context.save()
    }

    private func makePhoto(
        id: UUID = UUID(),
        annotationText: String = "",
        originalRelativePath: String,
        thumbnailRelativePath: String
    ) -> NewPhotoAttachment {
        NewPhotoAttachment(
            id: id,
            annotationText: annotationText,
            contentTypeIdentifier: "public.heic",
            pixelWidth: 3024,
            pixelHeight: 4032,
            byteCount: 2_048,
            originalRelativePath: originalRelativePath,
            thumbnailRelativePath: thumbnailRelativePath
        )
    }

    private func temporaryStoreDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeNotesTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func instant(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}
