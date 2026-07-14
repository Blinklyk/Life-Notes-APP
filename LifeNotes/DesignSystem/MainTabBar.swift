import SwiftUI

enum MainTabSelection {
    case today
    case calendar
}

struct MainTabBar: View {
    let selection: MainTabSelection
    let onToday: () -> Void
    let onNewEntry: () -> Void
    let onCalendar: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(AppTheme.divider)

            HStack(spacing: 0) {
                tabButton(
                    title: "今天",
                    systemImage: "sun.max",
                    isSelected: selection == .today,
                    action: onToday
                )

                Button(action: onNewEntry) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(AppTheme.ink, in: Circle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 64)
                .accessibilityLabel("立即记录")
                .help("立即记录")

                tabButton(
                    title: "日历",
                    systemImage: "calendar",
                    isSelected: selection == .calendar,
                    action: onCalendar
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
    }

    private func tabButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.mutedInk)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
