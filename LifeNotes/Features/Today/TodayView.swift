import SwiftUI

struct TodayView: View {
    @ObservedObject var appModel: AppModel
    @AccessibilityFocusState private var isTitleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TodayHeader(
                    date: appModel.todayDate,
                    timeZone: appModel.todayTimeZone,
                    onNewEntry: { appModel.showCapture() },
                    isTitleFocused: $isTitleFocused
                )

                HStack(alignment: .firstTextBaseline) {
                    Text("随心记录")
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    Spacer(minLength: 12)
                    Text("按时间排列 · \(appModel.entries.count) 条")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedInk)
                }
                .padding(.top, 32)
                .accessibilityElement(children: .combine)

                if appModel.isLoadingToday && appModel.entries.isEmpty {
                    ProgressView("正在读取今天的记录")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 72)
                } else if appModel.entries.isEmpty {
                    TodayEmptyState()
                        .padding(.top, 64)
                } else {
                    EntryTimeline(
                        entries: appModel.entries,
                        timeZone: appModel.todayTimeZone
                    )
                    .padding(.top, 18)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(AppTheme.paper.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            if let notice = appModel.notice {
                Text(notice)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NewEntryBar(onNewEntry: { appModel.showCapture() })
        }
        .animation(.easeInOut(duration: 0.2), value: appModel.notice)
        .task {
            isTitleFocused = true
            await appModel.refreshToday()
        }
    }
}

private struct TodayHeader: View {
    let date: Date
    let timeZone: TimeZone
    let onNewEntry: () -> Void
    let isTitleFocused: AccessibilityFocusState<Bool>.Binding

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                titleBlock
                Spacer(minLength: 12)
                newEntryButton
            }

            VStack(alignment: .leading, spacing: 10) {
                titleBlock
                newEntryButton
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(AppDateFormatting.dayHeading(date, timeZone: timeZone))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.sage)

            Text("今天")
                .font(.largeTitle.bold())
                .foregroundStyle(AppTheme.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused(isTitleFocused)
        }
    }

    private var newEntryButton: some View {
        Button(action: onNewEntry) {
            Image(systemName: "square.and.pencil")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 44, height: 44)
                .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("立即记录")
        .help("立即记录")
    }
}

private struct EntryTimeline: View {
    let entries: [Entry]
    let timeZone: TimeZone

    var body: some View {
        LazyVStack(spacing: 12) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                EntryTimelineRow(
                    entry: entry,
                    timeZone: timeZone,
                    isLast: index == entries.count - 1
                )
            }
        }
    }
}

private struct EntryTimelineRow: View {
    let entry: Entry
    let timeZone: TimeZone
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(AppTheme.accent)
                    .frame(width: 9, height: 9)
                    .overlay {
                        Circle()
                            .stroke(AppTheme.paper, lineWidth: 2)
                    }

                if !isLast {
                    Rectangle()
                        .fill(AppTheme.divider)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 12)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(AppDateFormatting.entryTime(entry.createdAt, timeZone: timeZone))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.sage)

                Text(entry.text)
                    .font(.body)
                    .foregroundStyle(AppTheme.ink)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppTheme.divider.opacity(0.55), lineWidth: 1)
            }
            .shadow(color: AppTheme.ink.opacity(0.04), radius: 10, y: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(AppDateFormatting.accessibleEntryTime(entry.createdAt, timeZone: timeZone))，\(entry.text)"
        )
    }
}

private struct TodayEmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)

            Text("今天还没有随心记录")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)

            Text("这一刻值得留下一点什么。")
                .font(.body)
                .foregroundStyle(AppTheme.mutedInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct NewEntryBar: View {
    let onNewEntry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(AppTheme.divider)

            Button(action: onNewEntry) {
                Label("立即记录", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(AppTheme.ink, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
    }
}
