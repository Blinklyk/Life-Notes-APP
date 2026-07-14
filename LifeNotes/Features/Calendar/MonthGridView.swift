import SwiftUI

struct MonthGridView: View {
    let month: CalendarMonth
    let summaries: [DayKey: CalendarDaySummary]
    let currentDayKey: DayKey
    let isDaySelectionEnabled: Bool
    let onPreviousMonth: () -> Void
    let onNextMonth: () -> Void
    let onSelectDay: (DayKey) -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 36), spacing: 4),
        count: 7
    )
    private let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                monthButton(
                    systemImage: "chevron.left",
                    label: "上个月",
                    isEnabled: month.previous != nil,
                    action: onPreviousMonth
                )

                Spacer(minLength: 8)

                Text(AppDateFormatting.calendarMonthHeading(month))
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 8)

                monthButton(
                    systemImage: "chevron.right",
                    label: "下个月",
                    isEnabled: month.next != nil,
                    action: onNextMonth
                )
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdayLabels, id: \.self) { label in
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedInk)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .accessibilityHidden(true)
                }

                ForEach(month.gridDays, id: \.self) { day in
                    CalendarDayCell(
                        day: day,
                        summary: summaries[day],
                        isInDisplayedMonth: month.contains(day),
                        isToday: day == currentDayKey,
                        isSelectionEnabled: isDaySelectionEnabled,
                        onSelect: { onSelectDay(day) }
                    )
                }
            }
        }
    }

    private func monthButton(
        systemImage: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(AppTheme.mutedInk)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

private struct CalendarDayCell: View {
    let day: DayKey
    let summary: CalendarDaySummary?
    let isInDisplayedMonth: Bool
    let isToday: Bool
    let isSelectionEnabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 3) {
                Text("\(day.day)")
                    .font(.callout.monospacedDigit().weight(isToday ? .bold : .regular))
                    .foregroundStyle(isInDisplayedMonth ? AppTheme.ink : AppTheme.mutedInk)

                marker
                    .frame(width: 20, height: 20)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isToday ? AppTheme.accent : Color.clear,
                        lineWidth: isToday ? 1.5 : 0
                    )
            }
            .overlay(alignment: .topTrailing) {
                if summary?.isImportant == true {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(4)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topLeading) {
                if summary?.hasJournal == true {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppTheme.sage)
                        .padding(4)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .opacity(isInDisplayedMonth ? 1 : 0.48)
        }
        .buttonStyle(.plain)
        .disabled(!isSelectionEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isSelectionEnabled ? "打开日期详情" : "月份加载完成后可以打开")
    }

    @ViewBuilder
    private var marker: some View {
        if let feeling = summary?.feeling {
            FeelingFlower(level: feeling.level, size: 18)
        } else if let summary, summary.entryCount > 0 {
            Circle()
                .fill(AppTheme.accent)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }

    private var accessibilityLabel: String {
        var parts = ["\(day.year) 年 \(day.month) 月 \(day.day) 日"]
        if isToday {
            parts.append("今天")
        }
        if let summary {
            if summary.entryCount > 0 {
                parts.append("\(summary.entryCount) 条记录")
            }
            if let feeling = summary.feeling {
                parts.append("每日感受 \(feeling.label)，第 \(feeling.level) 级，共 5 级")
            }
            if summary.isImportant {
                parts.append("重要的一天")
            }
            if summary.hasJournal {
                parts.append("已有随心日记")
            }
        }
        return parts.joined(separator: "，")
    }
}
