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
}
