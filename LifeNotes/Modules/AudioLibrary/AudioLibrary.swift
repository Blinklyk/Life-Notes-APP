import Foundation

enum VoiceAudioStoragePath {
    static let directoryName = "Audio"
    static let originalFilename = "original.m4a"

    static func relativePath(for id: UUID) -> String {
        "\(directoryName)/\(id.uuidString)/\(originalFilename)"
    }

    static func audioID(from relativePath: String) -> UUID? {
        let components = (relativePath as NSString).pathComponents
        guard
            components.count == 3,
            components[0] == directoryName,
            components[2] == originalFilename,
            let id = UUID(uuidString: components[1]),
            id.uuidString.caseInsensitiveCompare(components[1]) == .orderedSame,
            relativePath == self.relativePath(for: id)
        else {
            return nil
        }
        return id
    }
}

struct AudioRecordingTarget: Equatable, Sendable {
    let id: UUID
    let fileURL: URL
    let relativePath: String
}

struct ImportedAudio: Equatable, Sendable {
    let id: UUID
    let durationMilliseconds: Int
    let contentTypeIdentifier: String
    let byteCount: Int64
    let relativePath: String
}

enum AudioLibraryError: LocalizedError, Equatable {
    case audioAlreadyExists(UUID)
    case audioMissing(UUID)
    case invalidAudio
    case audioExceedsMaximumByteCount
    case audioExceedsMaximumDuration
    case invalidRelativePath(String)
    case unsafeStoragePath(String)

    var errorDescription: String? {
        switch self {
        case .audioAlreadyExists:
            return "这段录音已经存在。"
        case .audioMissing:
            return "找不到这段录音。"
        case .invalidAudio:
            return "录音文件无法读取。"
        case .audioExceedsMaximumByteCount:
            return "录音文件过大。"
        case .audioExceedsMaximumDuration:
            return "单段录音最长为 60 秒。"
        case .invalidRelativePath, .unsafeStoragePath:
            return "录音存储路径无效。"
        }
    }
}

protocol AudioLibrary: Sendable {
    func prepareRecording(id: UUID) async throws -> AudioRecordingTarget
    func completeRecording(id: UUID) async throws -> ImportedAudio
    func playbackURL(for relativePath: String) async throws -> URL
    func removeAudio(id: UUID) async throws
    func removeUnreferencedAudio(
        keeping audioIDs: Set<UUID>,
        olderThan: Date
    ) async throws
}
