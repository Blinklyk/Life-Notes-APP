import Foundation
import SwiftData
import XCTest
@testable import LifeNotes

@MainActor
final class CalendarPersistenceTests: XCTestCase {
    private let userID = UUID(uuidString: "1B249432-394B-472F-BBE2-E8E69F90C999")!
    private let otherUserID = UUID(uuidString: "AF0F16C7-E122-45E2-9EF5-8EA6C7F8996B")!

    func testSummariesMergeEntriesAndStateIntoSparseSortedDays() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let july4 = day(2026, 7, 4)
        let july7 = day(2026, 7, 7)
        let july9 = day(2026, 7, 9)
        let july12 = day(2026, 7, 12)
        let july20 = day(2026, 7, 20)

        _ = try await createTextEntry("第一条", on: july4, workspace: workspace)
        _ = try await createTextEntry("第二条", on: july4, workspace: workspace)
        _ = try await workspace.setFeeling(
            .low,
            for: july4,
            userID: userID,
            updatedAt: instant(for: july4)
        )
        _ = try await workspace.setImportant(
            true,
            for: july7,
            userID: userID,
            updatedAt: instant(for: july7)
        )
        _ = try await workspace.setFeeling(
            nil,
            for: july9,
            userID: userID,
            updatedAt: instant(for: july9)
        )
        _ = try await createTextEntry("组合状态", on: july12, workspace: workspace)
        _ = try await workspace.setFeeling(
            .calm,
            for: july12,
            userID: userID,
            updatedAt: instant(for: july12)
        )
        _ = try await workspace.setImportant(
            true,
            for: july12,
            userID: userID,
            updatedAt: instant(for: july12).addingTimeInterval(1)
        )
        _ = try await createTextEntry("只有记录", on: july20, workspace: workspace)
        _ = try await createTextEntry(
            "其他用户",
            on: july4,
            userID: otherUserID,
            workspace: workspace
        )
        _ = try await createTextEntry(
            "范围之外",
            on: day(2026, 8, 1),
            workspace: workspace
        )

        let summaries = try await workspace.daySummaries(
            from: day(2026, 7, 1),
            through: day(2026, 7, 31),
            userID: userID
        )

        XCTAssertEqual(
            summaries,
            [
                CalendarDaySummary(dayKey: july4, entryCount: 2, feeling: .low),
                CalendarDaySummary(dayKey: july7, isImportant: true),
                CalendarDaySummary(
                    dayKey: july12,
                    entryCount: 1,
                    feeling: .calm,
                    isImportant: true
                ),
                CalendarDaySummary(dayKey: july20, entryCount: 1),
            ]
        )
        XCTAssertTrue(summaries.allSatisfy { !$0.hasJournal })
    }

    func testSummaryRangeIsInclusiveAndRejectsReversedBounds() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let first = day(2026, 7, 1)
        let last = day(2026, 7, 31)

        _ = try await createTextEntry("第一天", on: first, workspace: workspace)
        _ = try await createTextEntry("最后一天", on: last, workspace: workspace)
        _ = try await createTextEntry(
            "前一天",
            on: day(2026, 6, 30),
            workspace: workspace
        )

        let summaries = try await workspace.daySummaries(
            from: first,
            through: last,
            userID: userID
        )

        XCTAssertEqual(summaries.map(\.dayKey), [first, last])

        do {
            _ = try await workspace.daySummaries(
                from: last,
                through: first,
                userID: userID
            )
            XCTFail("反向日期范围不应执行查询")
        } catch DayWorkspaceError.invalidDayRange {
            // 预期错误。
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }
    }

    func testSummariesRejectInvalidEntryDayKeyInsideNumericRange() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let createdAt = Date(timeIntervalSince1970: 1_770_000_000)
        context.insert(
            EntryRecord(
                id: UUID(),
                userID: userID,
                dayKeyRawValue: 20_260_230,
                createdAt: createdAt,
                updatedAt: createdAt,
                creationTimeZoneIdentifier: "UTC",
                text: "损坏日期"
            )
        )
        try context.save()
        let workspace = SwiftDataDayWorkspace(modelContainer: container)

        do {
            _ = try await workspace.daySummaries(
                from: day(2026, 1, 1),
                through: day(2026, 3, 31),
                userID: userID
            )
            XCTFail("损坏的日期键不应被静默汇总")
        } catch PersistenceMappingError.invalidDayKey(20_260_230) {
            // 预期错误。
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }
    }

    func testSummariesRejectMismatchedDayRecordScope() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let requestedDay = day(2026, 7, 15)
        context.insert(
            DayRecord(
                scopeKey: DayRecord.makeScopeKey(
                    userID: otherUserID,
                    dayKey: requestedDay
                ),
                userID: userID,
                dayKeyRawValue: requestedDay.storageValue,
                feelingRawValue: DailyFeeling.happy.rawValue
            )
        )
        try context.save()
        let workspace = SwiftDataDayWorkspace(modelContainer: container)

        do {
            _ = try await workspace.daySummaries(
                from: day(2026, 7, 1),
                through: day(2026, 7, 31),
                userID: userID
            )
            XCTFail("范围字段不一致的每日状态不应进入月历")
        } catch let PersistenceMappingError.invalidDayRecordScope(value) {
            XCTAssertEqual(
                value,
                DayRecord.makeScopeKey(userID: otherUserID, dayKey: requestedDay)
            )
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }
    }

    func testDayDetailReturnsCompleteAttachmentsAndState() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let requestedDay = day(2026, 7, 12)
        let photoID = UUID(uuidString: "EC62D7C4-D253-428B-B8F8-8D32AE5919A1")!
        let voiceID = UUID(uuidString: "17B6D5A2-E1CF-43AD-B28C-B31D04072E4D")!
        let saved = try await workspace.create(
            NewEntry(
                text: "带完整附件的记录",
                photos: [
                    NewPhotoAttachment(
                        id: photoID,
                        annotationText: "照片批注",
                        contentTypeIdentifier: "public.jpeg",
                        pixelWidth: 1_200,
                        pixelHeight: 800,
                        byteCount: 5_000,
                        originalRelativePath: "Photos/\(photoID.uuidString)/original.jpg",
                        thumbnailRelativePath: "Photos/\(photoID.uuidString)/thumbnail.jpg"
                    )
                ],
                voices: [
                    NewVoiceAttachment(
                        id: voiceID,
                        targetPhotoID: photoID,
                        durationMilliseconds: 2_500,
                        transcriptText: "逐图语音批注",
                        transcriptionStatus: .completed,
                        transcriptionSource: .manual,
                        sourceLocaleIdentifier: "zh-CN",
                        isTranscriptUserEdited: true
                    )
                ]
            ),
            userID: userID,
            context: RecordingContext(
                instant: instant(for: requestedDay),
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
        )
        _ = try await createTextEntry(
            "其他用户同一天",
            on: requestedDay,
            userID: otherUserID,
            workspace: workspace
        )
        let feelingUpdatedAt = instant(for: requestedDay).addingTimeInterval(10)
        let importantUpdatedAt = feelingUpdatedAt.addingTimeInterval(10)
        _ = try await workspace.setFeeling(
            .happy,
            for: requestedDay,
            userID: userID,
            updatedAt: feelingUpdatedAt
        )
        _ = try await workspace.setImportant(
            true,
            for: requestedDay,
            userID: userID,
            updatedAt: importantUpdatedAt
        )

        let detail = try await workspace.dayDetail(for: requestedDay, userID: userID)

        XCTAssertEqual(detail.dayKey, requestedDay)
        XCTAssertEqual(detail.entries, [saved])
        XCTAssertEqual(detail.entries.first?.photos.map(\.id), [photoID])
        XCTAssertEqual(detail.entries.first?.voices.map(\.id), [voiceID])
        XCTAssertEqual(
            detail.state,
            DayState(
                dayKey: requestedDay,
                feeling: .happy,
                isImportant: true,
                feelingUpdatedAt: feelingUpdatedAt,
                importantUpdatedAt: importantUpdatedAt
            )
        )
    }

    func testEmptyDayDetailUsesDefaultState() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let workspace = SwiftDataDayWorkspace(modelContainer: container)
        let requestedDay = day(2026, 7, 30)

        let detail = try await workspace.dayDetail(for: requestedDay, userID: userID)

        XCTAssertEqual(
            detail,
            DayDetail(
                dayKey: requestedDay,
                entries: [],
                state: DayState(dayKey: requestedDay)
            )
        )
    }

    private func createTextEntry(
        _ text: String,
        on day: DayKey,
        userID: UUID? = nil,
        workspace: SwiftDataDayWorkspace
    ) async throws -> Entry {
        try await workspace.create(
            NewEntry(text: text),
            userID: userID ?? self.userID,
            context: RecordingContext(
                instant: instant(for: day),
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
        )
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> DayKey {
        DayKey(year: year, month: month, day: day)!
    }

    private func instant(for day: DayKey) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: day.year,
                month: day.month,
                day: day.day,
                hour: 12
            )
        )!
    }
}
