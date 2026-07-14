import Foundation

actor FileCaptureDraftStore: CaptureDraftStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) throws {
        let standardizedFileURL = fileURL.standardizedFileURL
        try FileManager.default.createDirectory(
            at: standardizedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        self.fileURL = standardizedFileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    static func makeDefault() throws -> FileCaptureDraftStore {
        let fileManager = FileManager.default
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let applicationDirectoryName = Bundle.main.bundleIdentifier ?? "LifeNotes"
        let fileURL = applicationSupportURL
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
            .appendingPathComponent("Drafts", isDirectory: true)
            .appendingPathComponent("capture.json", isDirectory: false)
        return try FileCaptureDraftStore(fileURL: fileURL)
    }

    func load() async throws -> CaptureDraftSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let identifierEnvelope = try decoder.decode(
            CaptureDraftIdentifierEnvelope.self,
            from: data
        )
        let snapshot = try decoder.decode(CaptureDraftSnapshot.self, from: data)
        if identifierEnvelope.id == nil {
            try write(snapshot)
        }
        return snapshot
    }

    func save(_ snapshot: CaptureDraftSnapshot) async throws {
        try write(snapshot)
    }

    private func write(_ snapshot: CaptureDraftSnapshot) throws {
        let data = try encoder.encode(snapshot)
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtection]
        )
    }

    func clear() async throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}

private struct CaptureDraftIdentifierEnvelope: Decodable {
    let id: UUID?
}
