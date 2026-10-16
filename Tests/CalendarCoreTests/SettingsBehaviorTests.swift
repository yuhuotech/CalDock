import CoreGraphics
import Foundation
import XCTest
@testable import CalendarCore

final class SettingsBehaviorTests: XCTestCase {
    func testAllPaletteRolesApplyIndependentlyInBothThemes() throws {
        for dark in [false, true] {
            for role in PaletteRole.allCases {
                var p = AppPreferences()
                let opposite = p.palette(dark: !dark)
                p.setColor("#123456", role: role, dark: dark)
                XCTAssertEqual(p.palette(dark: dark)[role], "#123456", "\(dark) \(role)")
                XCTAssertEqual(p.palette(dark: !dark), opposite)
                let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(p))
                XCTAssertEqual(decoded, p)
            }
        }
    }

    func testSmallestRowsStillFitLargestFont() {
        var p = AppPreferences()
        p.rowHeight = 28; p.fontScale = 1.3
        XCTAssertGreaterThanOrEqual(p.effectiveRowHeight, 32 * 1.3)
        p.fontScale = 0.75
        XCTAssertEqual(p.effectiveRowHeight, 28)
    }

    func testPlacementOnNegativeAndSmallDisplays() {
        for screen in [CGRect(x: -1920, y: 0, width: 1920, height: 1080), CGRect(x: 0, y: -768, width: 1024, height: 768), CGRect(x: 0, y: 0, width: 800, height: 480)] {
            for anchor in [nil, CGRect(x: screen.minX, y: screen.maxY - 24, width: 22, height: 24), CGRect(x: screen.maxX - 22, y: screen.maxY - 24, width: 22, height: 24)] {
                for size in [CGSize(width: 280, height: 200), CGSize(width: 500, height: 900)] {
                    let frame = PanelPlacement.frame(content: size, screen: screen, anchor: anchor, menuHeight: 24)
                    XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
                    XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
                    XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
                    XCTAssertLessThanOrEqual(frame.maxY, screen.maxY - 24)
                    XCTAssertEqual(frame.height, min(size.height, screen.height - 40))
                }
            }
        }
    }

    func testNotificationPlanUsesFutureStableIdentifiersAndLocal18Hours() {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let engine = CalendarEngine(timeZone: zone)
        let now = engine.calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 17))!
        let plan = HolidayReminderPlanner.reminders(after: now, timeZone: zone)
        let national = plan.first { $0.title == "明天是国庆节" }!
        XCTAssertEqual(engine.dateKey(national.fireDate), "2026-09-30")
        XCTAssertEqual(engine.calendar.component(.hour, from: national.fireDate), 18)
        XCTAssertTrue(national.body.contains("放假休息"))
        XCTAssertEqual(Set(plan.map(\.identifier)).count, plan.count)
        XCTAssertTrue(plan.allSatisfy { $0.fireDate > now })
        XCTAssertLessThanOrEqual(plan.count, 60)
        XCTAssertEqual(plan, HolidayReminderPlanner.reminders(after: now, timeZone: zone))
        XCTAssertFalse(HolidayReminderPlanner.reminders(after: now.addingTimeInterval(7200), timeZone: zone).contains { $0.identifier == national.identifier })
    }

    func testWidgetSettingsAreSeparateAndRoundTrip() throws {
        var p = AppPreferences()
        var widget = WidgetPreferences()
        widget.appearance = "dark"; widget.firstWeekday = 2
        widget.hideLunar = true; widget.showHolidayBadges = false
        widget.dark[.background] = "#112233"
        p.widget = widget
        XCTAssertEqual(p.appearance, "system")
        XCTAssertFalse(p.hideLunar)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(p)).widget, widget)
    }
}
