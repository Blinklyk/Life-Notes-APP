import Foundation

struct ImportedPhoto: Identifiable, Equatable, Sendable {
    let id: UUID
    let contentTypeIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64
    let originalRelativePath: String
    let thumbnailRelativePath: String

    init(
        id: UUID,
        contentTypeIdentifier: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int64,
        originalRelativePath: String,
        thumbnailRelativePath: String
    ) {
        self.id = id
        self.contentTypeIdentifier = contentTypeIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.originalRelativePath = originalRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
    }
}

protocol PhotoLibrary: Sendable {
    func importPhoto(
        id: UUID,
        fileURL: URL,
        contentTypeIdentifier: String?
    ) async throws -> ImportedPhoto

    func importPhoto(
        id: UUID,
        data: Data,
        contentTypeIdentifier: String?
    ) async throws -> ImportedPhoto

    func removePhoto(_ photo: ImportedPhoto) async throws

    func data(for relativePath: String) async throws -> Data

    func previewData(
        for relativePath: String,
        maxPixelSize: Int
    ) async throws -> Data

    func removeUnreferencedPhotos(
        keeping photoIDs: Set<UUID>,
        olderThan: Date
    ) async throws
}

extension PhotoLibrary {
    func importPhoto(
        id: UUID,
        fileURL: URL,
        contentTypeIdentifier: String?
    ) async throws -> ImportedPhoto {
        throw PhotoLibraryError.invalidImage
    }
}

enum PhotoLibraryError: Error, Equatable {
    case invalidContentType(String)
    case invalidImage
    case invalidImageMetadata
    case imageExceedsMaximumByteCount
    case imageExceedsMaximumPixelCount
    case invalidPreviewMaxPixelSize(Int)
    case unsupportedFilenameExtension(String)
    case photoAlreadyExists(UUID)
    case invalidRelativePath(String)
    case unsafeStoragePath(String)
}
