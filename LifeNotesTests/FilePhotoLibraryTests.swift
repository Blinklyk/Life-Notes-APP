import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LifeNotes

final class FilePhotoLibraryTests: XCTestCase {
    func testImportPersistsOriginalAndCreatesOrientedJPEGThumbnail() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FilePhotoLibrary(rootURL: rootURL)
        let id = UUID(uuidString: "02DBA129-E85C-4826-A9DD-7739F5AFACB2")!
        let originalData = try makeJPEG(width: 80, height: 40, orientation: 6)

        let imported = try await library.importPhoto(
            id: id,
            data: originalData,
            contentTypeIdentifier: UTType.jpeg.identifier
        )

        XCTAssertEqual(imported.id, id)
        XCTAssertEqual(imported.contentTypeIdentifier, UTType.jpeg.identifier)
        XCTAssertEqual(imported.pixelWidth, 40)
        XCTAssertEqual(imported.pixelHeight, 80)
        XCTAssertEqual(imported.byteCount, Int64(originalData.count))
        let filenameExtension = try XCTUnwrap(UTType.jpeg.preferredFilenameExtension)
        XCTAssertEqual(
            imported.originalRelativePath,
            "Photos/\(id.uuidString)/original.\(filenameExtension)"
        )
        XCTAssertEqual(
            imported.thumbnailRelativePath,
            "Photos/\(id.uuidString)/thumbnail.jpg"
        )
        let persistedOriginalData = try await library.data(for: imported)
        XCTAssertEqual(persistedOriginalData, originalData)

        let thumbnailURL = rootURL.appendingPathComponent(imported.thumbnailRelativePath)
        let thumbnailData = try Data(contentsOf: thumbnailURL)
        let persistedThumbnailData = try await library.data(
            for: imported.thumbnailRelativePath
        )
        XCTAssertEqual(persistedThumbnailData, thumbnailData)
        let thumbnailProperties = try imageProperties(from: thumbnailData)
        XCTAssertEqual(thumbnailProperties.contentTypeIdentifier, UTType.jpeg.identifier)
        XCTAssertEqual(thumbnailProperties.pixelWidth, 40)
        XCTAssertEqual(thumbnailProperties.pixelHeight, 80)

        let previewData = try await library.previewData(
            for: imported.originalRelativePath,
            maxPixelSize: 30
        )
        let previewProperties = try imageProperties(from: previewData)
        XCTAssertEqual(previewProperties.contentTypeIdentifier, UTType.jpeg.identifier)
        XCTAssertEqual(previewProperties.pixelWidth, 15)
        XCTAssertEqual(previewProperties.pixelHeight, 30)
    }

    func testFileImportPersistsOriginalBytes() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FilePhotoLibrary(rootURL: rootURL)
        let sourceURL = rootURL.appendingPathComponent("source-image")
        let originalData = try makeJPEG(width: 80, height: 40, orientation: 6)
        try originalData.write(to: sourceURL)

        let imported = try await library.importPhoto(
            id: UUID(),
            fileURL: sourceURL,
            contentTypeIdentifier: UTType.jpeg.identifier
        )

        XCTAssertEqual(imported.byteCount, Int64(originalData.count))
        let persistedData = try await library.data(for: imported)
        XCTAssertEqual(persistedData, originalData)
    }

    func testFileImportRejectsOversizedSparseFileBeforeImageDecoding() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FilePhotoLibrary(rootURL: rootURL)
        let sourceURL = rootURL.appendingPathComponent("oversized-sparse-image")
        XCTAssertTrue(FileManager.default.createFile(atPath: sourceURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.truncate(atOffset: UInt64(100 * 1_024 * 1_024 + 1))
        try handle.close()

        do {
            _ = try await library.importPhoto(
                id: UUID(),
                fileURL: sourceURL,
                contentTypeIdentifier: UTType.jpeg.identifier
            )
            XCTFail("超过 100 MiB 的稀疏文件不应导入成功")
        } catch {
            XCTAssertEqual(
                error as? PhotoLibraryError,
                .imageExceedsMaximumByteCount
            )
        }

        let photosURL = rootURL.appendingPathComponent("Photos", isDirectory: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: photosURL.path).isEmpty)
    }

    func testFileImportRejectsSymbolicLinkAndDirectory() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FilePhotoLibrary(rootURL: rootURL)
        let sourceURL = rootURL.appendingPathComponent("source.jpg")
        try makeJPEG(width: 12, height: 8).write(to: sourceURL)
        let symlinkURL = rootURL.appendingPathComponent("source-link.jpg")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: sourceURL
        )
        let directoryURL = rootURL.appendingPathComponent(
            "source-directory",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )

        for invalidURL in [symlinkURL, directoryURL] {
            do {
                _ = try await library.importPhoto(
                    id: UUID(),
                    fileURL: invalidURL,
                    contentTypeIdentifier: UTType.jpeg.identifier
                )
                XCTFail("符号链接和目录不应作为图片源导入")
            } catch {
                XCTAssertEqual(error as? PhotoLibraryError, .invalidImage)
            }
        }

        let photosURL = rootURL.appendingPathComponent("Photos", isDirectory: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: photosURL.path).isEmpty)
    }

    func testLargeImageThumbnailLongestEdgeIsLimited() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FilePhotoLibrary(rootURL: rootURL)
        let originalData = try makeJPEG(width: 1_600, height: 800)

        let imported = try await library.importPhoto(
            id: UUID(),
            data: originalData,
            contentTypeIdentifier: nil
        )

        XCTAssertEqual(imported.contentTypeIdentifier, UTType.jpeg.identifier)
        let thumbnailURL = rootURL.appendingPathComponent(imported.thumbnailRelativePath)
        let properties = try imageProperties(from: Data(contentsOf: thumbnailURL))
        XCTAssertLessThanOrEqual(max(properties.pixelWidth, properties.pixelHeight), 1_200)
        XCTAssertEqual(properties.pixelWidth, 1_200)
        XCTAssertEqual(properties.pixelHeight, 600)
    }

    func testExifOrientationsFiveThroughEightUseDisplayDimensions() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FilePhotoLibrary(rootURL: rootURL)

        for orientation in 5...8 {
            let imported = try await library.importPhoto(
                id: UUID(),
                data: try makeJPEG(
                    width: 24,
                    height: 12,
                    orientation: orientation
                ),
                contentTypeIdentifier: UTType.jpeg.identifier
            )

            XCTAssertEqual(imported.pixelWidth, 12, "orientation \(orientation)")
            XCTAssertEqual(imported.pixelHeight, 24, "orientation \(orientation)")
        }
    }

    func testRemoveDeletesPhotoDirectoryAndCanBeRepeated() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FilePhotoLibrary(rootURL: rootURL)
        let imported = try await library.importPhoto(
            id: UUID(),
            data: try makeJPEG(width: 12, height: 8),
            contentTypeIdentifier: UTType.jpeg.identifier
        )
        let photoDirectoryURL = rootURL
            .appendingPathComponent("Photos", isDirectory: true)
            .appendingPathComponent(imported.id.uuidString, isDirectory: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: photoDirectoryURL.path))
        try await library.removePhoto(imported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: photoDirectoryURL.path))
        try await library.removePhoto(imported)
    }

    func testInvalidImageAndNonImageContentTypeAreRejectedWithoutArtifacts() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FilePhotoLibrary(rootURL: rootURL)

        do {
            _ = try await library.importPhoto(
                id: UUID(),
                data: Data("not an image".utf8),
                contentTypeIdentifier: UTType.jpeg.identifier
            )
            XCTFail("无效图片不应导入成功")
        } catch {
            XCTAssertEqual(error as? PhotoLibraryError, .invalidImage)
        }

        do {
            _ = try await library.importPhoto(
                id: UUID(),
                data: try makeJPEG(width: 12, height: 8),
                contentTypeIdentifier: UTType.plainText.identifier
            )
            XCTFail("非图片 UTI 不应导入成功")
        } catch {
            XCTAssertEqual(
                error as? PhotoLibraryError,
                .invalidContentType(UTType.plainText.identifier)
            )
        }

        let photosURL = rootURL.appendingPathComponent("Photos", isDirectory: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: photosURL.path).isEmpty)
    }

    func testImageOverMaximumByteCountIsRejectedBeforeDecoding() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FilePhotoLibrary(rootURL: rootURL)
        let oversizedData = Data(count: 100 * 1_024 * 1_024 + 1)

        do {
            _ = try await library.importPhoto(
                id: UUID(),
                data: oversizedData,
                contentTypeIdentifier: UTType.jpeg.identifier
            )
            XCTFail("超过 100 MiB 的图片不应导入成功")
        } catch {
            XCTAssertEqual(
                error as? PhotoLibraryError,
                .imageExceedsMaximumByteCount
            )
        }

        let photosURL = rootURL.appendingPathComponent("Photos", isDirectory: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: photosURL.path).isEmpty)
    }

    func testImageOverMaximumPixelCountIsRejectedBeforeThumbnailGeneration() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FilePhotoLibrary(rootURL: rootURL)
        let oversizedImage = makeBMPWithDeclaredDimensions(
            width: 20_000,
            height: 5_001
        )
        let properties = try imageProperties(from: oversizedImage)
        XCTAssertEqual(properties.pixelWidth, 20_000)
        XCTAssertEqual(properties.pixelHeight, 5_001)

        do {
            _ = try await library.importPhoto(
                id: UUID(),
                data: oversizedImage,
                contentTypeIdentifier: UTType.bmp.identifier
            )
            XCTFail("超过一亿像素的图片不应导入成功")
        } catch {
            XCTAssertEqual(
                error as? PhotoLibraryError,
                .imageExceedsMaximumPixelCount
            )
        }

        let photosURL = rootURL.appendingPathComponent("Photos", isDirectory: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: photosURL.path).isEmpty)
    }

    func testPreviewRejectsNonpositiveMaximumPixelSize() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FilePhotoLibrary(rootURL: rootURL)
        let imported = try await library.importPhoto(
            id: UUID(),
            data: try makeJPEG(width: 12, height: 8),
            contentTypeIdentifier: UTType.jpeg.identifier
        )

        do {
            _ = try await library.previewData(
                for: imported.originalRelativePath,
                maxPixelSize: 0
            )
            XCTFail("预览边长必须为正数")
        } catch {
            XCTAssertEqual(
                error as? PhotoLibraryError,
                .invalidPreviewMaxPixelSize(0)
            )
        }
    }

    func testReadRejectsParentTraversalAndSymlinkEscape() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FilePhotoLibrary(rootURL: rootURL)
        let outsideURL = rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).jpg")
        let outsideData = try makeJPEG(width: 8, height: 8)
        try outsideData.write(to: outsideURL)
        defer { try? FileManager.default.removeItem(at: outsideURL) }

        let traversalPhoto = makePhoto(originalRelativePath: "../\(outsideURL.lastPathComponent)")
        await assertInvalidRelativePath(traversalPhoto, in: library)

        let linkURL = rootURL.appendingPathComponent("outside-link.jpg")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)
        let symlinkPhoto = makePhoto(originalRelativePath: "outside-link.jpg")
        await assertInvalidRelativePath(symlinkPhoto, in: library)
    }

    func testInitializationRejectsPreexistingPhotosSymlink() throws {
        let rootURL = try makeTemporaryDirectory()
        let outsideURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }
        let photosURL = rootURL.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: photosURL,
            withDestinationURL: outsideURL
        )

        XCTAssertThrowsError(try FilePhotoLibrary(rootURL: rootURL)) { error in
            XCTAssertEqual(
                error as? PhotoLibraryError,
                .unsafeStoragePath("Photos")
            )
        }
    }

    func testImportAndRemoveRejectPhotosDirectoryReplacedWithSymlink() async throws {
        let rootURL = try makeTemporaryDirectory()
        let outsideURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }
        let library = try FilePhotoLibrary(rootURL: rootURL)
        let photosURL = rootURL.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.removeItem(at: photosURL)
        try FileManager.default.createSymbolicLink(
            at: photosURL,
            withDestinationURL: outsideURL
        )
        let id = UUID()

        do {
            _ = try await library.importPhoto(
                id: id,
                data: try makeJPEG(width: 12, height: 8),
                contentTypeIdentifier: UTType.jpeg.identifier
            )
            XCTFail("被替换成符号链接的 Photos 目录不应接受写入")
        } catch {
            XCTAssertEqual(error as? PhotoLibraryError, .unsafeStoragePath("Photos"))
        }

        do {
            try await library.removePhoto(makePhoto(id: id))
            XCTFail("被替换成符号链接的 Photos 目录不应执行删除")
        } catch {
            XCTAssertEqual(error as? PhotoLibraryError, .unsafeStoragePath("Photos"))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outsideURL.path).isEmpty)
    }

    func testImportAndRemoveRejectPhotoDirectorySymlink() async throws {
        let rootURL = try makeTemporaryDirectory()
        let outsideURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }
        let library = try FilePhotoLibrary(rootURL: rootURL)
        let id = UUID()
        let linkedPhotoURL = rootURL
            .appendingPathComponent("Photos", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedPhotoURL,
            withDestinationURL: outsideURL
        )
        let unsafePath = "Photos/\(id.uuidString)"

        do {
            _ = try await library.importPhoto(
                id: id,
                data: try makeJPEG(width: 12, height: 8),
                contentTypeIdentifier: UTType.jpeg.identifier
            )
            XCTFail("符号链接照片目录不应接受写入")
        } catch {
            XCTAssertEqual(error as? PhotoLibraryError, .unsafeStoragePath(unsafePath))
        }

        do {
            try await library.removePhoto(makePhoto(id: id))
            XCTFail("符号链接照片目录不应执行删除")
        } catch {
            XCTAssertEqual(error as? PhotoLibraryError, .unsafeStoragePath(unsafePath))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outsideURL.path).isEmpty)
    }

    func testReconcilePreservesReferencedAndFreshPhotosAndRemovesOldOrphan() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let library = try FilePhotoLibrary(rootURL: rootURL)
        let referenced = try await importPhoto(in: library)
        let oldOrphan = try await importPhoto(in: library)
        let freshOrphan = try await importPhoto(in: library)
        let photosURL = rootURL.appendingPathComponent("Photos", isDirectory: true)
        let oldDate = Date(timeIntervalSinceNow: -3_600)
        let cutoffDate = Date(timeIntervalSinceNow: -60)

        try setModificationDate(oldDate, forPhotoID: referenced.id, in: photosURL)
        try setModificationDate(oldDate, forPhotoID: oldOrphan.id, in: photosURL)

        try await library.removeUnreferencedPhotos(
            keeping: [referenced.id],
            olderThan: cutoffDate
        )

        XCTAssertTrue(photoDirectoryExists(referenced.id, in: photosURL))
        XCTAssertFalse(photoDirectoryExists(oldOrphan.id, in: photosURL))
        XCTAssertTrue(photoDirectoryExists(freshOrphan.id, in: photosURL))
    }

    func testReconcileSkipsSymlinksAndUnexpectedItems() async throws {
        let rootURL = try makeTemporaryDirectory()
        let outsideURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }
        let library = try FilePhotoLibrary(rootURL: rootURL)
        let photosURL = rootURL.appendingPathComponent("Photos", isDirectory: true)
        let linkedID = UUID()
        let linkedURL = photosURL.appendingPathComponent(
            linkedID.uuidString,
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedURL,
            withDestinationURL: outsideURL
        )
        let unexpectedURL = photosURL.appendingPathComponent(
            "not-a-photo",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: unexpectedURL, withIntermediateDirectories: false)

        try await library.removeUnreferencedPhotos(
            keeping: [],
            olderThan: Date(timeIntervalSinceNow: 60)
        )

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkedURL.path),
            outsideURL.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: unexpectedURL.path))
    }

    private func assertInvalidRelativePath(
        _ photo: ImportedPhoto,
        in library: FilePhotoLibrary
    ) async {
        do {
            _ = try await library.data(for: photo)
            XCTFail("越界路径不应被读取")
        } catch {
            XCTAssertEqual(
                error as? PhotoLibraryError,
                .invalidRelativePath(photo.originalRelativePath)
            )
        }
    }

    private func makePhoto(
        id: UUID = UUID(),
        originalRelativePath: String = "original.jpg"
    ) -> ImportedPhoto {
        ImportedPhoto(
            id: id,
            contentTypeIdentifier: UTType.jpeg.identifier,
            pixelWidth: 1,
            pixelHeight: 1,
            byteCount: 1,
            originalRelativePath: originalRelativePath,
            thumbnailRelativePath: "thumbnail.jpg"
        )
    }

    private func importPhoto(in library: FilePhotoLibrary) async throws -> ImportedPhoto {
        try await library.importPhoto(
            id: UUID(),
            data: try makeJPEG(width: 12, height: 8),
            contentTypeIdentifier: UTType.jpeg.identifier
        )
    }

    private func setModificationDate(
        _ date: Date,
        forPhotoID id: UUID,
        in photosURL: URL
    ) throws {
        let photoURL = photosURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: photoURL.path
        )
    }

    private func photoDirectoryExists(_ id: UUID, in photosURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: photosURL
                .appendingPathComponent(id.uuidString, isDirectory: true)
                .path
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilePhotoLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeJPEG(
        width: Int,
        height: Int,
        orientation: Int? = nil
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        )
        context.setFillColor(CGColor(red: 0.82, green: 0.24, blue: 0.18, alpha: 1))
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
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return Data(referencing: output)
    }

    private func makeBMPWithDeclaredDimensions(
        width: Int,
        height: Int
    ) -> Data {
        precondition((1...Int(UInt32.max)).contains(width))
        precondition((1...Int(UInt32.max)).contains(height))
        var bytes = [UInt8](repeating: 0, count: 58)
        bytes[0] = 0x42
        bytes[1] = 0x4D
        writeLittleEndian(UInt32(bytes.count), at: 2, in: &bytes)
        writeLittleEndian(UInt32(54), at: 10, in: &bytes)
        writeLittleEndian(UInt32(40), at: 14, in: &bytes)
        writeLittleEndian(UInt32(width), at: 18, in: &bytes)
        writeLittleEndian(UInt32(height), at: 22, in: &bytes)
        writeLittleEndian(UInt16(1), at: 26, in: &bytes)
        writeLittleEndian(UInt16(24), at: 28, in: &bytes)
        return Data(bytes)
    }

    private func writeLittleEndian(
        _ value: UInt32,
        at index: Int,
        in bytes: inout [UInt8]
    ) {
        bytes[index] = UInt8(value & 0xFF)
        bytes[index + 1] = UInt8((value >> 8) & 0xFF)
        bytes[index + 2] = UInt8((value >> 16) & 0xFF)
        bytes[index + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func writeLittleEndian(
        _ value: UInt16,
        at index: Int,
        in bytes: inout [UInt8]
    ) {
        bytes[index] = UInt8(value & 0xFF)
        bytes[index + 1] = UInt8((value >> 8) & 0xFF)
    }

    private func imageProperties(from data: Data) throws -> (
        contentTypeIdentifier: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let contentTypeIdentifier = try XCTUnwrap(CGImageSourceGetType(source) as String?)
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
        )
        let width = try XCTUnwrap(
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        )
        let height = try XCTUnwrap(
            (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        )
        return (contentTypeIdentifier, width, height)
    }
}
