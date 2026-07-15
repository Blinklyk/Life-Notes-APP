import Foundation
import XCTest
@testable import LifeNotes

final class LocalJournalGeneratorTests: XCTestCase {
    func testEmptyEntriesFailExplicitly() async throws {
        let generator = LocalJournalGenerator()
        let day = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 15))

        do {
            _ = try await generator.generate(
                JournalGenerationRequest(dayKey: day, entries: [], style: .natural)
            )
            XCTFail("空素材不应生成日记")
        } catch let error as JournalGenerationError {
            XCTAssertEqual(error, .emptyEntries)
        }
    }

    func testGeneratorUsesOnlyTextAnnotationsTranscriptsCountsAndPhotoSnapshots() async throws {
        let day = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 15))
        let laterPhoto = makePhoto(idSuffix: 2, sortIndex: 0, annotation: "晚霞映在水面")
        let earlierPhoto = makePhoto(idSuffix: 1, sortIndex: 1, annotation: "树下的长椅")
        let entries = [
            makeEntry(
                idSuffix: 2,
                createdAt: Date(timeIntervalSince1970: 200),
                text: "傍晚沿河走了一段。",
                photos: [laterPhoto],
                voices: [makeVoice(idSuffix: 2, transcript: "回家前买了面包。")]
            ),
            makeEntry(
                idSuffix: 1,
                createdAt: Date(timeIntervalSince1970: 100),
                text: "上午整理了书桌。",
                photos: [earlierPhoto],
                voices: [
                    makeVoice(idSuffix: 1, transcript: "窗外很安静。"),
                    makeVoice(idSuffix: 3, transcript: "   ")
                ]
            )
        ]
        let generator = LocalJournalGenerator()

        let draft = try await generator.generate(
            JournalGenerationRequest(dayKey: day, entries: entries, style: .natural)
        )

        XCTAssertEqual(draft.title, "7 月 15 日随心日记")
        XCTAssertEqual(draft.sourceEntryCount, 2)
        XCTAssertEqual(draft.generatorIdentifier, "local.rule-based.v1")
        XCTAssertEqual(draft.sourceFingerprint, try JournalSourceFingerprint.make(entries: entries))

        let text = try XCTUnwrap(draft.blocks.first?.text)
        XCTAssertTrue(text.contains("2 条随心记录、2 张照片、3 段语音"))
        XCTAssertTrue(text.contains("上午整理了书桌。"))
        XCTAssertTrue(text.contains("傍晚沿河走了一段。"))
        XCTAssertTrue(text.contains("树下的长椅"))
        XCTAssertTrue(text.contains("晚霞映在水面"))
        XCTAssertTrue(text.contains("窗外很安静。"))
        XCTAssertTrue(text.contains("回家前买了面包。"))
        XCTAssertFalse(text.contains("original.jpg"))
        XCTAssertFalse(text.contains("public.jpeg"))

        let orderedSourcePhotos = JournalSourceOrdering.entries(entries).flatMap {
            JournalSourceOrdering.photos($0.photos)
        }
        XCTAssertEqual(draft.blocks.dropFirst().compactMap(\.photo), orderedSourcePhotos)
        XCTAssertEqual(
            draft.blocks.dropFirst().compactMap(\.caption),
            ["树下的长椅", "晚霞映在水面"]
        )
    }

    func testStylesChangePresentationWithoutDroppingSourceText() async throws {
        let day = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 15))
        let entry = makeEntry(
            idSuffix: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            text: "今天完成了计划。"
        )
        let generator = LocalJournalGenerator()

        let drafts = try await WritingStyle.allCases.asyncMap { style in
            try await generator.generate(
                JournalGenerationRequest(dayKey: day, entries: [entry], style: style)
            )
        }
        let texts = try drafts.map { try XCTUnwrap($0.blocks.first?.text) }

        XCTAssertEqual(Set(texts).count, WritingStyle.allCases.count)
        XCTAssertTrue(texts.allSatisfy { $0.contains("今天完成了计划。") })
        XCTAssertTrue(drafts.allSatisfy { $0.sourceFingerprint == drafts[0].sourceFingerprint })
    }

    func testPhotoOnlyEntryStillGeneratesGroundedCountAndPhotoBlock() async throws {
        let day = try XCTUnwrap(DayKey(year: 2026, month: 7, day: 15))
        let photo = makePhoto(idSuffix: 1, sortIndex: 0, annotation: "")
        let entry = makeEntry(
            idSuffix: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            text: "",
            photos: [photo]
        )

        let draft = try await LocalJournalGenerator().generate(
            JournalGenerationRequest(dayKey: day, entries: [entry], style: .concise)
        )

        XCTAssertEqual(draft.blocks.first?.text, "1 条随心记录、1 张照片、0 段语音。")
        XCTAssertEqual(draft.blocks.dropFirst().compactMap(\.photo), entry.photos)
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

    private func makeVoice(idSuffix: UInt8, transcript: String) -> VoiceAttachment {
        VoiceAttachment(
            id: uuid(idSuffix),
            entryID: uuid(100),
            sortIndex: Int(idSuffix),
            durationMilliseconds: 2_000,
            transcriptText: transcript,
            transcriptionStatus: transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .failed
                : .completed,
            transcriptionSource: transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : .onDevice,
            sourceLocaleIdentifier: "zh-CN"
        )
    }

    private func uuid(_ suffix: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix))
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        for element in self {
            values.append(try await transform(element))
        }
        return values
    }
}
