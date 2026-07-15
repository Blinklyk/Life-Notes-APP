import Foundation

enum JournalBlockCodec {
    private static let schemaVersion = 1

    static func encode(_ blocks: [JournalBlock]) throws -> Data {
        guard Set(blocks.map(\.id)).count == blocks.count else {
            throw JournalPersistenceError.invalidBlocksData
        }

        let envelope = Envelope(
            schemaVersion: schemaVersion,
            blocks: blocks.map(BlockSnapshot.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(envelope)
        } catch {
            throw JournalPersistenceError.invalidBlocksData
        }
    }

    static func decode(_ data: Data) throws -> [JournalBlock] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw JournalPersistenceError.invalidBlocksData
        }
        guard envelope.schemaVersion == schemaVersion else {
            throw JournalPersistenceError.invalidBlocksData
        }

        let blocks = try envelope.blocks.map { try $0.domainBlock() }
        guard Set(blocks.map(\.id)).count == blocks.count else {
            throw JournalPersistenceError.invalidBlocksData
        }
        return blocks
    }
}

private struct Envelope: Codable {
    let schemaVersion: Int
    let blocks: [BlockSnapshot]
}

private struct BlockSnapshot: Codable {
    enum Kind: String, Codable {
        case text
        case photo
    }

    let id: UUID
    let kind: Kind
    let text: String?
    let photo: PhotoSnapshot?
    let caption: String?

    init(_ block: JournalBlock) {
        id = block.id
        switch block.content {
        case let .text(value):
            kind = .text
            text = value
            photo = nil
            caption = nil
        case let .photo(value):
            kind = .photo
            text = nil
            photo = PhotoSnapshot(value.photo)
            caption = value.caption
        }
    }

    func domainBlock() throws -> JournalBlock {
        switch kind {
        case .text:
            guard let text, photo == nil, caption == nil else {
                throw JournalPersistenceError.invalidBlocksData
            }
            return JournalBlock(id: id, text: text)
        case .photo:
            guard text == nil, let photo, let caption else {
                throw JournalPersistenceError.invalidBlocksData
            }
            return JournalBlock(id: id, photo: photo.domainPhoto(), caption: caption)
        }
    }
}

private struct PhotoSnapshot: Codable {
    let id: UUID
    let entryID: UUID
    let sortIndex: Int
    let annotationText: String
    let contentTypeIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64
    let originalRelativePath: String
    let thumbnailRelativePath: String

    init(_ photo: PhotoAttachment) {
        id = photo.id
        entryID = photo.entryID
        sortIndex = photo.sortIndex
        annotationText = photo.annotationText
        contentTypeIdentifier = photo.contentTypeIdentifier
        pixelWidth = photo.pixelWidth
        pixelHeight = photo.pixelHeight
        byteCount = photo.byteCount
        originalRelativePath = photo.originalRelativePath
        thumbnailRelativePath = photo.thumbnailRelativePath
    }

    func domainPhoto() -> PhotoAttachment {
        PhotoAttachment(
            id: id,
            entryID: entryID,
            sortIndex: sortIndex,
            annotationText: annotationText,
            contentTypeIdentifier: contentTypeIdentifier,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            byteCount: byteCount,
            originalRelativePath: originalRelativePath,
            thumbnailRelativePath: thumbnailRelativePath
        )
    }
}
