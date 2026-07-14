import Combine
import Foundation

@MainActor
final class CalendarModel: ObservableObject {
    struct Alert: Identifiable {
        let id = UUID()
        let message: String
    }

    @Published private(set) var month: CalendarMonth
    @Published private(set) var summaries: [DayKey: CalendarDaySummary] = [:]
    @Published private(set) var detail: DayDetail?
    @Published private(set) var currentDayKey: DayKey
    @Published private(set) var isLoadingMonth = false
    @Published private(set) var isLoadingDetail = false
    @Published private(set) var isUpdatingDayState = false
    @Published var alert: Alert?

    private let workspace: any DayWorkspace
    private let userID: UUID
    private let now: @Sendable () -> Date
    private let currentTimeZone: @Sendable () -> TimeZone

    private var requestedMonth: CalendarMonth
    private var requestedDetailDayKey: DayKey?
    private var monthLoadGeneration = 0
    private var detailLoadGeneration = 0
    private var dayStateMutationGeneration = 0
    private var dayStateMutationGenerations: [DayKey: Int] = [:]
    private var dayStatePublicationGenerations: [DayKey: Int] = [:]
    private var locallyPublishedDayStates: [DayKey: DayState] = [:]

    init(
        workspace: any DayWorkspace,
        userID: UUID,
        now: @escaping @Sendable () -> Date = { Date() },
        currentTimeZone: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent }
    ) {
        self.workspace = workspace
        self.userID = userID
        self.now = now
        self.currentTimeZone = currentTimeZone

        let initialDate = now()
        let initialTimeZone = currentTimeZone()
        let initialDayKey = DayKey(containing: initialDate, in: initialTimeZone)
        let initialMonth = CalendarMonth(containing: initialDate, in: initialTimeZone)
        currentDayKey = initialDayKey
        month = initialMonth
        requestedMonth = initialMonth
    }

    func loadMonth(showError: Bool = true) async {
        updateCurrentDayKey()
        requestedMonth = month
        await loadMonth(month, showError: showError)
    }

    func showPreviousMonth() async {
        updateCurrentDayKey()
        guard let targetMonth = requestedMonth.previous else {
            return
        }
        requestedMonth = targetMonth
        await loadMonth(targetMonth, showError: true)
    }

    func showNextMonth() async {
        updateCurrentDayKey()
        guard let targetMonth = requestedMonth.next else {
            return
        }
        requestedMonth = targetMonth
        await loadMonth(targetMonth, showError: true)
    }

    func showCurrentMonth() async {
        let date = now()
        let timeZone = currentTimeZone()
        currentDayKey = DayKey(containing: date, in: timeZone)
        let targetMonth = CalendarMonth(containing: date, in: timeZone)
        requestedMonth = targetMonth
        await loadMonth(targetMonth, showError: true)
    }

    func loadDetail(for day: DayKey, showError: Bool = true) async {
        if requestedDetailDayKey != day {
            invalidateDayStateMutation()
        }
        requestedDetailDayKey = day
        detailLoadGeneration += 1
        let generation = detailLoadGeneration
        let stateGeneration = dayStatePublicationGenerations[day, default: 0]
        isLoadingDetail = true
        defer {
            if detailLoadGeneration == generation {
                isLoadingDetail = false
            }
        }

        do {
            let loadedDetail = try await workspace.dayDetail(for: day, userID: userID)
            guard detailLoadGeneration == generation else {
                return
            }
            guard loadedDetail.dayKey == day, loadedDetail.state.dayKey == day else {
                throw CalendarModelError.invalidDayDetail
            }

            let publishedDetail: DayDetail
            if dayStatePublicationGenerations[day, default: 0] != stateGeneration,
               let localState = locallyPublishedDayStates[day] {
                publishedDetail = DayDetail(
                    dayKey: day,
                    entries: loadedDetail.entries,
                    state: localState
                )
            } else {
                publishedDetail = loadedDetail
            }

            detail = publishedDetail
            synchronizeSummary(with: publishedDetail)
        } catch {
            guard detailLoadGeneration == generation else {
                return
            }
            requestedDetailDayKey = detail?.dayKey
            if showError {
                alert = Alert(message: "暂时无法读取当天详情，请稍后重试。")
            }
        }
    }

    func setFeeling(_ feeling: DailyFeeling?) async {
        guard
            !isUpdatingDayState,
            let currentDetail = detail,
            requestedDetailDayKey == currentDetail.dayKey,
            currentDetail.state.feeling != feeling
        else {
            return
        }

        let dayKey = currentDetail.dayKey
        let mutation = beginDayStateMutation(for: dayKey)
        defer { finishDayStateMutation(mutation.busyGeneration) }

        do {
            let updatedState = try await workspace.setFeeling(
                feeling,
                for: dayKey,
                userID: userID,
                updatedAt: now()
            )
            guard
                dayStateMutationGenerations[dayKey] == mutation.dayGeneration,
                updatedState.dayKey == dayKey
            else {
                return
            }
            publish(updatedState, for: dayKey)
        } catch {
            guard
                dayStateMutationGenerations[dayKey] == mutation.dayGeneration,
                detail?.dayKey == dayKey
            else {
                return
            }
            alert = Alert(message: "暂时无法保存每日感受，请稍后重试。")
        }
    }

    func setImportant(_ isImportant: Bool) async {
        guard
            !isUpdatingDayState,
            let currentDetail = detail,
            requestedDetailDayKey == currentDetail.dayKey,
            currentDetail.state.isImportant != isImportant
        else {
            return
        }

        let dayKey = currentDetail.dayKey
        let mutation = beginDayStateMutation(for: dayKey)
        defer { finishDayStateMutation(mutation.busyGeneration) }

        do {
            let updatedState = try await workspace.setImportant(
                isImportant,
                for: dayKey,
                userID: userID,
                updatedAt: now()
            )
            guard
                dayStateMutationGenerations[dayKey] == mutation.dayGeneration,
                updatedState.dayKey == dayKey
            else {
                return
            }
            publish(updatedState, for: dayKey)
        } catch {
            guard
                dayStateMutationGenerations[dayKey] == mutation.dayGeneration,
                detail?.dayKey == dayKey
            else {
                return
            }
            alert = Alert(message: "暂时无法保存重要日标记，请稍后重试。")
        }
    }

    private func loadMonth(
        _ targetMonth: CalendarMonth,
        showError: Bool
    ) async {
        monthLoadGeneration += 1
        let generation = monthLoadGeneration
        let stateGenerations = dayStatePublicationGenerations
        isLoadingMonth = true
        defer {
            if monthLoadGeneration == generation {
                isLoadingMonth = false
            }
        }

        do {
            let loadedSummaries = try await workspace.daySummaries(
                from: targetMonth.gridDays.first!,
                through: targetMonth.gridDays.last!,
                userID: userID
            )
            guard monthLoadGeneration == generation else {
                return
            }

            var loadedByDay: [DayKey: CalendarDaySummary] = [:]
            for summary in loadedSummaries where isVisible(summary.dayKey, in: targetMonth) {
                loadedByDay[summary.dayKey] = summary
            }
            mergeLocallyPublishedDayStates(
                into: &loadedByDay,
                for: targetMonth,
                generationsAtLoadStart: stateGenerations
            )

            if month != targetMonth {
                invalidateDetail()
            }
            month = targetMonth
            requestedMonth = targetMonth
            summaries = loadedByDay
        } catch {
            guard monthLoadGeneration == generation else {
                return
            }
            requestedMonth = month
            if showError {
                alert = Alert(message: "暂时无法读取日历，请稍后重试。")
            }
        }
    }

    private func updateCurrentDayKey() {
        currentDayKey = DayKey(containing: now(), in: currentTimeZone())
    }

    private func beginDayStateMutation(for day: DayKey) -> DayStateMutationToken {
        dayStateMutationGeneration += 1
        dayStateMutationGenerations[day, default: 0] += 1
        isUpdatingDayState = true
        return DayStateMutationToken(
            busyGeneration: dayStateMutationGeneration,
            dayGeneration: dayStateMutationGenerations[day, default: 0]
        )
    }

    private func finishDayStateMutation(_ generation: Int) {
        if dayStateMutationGeneration == generation {
            isUpdatingDayState = false
        }
    }

    private func invalidateDayStateMutation() {
        dayStateMutationGeneration += 1
        isUpdatingDayState = false
    }

    private func invalidateDetail() {
        detailLoadGeneration += 1
        isLoadingDetail = false
        requestedDetailDayKey = nil
        detail = nil
        invalidateDayStateMutation()
    }

    private func publish(_ state: DayState, for day: DayKey) {
        dayStatePublicationGenerations[day, default: 0] += 1
        locallyPublishedDayStates[day] = state
        if let currentDetail = detail, currentDetail.dayKey == day {
            let updatedDetail = DayDetail(
                dayKey: day,
                entries: currentDetail.entries,
                state: state
            )
            detail = updatedDetail
            synchronizeSummary(with: updatedDetail)
        } else {
            synchronizeSummary(with: state, for: day)
        }
    }

    private func synchronizeSummary(with detail: DayDetail) {
        guard isVisible(detail.dayKey, in: month) else {
            return
        }
        let existing = summaries[detail.dayKey]
        let summary = CalendarDaySummary(
            dayKey: detail.dayKey,
            entryCount: detail.entries.count,
            hasJournal: existing?.hasJournal ?? false,
            feeling: detail.state.feeling,
            isImportant: detail.state.isImportant
        )
        setSummary(summary)
    }

    private func synchronizeSummary(with state: DayState, for day: DayKey) {
        guard isVisible(day, in: month) else {
            return
        }
        let existing = summaries[day]
        let summary = CalendarDaySummary(
            dayKey: day,
            entryCount: existing?.entryCount ?? 0,
            hasJournal: existing?.hasJournal ?? false,
            feeling: state.feeling,
            isImportant: state.isImportant
        )
        setSummary(summary)
    }

    private func mergeLocallyPublishedDayStates(
        into summaries: inout [DayKey: CalendarDaySummary],
        for month: CalendarMonth,
        generationsAtLoadStart: [DayKey: Int]
    ) {
        for (day, currentGeneration) in dayStatePublicationGenerations {
            guard
                isVisible(day, in: month),
                currentGeneration != generationsAtLoadStart[day, default: 0],
                let state = locallyPublishedDayStates[day]
            else {
                continue
            }

            let existing = summaries[day] ?? self.summaries[day]
            let entryCount = existing?.entryCount
                ?? (detail?.dayKey == day ? detail?.entries.count : nil)
                ?? 0
            let merged = CalendarDaySummary(
                dayKey: day,
                entryCount: entryCount,
                hasJournal: existing?.hasJournal ?? false,
                feeling: state.feeling,
                isImportant: state.isImportant
            )
            if isMeaningful(merged) {
                summaries[day] = merged
            } else {
                summaries.removeValue(forKey: day)
            }
        }
    }

    private func setSummary(_ summary: CalendarDaySummary) {
        if isMeaningful(summary) {
            summaries[summary.dayKey] = summary
        } else {
            summaries.removeValue(forKey: summary.dayKey)
        }
    }

    private func isMeaningful(_ summary: CalendarDaySummary) -> Bool {
        summary.entryCount > 0
            || summary.hasJournal
            || summary.feeling != nil
            || summary.isImportant
    }

    private func isVisible(_ day: DayKey, in month: CalendarMonth) -> Bool {
        guard let firstDay = month.gridDays.first, let lastDay = month.gridDays.last else {
            return false
        }
        return firstDay <= day && day <= lastDay
    }
}

private struct DayStateMutationToken {
    let busyGeneration: Int
    let dayGeneration: Int
}

private enum CalendarModelError: Error {
    case invalidDayDetail
}
