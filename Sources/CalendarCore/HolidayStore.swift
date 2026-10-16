import Foundation

public struct Holiday: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case rest, work }
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

public final class HolidayStore: @unchecked Sendable {
    public static let shared = HolidayStore()
    public let schedules: [HolidaySchedule]
    private let bundledDays: [String: Holiday]
    private var days: [String: Holiday]
    private var downloaded: [Int: HolidayYearData] = [:]
    private let lock = NSLock()
    public var supportedYears: [Int] {
        lock.lock(); defer { lock.unlock() }
        return Set(schedules.map(\.year) + downloaded.keys).sorted()
    }
    public var downloadedYears: [HolidayYearData] {
        lock.lock(); defer { lock.unlock() }
        return downloaded.values.sorted { $0.year < $1.year }
    }

    public init() {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "holidays", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let schedules = try? JSONDecoder().decode([HolidaySchedule].self, from: data) else {
            self.schedules = []; self.days = [:]; self.bundledDays = [:]; return
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
        self.bundledDays = days
    }

    public func loadCache(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_097_152 else { throw HolidayDataError.oversized }
        let entries = try JSONDecoder().decode([HolidayYearData].self, from: data)
        guard !entries.isEmpty else { throw HolidayDataError.invalid }
        var checked: [Int: HolidayYearData] = [:]
        for entry in entries {
            guard checked[entry.year] == nil else { throw HolidayDataError.invalid }
            checked[entry.year] = try entry.validated()
        }
        lock.lock(); defer { lock.unlock() }
        downloaded = checked
        rebuildDays()
    }

    @discardableResult
    public func install(_ entries: [HolidayYearData], cacheURL: URL) throws -> Bool {
        let checked = try entries.map { try $0.validated() }
        lock.lock(); defer { lock.unlock() }
        var merged = downloaded
        for entry in checked { merged[entry.year] = entry }
        guard merged != downloaded else { return false }
        let data = try JSONEncoder().encode(merged.values.sorted { $0.year < $1.year })
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Commit to disk before changing the in-memory calendar; widgets read the same atomic file.
        try data.write(to: cacheURL, options: .atomic)
        downloaded = merged
        rebuildDays()
        return true
    }

    private func rebuildDays() {
        days = bundledDays
        for entry in downloaded.values.sorted(by: { $0.year < $1.year }) {
            days = days.filter { !$0.key.hasPrefix("\(entry.year)-") }
            days.merge(entry.days) { _, new in new }
        }
    }

    public func holiday(on date: Date, calendar: Calendar) -> Holiday? {
        lock.lock(); defer { lock.unlock() }
        return days[CalendarEngine.dateKey(date, calendar: calendar)]
    }
}
