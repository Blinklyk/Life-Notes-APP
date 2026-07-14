import AVFoundation
import Foundation

actor FileAudioLibrary: AudioLibrary {
    static let maximumRecordingDurationMilliseconds = 60_500
    static let maximumAudioByteCount: Int64 = 20 * 1_024 * 1_024

    private let rootURL: URL
    private let audioURL: URL

    init(rootURL: URL) throws {
        let standardizedRootURL = rootURL.standardizedFileURL
        let standardizedAudioURL = standardizedRootURL
            .appendingPathComponent(VoiceAudioStoragePath.directoryName, isDirectory: true)
            .standardizedFileURL

        try Self.ensureDirectory(
            at: standardizedRootURL,
            within: standardizedRootURL.deletingLastPathComponent(),
            pathDescription: standardizedRootURL.lastPathComponent
        )
        try Self.ensureDirectory(
            at: standardizedAudioURL,
            within: standardizedRootURL,
            pathDescription: VoiceAudioStoragePath.directoryName
        )

        self.rootURL = standardizedRootURL
        self.audioURL = standardizedAudioURL

        try Self.validateDirectory(
            at: standardizedRootURL,
            canonicalURL: standardizedRootURL,
            within: standardizedRootURL.deletingLastPathComponent(),
            pathDescription: standardizedRootURL.lastPathComponent
        )
        try Self.validateDirectory(
            at: standardizedAudioURL,
            canonicalURL: standardizedAudioURL,
            within: standardizedRootURL,
            pathDescription: VoiceAudioStoragePath.directoryName
        )
    }

    static func makeDefault() throws -> FileAudioLibrary {
        let fileManager = FileManager.default
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let applicationDirectoryName = Bundle.main.bundleIdentifier ?? "LifeNotes"
        let applicationDirectoryURL = applicationSupportURL
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
        try ensureDirectory(
            at: applicationDirectoryURL,
            within: applicationSupportURL,
            pathDescription: applicationDirectoryName
        )
        let rootURL = applicationDirectoryURL
            .appendingPathComponent("Media", isDirectory: true)
        return try FileAudioLibrary(rootURL: rootURL)
    }

    func prepareRecording(id: UUID) async throws -> AudioRecordingTarget {
        try validateStorageDirectories()
        let directoryURL = audioDirectoryURL(for: id)
        let fileManager = FileManager.default
        guard !Self.itemExistsIncludingSymbolicLink(at: directoryURL) else {
            throw AudioLibraryError.audioAlreadyExists(id)
        }
        try validateCandidateURL(
            directoryURL,
            within: audioURL,
            pathDescription: relativeDirectoryPath(for: id)
        )

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try validateAudioDirectory(directoryURL, id: id)
            let fileURL = recordingURL(for: id)
            try validateCandidateURL(
                fileURL,
                within: directoryURL,
                pathDescription: relativePath(for: id)
            )
            return AudioRecordingTarget(
                id: id,
                fileURL: fileURL,
                relativePath: relativePath(for: id)
            )
        } catch {
            if Self.itemExistsIncludingSymbolicLink(at: directoryURL),
               !Self.isSymbolicLink(at: directoryURL) {
                try? fileManager.removeItem(at: directoryURL)
            }
            throw error
        }
    }

    func completeRecording(id: UUID) async throws -> ImportedAudio {
        try validateStorageDirectories()
        let directoryURL = audioDirectoryURL(for: id)
        guard Self.itemExistsIncludingSymbolicLink(at: directoryURL) else {
            throw AudioLibraryError.audioMissing(id)
        }
        try validateAudioDirectory(directoryURL, id: id)

        let fileURL = recordingURL(for: id)
        let byteCount = try validatedByteCount(at: fileURL)
        let durationMilliseconds = try validatedDurationMilliseconds(at: fileURL)
        guard durationMilliseconds <= Self.maximumRecordingDurationMilliseconds else {
            throw AudioLibraryError.audioExceedsMaximumDuration
        }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path
        )

        return ImportedAudio(
            id: id,
            durationMilliseconds: durationMilliseconds,
            contentTypeIdentifier: "public.mpeg-4-audio",
            byteCount: byteCount,
            relativePath: relativePath(for: id)
        )
    }

    func playbackURL(for relativePath: String) async throws -> URL {
        let fileURL = try resolvedURL(for: relativePath)
        _ = try validatedByteCount(at: fileURL)
        _ = try validatedDurationMilliseconds(at: fileURL)
        return fileURL
    }

    func removeAudio(id: UUID) async throws {
        try validateStorageDirectories()
        let directoryURL = audioDirectoryURL(for: id)
        guard Self.itemExistsIncludingSymbolicLink(at: directoryURL) else {
            return
        }
        try validateAudioDirectory(directoryURL, id: id)
        try FileManager.default.removeItem(at: directoryURL)
    }

    func removeUnreferencedAudio(
        keeping audioIDs: Set<UUID>,
        olderThan: Date
    ) async throws {
        try validateStorageDirectories()
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ]
        let contents = try FileManager.default.contentsOfDirectory(
            at: audioURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        for itemURL in contents {
            let directoryName = itemURL.lastPathComponent
            guard
                let id = UUID(uuidString: directoryName),
                id.uuidString.caseInsensitiveCompare(directoryName) == .orderedSame,
                !audioIDs.contains(id)
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
                modificationDate < olderThan
            else {
                continue
            }

            try validateAudioDirectory(itemURL.standardizedFileURL, id: id)
            try FileManager.default.removeItem(at: itemURL)
        }
    }

    private func validatedByteCount(at fileURL: URL) throws -> Int64 {
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
        } catch {
            throw AudioLibraryError.invalidAudio
        }
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize > 0
        else {
            throw AudioLibraryError.invalidAudio
        }
        guard Int64(fileSize) <= Self.maximumAudioByteCount else {
            throw AudioLibraryError.audioExceedsMaximumByteCount
        }
        return Int64(fileSize)
    }

    private func validatedDurationMilliseconds(at fileURL: URL) throws -> Int {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw AudioLibraryError.invalidAudio
        }

        let sampleRate = audioFile.processingFormat.sampleRate
        let frameLength = audioFile.length
        guard sampleRate > 0, frameLength > 0 else {
            throw AudioLibraryError.invalidAudio
        }
        let duration = Double(frameLength) / sampleRate
        guard duration.isFinite, duration > 0 else {
            throw AudioLibraryError.invalidAudio
        }
        return max(1, Int((duration * 1_000).rounded()))
    }

    private func validateStorageDirectories() throws {
        try Self.validateDirectory(
            at: rootURL,
            canonicalURL: rootURL,
            within: rootURL.deletingLastPathComponent(),
            pathDescription: rootURL.lastPathComponent
        )
        try Self.validateDirectory(
            at: audioURL,
            canonicalURL: audioURL,
            within: rootURL,
            pathDescription: VoiceAudioStoragePath.directoryName
        )
    }

    private func validateAudioDirectory(_ url: URL, id: UUID) throws {
        let pathDescription = relativeDirectoryPath(for: id)
        try Self.validateDirectory(
            at: url,
            canonicalURL: audioDirectoryURL(for: id),
            within: audioURL,
            pathDescription: pathDescription
        )
        guard Self.hasSamePath(url.deletingLastPathComponent(), audioURL) else {
            throw AudioLibraryError.unsafeStoragePath(pathDescription)
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
            throw AudioLibraryError.unsafeStoragePath(pathDescription)
        }
    }

    private func resolvedURL(for relativePath: String) throws -> URL {
        guard VoiceAudioStoragePath.audioID(from: relativePath) != nil else {
            throw AudioLibraryError.invalidRelativePath(relativePath)
        }
        let candidateURL = rootURL
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        let resolvedURL = candidateURL.resolvingSymlinksInPath()
        guard
            Self.hasSamePath(candidateURL, resolvedURL),
            Self.isStrictDescendant(candidateURL, of: audioURL)
        else {
            throw AudioLibraryError.invalidRelativePath(relativePath)
        }
        return candidateURL
    }

    private func audioDirectoryURL(for id: UUID) -> URL {
        audioURL
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .standardizedFileURL
    }

    private func recordingURL(for id: UUID) -> URL {
        audioDirectoryURL(for: id)
            .appendingPathComponent(VoiceAudioStoragePath.originalFilename, isDirectory: false)
            .standardizedFileURL
    }

    private func relativeDirectoryPath(for id: UUID) -> String {
        "\(VoiceAudioStoragePath.directoryName)/\(id.uuidString)"
    }

    private func relativePath(for id: UUID) -> String {
        VoiceAudioStoragePath.relativePath(for: id)
    }

    private static func validateDirectory(
        at url: URL,
        canonicalURL: URL,
        within parentURL: URL,
        pathDescription: String
    ) throws {
        let standardizedURL = url.standardizedFileURL
        guard itemExistsIncludingSymbolicLink(at: standardizedURL) else {
            throw AudioLibraryError.unsafeStoragePath(pathDescription)
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: standardizedURL.path
        )
        guard
            attributes[.type] as? FileAttributeType == .typeDirectory,
            !isSymbolicLink(at: standardizedURL),
            hasSamePath(standardizedURL.resolvingSymlinksInPath(), canonicalURL),
            isStrictDescendant(canonicalURL, of: parentURL)
        else {
            throw AudioLibraryError.unsafeStoragePath(pathDescription)
        }
    }

    private static func ensureDirectory(
        at url: URL,
        within parentURL: URL,
        pathDescription: String
    ) throws {
        let standardizedURL = url.standardizedFileURL
        let standardizedParentURL = parentURL.standardizedFileURL
        let parentAttributes = try FileManager.default.attributesOfItem(
            atPath: standardizedParentURL.path
        )
        guard
            parentAttributes[.type] as? FileAttributeType == .typeDirectory,
            !isSymbolicLink(at: standardizedParentURL),
            hasSamePath(
                standardizedParentURL.resolvingSymlinksInPath(),
                standardizedParentURL
            ),
            isStrictDescendant(standardizedURL, of: standardizedParentURL)
        else {
            throw AudioLibraryError.unsafeStoragePath(pathDescription)
        }

        if itemExistsIncludingSymbolicLink(at: standardizedURL) {
            try validateDirectory(
                at: standardizedURL,
                canonicalURL: standardizedURL,
                within: standardizedParentURL,
                pathDescription: pathDescription
            )
            return
        }

        guard hasSamePath(
            standardizedURL.resolvingSymlinksInPath(),
            standardizedURL
        ) else {
            throw AudioLibraryError.unsafeStoragePath(pathDescription)
        }
        try FileManager.default.createDirectory(
            at: standardizedURL,
            withIntermediateDirectories: false
        )
        try validateDirectory(
            at: standardizedURL,
            canonicalURL: standardizedURL,
            within: standardizedParentURL,
            pathDescription: pathDescription
        )
    }

    private static func itemExistsIncludingSymbolicLink(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
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
