import Foundation

struct JournalPhotoBlock: Hashable, Sendable {
    let photo: PhotoAttachment
    var caption: String

    init(photo: PhotoAttachment, caption: String) {
        self.photo = photo
        self.caption = caption
    }
}

enum JournalBlockContent: Hashable, Sendable {
    case text(String)
    case photo(JournalPhotoBlock)
}

struct JournalBlock: Identifiable, Hashable, Sendable {
    let id: UUID
    var content: JournalBlockContent

    init(id: UUID = UUID(), content: JournalBlockContent) {
        self.id = id
        self.content = content
    }

    init(id: UUID = UUID(), text: String) {
        self.init(id: id, content: .text(text))
    }

    init(id: UUID = UUID(), photo: PhotoAttachment, caption: String? = nil) {
        self.init(
            id: id,
            content: .photo(
                JournalPhotoBlock(
                    photo: photo,
                    caption: caption ?? photo.annotationText
                )
            )
        )
    }

    var text: String? {
        guard case let .text(value) = content else {
            return nil
        }
        return value
    }

    var photoBlock: JournalPhotoBlock? {
        guard case let .photo(value) = content else {
            return nil
        }
        return value
    }

    var photo: PhotoAttachment? { photoBlock?.photo }

    var caption: String? { photoBlock?.caption }

    mutating func updatePhotoCaption(_ caption: String) {
        guard var photoBlock else {
            return
        }
        photoBlock.caption = caption
        content = .photo(photoBlock)
    }
}

enum JournalVersionOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case generated
    case edited
    case restored
}

struct JournalSourceFingerprint: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

struct JournalVersion: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let versionNumber: Int
    let title: String
    let blocks: [JournalBlock]
    let origin: JournalVersionOrigin
    let sourceFingerprint: JournalSourceFingerprint
    let sourceEntryCount: Int
    let baseVersionID: UUID?
    let generatorIdentifier: String?
    let createdAt: Date

    init(
        id: UUID,
        versionNumber: Int,
        title: String,
        blocks: [JournalBlock],
        origin: JournalVersionOrigin,
        sourceFingerprint: JournalSourceFingerprint,
        sourceEntryCount: Int,
        baseVersionID: UUID? = nil,
        generatorIdentifier: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.versionNumber = versionNumber
        self.title = title
        self.blocks = blocks
        self.origin = origin
        self.sourceFingerprint = sourceFingerprint
        self.sourceEntryCount = sourceEntryCount
        self.baseVersionID = baseVersionID
        self.generatorIdentifier = generatorIdentifier
        self.createdAt = createdAt
    }
}

struct JournalDay: Identifiable, Equatable, Sendable {
    let dayKey: DayKey
    let currentVersion: JournalVersion
    let historyVersions: [JournalVersion]

    var id: DayKey { dayKey }

    init(
        dayKey: DayKey,
        currentVersion: JournalVersion,
        historyVersions: [JournalVersion] = []
    ) {
        self.dayKey = dayKey
        self.currentVersion = currentVersion
        self.historyVersions = historyVersions
    }

    var allVersions: [JournalVersion] {
        ([currentVersion] + historyVersions).sorted { lhs, rhs in
            if lhs.versionNumber != rhs.versionNumber {
                return lhs.versionNumber > rhs.versionNumber
            }
            return lhs.createdAt > rhs.createdAt
        }
    }
}

struct NewJournalVersion: Equatable, Sendable {
    let id: UUID
    let title: String
    let blocks: [JournalBlock]
    let origin: JournalVersionOrigin
    let sourceFingerprint: JournalSourceFingerprint
    let sourceEntryCount: Int
    let baseVersionID: UUID?
    let generatorIdentifier: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        blocks: [JournalBlock],
        origin: JournalVersionOrigin,
        sourceFingerprint: JournalSourceFingerprint,
        sourceEntryCount: Int,
        baseVersionID: UUID? = nil,
        generatorIdentifier: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.blocks = blocks
        self.origin = origin
        self.sourceFingerprint = sourceFingerprint
        self.sourceEntryCount = sourceEntryCount
        self.baseVersionID = baseVersionID
        self.generatorIdentifier = generatorIdentifier
        self.createdAt = createdAt
    }
}

enum WritingStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case natural
    case concise
    case delicate

    var label: String {
        switch self {
        case .natural:
            return "自然"
        case .concise:
            return "简洁"
        case .delicate:
            return "细腻"
        }
    }
}
