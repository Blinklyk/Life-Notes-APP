import Foundation

struct DayKey: Hashable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init?(year: Int, month: Int, day: Int) {
        guard (1...9_999).contains(year),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day

        guard let date = calendar.date(from: components) else {
            return nil
        }

        let normalized = calendar.dateComponents([.year, .month, .day], from: date)
        guard normalized.year == year,
              normalized.month == month,
              normalized.day == day else {
            return nil
        }

        self.year = year
        self.month = month
        self.day = day
    }

    init(containing instant: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: instant)

        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            preconditionFailure("无法从日期生成记录日")
        }

        self.year = year
        self.month = month
        self.day = day
    }

    init?(storageValue: Int) {
        guard storageValue > 0 else {
            return nil
        }

        let year = storageValue / 10_000
        let month = storageValue / 100 % 100
        let day = storageValue % 100
        self.init(year: year, month: month, day: day)
    }

    var storageValue: Int {
        year * 10_000 + month * 100 + day
    }

    static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        lhs.storageValue < rhs.storageValue
    }
}
