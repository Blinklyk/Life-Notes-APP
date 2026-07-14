import Foundation

struct CalendarMonth: Hashable, Comparable, Sendable {
    let year: Int
    let month: Int

    init?(year: Int, month: Int) {
        guard (1...9_999).contains(year), (1...12).contains(month) else {
            return nil
        }

        let calendar = Self.gregorianCalendar()
        guard
            let startDate = Self.date(year: year, month: month, day: 1, calendar: calendar),
            let dayRange = calendar.range(of: .day, in: .month, for: startDate),
            let gridStart = calendar.date(
                byAdding: .day,
                value: -Self.mondayOffset(for: startDate, calendar: calendar),
                to: startDate
            ),
            let gridEnd = calendar.date(byAdding: .day, value: 41, to: gridStart),
            Self.dayKey(for: gridStart, calendar: calendar) != nil,
            Self.dayKey(for: gridEnd, calendar: calendar) != nil,
            DayKey(year: year, month: month, day: dayRange.count) != nil
        else {
            return nil
        }

        self.year = year
        self.month = month
    }

    init(containing instant: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month], from: instant)
        guard
            let year = components.year,
            let month = components.month,
            let value = CalendarMonth(year: year, month: month)
        else {
            preconditionFailure("无法从日期生成日历月份")
        }
        self = value
    }

    var previous: CalendarMonth? {
        month == 1
            ? CalendarMonth(year: year - 1, month: 12)
            : CalendarMonth(year: year, month: month - 1)
    }

    var next: CalendarMonth? {
        month == 12
            ? CalendarMonth(year: year + 1, month: 1)
            : CalendarMonth(year: year, month: month + 1)
    }

    var startDay: DayKey {
        DayKey(year: year, month: month, day: 1)!
    }

    var endDay: DayKey {
        let calendar = Self.gregorianCalendar()
        let startDate = Self.date(year: year, month: month, day: 1, calendar: calendar)!
        let dayCount = calendar.range(of: .day, in: .month, for: startDate)!.count
        return DayKey(year: year, month: month, day: dayCount)!
    }

    var gridDays: [DayKey] {
        let calendar = Self.gregorianCalendar()
        let startDate = Self.date(year: year, month: month, day: 1, calendar: calendar)!
        let offset = Self.mondayOffset(for: startDate, calendar: calendar)
        let gridStart = calendar.date(byAdding: .day, value: -offset, to: startDate)!

        return (0..<42).map { index in
            let date = calendar.date(byAdding: .day, value: index, to: gridStart)!
            return Self.dayKey(for: date, calendar: calendar)!
        }
    }

    func contains(_ day: DayKey) -> Bool {
        day.year == year && day.month == month
    }

    static func < (lhs: CalendarMonth, rhs: CalendarMonth) -> Bool {
        lhs.year != rhs.year ? lhs.year < rhs.year : lhs.month < rhs.month
    }

    private static func gregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        calendar: Calendar
    ) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    private static func mondayOffset(for date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> DayKey? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard
            let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            return nil
        }
        return DayKey(year: year, month: month, day: day)
    }
}
