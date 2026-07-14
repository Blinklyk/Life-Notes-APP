import Foundation
import XCTest
@testable import LifeNotes

final class CalendarMonthTests: XCTestCase {
    func testValidationAndContainment() throws {
        let month = try XCTUnwrap(CalendarMonth(year: 2026, month: 7))

        XCTAssertEqual(month.year, 2026)
        XCTAssertEqual(month.month, 7)
        XCTAssertTrue(month.contains(try XCTUnwrap(DayKey(year: 2026, month: 7, day: 31))))
        XCTAssertFalse(month.contains(try XCTUnwrap(DayKey(year: 2026, month: 8, day: 1))))
        XCTAssertNil(CalendarMonth(year: 0, month: 7))
        XCTAssertNil(CalendarMonth(year: 10_000, month: 7))
        XCTAssertNil(CalendarMonth(year: 2026, month: 0))
        XCTAssertNil(CalendarMonth(year: 2026, month: 13))
    }

    func testPreviousAndNextCrossYearBoundaries() throws {
        let january = try XCTUnwrap(CalendarMonth(year: 2026, month: 1))
        let december = try XCTUnwrap(CalendarMonth(year: 2026, month: 12))

        XCTAssertEqual(january.previous, CalendarMonth(year: 2025, month: 12))
        XCTAssertEqual(january.next, CalendarMonth(year: 2026, month: 2))
        XCTAssertEqual(december.previous, CalendarMonth(year: 2026, month: 11))
        XCTAssertEqual(december.next, CalendarMonth(year: 2027, month: 1))
    }

    func testLeapYearAndCommonYearHaveCorrectEndDays() throws {
        let leapFebruary = try XCTUnwrap(CalendarMonth(year: 2024, month: 2))
        let commonFebruary = try XCTUnwrap(CalendarMonth(year: 2026, month: 2))

        XCTAssertEqual(leapFebruary.startDay, DayKey(year: 2024, month: 2, day: 1))
        XCTAssertEqual(leapFebruary.endDay, DayKey(year: 2024, month: 2, day: 29))
        XCTAssertEqual(commonFebruary.endDay, DayKey(year: 2026, month: 2, day: 28))
    }

    func testGridAlwaysUsesSixMondayFirstWeeks() throws {
        let month = try XCTUnwrap(CalendarMonth(year: 2026, month: 7))

        XCTAssertEqual(month.gridDays.count, 42)
        XCTAssertEqual(month.gridDays.first, DayKey(year: 2026, month: 6, day: 29))
        XCTAssertEqual(month.gridDays[2], DayKey(year: 2026, month: 7, day: 1))
        XCTAssertEqual(month.gridDays.last, DayKey(year: 2026, month: 8, day: 9))
        XCTAssertEqual(month.gridDays.filter(month.contains).count, 31)
    }

    func testContainingInstantUsesRequestedTimeZone() throws {
        let instant = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-31T16:30:00Z")
        )
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))

        XCTAssertEqual(
            CalendarMonth(containing: instant, in: shanghai),
            CalendarMonth(year: 2026, month: 8)
        )
        XCTAssertEqual(
            CalendarMonth(containing: instant, in: utc),
            CalendarMonth(year: 2026, month: 7)
        )
    }
}
