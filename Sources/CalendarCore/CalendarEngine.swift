import Foundation

public struct LunarInfo: Equatable {
    public let month: Int
    public let day: Int
    public let isLeapMonth: Bool
    public let monthName: String
    public let dayName: String
    public var shortLabel: String { day == 1 ? monthName : dayName }
    public var fullLabel: String { monthName + dayName }
}

public struct DayInfo: Identifiable {
    public var id: Date { date }
    public let date: Date
    public let day: Int
    public let inMonth: Bool
    public let isWeekend: Bool
    public let lunar: LunarInfo
    public let festival: String?
    public let solarTerm: String?
    public let holiday: Holiday?
    public var label: String { festival ?? solarTerm ?? lunar.shortLabel }
}

public struct CalendarEngine {
    public var calendar: Calendar
    private var chinese: Calendar

    public init(timeZone: TimeZone = .current, firstWeekday: Int = 1) {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "zh_CN")
        cal.timeZone = timeZone
        cal.firstWeekday = firstWeekday
        cal.minimumDaysInFirstWeek = 4
        calendar = cal
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = timeZone
        chinese = lunar
    }

    public func monthStart(_ date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)!.start
    }

    public func monthGrid(_ date: Date, holidays: HolidayStore = .shared) -> [DayInfo] {
        let first = monthStart(date)
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: first)!
        let year = calendar.component(.year, from: first)
        let terms = SolarTerms.dates(year: year, timeZone: calendar.timeZone)
            .merging(SolarTerms.dates(year: year - 1, timeZone: calendar.timeZone)) { a, _ in a }
            .merging(SolarTerms.dates(year: year + 1, timeZone: calendar.timeZone)) { a, _ in a }
        return (0..<42).map { index in
            let day = calendar.date(byAdding: .day, value: index, to: start)!
            let lunar = lunarInfo(day)
            return DayInfo(date: day, day: calendar.component(.day, from: day),
                           inMonth: calendar.isDate(day, equalTo: first, toGranularity: .month),
                           isWeekend: calendar.isDateInWeekend(day), lunar: lunar,
                           festival: festival(day, lunar: lunar),
                           solarTerm: terms[dateKey(day)], holiday: holidays.holiday(on: day, calendar: calendar))
        }
    }

    public func lunarInfo(_ date: Date) -> LunarInfo {
        let parts = chinese.dateComponents([.month, .day, .isLeapMonth], from: date)
        let month = parts.month ?? 1, day = parts.day ?? 1
        let months = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]
        let days = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
                    "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
                    "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
        return LunarInfo(month: month, day: day, isLeapMonth: parts.isLeapMonth == true,
                         monthName: (parts.isLeapMonth == true ? "闰" : "") + months[max(0, min(11, month - 1))],
                         dayName: days[max(0, min(29, day - 1))])
    }

    public func festival(_ date: Date, lunar: LunarInfo? = nil) -> String? {
        let m = calendar.component(.month, from: date), d = calendar.component(.day, from: date)
        let solar = ["1-1": "元旦", "2-14": "情人节", "3-8": "妇女节", "3-12": "植树节", "4-1": "愚人节",
                     "5-1": "劳动节", "5-4": "青年节", "6-1": "儿童节", "7-1": "建党节", "8-1": "建军节",
                     "9-10": "教师节", "10-1": "国庆节", "10-31": "万圣夜", "12-24": "平安夜", "12-25": "圣诞节"]
        let l = lunar ?? lunarInfo(date)
        if !l.isLeapMonth {
            let traditional = ["1-1": "春节", "1-15": "元宵节", "2-2": "龙抬头", "5-5": "端午节",
                               "7-7": "七夕", "7-15": "中元节", "8-15": "中秋节", "9-9": "重阳节",
                               "12-8": "腊八节", "12-23": "小年"]
            if let name = traditional["\(l.month)-\(l.day)"] { return name }
            if l.month == 12, let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) {
                let next = lunarInfo(tomorrow)
                if next.month == 1 && next.day == 1 { return "除夕" }
            }
        }
        // Mother's Day and Father's Day are based on weekdays, not fixed dates.
        let weekday = calendar.component(.weekday, from: date)
        if weekday == 1 && m == 5 && (8...14).contains(d) { return "母亲节" }
        if weekday == 1 && m == 6 && (15...21).contains(d) { return "父亲节" }
        return solar["\(m)-\(d)"]
    }

    public func dateKey(_ date: Date) -> String { Self.dateKey(date, calendar: calendar) }

    public func eventIntersectsDay(start: Date, end: Date, day: Date) -> Bool {
        guard end >= start, let interval = calendar.dateInterval(of: .day, for: day) else { return false }
        if start == end { return start >= interval.start && start < interval.end }
        return start < interval.end && end > interval.start
    }

    public static func dateKey(_ date: Date, calendar: Calendar) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
    }
}

public enum SolarTerms {
    public static let names = ["小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨", "立夏", "小满", "芒种", "夏至",
                               "小暑", "大暑", "立秋", "处暑", "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至"]
    // Solve for the apparent solar longitude. Dates are calendar-day precision;
    // this is intentionally not an astronomical ephemeris for exact term times.
    public static func dates(year: Int, timeZone: TimeZone) -> [String: String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard let january = cal.date(from: DateComponents(year: year, month: 1, day: 5, hour: 12)) else { return [:] }
        var result: [String: String] = [:]
        for i in 0..<24 {
            var jd = january.timeIntervalSince1970 / 86400 + 2440587.5 + Double(i) * 15.2184
            let target = (285.0 + Double(i) * 15).truncatingRemainder(dividingBy: 360)
            for _ in 0..<6 {
                let t = (jd - 2451545.0) / 36525
                let l = 280.46646 + 36000.76983 * t + 0.0003032 * t * t
                let m = (357.52911 + 35999.05029 * t - 0.0001537 * t * t) * .pi / 180
                let c = (1.914602 - 0.004817 * t - 0.000014 * t * t) * sin(m)
                    + (0.019993 - 0.000101 * t) * sin(2 * m) + 0.000289 * sin(3 * m)
                let omega = (125.04 - 1934.136 * t) * .pi / 180
                let longitude = l + c - 0.00569 - 0.00478 * sin(omega)
                var difference = (longitude - target).truncatingRemainder(dividingBy: 360)
                if difference > 180 { difference -= 360 }
                if difference < -180 { difference += 360 }
                jd -= difference / 0.98564736
            }
            // Approximate TT -> UTC for the modern era (well below day precision).
            let date = Date(timeIntervalSince1970: (jd - 2440587.5) * 86400 - 70)
            result[CalendarEngine.dateKey(date, calendar: cal)] = names[i]
        }
        return result
    }
}
