import Foundation
import XCTest
@testable import LifeNotes

final class JournalDomainTests: XCTestCase {
    func testTextAndPhotoBlocksRemainEditableValueSnapshots() {
        let photo = makePhoto(idSuffix: 1, sortIndex: 0, annotation: "河边晚霞")
        var textBlock = JournalBlock(text: "初稿")
        var photoBlock = JournalBlock(photo: photo)

        textBlock.content = .text("修改后的段落")
        photoBlock.updatePhotoCaption("只修改日记里的说明")

        XCTAssertEqual(textBlock.text, "修改后的段落")
        XCTAssertNil(textBlock.photo)
        XCTAssertEqual(photoBlock.photo, photo)
        XCTAssertEqual(photoBlock.caption, "只修改日记里的说明")
        XCTAssertEqual(photo.annotationText, "河边晚霞")
        XCTAssertNil(photoBlock.text)
    }

    func testVersionAndJournalDayKeepCurrentAndHistoricalVersions() throws {
        let day = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 15))
        let fingerprint = JournalSourceFingerprint(rawValue: String(repeating: "a", count: 64))
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = JournalVersion(
            id: firstID,
            versionNumber: 1,
            title: "第一版",
            blocks: [JournalBlock(text: "生成内容")],
            origin: .generated,
            sourceFingerprint: fingerprint,
            sourceEntryCount: 2,
            generatorIdentifier: "local.rule-based.v1",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let second = JournalVersion(
            id: secondID,
            versionNumber: 2,
            title: "第二版",
            blocks: [JournalBlock(text: "编辑内容")],
            origin: .edited,
            sourceFingerprint: fingerprint,
            sourceEntryCount: 2,
            baseVersionID: firstID,
            generatorIdentifier: "local.rule-based.v1",
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let journal = JournalDay(
            dayKey: day,
            currentVersion: second,
            historyVersions: [first]
        )

        XCTAssertEqual(journal.id, day)
        XCTAssertEqual(journal.currentVersion, second)
        XCTAssertEqual(journal.historyVersions, [first])
        XCTAssertEqual(journal.allVersions, [second, first])
    }

    func testNewVersionCarriesOriginAndSourceMetadata() {
        let baseID = UUID()
        let fingerprint = JournalSourceFingerprint(rawValue: String(repeating: "b", count: 64))
        let createdAt = Date(timeIntervalSince1970: 300)

        let version = NewJournalVersion(
            title: "恢复的版本",
            blocks: [JournalBlock(text: "历史内容")],
            origin: .restored,
            sourceFingerprint: fingerprint,
            sourceEntryCount: 3,
            baseVersionID: baseID,
            generatorIdentifier: "local.rule-based.v1",
            createdAt: createdAt
        )

        XCTAssertEqual(version.origin, .restored)
        XCTAssertEqual(version.sourceFingerprint, fingerprint)
        XCTAssertEqual(version.sourceEntryCount, 3)
        XCTAssertEqual(version.baseVersionID, baseID)
        XCTAssertEqual(version.createdAt, createdAt)
    }

    func testFingerprintIsCanonicalAndChangesWithGeneratedSource() throws {
        let first = makeEntry(
            idSuffix: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            text: "上午散步",
            photos: [makePhoto(idSuffix: 1, sortIndex: 1, annotation: "树影")],
            voices: [makeVoice(idSuffix: 1, sortIndex: 1, transcript: "风有一点凉")]
        )
        let second = makeEntry(
            idSuffix: 2,
            createdAt: Date(timeIntervalSince1970: 200),
            text: "晚上读书"
        )

        let ordered = try JournalSourceFingerprint.make(entries: [first, second])
        let reversed = try JournalSourceFingerprint.make(entries: [second, first])
        let changed = try JournalSourceFingerprint.make(
            entries: [
                first,
                makeEntry(
                    idSuffix: 2,
                    createdAt: Date(timeIntervalSince1970: 200),
                    text: "晚上读完一本书"
                )
            ]
        )

        XCTAssertEqual(ordered, reversed)
        XCTAssertNotEqual(ordered, changed)
        XCTAssertEqual(ordered.rawValue.count, 64)
        XCTAssertTrue(ordered.rawValue.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    private func makeEntry(
        idSuffix: UInt8,
        createdAt: Date,
        text: String,
        photos: [PhotoAttachment] = [],
        voices: [VoiceAttachment] = []
    ) -> Entry {
        let id = uuid(idSuffix)
        return Entry(
            id: id,
            userID: uuid(200),
            dayKey: DayKey(year: 2026, month: 7, day: 15)!,
            createdAt: createdAt,
            updatedAt: createdAt,
            creationTimeZoneIdentifier: "Asia/Shanghai",
            text: text,
            photos: photos.map {
                PhotoAttachment(
                    id: $0.id,
                    entryID: id,
                    sortIndex: $0.sortIndex,
                    annotationText: $0.annotationText,
                    contentTypeIdentifier: $0.contentTypeIdentifier,
                    pixelWidth: $0.pixelWidth,
                    pixelHeight: $0.pixelHeight,
                    byteCount: $0.byteCount,
                    originalRelativePath: $0.originalRelativePath,
                    thumbnailRelativePath: $0.thumbnailRelativePath
                )
            },
            voices: voices.map {
                VoiceAttachment(
                    id: $0.id,
                    entryID: id,
                    targetPhotoID: $0.targetPhotoID,
                    sortIndex: $0.sortIndex,
                    durationMilliseconds: $0.durationMilliseconds,
                    contentTypeIdentifier: $0.contentTypeIdentifier,
                    byteCount: $0.byteCount,
                    originalRelativePath: $0.originalRelativePath,
                    transcriptText: $0.transcriptText,
                    transcriptionStatus: $0.transcriptionStatus,
                    transcriptionSource: $0.transcriptionSource,
                    sourceLocaleIdentifier: $0.sourceLocaleIdentifier,
                    isTranscriptUserEdited: $0.isTranscriptUserEdited
                )
            }
        )
    }

    private func makePhoto(
        idSuffix: UInt8,
        sortIndex: Int,
        annotation: String
    ) -> PhotoAttachment {
        let id = uuid(idSuffix)
        return PhotoAttachment(
            id: id,
            entryID: uuid(100),
            sortIndex: sortIndex,
            annotationText: annotation,
            contentTypeIdentifier: "public.jpeg",
            pixelWidth: 1_200,
            pixelHeight: 800,
            byteCount: 4_096,
            originalRelativePath: "Photos/\(id.uuidString)/original.jpg",
            thumbnailRelativePath: "Photos/\(id.uuidString)/thumbnail.jpg"
        )
    }

    private func makeVoice(
        idSuffix: UInt8,
        sortIndex: Int,
        transcript: String
    ) -> VoiceAttachment {
        VoiceAttachment(
            id: uuid(idSuffix),
            entryID: uuid(100),
            sortIndex: sortIndex,
            durationMilliseconds: 2_000,
            transcriptText: transcript,
            transcriptionStatus: .completed,
            transcriptionSource: .onDevice,
            sourceLocaleIdentifier: "zh-CN"
        )
    }

    private func uuid(_ suffix: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix))
    }
}
