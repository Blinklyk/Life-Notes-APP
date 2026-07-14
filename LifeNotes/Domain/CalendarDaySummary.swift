import Foundation

struct CalendarDaySummary: Identifiable, Equatable, Hashable, Sendable {
    let dayKey: DayKey
    let entryCount: Int
    let hasJournal: Bool
    let feeling: DailyFeeling?
    let isImportant: Bool

    var id: DayKey { dayKey }

    init(
        dayKey: DayKey,
        entryCount: Int = 0,
        hasJournal: Bool = false,
        feeling: DailyFeeling? = nil,
        isImportant: Bool = false
    ) {
        precondition(entryCount >= 0, "记录数量不能为负数")
        self.dayKey = dayKey
        self.entryCount = entryCount
        self.hasJournal = hasJournal
        self.feeling = feeling
        self.isImportant = isImportant
    }
}
