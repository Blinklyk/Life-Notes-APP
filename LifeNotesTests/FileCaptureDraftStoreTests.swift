import Foundation
import XCTest
@testable import LifeNotes

final class FileCaptureDraftStoreTests: XCTestCase {
    func testRoundTripPreservesTextPhotoStatesAndReadyMetadata() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = try FileCaptureDraftStore(fileURL: fixture.fileURL)
        let snapshot = makeSnapshot(text: "一段尚未保存的记录")

        let emptySnapshot = try await store.load()
        XCTAssertNil(emptySnapshot)
        try await store.save(snapshot)

        let restoredSnapshot = try await store.load()
        XCTAssertEqual(restoredSnapshot, snapshot)
    }

    func testSaveOverwritesExistingSnapshot() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = try FileCaptureDraftStore(fileURL: fixture.fileURL)
        let original = makeSnapshot(text: "旧草稿")
        let replacement = CaptureDraftSnapshot(text: "新草稿", photos: [])

        try await store.save(original)
        try await store.save(replacement)

        let restoredSnapshot = try await store.load()
        XCTAssertEqual(restoredSnapshot, replacement)
    }

    func testClearDeletesSnapshotAndCanBeRepeated() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = try FileCaptureDraftStore(fileURL: fixture.fileURL)
        try await store.save(makeSnapshot(text: "待清理"))

        try await store.clear()
        let firstLoad = try await store.load()
        XCTAssertNil(firstLoad)
        try await store.clear()
        let secondLoad = try await store.load()
        XCTAssertNil(secondLoad)
    }

    func testLoadThrowsForCorruptedFile() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = try FileCaptureDraftStore(fileURL: fixture.fileURL)
        try Data("not valid json".utf8).write(to: fixture.fileURL)

        do {
            _ = try await store.load()
            XCTFail("损坏的草稿文件不应被当作有效草稿读取")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testLegacySnapshotWithoutIDIsRewrittenDuringLoadWithStableID() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = try FileCaptureDraftStore(fileURL: fixture.fileURL)
        let legacyData = Data(
            #"{"text":"旧草稿","photos":[]}"#.utf8
        )
        try legacyData.write(to: fixture.fileURL)

        let migratedSnapshot = try await store.load()
        let snapshot = try XCTUnwrap(migratedSnapshot)
        let reopenedStore = try FileCaptureDraftStore(fileURL: fixture.fileURL)
        let reloadedSnapshot = try await reopenedStore.load()

        XCTAssertEqual(reloadedSnapshot?.id, snapshot.id)
        XCTAssertEqual(reloadedSnapshot?.text, "旧草稿")
        XCTAssertEqual(reloadedSnapshot?.photos, [])
    }

    private func makeSnapshot(text: String) -> CaptureDraftSnapshot {
        CaptureDraftSnapshot(
            text: text,
            photos: [
                CaptureDraftPhotoSnapshot(
                    id: UUID(uuidString: "655CA811-F48A-461F-8692-91DCE269764A")!,
                    status: .importing,
                    annotationText: "正在导入"
                ),
                CaptureDraftPhotoSnapshot(
                    id: UUID(uuidString: "448C7483-D2FD-45D9-8614-F55EEDEBC38C")!,
                    status: .ready,
                    annotationText: "晚霞",
                    mediaMetadata: CaptureDraftPhotoSnapshot.MediaMetadata(
                        contentTypeIdentifier: "public.jpeg",
                        pixelWidth: 4_032,
                        pixelHeight: 3_024,
                        byteCount: 2_048,
                        originalRelativePath: "Photos/ready/original.jpg",
                        thumbnailRelativePath: "Photos/ready/thumbnail.jpg"
                    )
                ),
                CaptureDraftPhotoSnapshot(
                    id: UUID(uuidString: "5599B566-27E3-4055-B7FE-E9F1133AD511")!,
                    status: .failed,
                    annotationText: "导入失败"
                )
            ]
        )
    }

    private func makeFixture() throws -> Fixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FileCaptureDraftStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directoryURL
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("capture.json", isDirectory: false)
        return Fixture(directoryURL: directoryURL, fileURL: fileURL)
    }
}

private struct Fixture {
    let directoryURL: URL
    let fileURL: URL

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
