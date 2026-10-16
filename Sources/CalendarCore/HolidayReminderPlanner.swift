import Foundation

public struct HolidayReminder: Equatable {
    public let identifier: String
    public let fireDate: Date
    public let title: String
    public let body: String
}

public enum HolidayReminderPlanner {
    public static func reminders(after now: Date, timeZone: TimeZone = .current) -> [HolidayReminder] {
        let engine = CalendarEngine(timeZone: timeZone)
        let cal = engine.calendar
        let year = cal.component(.year, from: now)
        let terms = SolarTerms.dates(year: year, timeZone: timeZone)
            .merging(SolarTerms.dates(year: year + 1, timeZone: timeZone)) { first, _ in first }
        let formatter = StatusFormatter(timeZone: timeZone)
        var result: [HolidayReminder] = []
        for offset in 0..<366 {
            let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now))!
            let tomorrow = cal.date(byAdding: .day, value: 1, to: day)!
            let lunar = engine.lunarInfo(tomorrow)
            let name = engine.festival(tomorrow, lunar: lunar)
                ?? (terms[engine.dateKey(tomorrow)] == "清明" ? "清明节" : nil)
            guard let name, let fire = cal.date(bySettingHour: 18, minute: 0, second: 0, of: day), fire > now else { continue }
            var body = formatter.string(tomorrow, pattern: "M月d日 EEEE") + " · " + lunar.fullLabel
            if let holiday = HolidayStore.shared.holiday(on: tomorrow, calendar: cal) {
                body += holiday.kind == .rest ? " · 放假休息" : " · 调休上班"
            }
            result.append(HolidayReminder(identifier: "caldock.holiday." + engine.dateKey(tomorrow), fireDate: fire,
                                          title: "明天是\(name)", body: body))
        }
        return Array(result.prefix(60))
    }
}
