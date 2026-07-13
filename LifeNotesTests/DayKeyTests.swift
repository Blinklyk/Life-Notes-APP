import Foundation
import XCTest
@testable import LifeNotes

final class DayKeyTests: XCTestCase {
    func testShanghaiDayChangesAtLocalMidnight() throws {
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let beforeMidnight = try instant("2026-07-12T15:59:59Z")
        let midnight = try instant("2026-07-12T16:00:00Z")

        XCTAssertEqual(
            DayKey(containing: beforeMidnight, in: shanghai),
            DayKey(year: 2026, month: 7, day: 12)
        )
        XCTAssertEqual(
            DayKey(containing: midnight, in: shanghai),
            DayKey(year: 2026, month: 7, day: 13)
        )
    }

    func testSameInstantCanBelongToDifferentLocalDays() throws {
        let instant = try instant("2026-07-12T16:30:00Z")
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))

        XCTAssertEqual(
            DayKey(containing: instant, in: shanghai),
            DayKey(year: 2026, month: 7, day: 13)
        )
        XCTAssertEqual(
            DayKey(containing: instant, in: utc),
            DayKey(year: 2026, month: 7, day: 12)
        )
    }

    func testStorageValueRoundTripsAndInvalidDatesAreRejected() throws {
        let dayKey = try XCTUnwrap(DayKey(year: 2026, month: 2, day: 28))

        XCTAssertEqual(dayKey.storageValue, 20_260_228)
        XCTAssertEqual(DayKey(storageValue: dayKey.storageValue), dayKey)
        XCTAssertNil(DayKey(year: 0, month: 1, day: 1))
        XCTAssertNil(DayKey(year: 2026, month: 2, day: 30))
        XCTAssertNil(DayKey(storageValue: 20_261_332))
    }

    private func instant(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}
