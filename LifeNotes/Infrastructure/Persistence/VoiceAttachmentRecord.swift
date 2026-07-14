import Foundation
import SwiftData

@Model
final class VoiceAttachmentRecord {
    @Attribute(.unique) var id: UUID
    var entryID: UUID
    var userID: UUID
    var dayKeyRawValue: Int
    var targetPhotoID: UUID?
    var sortIndex: Int
    var durationMilliseconds: Int
    var contentTypeIdentifier: String?
    var byteCount: Int64
    var originalRelativePath: String?
    var transcriptText: String
    var transcriptionStatusRawValue: String
    var transcriptionSourceRawValue: String?
    var isTranscriptUserEdited: Bool
    var sourceLocaleIdentifier: String

    init(
        id: UUID,
        entryID: UUID,
        userID: UUID,
        dayKeyRawValue: Int,
        targetPhotoID: UUID?,
        sortIndex: Int,
        durationMilliseconds: Int,
        contentTypeIdentifier: String?,
        byteCount: Int64,
        originalRelativePath: String?,
        transcriptText: String,
        transcriptionStatusRawValue: String,
        transcriptionSourceRawValue: String? = nil,
        isTranscriptUserEdited: Bool,
        sourceLocaleIdentifier: String = ""
    ) {
        self.id = id
        self.entryID = entryID
        self.userID = userID
        self.dayKeyRawValue = dayKeyRawValue
        self.targetPhotoID = targetPhotoID
        self.sortIndex = sortIndex
        self.durationMilliseconds = durationMilliseconds
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.originalRelativePath = originalRelativePath
        self.transcriptText = transcriptText
        self.transcriptionStatusRawValue = transcriptionStatusRawValue
        self.transcriptionSourceRawValue = transcriptionSourceRawValue
        self.isTranscriptUserEdited = isTranscriptUserEdited
        self.sourceLocaleIdentifier = sourceLocaleIdentifier
    }

    func domainAttachment() throws -> VoiceAttachment {
        if let originalRelativePath,
           VoiceAudioStoragePath.audioID(from: originalRelativePath) != id {
            throw PersistenceMappingError.invalidVoiceStorageReference(
                originalRelativePath
            )
        }
        guard let transcriptionStatus = VoiceTranscriptionStatus(
            rawValue: transcriptionStatusRawValue
        ) else {
            throw PersistenceMappingError.invalidVoiceTranscriptionStatus(
                transcriptionStatusRawValue
            )
        }
        let transcriptionSource: VoiceTranscriptionSource?
        if let transcriptionSourceRawValue {
            guard let parsedSource = VoiceTranscriptionSource(
                rawValue: transcriptionSourceRawValue
            ) else {
                throw PersistenceMappingError.invalidVoiceTranscriptionSource(
                    transcriptionSourceRawValue
                )
            }
            transcriptionSource = parsedSource
        } else {
            transcriptionSource = nil
        }

        return VoiceAttachment(
            id: id,
            entryID: entryID,
            targetPhotoID: targetPhotoID,
            sortIndex: sortIndex,
            durationMilliseconds: durationMilliseconds,
            contentTypeIdentifier: contentTypeIdentifier,
            byteCount: byteCount,
            originalRelativePath: originalRelativePath,
            transcriptText: transcriptText,
            transcriptionStatus: transcriptionStatus,
            transcriptionSource: transcriptionSource,
            sourceLocaleIdentifier: sourceLocaleIdentifier,
            isTranscriptUserEdited: isTranscriptUserEdited
        )
    }
}
