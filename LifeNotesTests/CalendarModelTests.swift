import Foundation
import XCTest
@testable import LifeNotes

@MainActor
final class CalendarModelTests: XCTestCase {
    private let userID = UUID(uuidString: "7B7238D6-8609-4C15-B8BC-7B4FD7E5B001")!
    private let instant = Date(timeIntervalSince1970: 1_768_435_200)
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    func testInitialLoadNavigationAndReturnToCurrentMonthUseFullGridRange() async {
        let currentMonth = expectedMonth
        let previousMonth = currentMonth.previous!
        let nextMonth = currentMonth.next!
        let adjacentDay = currentMonth.gridDays.first!
        let currentSummary = CalendarDaySummary(
            dayKey: expectedDayKey,
            entryCount: 2,
            feeling: .calm
        )
        let adjacentSummary = CalendarDaySummary(dayKey: adjacentDay, isImportant: true)
        let previousSummary = CalendarDaySummary(
            dayKey: previousMonth.startDay,
            entryCount: 1
        )
        let nextSummary = CalendarDaySummary(
            dayKey: nextMonth.startDay,
            hasJournal: true
        )
        let workspace = CalendarModelTestWorkspace(
            summaryResponses: [
                .success([currentSummary, adjacentSummary]),
                .success([previousSummary]),
                .success([currentSummary, adjacentSummary]),
                .success([nextSummary])
            ]
        )
        let clock = CalendarModelTestClock(instant)
        let model = makeModel(workspace: workspace, clock: clock)
        await waitForInitialMonthLoad(model, workspace: workspace)

        XCTAssertEqual(model.month, currentMonth)
        XCTAssertEqual(
            model.summaries,
            [currentSummary.dayKey: currentSummary, adjacentDay: adjacentSummary]
        )

        await model.showPreviousMonth()
        XCTAssertEqual(model.month, previousMonth)
        XCTAssertEqual(model.summaries, [previousSummary.dayKey: previousSummary])

        await model.showNextMonth()
        XCTAssertEqual(model.month, currentMonth)

        let nextMonthDate = makeDate(
            year: nextMonth.year,
            month: nextMonth.month,
            day: 10
        )
        clock.set(nextMonthDate)
        await model.showCurrentMonth()

        XCTAssertEqual(model.month, nextMonth)
        XCTAssertEqual(model.currentDayKey, DayKey(containing: nextMonthDate, in: timeZone))
        XCTAssertEqual(model.summaries, [nextSummary.dayKey: nextSummary])

        let calls = await workspace.summaryCalls()
        XCTAssertEqual(
            calls,
            [
                makeSummaryCall(for: currentMonth),
                makeSummaryCall(for: previousMonth),
                makeSummaryCall(for: currentMonth),
                makeSummaryCall(for: nextMonth)
            ]
        )
    }

    func testRapidMonthNavigationDropsLateResultsAndFailurePreservesPublishedMonth() async {
        let currentMonth = expectedMonth
        let nextMonth = currentMonth.next!
        let followingMonth = nextMonth.next!
        let initialSummary = CalendarDaySummary(dayKey: expectedDayKey, entryCount: 1)
        let lateSummary = CalendarDaySummary(dayKey: nextMonth.startDay, entryCount: 2)
        let latestSummary = CalendarDaySummary(
            dayKey: followingMonth.startDay,
            entryCount: 3,
            isImportant: true
        )
        let workspace = CalendarModelTestWorkspace(
            summaryResponses: [.success([initialSummary])]
        )
        let model = makeModel(workspace: workspace)
        await waitForInitialMonthLoad(model, workspace: workspace)

        let lateGate = CalendarModelTestGate()
        await workspace.enqueueSummaryResponse(.success([lateSummary], gate: lateGate))
        await workspace.enqueueSummaryResponse(.success([latestSummary]))

        let lateTask = Task {
            await model.showNextMonth()
        }
        await waitUntil { await lateGate.hasWaiter() }
        XCTAssertTrue(model.isLoadingMonth)

        await model.showNextMonth()

        XCTAssertEqual(model.month, followingMonth)
        XCTAssertEqual(model.summaries, [latestSummary.dayKey: latestSummary])
        XCTAssertFalse(model.isLoadingMonth)

        await lateGate.open()
        await lateTask.value

        XCTAssertEqual(model.month, followingMonth)
        XCTAssertEqual(model.summaries, [latestSummary.dayKey: latestSummary])

        await workspace.enqueueSummaryResponse(.failure())
        await model.showPreviousMonth()

        XCTAssertEqual(model.month, followingMonth)
        XCTAssertEqual(model.summaries, [latestSummary.dayKey: latestSummary])
        XCTAssertEqual(model.alert?.message, "暂时无法读取日历，请稍后重试。")
        XCTAssertFalse(model.isLoadingMonth)
    }

    func testRapidDetailSelectionDropsLateResultAndFailureKeepsCurrentDetail() async {
        let dayA = expectedDayKey
        let dayB = DayKey(year: dayA.year, month: dayA.month, day: dayA.day + 1)!
        let dayC = DayKey(year: dayA.year, month: dayA.month, day: dayA.day + 2)!
        let detailA = DayDetail(dayKey: dayA, entries: [], state: DayState(dayKey: dayA))
        let detailB = DayDetail(
            dayKey: dayB,
            entries: [makeEntry(dayKey: dayB, idSuffix: 2)],
            state: DayState(dayKey: dayB, feeling: .happy, isImportant: true)
        )
        let workspace = CalendarModelTestWorkspace(summaryResponses: [.success([])])
        let model = makeModel(workspace: workspace)
        await waitForInitialMonthLoad(model, workspace: workspace)

        let lateGate = CalendarModelTestGate()
        await workspace.enqueueDetailResponse(.success(detailA, gate: lateGate))
        await workspace.enqueueDetailResponse(.success(detailB))

        let lateTask = Task {
            await model.loadDetail(for: dayA)
        }
        await waitUntil { await lateGate.hasWaiter() }
        XCTAssertTrue(model.isLoadingDetail)

        await model.loadDetail(for: dayB)

        XCTAssertEqual(model.detail, detailB)
        XCTAssertFalse(model.isLoadingDetail)

        await lateGate.open()
        await lateTask.value
        XCTAssertEqual(model.detail, detailB)

        await workspace.enqueueDetailResponse(.failure())
        await model.loadDetail(for: dayC)

        XCTAssertEqual(model.detail, detailB)
        XCTAssertEqual(model.alert?.message, "暂时无法读取当天详情，请稍后重试。")
        XCTAssertFalse(model.isLoadingDetail)
    }

    func testHistoricalDayUpdatesSynchronizeDetailAndMonthSummary() async {
        let day = expectedDayKey
        let entries = [
            makeEntry(dayKey: day, idSuffix: 3),
            makeEntry(dayKey: day, idSuffix: 4)
        ]
        let initialState = DayState(
            dayKey: day,
            feeling: .calm,
            isImportant: false,
            feelingUpdatedAt: instant.addingTimeInterval(-120)
        )
        let initialSummary = CalendarDaySummary(
            dayKey: day,
            entryCount: entries.count,
            hasJournal: true,
            feeling: .calm
        )
        let feelingState = DayState(
            dayKey: day,
            feeling: .happy,
            isImportant: false,
            feelingUpdatedAt: instant
        )
        let importantState = DayState(
            dayKey: day,
            feeling: .happy,
            isImportant: true,
            feelingUpdatedAt: instant,
            importantUpdatedAt: instant
        )
        let workspace = CalendarModelTestWorkspace(
            summaryResponses: [.success([initialSummary])],
            detailResponses: [
                .success(DayDetail(dayKey: day, entries: entries, state: initialState))
            ],
            feelingResponses: [.success(feelingState), .failure()],
            importantResponses: [.success(importantState)]
        )
        let model = makeModel(workspace: workspace)
        await waitForInitialMonthLoad(model, workspace: workspace)
        await model.loadDetail(for: day)

        await model.setFeeling(.happy)

        XCTAssertEqual(model.detail?.state, feelingState)
        XCTAssertEqual(
            model.summaries[day],
            CalendarDaySummary(
                dayKey: day,
                entryCount: entries.count,
                hasJournal: true,
                feeling: .happy
            )
        )

        await model.setFeeling(.happy)
        await model.setImportant(true)

        XCTAssertEqual(model.detail?.state, importantState)
        XCTAssertEqual(
            model.summaries[day],
            CalendarDaySummary(
                dayKey: day,
                entryCount: entries.count,
                hasJournal: true,
                feeling: .happy,
                isImportant: true
            )
        )

        await model.setFeeling(.veryLow)

        XCTAssertEqual(model.detail?.state, importantState)
        XCTAssertEqual(model.alert?.message, "暂时无法保存每日感受，请稍后重试。")
        XCTAssertFalse(model.isUpdatingDayState)

        let feelingCalls = await workspace.feelingCalls()
        XCTAssertEqual(feelingCalls.map(\.feeling), [.happy, .veryLow])
        let importantCalls = await workspace.importantCalls()
        XCTAssertEqual(importantCalls.map(\.isImportant), [true])
    }

    func testLateSameDayDetailRefreshKeepsNewStateAndPublishesNewEntries() async {
        let day = expectedDayKey
        let firstEntry = makeEntry(dayKey: day, idSuffix: 5)
        let secondEntry = makeEntry(dayKey: day, idSuffix: 6)
        let initialState = DayState(dayKey: day, feeling: .low, isImportant: true)
        let newState = DayState(
            dayKey: day,
            feeling: .veryHappy,
            isImportant: true,
            feelingUpdatedAt: instant
        )
        let initialSummary = CalendarDaySummary(
            dayKey: day,
            entryCount: 1,
            hasJournal: true,
            feeling: .low,
            isImportant: true
        )
        let refreshGate = CalendarModelTestGate()
        let workspace = CalendarModelTestWorkspace(
            summaryResponses: [.success([initialSummary])],
            detailResponses: [
                .success(
                    DayDetail(dayKey: day, entries: [firstEntry], state: initialState)
                ),
                .success(
                    DayDetail(
                        dayKey: day,
                        entries: [firstEntry, secondEntry],
                        state: initialState
                    ),
                    gate: refreshGate
                )
            ],
            feelingResponses: [.success(newState)]
        )
        let model = makeModel(workspace: workspace)
        await waitForInitialMonthLoad(model, workspace: workspace)
        await model.loadDetail(for: day)

        let refreshTask = Task {
            await model.loadDetail(for: day)
        }
        await waitUntil { await refreshGate.hasWaiter() }

        await model.setFeeling(.veryHappy)
        XCTAssertEqual(model.detail?.state, newState)

        await refreshGate.open()
        await refreshTask.value

        XCTAssertEqual(model.detail?.state, newState)
        XCTAssertEqual(model.detail?.entries, [firstEntry, secondEntry])
        XCTAssertEqual(
            model.summaries[day],
            CalendarDaySummary(
                dayKey: day,
                entryCount: 2,
                hasJournal: true,
                feeling: .veryHappy,
                isImportant: true
            )
        )
    }

    func testLateMonthRefreshKeepsNewStateAndPublishesFreshSummaryMetadata() async {
        let day = expectedDayKey
        let entry = makeEntry(dayKey: day, idSuffix: 7)
        let initialState = DayState(dayKey: day, feeling: .low)
        let feelingState = DayState(
            dayKey: day,
            feeling: .veryHappy,
            feelingUpdatedAt: instant
        )
        let importantState = DayState(
            dayKey: day,
            feeling: .veryHappy,
            isImportant: true,
            feelingUpdatedAt: instant,
            importantUpdatedAt: instant
        )
        let initialSummary = CalendarDaySummary(
            dayKey: day,
            entryCount: 1,
            feeling: .low
        )
        let refreshSummary = CalendarDaySummary(
            dayKey: day,
            entryCount: 3,
            hasJournal: true,
            feeling: .low
        )
        let refreshGate = CalendarModelTestGate()
        let workspace = CalendarModelTestWorkspace(
            summaryResponses: [
                .success([initialSummary]),
                .success([refreshSummary], gate: refreshGate)
            ],
            detailResponses: [
                .success(DayDetail(dayKey: day, entries: [entry], state: initialState))
            ],
            feelingResponses: [.success(feelingState)],
            importantResponses: [.success(importantState)]
        )
        let model = makeModel(workspace: workspace)
        await waitForInitialMonthLoad(model, workspace: workspace)
        await model.loadDetail(for: day)

        let refreshTask = Task {
            await model.loadMonth()
        }
        await waitUntil { await refreshGate.hasWaiter() }

        await model.setFeeling(.veryHappy)
        await model.setImportant(true)

        XCTAssertEqual(model.detail?.state, importantState)
        XCTAssertEqual(
            model.summaries[day],
            CalendarDaySummary(
                dayKey: day,
                entryCount: 1,
                feeling: .veryHappy,
                isImportant: true
            )
        )

        await refreshGate.open()
        await refreshTask.value

        XCTAssertEqual(model.detail?.state, importantState)
        XCTAssertEqual(
            model.summaries[day],
            CalendarDaySummary(
                dayKey: day,
                entryCount: 3,
                hasJournal: true,
                feeling: .veryHappy,
                isImportant: true
            )
        )
        XCTAssertFalse(model.isLoadingMonth)
    }

    func testAdjacentGridDayUpdatesSummaryImmediatelyAndSurvivesLateMonthRefresh() async {
        let month = expectedMonth
        let adjacentDay = month.gridDays.first { !month.contains($0) }!
        let entries = [
            makeEntry(dayKey: adjacentDay, idSuffix: 8),
            makeEntry(dayKey: adjacentDay, idSuffix: 9)
        ]
        let initialState = DayState(dayKey: adjacentDay, feeling: .calm)
        let feelingState = DayState(
            dayKey: adjacentDay,
            feeling: .happy,
            feelingUpdatedAt: instant
        )
        let importantState = DayState(
            dayKey: adjacentDay,
            feeling: .happy,
            isImportant: true,
            feelingUpdatedAt: instant,
            importantUpdatedAt: instant
        )
        let initialSummary = CalendarDaySummary(
            dayKey: adjacentDay,
            entryCount: 1,
            feeling: .calm
        )
        let refreshSummary = CalendarDaySummary(
            dayKey: adjacentDay,
            entryCount: 4,
            hasJournal: true,
            feeling: .calm
        )
        let refreshGate = CalendarModelTestGate()
        let workspace = CalendarModelTestWorkspace(
            summaryResponses: [
                .success([initialSummary]),
                .success([refreshSummary], gate: refreshGate)
            ],
            detailResponses: [
                .success(
                    DayDetail(dayKey: adjacentDay, entries: entries, state: initialState)
                )
            ],
            feelingResponses: [.success(feelingState)],
            importantResponses: [.success(importantState)]
        )
        let model = makeModel(workspace: workspace)
        await waitForInitialMonthLoad(model, workspace: workspace)

        XCTAssertFalse(month.contains(adjacentDay))
        XCTAssertEqual(model.summaries[adjacentDay], initialSummary)

        await model.loadDetail(for: adjacentDay)
        let refreshTask = Task {
            await model.loadMonth()
        }
        await waitUntil { await refreshGate.hasWaiter() }

        await model.setFeeling(.happy)
        await model.setImportant(true)

        XCTAssertEqual(model.detail?.state, importantState)
        XCTAssertEqual(
            model.summaries[adjacentDay],
            CalendarDaySummary(
                dayKey: adjacentDay,
                entryCount: entries.count,
                feeling: .happy,
                isImportant: true
            )
        )

        await refreshGate.open()
        await refreshTask.value

        XCTAssertEqual(
            model.summaries[adjacentDay],
            CalendarDaySummary(
                dayKey: adjacentDay,
                entryCount: 4,
                hasJournal: true,
                feeling: .happy,
                isImportant: true
            )
        )
        XCTAssertFalse(model.isLoadingMonth)
    }

    func testCompletedMutationForPreviousDetailUpdatesItsSummaryWithoutReplacingCurrentDetail() async {
        let dayA = expectedDayKey
        let dayB = DayKey(year: dayA.year, month: dayA.month, day: dayA.day + 1)!
        let entriesA = [
            makeEntry(dayKey: dayA, idSuffix: 10),
            makeEntry(dayKey: dayA, idSuffix: 11)
        ]
        let entryB = makeEntry(dayKey: dayB, idSuffix: 12)
        let initialA = DayState(dayKey: dayA, feeling: .low)
        let updatedA = DayState(
            dayKey: dayA,
            feeling: .happy,
            feelingUpdatedAt: instant
        )
        let stateB = DayState(dayKey: dayB, feeling: .calm, isImportant: true)
        let initialSummaryA = CalendarDaySummary(
            dayKey: dayA,
            entryCount: entriesA.count,
            feeling: .low
        )
        let refreshSummaryA = CalendarDaySummary(
            dayKey: dayA,
            entryCount: 4,
            hasJournal: true,
            feeling: .low
        )
        let monthGate = CalendarModelTestGate()
        let mutationGate = CalendarModelTestGate()
        let detailB = DayDetail(dayKey: dayB, entries: [entryB], state: stateB)
        let workspace = CalendarModelTestWorkspace(
            summaryResponses: [
                .success([initialSummaryA]),
                .success([refreshSummaryA], gate: monthGate)
            ],
            detailResponses: [
                .success(DayDetail(dayKey: dayA, entries: entriesA, state: initialA)),
                .success(detailB)
            ],
            feelingResponses: [.success(updatedA, gate: mutationGate)]
        )
        let model = makeModel(workspace: workspace)
        await waitForInitialMonthLoad(model, workspace: workspace)
        await model.loadDetail(for: dayA)

        let monthTask = Task {
            await model.loadMonth()
        }
        await waitUntil { await monthGate.hasWaiter() }

        let mutationTask = Task {
            await model.setFeeling(.happy)
        }
        await waitUntil { await mutationGate.hasWaiter() }
        XCTAssertTrue(model.isUpdatingDayState)

        await model.loadDetail(for: dayB)

        XCTAssertEqual(model.detail, detailB)
        XCTAssertFalse(model.isUpdatingDayState)

        await mutationGate.open()
        await mutationTask.value

        XCTAssertEqual(model.detail, detailB)
        XCTAssertEqual(
            model.summaries[dayA],
            CalendarDaySummary(
                dayKey: dayA,
                entryCount: entriesA.count,
                feeling: .happy
            )
        )
        XCTAssertFalse(model.isUpdatingDayState)
        XCTAssertNil(model.alert)

        await monthGate.open()
        await monthTask.value

        XCTAssertEqual(model.detail, detailB)
        XCTAssertEqual(
            model.summaries[dayA],
            CalendarDaySummary(
                dayKey: dayA,
                entryCount: 4,
                hasJournal: true,
                feeling: .happy
            )
        )
        XCTAssertFalse(model.isUpdatingDayState)
        XCTAssertNil(model.alert)
    }

    func testABALateMutationCannotOverwriteNewerStateOrChangeBusyAndAlert() async {
        let dayA = expectedDayKey
        let dayB = DayKey(year: dayA.year, month: dayA.month, day: dayA.day + 1)!
        let initialA = DayState(dayKey: dayA, feeling: .veryLow)
        let stateB = DayState(dayKey: dayB, feeling: .happy, isImportant: true)
        let returnedA = DayState(dayKey: dayA, feeling: .calm)
        let oldAResult = DayState(
            dayKey: dayA,
            feeling: .low,
            feelingUpdatedAt: instant
        )
        let newerAResult = DayState(
            dayKey: dayA,
            feeling: .veryHappy,
            feelingUpdatedAt: instant.addingTimeInterval(60)
        )
        let oldGate = CalendarModelTestGate()
        let workspace = CalendarModelTestWorkspace(
            summaryResponses: [.success([])],
            detailResponses: [
                .success(DayDetail(dayKey: dayA, entries: [], state: initialA)),
                .success(DayDetail(dayKey: dayB, entries: [], state: stateB)),
                .success(DayDetail(dayKey: dayA, entries: [], state: returnedA))
            ],
            feelingResponses: [
                .success(oldAResult, gate: oldGate),
                .success(newerAResult)
            ]
        )
        let clock = CalendarModelTestClock(instant)
        let model = makeModel(workspace: workspace, clock: clock)
        await waitForInitialMonthLoad(model, workspace: workspace)
        await model.loadDetail(for: dayA)

        let oldTask = Task {
            await model.setFeeling(.low)
        }
        await waitUntil { await oldGate.hasWaiter() }
        XCTAssertTrue(model.isUpdatingDayState)

        await model.loadDetail(for: dayB)
        XCTAssertEqual(model.detail?.dayKey, dayB)
        XCTAssertFalse(model.isUpdatingDayState)

        await model.loadDetail(for: dayA)
        clock.set(instant.addingTimeInterval(60))
        await model.setFeeling(.veryHappy)

        XCTAssertEqual(model.detail?.state, newerAResult)
        XCTAssertEqual(
            model.summaries[dayA],
            CalendarDaySummary(dayKey: dayA, feeling: .veryHappy)
        )
        XCTAssertFalse(model.isUpdatingDayState)
        XCTAssertNil(model.alert)

        await oldGate.open()
        await oldTask.value

        XCTAssertEqual(model.detail?.state, newerAResult)
        XCTAssertEqual(
            model.summaries[dayA],
            CalendarDaySummary(dayKey: dayA, feeling: .veryHappy)
        )
        XCTAssertFalse(model.isUpdatingDayState)
        XCTAssertNil(model.alert)
    }

    private var expectedDayKey: DayKey {
        DayKey(containing: instant, in: timeZone)
    }

    private var expectedMonth: CalendarMonth {
        CalendarMonth(containing: instant, in: timeZone)
    }

    private func makeModel(
        workspace: CalendarModelTestWorkspace,
        clock: CalendarModelTestClock? = nil
    ) -> CalendarModel {
        let clock = clock ?? CalendarModelTestClock(instant)
        let timeZone = self.timeZone
        return CalendarModel(
            workspace: workspace,
            userID: userID,
            now: clock.now,
            currentTimeZone: { timeZone }
        )
    }

    private func makeSummaryCall(for month: CalendarMonth) -> CalendarModelTestSummaryCall {
        CalendarModelTestSummaryCall(
            startDay: month.gridDays.first!,
            endDay: month.gridDays.last!,
            userID: userID
        )
    }

    private func makeEntry(dayKey: DayKey, idSuffix: Int) -> Entry {
        let id = UUID(
            uuid: (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0,
                UInt8(idSuffix / 256), UInt8(idSuffix % 256)
            )
        )
        return Entry(
            id: id,
            userID: userID,
            dayKey: dayKey,
            createdAt: instant.addingTimeInterval(TimeInterval(idSuffix)),
            updatedAt: instant.addingTimeInterval(TimeInterval(idSuffix)),
            creationTimeZoneIdentifier: timeZone.identifier,
            text: "记录 \(idSuffix)"
        )
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return calendar.date(from: components)!
    }

    private func waitForInitialMonthLoad(
        _ model: CalendarModel,
        workspace: CalendarModelTestWorkspace,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await model.loadMonth(showError: false)
        await waitUntil(file: file, line: line) {
            guard !model.isLoadingMonth else {
                return false
            }
            return await workspace.summaryCallCount() == 1
        }
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        for _ in 0..<10_000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("等待异步状态超时", file: file, line: line)
    }
}

private struct CalendarModelTestSummaryCall: Equatable, Sendable {
    let startDay: DayKey
    let endDay: DayKey
    let userID: UUID
}

private struct CalendarModelTestDetailCall: Equatable, Sendable {
    let dayKey: DayKey
    let userID: UUID
}

private struct CalendarModelTestFeelingCall: Equatable, Sendable {
    let feeling: DailyFeeling?
    let dayKey: DayKey
    let userID: UUID
    let updatedAt: Date
}

private struct CalendarModelTestImportantCall: Equatable, Sendable {
    let isImportant: Bool
    let dayKey: DayKey
    let userID: UUID
    let updatedAt: Date
}

private struct CalendarModelTestResponse<Value: Sendable>: Sendable {
    let value: Value?
    let gate: CalendarModelTestGate?
    let fails: Bool

    static func success(
        _ value: Value,
        gate: CalendarModelTestGate? = nil
    ) -> Self {
        Self(value: value, gate: gate, fails: false)
    }

    static func failure(gate: CalendarModelTestGate? = nil) -> Self {
        Self(value: nil, gate: gate, fails: true)
    }
}

private enum CalendarModelTestError: Error {
    case unsupported
    case failed
}

private actor CalendarModelTestWorkspace: DayWorkspace {
    private var summaryResponses: [CalendarModelTestResponse<[CalendarDaySummary]>]
    private var detailResponses: [CalendarModelTestResponse<DayDetail>]
    private var feelingResponses: [CalendarModelTestResponse<DayState>]
    private var importantResponses: [CalendarModelTestResponse<DayState>]
    private var recordedSummaryCalls: [CalendarModelTestSummaryCall] = []
    private var recordedDetailCalls: [CalendarModelTestDetailCall] = []
    private var recordedFeelingCalls: [CalendarModelTestFeelingCall] = []
    private var recordedImportantCalls: [CalendarModelTestImportantCall] = []

    init(
        summaryResponses: [CalendarModelTestResponse<[CalendarDaySummary]>] = [],
        detailResponses: [CalendarModelTestResponse<DayDetail>] = [],
        feelingResponses: [CalendarModelTestResponse<DayState>] = [],
        importantResponses: [CalendarModelTestResponse<DayState>] = []
    ) {
        self.summaryResponses = summaryResponses
        self.detailResponses = detailResponses
        self.feelingResponses = feelingResponses
        self.importantResponses = importantResponses
    }

    func create(
        _ draft: NewEntry,
        userID: UUID,
        context: RecordingContext
    ) async throws -> Entry {
        throw CalendarModelTestError.unsupported
    }

    func entries(for day: DayKey, userID: UUID) async throws -> [Entry] { [] }

    func daySummaries(
        from startDay: DayKey,
        through endDay: DayKey,
        userID: UUID
    ) async throws -> [CalendarDaySummary] {
        recordedSummaryCalls.append(
            CalendarModelTestSummaryCall(
                startDay: startDay,
                endDay: endDay,
                userID: userID
            )
        )
        let response = summaryResponses.isEmpty
            ? .success([])
            : summaryResponses.removeFirst()
        return try await resolve(response)
    }

    func dayDetail(for day: DayKey, userID: UUID) async throws -> DayDetail {
        recordedDetailCalls.append(CalendarModelTestDetailCall(dayKey: day, userID: userID))
        let response = detailResponses.isEmpty
            ? .success(DayDetail(dayKey: day, entries: [], state: DayState(dayKey: day)))
            : detailResponses.removeFirst()
        return try await resolve(response)
    }

    func dayState(for day: DayKey, userID: UUID) async throws -> DayState {
        DayState(dayKey: day)
    }

    func setFeeling(
        _ feeling: DailyFeeling?,
        for day: DayKey,
        userID: UUID,
        updatedAt: Date
    ) async throws -> DayState {
        recordedFeelingCalls.append(
            CalendarModelTestFeelingCall(
                feeling: feeling,
                dayKey: day,
                userID: userID,
                updatedAt: updatedAt
            )
        )
        let response = feelingResponses.isEmpty
            ? .success(DayState(dayKey: day, feeling: feeling, feelingUpdatedAt: updatedAt))
            : feelingResponses.removeFirst()
        return try await resolve(response)
    }

    func setImportant(
        _ isImportant: Bool,
        for day: DayKey,
        userID: UUID,
        updatedAt: Date
    ) async throws -> DayState {
        recordedImportantCalls.append(
            CalendarModelTestImportantCall(
                isImportant: isImportant,
                dayKey: day,
                userID: userID,
                updatedAt: updatedAt
            )
        )
        let response = importantResponses.isEmpty
            ? .success(
                DayState(
                    dayKey: day,
                    isImportant: isImportant,
                    importantUpdatedAt: updatedAt
                )
            )
            : importantResponses.removeFirst()
        return try await resolve(response)
    }

    func hasCommittedDraft(id: UUID, userID: UUID) async throws -> Bool { false }

    func photoIDs(userID: UUID) async throws -> Set<UUID> { [] }

    func allPhotoIDs() async throws -> Set<UUID> { [] }

    func retainedVoiceIDs(userID: UUID) async throws -> Set<UUID> { [] }

    func allRetainedVoiceIDs() async throws -> Set<UUID> { [] }

    func updateVoiceTranscript(
        id: UUID,
        userID: UUID,
        text: String,
        status: VoiceTranscriptionStatus,
        source: VoiceTranscriptionSource?,
        isUserEdited: Bool,
        sourceLocaleIdentifier: String,
        updatedAt: Date
    ) async throws -> VoiceAttachment {
        throw CalendarModelTestError.unsupported
    }

    func enqueueSummaryResponse(
        _ response: CalendarModelTestResponse<[CalendarDaySummary]>
    ) {
        summaryResponses.append(response)
    }

    func enqueueDetailResponse(_ response: CalendarModelTestResponse<DayDetail>) {
        detailResponses.append(response)
    }

    func summaryCalls() -> [CalendarModelTestSummaryCall] { recordedSummaryCalls }

    func summaryCallCount() -> Int { recordedSummaryCalls.count }

    func detailCalls() -> [CalendarModelTestDetailCall] { recordedDetailCalls }

    func feelingCalls() -> [CalendarModelTestFeelingCall] { recordedFeelingCalls }

    func importantCalls() -> [CalendarModelTestImportantCall] { recordedImportantCalls }

    private func resolve<Value: Sendable>(
        _ response: CalendarModelTestResponse<Value>
    ) async throws -> Value {
        if let gate = response.gate {
            await gate.wait()
        }
        guard !response.fails, let value = response.value else {
            throw CalendarModelTestError.failed
        }
        return value
    }
}

private final class CalendarModelTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private actor CalendarModelTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func hasWaiter() -> Bool { !continuations.isEmpty }

    func open() {
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}
