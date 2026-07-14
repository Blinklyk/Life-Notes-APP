import Foundation

struct DayState: Equatable, Sendable {
    let dayKey: DayKey
    let feeling: DailyFeeling?
    let isImportant: Bool
    let feelingUpdatedAt: Date?
    let importantUpdatedAt: Date?

    init(
        dayKey: DayKey,
        feeling: DailyFeeling? = nil,
        isImportant: Bool = false,
        feelingUpdatedAt: Date? = nil,
        importantUpdatedAt: Date? = nil
    ) {
        self.dayKey = dayKey
        self.feeling = feeling
        self.isImportant = isImportant
        self.feelingUpdatedAt = feelingUpdatedAt
        self.importantUpdatedAt = importantUpdatedAt
    }
}
