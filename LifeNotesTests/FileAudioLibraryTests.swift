import AVFoundation
import Foundation
import XCTest
@testable import LifeNotes

final class FileAudioLibraryTests: XCTestCase {
    func testCompleteRecordingReturnsMetadataAndPlaybackURLCanPreparePlayer() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FileAudioLibrary(rootURL: rootURL)
        let id = UUID(uuidString: "85743304-4486-45B3-A10E-FC98165B10A8")!
        let fixture = try shortM4AData()

        let target = try await library.prepareRecording(id: id)
        try fixture.write(to: target.fileURL, options: .atomic)
        let imported = try await library.completeRecording(id: id)

        XCTAssertEqual(imported.id, id)
        XCTAssertEqual(imported.contentTypeIdentifier, "public.mpeg-4-audio")
        XCTAssertEqual(imported.byteCount, Int64(fixture.count))
        XCTAssertGreaterThan(imported.durationMilliseconds, 0)
        XCTAssertLessThan(imported.durationMilliseconds, 1_000)
        XCTAssertEqual(imported.relativePath, "Audio/\(id.uuidString)/original.m4a")
        XCTAssertEqual(target.relativePath, imported.relativePath)

        let playbackURL = try await library.playbackURL(for: imported.relativePath)
        XCTAssertEqual(playbackURL.standardizedFileURL, target.fileURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: playbackURL), fixture)

        let player = try AVAudioPlayer(contentsOf: playbackURL)
        XCTAssertTrue(player.prepareToPlay())
        XCTAssertGreaterThan(player.duration, 0)
    }

    func testCompleteRecordingRejectsEmptyAndForgedFiles() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FileAudioLibrary(rootURL: rootURL)
        let invalidContents = [
            Data(),
            Data("not an MPEG-4 audio file".utf8),
        ]

        for contents in invalidContents {
            let id = UUID()
            let target = try await library.prepareRecording(id: id)
            try contents.write(to: target.fileURL, options: .atomic)

            do {
                _ = try await library.completeRecording(id: id)
                XCTFail("空文件或伪造音频不应完成录音")
            } catch {
                XCTAssertEqual(error as? AudioLibraryError, .invalidAudio)
            }

            try await library.removeAudio(id: id)
        }
    }

    func testPlaybackRejectsParentTraversalAndSymlinkEscape() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FileAudioLibrary(rootURL: rootURL)
        let outsideURL = rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).m4a")
        try shortM4AData().write(to: outsideURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: outsideURL) }

        let traversalPath = "../\(outsideURL.lastPathComponent)"
        do {
            _ = try await library.playbackURL(for: traversalPath)
            XCTFail("父目录穿越路径不应被读取")
        } catch {
            XCTAssertEqual(
                error as? AudioLibraryError,
                .invalidRelativePath(traversalPath)
            )
        }

        let target = try await library.prepareRecording(id: UUID())
        try FileManager.default.createSymbolicLink(
            at: target.fileURL,
            withDestinationURL: outsideURL
        )
        do {
            _ = try await library.playbackURL(for: target.relativePath)
            XCTFail("指向存储目录外的符号链接不应被读取")
        } catch {
            XCTAssertEqual(
                error as? AudioLibraryError,
                .invalidRelativePath(target.relativePath)
            )
        }
    }

    func testInitRejectsSymlinkRootBeforeCreatingAudioOutside() throws {
        let fixtureURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let outsideURL = fixtureURL.appendingPathComponent(
            "outside",
            isDirectory: true
        )
        let symlinkURL = fixtureURL.appendingPathComponent(
            "linked-root",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: outsideURL
        )

        XCTAssertThrowsError(try FileAudioLibrary(rootURL: symlinkURL))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outsideURL
                    .appendingPathComponent("Audio", isDirectory: true)
                    .path
            )
        )
    }

    func testRemoveDeletesAudioDirectoryAndCanBeRepeated() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FileAudioLibrary(rootURL: rootURL)
        let imported = try await storeValidAudio(in: library)
        let audioURL = rootURL
            .appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent(imported.id.uuidString, isDirectory: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        try await library.removeAudio(id: imported.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        try await library.removeAudio(id: imported.id)
    }

    func testReconcileRemovesOnlyOldUnreferencedAudio() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FileAudioLibrary(rootURL: rootURL)
        let referenced = try await storeValidAudio(in: library)
        let oldOrphan = try await storeValidAudio(in: library)
        let freshOrphan = try await storeValidAudio(in: library)
        let audioURL = rootURL.appendingPathComponent("Audio", isDirectory: true)
        let oldDate = Date(timeIntervalSinceNow: -3_600)
        let cutoffDate = Date(timeIntervalSinceNow: -60)

        try setModificationDate(oldDate, forAudioID: referenced.id, in: audioURL)
        try setModificationDate(oldDate, forAudioID: oldOrphan.id, in: audioURL)

        try await library.removeUnreferencedAudio(
            keeping: [referenced.id],
            olderThan: cutoffDate
        )

        XCTAssertTrue(audioDirectoryExists(referenced.id, in: audioURL))
        XCTAssertFalse(audioDirectoryExists(oldOrphan.id, in: audioURL))
        XCTAssertTrue(audioDirectoryExists(freshOrphan.id, in: audioURL))
    }

    private func storeValidAudio(
        in library: FileAudioLibrary,
        id: UUID = UUID()
    ) async throws -> ImportedAudio {
        let target = try await library.prepareRecording(id: id)
        try shortM4AData().write(to: target.fileURL, options: .atomic)
        return try await library.completeRecording(id: id)
    }

    private func setModificationDate(
        _ date: Date,
        forAudioID id: UUID,
        in audioURL: URL
    ) throws {
        let directoryURL = audioURL.appendingPathComponent(
            id.uuidString,
            isDirectory: true
        )
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: directoryURL.path
        )
    }

    private func audioDirectoryExists(_ id: UUID, in audioURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: audioURL
                .appendingPathComponent(id.uuidString, isDirectory: true)
                .path
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FileAudioLibraryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func shortM4AData() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: Self.shortM4ABase64))
    }

    private static let shortM4ABase64 = "AAAAHGZ0eXBNNEEgAAAAAE00QSBtcDQyaXNvbQAAAAh3aWRlAAABFm1kYXQhAANAaBvBN+wE8CEAAAAAAAAAAAAAGjQAOCELVPB9y3GWLqABCAiKeD7luMtXUDxEAEW8E37ATwIQAAAAAAAAAAAAAaNAA4AhC1PoBpKJDRd2UZAUtxn2WWUECxjde0FVpFjcolIKrYGZZBYcjfif9j/7fJyMzdQtK5E5FISEIcNPwvq3eeTw6EW4y9AMCExEBP+OUOqLvGzKYnAWdgIxMSypldTuP1D9cNoyKRyxveA6AhQAAAAAAAAAAAAAyAAcIQtUIihIHwOOtEBRbiY2JODy86Lcvje1JaBVFWB6Mj+MA6kaHTcBbiomJeDxDwY/dF/L0Zcfu6Dp6MjeA6AhEAAAAAAAAAAAABTAAcAAAANFbW9vdgAAAGxtdmhkAAAAANWepujVnqboAABdwAAABMwAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAdd0cmFrAAAAXHRraGQAAAAB1Z6m6NWepugAAAABAAAAAAAABMwAAAAAAAAAAAAAAAABAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAFzbWRpYQAAACBtZGhkAAAAANWepujVnqboAABdwAAAEABVxAAAAAAAMWhkbHIAAAAAAAAAAHNvdW4AAAAAAAAAAAAAAABDb3JlIE1lZGlhIEF1ZGlvAAAAARptaW5mAAAAEHNtaGQAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAN5zdGJsAAAAanN0c2QAAAAAAAAAAQAAAFptcDRhAAAAAAAAAAEAAAAAAAAAAAACABAAAAAAXcAAAAAAADZlc2RzAAAAAAOAgIAlAAAABICAgBdAFQAYAAAA+gAAAPoABYCAgAUTEFblmAaAgIABAgAAABhzdHRzAAAAAAAAAAEAAAAEAAAEAAAAABxzdHNjAAAAAAAAAAEAAAABAAAABAAAAAEAAAAkc3RzegAAAAAAAAAAAAAABAAAABoAAAAuAAAAeQAAAE0AAAAUc3RjbwAAAAAAAAABAAAALAAAAPp1ZHRhAAAA8m1ldGEAAAAAAAAAImhkbHIAAAAAAAAAAG1kaXIAAAAAAAAAAAAAAAAAAAAAAMRpbHN0AAAAvC0tLS0AAAAcbWVhbgAAAABjb20uYXBwbGUuaVR1bmVzAAAAFG5hbWUAAAAAaVR1blNNUEIAAACEZGF0YQAAAAEAAAAAIDAwMDAwMDAwIDAwMDAwODQwIDAwMDAwMkY0IDAwMDAwMDAwMDAwMDA0Q0MgMDAwMDAwMDAgMDAwMDAwMDAgMDAwMDAwMDAgMDAwMDAwMDAgMDAwMDAwMDAgMDAwMDAwMDAgMDAwMDAwMDAgMDAwMDAwMDA="
}
