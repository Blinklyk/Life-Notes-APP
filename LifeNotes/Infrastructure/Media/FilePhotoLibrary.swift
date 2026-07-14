import Foundation
import ImageIO
import UniformTypeIdentifiers

actor FilePhotoLibrary: PhotoLibrary {
    private static let photosDirectoryName = "Photos"
    private static let thumbnailMaxPixelSize = 1_200
    private static let maximumImageByteCount = 100 * 1_024 * 1_024
    private static let maximumImagePixelCount: Int64 = 100_000_000

    private let rootURL: URL
    private let photosURL: URL

    init(rootURL: URL) throws {
        let fileManager = FileManager.default
        let standardizedRootURL = rootURL.standardizedFileURL
        try fileManager.createDirectory(
            at: standardizedRootURL,
            withIntermediateDirectories: true
        )

        let resolvedRootURL = standardizedRootURL.resolvingSymlinksInPath()
        let photosURL = resolvedRootURL.appendingPathComponent(
            Self.photosDirectoryName,
            isDirectory: true
        ).standardizedFileURL
        if Self.itemExistsIncludingSymbolicLink(at: photosURL) {
            try Self.validateDirectory(
                at: photosURL,
                canonicalURL: photosURL,
                within: resolvedRootURL,
                pathDescription: Self.photosDirectoryName
            )
        } else {
            try fileManager.createDirectory(
                at: photosURL,
                withIntermediateDirectories: false
            )
            try Self.validateDirectory(
                at: photosURL,
                canonicalURL: photosURL,
                within: resolvedRootURL,
                pathDescription: Self.photosDirectoryName
            )
        }

        self.rootURL = resolvedRootURL
        self.photosURL = photosURL
    }

    static func makeDefault() throws -> FilePhotoLibrary {
        let fileManager = FileManager.default
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let applicationDirectoryName = Bundle.main.bundleIdentifier ?? "LifeNotes"
        let rootURL = applicationSupportURL
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
            .appendingPathComponent("Media", isDirectory: true)
        return try FilePhotoLibrary(rootURL: rootURL)
    }

    func importPhoto(
        id: UUID,
        data: Data,
        contentTypeIdentifier: String?
    ) async throws -> ImportedPhoto {
        guard data.count <= Self.maximumImageByteCount else {
            throw PhotoLibraryError.imageExceedsMaximumByteCount
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeNotesPhotoImport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL)

        return try await importPhoto(
            id: id,
            fileURL: temporaryURL,
            contentTypeIdentifier: contentTypeIdentifier
        )
    }

    func importPhoto(
        id: UUID,
        fileURL: URL,
        contentTypeIdentifier: String?
    ) async throws -> ImportedPhoto {
        try validatePhotosDirectory()
        let sourceURL = fileURL.standardizedFileURL
        _ = try validatedSourceByteCount(at: sourceURL)
        let declaredContentType = try declaredImageContentType(
            identifier: contentTypeIdentifier
        )

        let directoryName = id.uuidString
        let photoDirectoryURL = photosURL.appendingPathComponent(
            directoryName,
            isDirectory: true
        ).standardizedFileURL
        let fileManager = FileManager.default
        if Self.itemExistsIncludingSymbolicLink(at: photoDirectoryURL) {
            if Self.isSymbolicLink(at: photoDirectoryURL) {
                throw PhotoLibraryError.unsafeStoragePath(
                    "\(Self.photosDirectoryName)/\(directoryName)"
                )
            }
            throw PhotoLibraryError.photoAlreadyExists(id)
        }
        try validateCandidateURL(
            photoDirectoryURL,
            within: photosURL,
            pathDescription: "\(Self.photosDirectoryName)/\(directoryName)"
        )

        let stagingFilename = ".original-\(UUID().uuidString).importing"
        let thumbnailFilename = "thumbnail.jpg"
        let stagingURL = photoDirectoryURL
            .appendingPathComponent(stagingFilename)
            .standardizedFileURL
        let thumbnailURL = photoDirectoryURL
            .appendingPathComponent(thumbnailFilename)
            .standardizedFileURL
        var createdDirectory = false

        do {
            try fileManager.createDirectory(
                at: photoDirectoryURL,
                withIntermediateDirectories: false
            )
            createdDirectory = true
            try validatePhotoDirectory(photoDirectoryURL, id: id)
            try validateCandidateURL(
                stagingURL,
                within: photoDirectoryURL,
                pathDescription: "\(Self.photosDirectoryName)/\(directoryName)/\(stagingFilename)"
            )
            try validateCandidateURL(
                thumbnailURL,
                within: photoDirectoryURL,
                pathDescription: "\(Self.photosDirectoryName)/\(directoryName)/\(thumbnailFilename)"
            )

            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            let byteCount = try validatedSourceByteCount(at: stagingURL)
            let image = try validatedImage(
                fileURL: stagingURL,
                declaredContentType: declaredContentType
            )
            let filenameExtension = try filenameExtension(for: image.contentType)
            let originalFilename = "original.\(filenameExtension)"
            let originalURL = photoDirectoryURL
                .appendingPathComponent(originalFilename)
                .standardizedFileURL
            try validateCandidateURL(
                originalURL,
                within: photoDirectoryURL,
                pathDescription: "\(Self.photosDirectoryName)/\(directoryName)/\(originalFilename)"
            )
            let thumbnailData = try makePreviewData(
                from: image.source,
                maxPixelSize: Self.thumbnailMaxPixelSize
            )

            try fileManager.moveItem(at: stagingURL, to: originalURL)
            try thumbnailData.write(to: thumbnailURL, options: .atomic)

            let relativeDirectory = "\(Self.photosDirectoryName)/\(directoryName)"
            return ImportedPhoto(
                id: id,
                contentTypeIdentifier: image.contentType.identifier,
                pixelWidth: image.displayPixelWidth,
                pixelHeight: image.displayPixelHeight,
                byteCount: byteCount,
                originalRelativePath: "\(relativeDirectory)/\(originalFilename)",
                thumbnailRelativePath: "\(relativeDirectory)/\(thumbnailFilename)"
            )
        } catch {
            if createdDirectory {
                try? removeDirectoryIfStillSafe(photoDirectoryURL, id: id)
            }
            throw error
        }
    }

    func removePhoto(_ photo: ImportedPhoto) async throws {
        try validatePhotosDirectory()
        let photoDirectoryURL = photosURL.appendingPathComponent(
            photo.id.uuidString,
            isDirectory: true
        ).standardizedFileURL
        let fileManager = FileManager.default
        guard Self.itemExistsIncludingSymbolicLink(at: photoDirectoryURL) else {
            return
        }
        try validatePhotoDirectory(photoDirectoryURL, id: photo.id)
        try fileManager.removeItem(at: photoDirectoryURL)
    }

    func data(for photo: ImportedPhoto) async throws -> Data {
        try await data(for: photo.originalRelativePath)
    }

    func data(for relativePath: String) async throws -> Data {
        let fileURL = try resolvedURL(for: relativePath)
        return try Data(contentsOf: fileURL, options: .mappedIfSafe)
    }

    func previewData(
        for relativePath: String,
        maxPixelSize: Int
    ) async throws -> Data {
        guard maxPixelSize > 0 else {
            throw PhotoLibraryError.invalidPreviewMaxPixelSize(maxPixelSize)
        }
        let fileURL = try resolvedURL(for: relativePath)
        _ = try validatedSourceByteCount(at: fileURL)
        let image = try validatedImage(
            fileURL: fileURL,
            declaredContentType: nil
        )
        return try makePreviewData(
            from: image.source,
            maxPixelSize: maxPixelSize
        )
    }

    func removeUnreferencedPhotos(
        keeping photoIDs: Set<UUID>,
        olderThan: Date
    ) async throws {
        try validatePhotosDirectory()
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ]
        let contents = try FileManager.default.contentsOfDirectory(
            at: photosURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        for itemURL in contents {
            let directoryName = itemURL.lastPathComponent
            guard
                let id = UUID(uuidString: directoryName),
                id.uuidString.caseInsensitiveCompare(directoryName) == .orderedSame
            else {
                continue
            }
            let values: URLResourceValues
            do {
                values = try itemURL.resourceValues(forKeys: resourceKeys)
            } catch {
                continue
            }
            guard
                values.isSymbolicLink != true,
                values.isDirectory == true,
                let modificationDate = values.contentModificationDate,
                modificationDate < olderThan,
                !photoIDs.contains(id)
            else {
                continue
            }

            try validatePhotoDirectory(itemURL.standardizedFileURL, id: id)
            try FileManager.default.removeItem(at: itemURL)
        }
    }

    private func declaredImageContentType(identifier: String?) throws -> UTType? {
        if let identifier {
            guard
                let contentType = UTType(identifier),
                contentType.conforms(to: .image)
            else {
                throw PhotoLibraryError.invalidContentType(identifier)
            }
            return contentType
        }
        return nil
    }

    private func validatedSourceByteCount(at fileURL: URL) throws -> Int64 {
        guard fileURL.isFileURL else {
            throw PhotoLibraryError.invalidImage
        }
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [
                .isSymbolicLinkKey,
                .isRegularFileKey,
                .fileSizeKey
            ])
        } catch {
            throw PhotoLibraryError.invalidImage
        }
        guard
            values.isSymbolicLink != true,
            values.isRegularFile == true,
            let fileSize = values.fileSize,
            fileSize >= 0
        else {
            throw PhotoLibraryError.invalidImage
        }
        guard fileSize <= Self.maximumImageByteCount else {
            throw PhotoLibraryError.imageExceedsMaximumByteCount
        }
        return Int64(fileSize)
    }

    private func validatedImage(
        fileURL: URL,
        declaredContentType: UTType?
    ) throws -> ValidatedImage {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard
            let source = CGImageSourceCreateWithURL(
                fileURL as CFURL,
                sourceOptions as CFDictionary
            ),
            CGImageSourceGetCount(source) > 0,
            let detectedTypeIdentifier = CGImageSourceGetType(source) as String?,
            let detectedType = UTType(detectedTypeIdentifier),
            detectedType.conforms(to: .image)
        else {
            throw PhotoLibraryError.invalidImage
        }

        if let declaredContentType,
           !detectedType.conforms(to: declaredContentType),
           !declaredContentType.conforms(to: detectedType),
           declaredContentType != .image {
            throw PhotoLibraryError.invalidImageMetadata
        }

        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as NSDictionary?,
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0,
            height > 0
        else {
            throw PhotoLibraryError.invalidImageMetadata
        }

        let width64 = Int64(width)
        let height64 = Int64(height)
        guard width64 <= Self.maximumImagePixelCount / height64 else {
            throw PhotoLibraryError.imageExceedsMaximumPixelCount
        }

        let orientation = (
            properties[kCGImagePropertyOrientation] as? NSNumber
        )?.intValue ?? 1
        let swapsDimensions = (5...8).contains(orientation)

        return ValidatedImage(
            source: source,
            contentType: detectedType,
            displayPixelWidth: swapsDimensions ? height : width,
            displayPixelHeight: swapsDimensions ? width : height
        )
    }

    private func filenameExtension(for contentType: UTType) throws -> String {
        guard
            let filenameExtension = contentType.preferredFilenameExtension?.lowercased(),
            !filenameExtension.isEmpty,
            filenameExtension.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0)
            })
        else {
            throw PhotoLibraryError.unsupportedFilenameExtension(contentType.identifier)
        }
        return filenameExtension
    }

    private func makePreviewData(
        from source: CGImageSource,
        maxPixelSize: Int
    ) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw PhotoLibraryError.invalidImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoLibraryError.invalidImage
        }
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ]
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            destinationOptions as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoLibraryError.invalidImage
        }
        return Data(referencing: output)
    }

    private func validatePhotosDirectory() throws {
        try Self.validateDirectory(
            at: photosURL,
            canonicalURL: photosURL,
            within: rootURL,
            pathDescription: Self.photosDirectoryName
        )
    }

    private func validatePhotoDirectory(_ url: URL, id: UUID) throws {
        let pathDescription = "\(Self.photosDirectoryName)/\(id.uuidString)"
        try Self.validateDirectory(
            at: url,
            canonicalURL: url.standardizedFileURL,
            within: photosURL,
            pathDescription: pathDescription
        )
        guard Self.hasSamePath(url.deletingLastPathComponent(), photosURL) else {
            throw PhotoLibraryError.unsafeStoragePath(pathDescription)
        }
    }

    private func validateCandidateURL(
        _ url: URL,
        within directoryURL: URL,
        pathDescription: String
    ) throws {
        let standardizedURL = url.standardizedFileURL
        guard
            !Self.itemExistsIncludingSymbolicLink(at: standardizedURL),
            Self.hasSamePath(
                standardizedURL.resolvingSymlinksInPath(),
                standardizedURL
            ),
            Self.isStrictDescendant(standardizedURL, of: directoryURL)
        else {
            throw PhotoLibraryError.unsafeStoragePath(pathDescription)
        }
    }

    private func removeDirectoryIfStillSafe(_ url: URL, id: UUID) throws {
        try validatePhotosDirectory()
        try validatePhotoDirectory(url, id: id)
        try FileManager.default.removeItem(at: url)
    }

    private func resolvedURL(for relativePath: String) throws -> URL {
        let path = relativePath as NSString
        let components = path.pathComponents
        guard
            !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !components.contains(".."),
            !components.contains("."),
            !components.contains("/")
        else {
            throw PhotoLibraryError.invalidRelativePath(relativePath)
        }

        let candidateURL = rootURL
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootComponents = rootURL.pathComponents
        let candidateComponents = candidateURL.pathComponents
        guard
            candidateComponents.count > rootComponents.count,
            Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw PhotoLibraryError.invalidRelativePath(relativePath)
        }
        return candidateURL
    }

    private static func validateDirectory(
        at url: URL,
        canonicalURL: URL,
        within parentURL: URL,
        pathDescription: String
    ) throws {
        let standardizedURL = url.standardizedFileURL
        guard itemExistsIncludingSymbolicLink(at: standardizedURL) else {
            throw PhotoLibraryError.unsafeStoragePath(pathDescription)
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: standardizedURL.path
        )
        guard
            attributes[.type] as? FileAttributeType == .typeDirectory,
            !isSymbolicLink(at: standardizedURL),
            hasSamePath(
                standardizedURL.resolvingSymlinksInPath(),
                canonicalURL
            ),
            isStrictDescendant(canonicalURL, of: parentURL)
        else {
            throw PhotoLibraryError.unsafeStoragePath(pathDescription)
        }
    }

    private static func itemExistsIncludingSymbolicLink(at url: URL) -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            return values.isSymbolicLink == true
        } catch {
            return false
        }
    }

    private static func isStrictDescendant(_ url: URL, of parentURL: URL) -> Bool {
        let parentComponents = parentURL.standardizedFileURL.pathComponents
        let candidateComponents = url.standardizedFileURL.pathComponents
        return candidateComponents.count > parentComponents.count
            && Array(candidateComponents.prefix(parentComponents.count)) == parentComponents
    }

    private static func hasSamePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.pathComponents == rhs.standardizedFileURL.pathComponents
    }
}

private struct ValidatedImage {
    let source: CGImageSource
    let contentType: UTType
    let displayPixelWidth: Int
    let displayPixelHeight: Int
}
