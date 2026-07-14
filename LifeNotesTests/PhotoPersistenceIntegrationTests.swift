import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LifeNotes

final class PhotoPersistenceIntegrationTests: XCTestCase {
    @MainActor
    func testPhotoPersistenceSurvivesRestartAndReconciliationKeepsReferences() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let initialState = try await Self.createInitialState(in: fixture)

        // 首轮实例已离开作用域，以下仅用磁盘路径重建依赖并恢复记录。
        let reopenedLibrary = try FilePhotoLibrary(rootURL: fixture.mediaRootURL)
        let reopenedContainer = try ModelContainerFactory.make(
            configurationName: "PhotoPersistenceIntegration",
            storeURL: fixture.storeURL
        )
        let reopenedWorkspace = SwiftDataDayWorkspace(modelContainer: reopenedContainer)
        let entries = try await reopenedWorkspace.entries(
            for: initialState.dayKey,
            userID: initialState.userID
        )
        let reloadedEntry = try XCTUnwrap(entries.first)
        let reloadedPhoto = try XCTUnwrap(reloadedEntry.photos.first)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(reloadedEntry.text, "雨停后去散步")
        XCTAssertEqual(reloadedPhoto.id, initialState.referencedPhoto.id)
        XCTAssertEqual(reloadedPhoto.annotationText, "路边的晚霞")
        XCTAssertEqual(
            reloadedPhoto.originalRelativePath,
            initialState.referencedPhoto.originalRelativePath
        )
        XCTAssertEqual(
            reloadedPhoto.thumbnailRelativePath,
            initialState.referencedPhoto.thumbnailRelativePath
        )

        let reloadedOriginal = try await reopenedLibrary.data(
            for: reloadedPhoto.originalRelativePath
        )
        let reloadedThumbnail = try await reopenedLibrary.data(
            for: reloadedPhoto.thumbnailRelativePath
        )
        XCTAssertEqual(reloadedOriginal, initialState.originalData)
        XCTAssertFalse(reloadedThumbnail.isEmpty)
        XCTAssertEqual(
            try Self.contentTypeIdentifier(of: reloadedThumbnail),
            UTType.jpeg.identifier
        )

        let referencedPhotoIDs = try await reopenedWorkspace.photoIDs(
            userID: initialState.userID
        )
        XCTAssertEqual(referencedPhotoIDs, [initialState.referencedPhoto.id])

        let oldModificationDate = Date(timeIntervalSinceNow: -3_600)
        let cutoffDate = Date(timeIntervalSinceNow: -60)
        try fixture.setPhotoModificationDate(
            oldModificationDate,
            photoID: initialState.referencedPhoto.id
        )
        try fixture.setPhotoModificationDate(
            oldModificationDate,
            photoID: initialState.orphanPhoto.id
        )
        XCTAssertTrue(fixture.photoDirectoryExists(initialState.referencedPhoto.id))
        XCTAssertTrue(fixture.photoDirectoryExists(initialState.orphanPhoto.id))

        try await reopenedLibrary.removeUnreferencedPhotos(
            keeping: referencedPhotoIDs,
            olderThan: cutoffDate
        )
        let retainedOriginal = try await reopenedLibrary.data(
            for: reloadedPhoto.originalRelativePath
        )

        XCTAssertTrue(fixture.photoDirectoryExists(initialState.referencedPhoto.id))
        XCTAssertFalse(fixture.photoDirectoryExists(initialState.orphanPhoto.id))
        XCTAssertEqual(retainedOriginal, initialState.originalData)
    }

    private static func createInitialState(in fixture: Fixture) async throws -> InitialState {
        let userID = UUID(uuidString: "8692CC36-4091-4D62-BD00-CF743C8A37D3")!
        let referencedPhotoID = UUID(uuidString: "1412C7B7-627E-4B27-B589-5E66D3ADDB06")!
        let orphanPhotoID = UUID(uuidString: "3F71741E-771C-486E-91E8-579E3FDBD663")!
        let originalData = try makeJPEG(width: 96, height: 64)
        let library = try FilePhotoLibrary(rootURL: fixture.mediaRootURL)
        let referencedPhoto = try await library.importPhoto(
            id: referencedPhotoID,
            data: originalData,
            contentTypeIdentifier: UTType.jpeg.identifier
        )
        let orphanPhoto = try await library.importPhoto(
            id: orphanPhotoID,
            data: try makeJPEG(width: 48, height: 32),
            contentTypeIdentifier: UTType.jpeg.identifier
        )
        let container = try ModelContainerFactory.make(
            configurationName: "PhotoPersistenceIntegration",
            storeURL: fixture.storeURL
        )
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let createdAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-14T13:30:00Z")
        )
        let draft = try NewEntry(
            text: "雨停后去散步",
            photos: [
                NewPhotoAttachment(
                    id: referencedPhoto.id,
                    annotationText: "路边的晚霞",
                    contentTypeIdentifier: referencedPhoto.contentTypeIdentifier,
                    pixelWidth: referencedPhoto.pixelWidth,
                    pixelHeight: referencedPhoto.pixelHeight,
                    byteCount: referencedPhoto.byteCount,
                    originalRelativePath: referencedPhoto.originalRelativePath,
                    thumbnailRelativePath: referencedPhoto.thumbnailRelativePath
                )
            ]
        )
        let savedEntry = try await workspace.create(
            draft,
            userID: userID,
            context: RecordingContext(instant: createdAt, timeZone: timeZone)
        )

        return InitialState(
            userID: userID,
            dayKey: savedEntry.dayKey,
            referencedPhoto: referencedPhoto,
            orphanPhoto: orphanPhoto,
            originalData: originalData
        )
    }

    private static func makeJPEG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(
            CGColor(red: 0.12, green: 0.48, blue: 0.72, alpha: 1)
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return Data(referencing: output)
    }

    private static func contentTypeIdentifier(of data: Data) throws -> String {
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(data as CFData, nil)
        )
        return try XCTUnwrap(CGImageSourceGetType(source) as String?)
    }
}

private struct InitialState: Sendable {
    let userID: UUID
    let dayKey: DayKey
    let referencedPhoto: ImportedPhoto
    let orphanPhoto: ImportedPhoto
    let originalData: Data
}

private struct Fixture: Sendable {
    let rootURL: URL
    let mediaRootURL: URL
    let storeURL: URL

    static func make() throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PhotoPersistenceIntegrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let storeDirectoryURL = rootURL.appendingPathComponent(
            "Store",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: storeDirectoryURL,
            withIntermediateDirectories: true
        )
        return Fixture(
            rootURL: rootURL,
            mediaRootURL: rootURL.appendingPathComponent("Media", isDirectory: true),
            storeURL: storeDirectoryURL.appendingPathComponent("LifeNotes.store")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func setPhotoModificationDate(_ date: Date, photoID: UUID) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: photoDirectoryURL(photoID).path
        )
    }

    func photoDirectoryExists(_ photoID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: photoDirectoryURL(photoID).path)
    }

    private func photoDirectoryURL(_ photoID: UUID) -> URL {
        mediaRootURL
            .appendingPathComponent("Photos", isDirectory: true)
            .appendingPathComponent(photoID.uuidString, isDirectory: true)
    }
}
