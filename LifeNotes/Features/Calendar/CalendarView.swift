import SwiftUI

struct CalendarView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var calendarModel: CalendarModel
    @ObservedObject var journalModel: JournalModel
    @State private var path: [DayKey] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    MonthGridView(
                        month: calendarModel.month,
                        summaries: calendarModel.summaries,
                        currentDayKey: calendarModel.currentDayKey,
                        isDaySelectionEnabled: !calendarModel.isLoadingMonth,
                        onPreviousMonth: {
                            Task { await calendarModel.showPreviousMonth() }
                        },
                        onNextMonth: {
                            Task { await calendarModel.showNextMonth() }
                        },
                        onSelectDay: { path.append($0) }
                    )

                    monthSummary
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
            .background(AppTheme.paper.ignoresSafeArea())
            .refreshable {
                await calendarModel.loadMonth(showError: true)
            }
            .navigationDestination(for: DayKey.self) { day in
                DayDetailView(
                    dayKey: day,
                    appModel: appModel,
                    calendarModel: calendarModel,
                    journalModel: journalModel
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MainTabBar(
                selection: .calendar,
                onToday: { appModel.showToday() },
                onNewEntry: { appModel.showCapture() },
                onCalendar: {}
            )
        }
        .task {
            await calendarModel.loadMonth(showError: true)
        }
        .alert(item: $calendarModel.alert) { alert in
            Alert(
                title: Text("随心记"),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                titleBlock
                Spacer(minLength: 12)
                currentMonthButton
            }

            VStack(alignment: .leading, spacing: 10) {
                titleBlock
                currentMonthButton
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("回望")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.sage)

            Text("日历")
                .font(.largeTitle.bold())
                .foregroundStyle(AppTheme.ink)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private var currentMonthButton: some View {
        if !calendarModel.month.contains(calendarModel.currentDayKey) {
            Button("回到本月") {
                Task { await calendarModel.showCurrentMonth() }
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .frame(minHeight: 44)
        }
    }

    private var monthSummary: some View {
        let summaries = calendarModel.summaries.values.filter {
            calendarModel.month.contains($0.dayKey)
                && ($0.entryCount > 0 || $0.feeling != nil || $0.isImportant || $0.hasJournal)
        }

        return HStack(spacing: 10) {
            if calendarModel.isLoadingMonth {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: summaries.isEmpty ? "calendar" : "calendar.badge.checkmark")
                    .foregroundStyle(AppTheme.sage)
                    .accessibilityHidden(true)
            }

            Text(summaries.isEmpty ? "这个月还没有留下内容" : "这个月已经留下 \(summaries.count) 个记录日")
                .font(.callout)
                .foregroundStyle(AppTheme.mutedInk)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
