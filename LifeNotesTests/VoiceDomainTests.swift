import Foundation
import XCTest
@testable import LifeNotes

final class VoiceDomainTests: XCTestCase {
    func testRetainedAudioMakesVoiceOnlyEntryValidWithoutTranscript() throws {
        let voiceID = UUID()
        let voice = NewVoiceAttachment(
            id: voiceID,
            durationMilliseconds: 2_400,
            contentTypeIdentifier: "public.mpeg-4-audio",
            byteCount: 1_024,
            originalRelativePath: VoiceAudioStoragePath.relativePath(for: voiceID),
            transcriptionStatus: .failed
        )

        let entry = try NewEntry(text: "", voices: [voice])

        XCTAssertEqual(entry.voices, [voice])
    }

    func testTranscriptOnlyVoiceRequiresNonemptyTranscript() {
        let voice = NewVoiceAttachment(
            durationMilliseconds: 2_400,
            transcriptText: "   ",
            transcriptionStatus: .completed
        )

        XCTAssertThrowsError(try NewEntry(text: "", voices: [voice])) { error in
            XCTAssertEqual(
                error as? EntryValidationError,
                .transcriptOnlyVoiceRequiresTranscript
            )
        }
    }

    func testPhotoVoiceMustReferencePhotoInSameEntry() {
        let voiceID = UUID()
        let voice = NewVoiceAttachment(
            id: voiceID,
            targetPhotoID: UUID(),
            durationMilliseconds: 2_400,
            contentTypeIdentifier: "public.mpeg-4-audio",
            byteCount: 1_024,
            originalRelativePath: VoiceAudioStoragePath.relativePath(for: voiceID)
        )

        XCTAssertThrowsError(try NewEntry(text: "", voices: [voice])) { error in
            XCTAssertEqual(
                error as? EntryValidationError,
                .invalidVoiceTargetPhoto
            )
        }
    }

    func testRetainedAudioPathMustMatchVoiceID() {
        let voice = NewVoiceAttachment(
            id: UUID(),
            durationMilliseconds: 2_400,
            contentTypeIdentifier: "public.mpeg-4-audio",
            byteCount: 1_024,
            originalRelativePath: VoiceAudioStoragePath.relativePath(for: UUID())
        )

        XCTAssertThrowsError(try NewEntry(text: "", voices: [voice])) { error in
            XCTAssertEqual(
                error as? EntryValidationError,
                .invalidVoiceStorageReference
            )
        }
    }
}
