import XCTest
@testable import CalendarCore

final class CalendarEngineTests: XCTestCase {
    let zone = TimeZone(identifier: "Asia/Shanghai")!
    var engine: CalendarEngine { CalendarEngine(timeZone: zone) }
    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        engine.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testReopenResetsToTodayOnlyAfterGraceInterval() {
        let closed = date(2026, 10, 16)
        XCTAssertTrue(engine.shouldResetToToday(closedAt: nil, now: closed))
        XCTAssertFalse(engine.shouldResetToToday(closedAt: closed, now: closed.addingTimeInterval(60)))
        XCTAssertFalse(engine.shouldResetToToday(closedAt: closed, now: closed.addingTimeInterval(300)))
        XCTAssertTrue(engine.shouldResetToToday(closedAt: closed, now: closed.addingTimeInterval(301)))
        let late = engine.calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 23, minute: 59))!
        XCTAssertTrue(engine.shouldResetToToday(closedAt: late, now: late.addingTimeInterval(120)))
    }

    func testReferenceOctober2026GridAndLunar() {
        let days = engine.monthGrid(date(2026, 10, 16))
        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(engine.dateKey(days[0].date), "2026-09-27")
        XCTAssertEqual(engine.dateKey(days[41].date), "2026-11-07")
        let today = days.first { engine.dateKey($0.date) == "2026-10-16" }!
        XCTAssertEqual(today.lunar.fullLabel, "九月初七")
        XCTAssertEqual(days.first { $0.day == 1 && $0.inMonth }?.festival, "国庆节")
        XCTAssertEqual(days.first { $0.day == 18 && $0.inMonth }?.festival, "重阳节")
    }

    func testMondayStartAndLeapFebruary() {
        let monday = CalendarEngine(timeZone: zone, firstWeekday: 2)
        let days = monday.monthGrid(date(2024, 2, 15))
        XCTAssertEqual(monday.calendar.component(.weekday, from: days[0].date), 2)
        XCTAssertEqual(days.filter(\.inMonth).count, 29)
        XCTAssertEqual(days.first { $0.day == 10 && $0.inMonth }?.festival, "春节")
        XCTAssertEqual(days.first { $0.day == 9 && $0.inMonth }?.festival, "除夕")
    }

    func testOfficialRestAndMakeupWork() {
        let store = HolidayStore.shared
        XCTAssertEqual(store.supportedYears, [2026])
        XCTAssertEqual(store.holiday(on: date(2026, 10, 1), calendar: engine.calendar)?.kind, .rest)
        XCTAssertEqual(store.holiday(on: date(2026, 10, 7), calendar: engine.calendar)?.kind, .rest)
        XCTAssertNil(store.holiday(on: date(2026, 10, 8), calendar: engine.calendar))
        XCTAssertEqual(store.holiday(on: date(2026, 10, 10), calendar: engine.calendar)?.kind, .work)
        XCTAssertEqual(store.holiday(on: date(2026, 9, 20), calendar: engine.calendar)?.kind, .work)
        XCTAssertEqual(store.holiday(on: date(2026, 2, 23), calendar: engine.calendar)?.kind, .rest)
        XCTAssertEqual(store.holiday(on: date(2026, 2, 28), calendar: engine.calendar)?.kind, .work)
        XCTAssertNil(store.holiday(on: date(2027, 10, 1), calendar: engine.calendar))
        let restDays = store.schedules[0].rest.reduce(0) { count, period in
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = zone
            return count + engine.calendar.dateComponents([.day], from: f.date(from: period.start)!, to: f.date(from: period.end)!).day! + 1
        }
        XCTAssertEqual(restDays, 33)
    }

    func testSolarTermsMatchReferenceDates() {
        let terms = SolarTerms.dates(year: 2026, timeZone: zone)
        XCTAssertEqual(terms.count, 24)
        XCTAssertEqual(terms["2026-04-05"], "清明")
        XCTAssertEqual(terms["2026-10-08"], "寒露")
        XCTAssertEqual(terms["2026-10-23"], "霜降")
        XCTAssertEqual(terms["2026-11-07"], "立冬")
        XCTAssertEqual(terms["2026-12-22"], "冬至")
    }

    func testLunarLeapMonthHasNoDuplicateFestival() {
        let info = engine.lunarInfo(date(2025, 7, 25))
        XCTAssertTrue(info.isLeapMonth)
        XCTAssertEqual(info.month, 6)
        XCTAssertTrue(info.monthName.hasPrefix("闰"))
    }

    func testGridAcrossDSTUsesCalendarDays() {
        let dst = CalendarEngine(timeZone: TimeZone(identifier: "America/Los_Angeles")!, firstWeekday: 2)
        let days = dst.monthGrid(date(2026, 3, 15))
        XCTAssertEqual(Set(days.map { dst.dateKey($0.date) }).count, 42)
        for pair in zip(days, days.dropFirst()) {
            XCTAssertEqual(dst.calendar.dateComponents([.day], from: pair.0.date, to: pair.1.date).day, 1)
        }
    }

    func testStatusFormatsOrderingAndTickPolicy() {
        let format = StatusFormatter(timeZone: zone)
        var p = AppPreferences()
        p.modules = [.lunar, .solar, .icon, .weekday, .time, .custom]
        p.enabledModules = [.solar, .lunar]
        XCTAssertEqual(format.text(date: date(2026, 10, 16), preferences: p, engine: engine), "初七 10月16日")
        XCTAssertFalse(p.needsSecondTicks)
        p.showSeconds = true
        XCTAssertFalse(p.needsSecondTicks)
        p.enabledModules.append(.time)
        XCTAssertTrue(p.needsSecondTicks)
        p.showSeconds = false
        p.enabledModules.append(.custom)
        p.customFormat = "HH:mm:ss"
        XCTAssertTrue(p.needsSecondTicks)
        p.customFormat = "HH:mm 'ss'"
        XCTAssertFalse(p.needsSecondTicks)
    }

    func testSettingsPersistAndNeverLoseAllModules() throws {
        var p = AppPreferences()
        p.setEnabled(.icon, false)
        XCTAssertEqual(p.enabledModules, [.icon])
        p.setEnabled(.solar, true); p.setEnabled(.icon, false)
        XCTAssertEqual(p.enabledModules, [.solar])
        p.panelWidth = 1200; p.rowHeight = 1; p.fontScale = 2
        p.modules = [.solar, .solar]
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(p)).normalized()
        XCTAssertEqual(restored.panelWidth, 500)
        XCTAssertEqual(restored.rowHeight, 28)
        XCTAssertEqual(restored.fontScale, 1.3)
        XCTAssertEqual(Set(restored.modules), Set(StatusModule.allCases))
        XCTAssertEqual(restored.modules.count, 6)
    }

    func testEventMidnightAndMultiDayBoundaries() {
        let start = engine.calendar.startOfDay(for: date(2026, 10, 16))
        let next = engine.calendar.date(byAdding: .day, value: 1, to: start)!
        XCTAssertTrue(engine.eventIntersectsDay(start: start, end: next, day: start))
        XCTAssertFalse(engine.eventIntersectsDay(start: start, end: next, day: next))
        XCTAssertTrue(engine.eventIntersectsDay(start: start, end: start, day: start))
        XCTAssertFalse(engine.eventIntersectsDay(start: next, end: start, day: start))
        XCTAssertTrue(engine.eventIntersectsDay(start: start.addingTimeInterval(-3600), end: next.addingTimeInterval(3600), day: start))
        XCTAssertTrue(engine.eventIntersectsDay(start: start.addingTimeInterval(-3600), end: next.addingTimeInterval(3600), day: next))
    }
}
