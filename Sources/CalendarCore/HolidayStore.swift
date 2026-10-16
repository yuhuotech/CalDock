import Foundation

public struct Holiday: Codable, Equatable {
    public enum Kind: String, Codable { case rest, work }
    public let name: String
    public let kind: Kind
    public var badge: String { kind == .rest ? "休" : "班" }
}

public struct HolidaySchedule: Codable {
    public struct Period: Codable {
        public let name: String
        public let start: String
        public let end: String
    }
    public let year: Int
    public let source: String
    public let rest: [Period]
    public let work: [String]
}

public final class HolidayStore {
    public static let shared = HolidayStore()
    public let schedules: [HolidaySchedule]
    private let days: [String: Holiday]
    public var supportedYears: [Int] { schedules.map(\.year).sorted() }

    public init() {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "holidays", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let schedules = try? JSONDecoder().decode([HolidaySchedule].self, from: data) else {
            self.schedules = []; self.days = [:]; return
        }
        self.schedules = schedules
        var days: [String: Holiday] = [:]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = cal.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        for schedule in schedules {
            for period in schedule.rest {
                guard var date = formatter.date(from: period.start), let end = formatter.date(from: period.end) else { continue }
                while date <= end {
                    days[formatter.string(from: date)] = Holiday(name: period.name, kind: .rest)
                    date = cal.date(byAdding: .day, value: 1, to: date)!
                }
            }
            for date in schedule.work { days[date] = Holiday(name: "调休补班", kind: .work) }
        }
        self.days = days
    }

    public func holiday(on date: Date, calendar: Calendar) -> Holiday? {
        days[CalendarEngine.dateKey(date, calendar: calendar)]
    }
}
