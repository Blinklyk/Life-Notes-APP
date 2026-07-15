import SwiftUI

struct CalendarView: View {
    @EnvironmentObject private var privacyGate: PrivacyGateModel
    @ObservedObject var appModel: AppModel
    @ObservedObject var calendarModel: CalendarModel
    @ObservedObject var journalModel: JournalModel
    @ObservedObject var entryLibraryModel: EntryLibraryModel
    @State private var path: [DayKey] = []
    @State private var showsSearch = false
    @State private var entryPendingDeletion: Entry?

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
                    journalModel: journalModel,
                    entryLibraryModel: entryLibraryModel,
                    onEditEntry: beginEditing,
                    onDeleteEntry: requestDeletion
                )
            }
            .navigationDestination(isPresented: $showsSearch) {
                EntrySearchView(
                    appModel: appModel,
                    entryLibraryModel: entryLibraryModel,
                    onEditEntry: beginEditing,
                    onDeleteEntry: requestDeletion
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let notice = entryLibraryModel.notice {
                EntryLibraryNoticeBanner(
                    message: notice.message,
                    onDismiss: { entryLibraryModel.notice = nil }
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
        .sheet(item: editingEntryBinding) { entry in
            EntryEditorView(
                entry: entry,
                model: entryLibraryModel,
                appModel: appModel
            )
        }
        .confirmationDialog(
            "永久删除这条随心记录？",
            isPresented: deletionConfirmationBinding,
            titleVisibility: .visible,
            presenting: entryPendingDeletion
        ) { entry in
            Button("永久删除记录", role: .destructive) {
                delete(entry)
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("原始文字、图片和录音将被删除且无法恢复；已有随心日记及其历史版本会保留。")
        }
        .animation(.easeInOut(duration: 0.2), value: entryLibraryModel.notice)
        .onChange(of: privacyGate.isContentCovered) { _, isCovered in
            if isCovered {
                entryPendingDeletion = nil
                entryLibraryModel.cancelEditingPreparation()
            }
        }
        .onDisappear {
            entryLibraryModel.cancelEditingPreparation()
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                titleBlock
                Spacer(minLength: 12)
                headerActions
            }

            VStack(alignment: .leading, spacing: 10) {
                titleBlock
                headerActions
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 10) {
            currentMonthButton

            Button {
                showsSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索随心记录")
            .help("搜索")
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

    private var editingEntryBinding: Binding<Entry?> {
        Binding(
            get: { entryLibraryModel.editingEntry },
            set: { entry in
                if entry == nil {
                    entryLibraryModel.cancelEditing()
                }
            }
        )
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { entryPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    entryPendingDeletion = nil
                }
            }
        )
    }

    private func beginEditing(_ entry: Entry) {
        appModel.stopVoicePlayback()
        Task {
            await entryLibraryModel.prepareEditing(entry) { entry in
                await appModel.prepareForEntryMutation(entry)
            }
        }
    }

    private func requestDeletion(_ entry: Entry) {
        appModel.stopVoicePlayback()
        entryLibraryModel.cancelEditingPreparation()
        entryPendingDeletion = entry
    }

    private func delete(_ entry: Entry) {
        Task {
            let currentEntry = await appModel.prepareForEntryMutation(entry)
            _ = await entryLibraryModel.deleteEntry(entry, preparedEntry: currentEntry)
        }
    }
}
