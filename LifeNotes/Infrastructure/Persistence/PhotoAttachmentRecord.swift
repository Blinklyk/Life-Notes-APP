import Foundation
import SwiftData

@Model
final class PhotoAttachmentRecord {
    @Attribute(.unique) var id: UUID
    var entryID: UUID
    var userID: UUID
    var dayKeyRawValue: Int
    var sortIndex: Int
    var annotationText: String
    var contentTypeIdentifier: String
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int64
    var originalRelativePath: String
    var thumbnailRelativePath: String

    init(
        id: UUID,
        entryID: UUID,
        userID: UUID,
        dayKeyRawValue: Int,
        sortIndex: Int,
        annotationText: String,
        contentTypeIdentifier: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int64,
        originalRelativePath: String,
        thumbnailRelativePath: String
    ) {
        self.id = id
        self.entryID = entryID
        self.userID = userID
        self.dayKeyRawValue = dayKeyRawValue
        self.sortIndex = sortIndex
        self.annotationText = annotationText
        self.contentTypeIdentifier = contentTypeIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.originalRelativePath = originalRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
    }

    func domainAttachment() -> PhotoAttachment {
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
