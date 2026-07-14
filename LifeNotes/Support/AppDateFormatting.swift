import Foundation

enum AppDateFormatting {
    static func captureTimestamp(
        _ date: Date,
        timeZone: TimeZone,
        locale: Locale = Locale(identifier: "zh_CN")
    ) -> String {
        formatted(date, format: "M 月 d 日 · EEEE · HH:mm", timeZone: timeZone, locale: locale)
    }

    static func dayHeading(
        _ date: Date,
        timeZone: TimeZone,
        locale: Locale = Locale(identifier: "zh_CN")
    ) -> String {
        formatted(date, format: "M 月 d 日 · EEEE", timeZone: timeZone, locale: locale)
    }

    static func entryTime(
        _ date: Date,
        timeZone: TimeZone,
        locale: Locale = Locale(identifier: "zh_CN")
    ) -> String {
        formatted(date, format: "HH:mm", timeZone: timeZone, locale: locale)
    }

    static func accessibleEntryTime(
        _ date: Date,
        timeZone: TimeZone,
        locale: Locale = Locale(identifier: "zh_CN")
    ) -> String {
        formatted(date, format: "H 点 mm 分", timeZone: timeZone, locale: locale)
    }

    static func calendarDayHeading(
        _ day: DayKey,
        locale: Locale = Locale(identifier: "zh_CN")
    ) -> String {
        guard let date = date(for: day) else {
            return "\(day.year) 年 \(day.month) 月 \(day.day) 日"
        }
        return formatted(
            date,
            format: "yyyy 年 M 月 d 日 · EEEE",
            timeZone: utcTimeZone,
            locale: locale
        )
    }

    static func calendarMonthHeading(_ month: CalendarMonth) -> String {
        "\(month.year) 年 \(month.month) 月"
    }

    private static func formatted(
        _ date: Date,
        format: String,
        timeZone: TimeZone,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static var utcTimeZone: TimeZone {
        TimeZone(secondsFromGMT: 0)!
    }

    private static func date(for day: DayKey) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = day.year
        components.month = day.month
        components.day = day.day
        return calendar.date(from: components)
    }
}
