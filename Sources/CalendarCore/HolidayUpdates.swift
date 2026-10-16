import Foundation

public enum HolidayDataSource: String, Codable, CaseIterable, Sendable {
    case gitee, timor, appworlds

    public var name: String {
        switch self {
        case .gitee: return "Gitee · holiday-calendar"
        case .timor: return "提莫节假日 API"
        case .appworlds: return "程序世界"
        }
    }

    public var website: URL {
        switch self {
        case .gitee: return URL(string: "https://gitee.com/cg-zhou/holiday-calendar")!
        case .timor: return URL(string: "https://timor.tech/api/holiday")!
        case .appworlds: return URL(string: "https://appworlds.cn/holiday/")!
        }
    }

    public func url(year: Int) -> URL {
        switch self {
        case .gitee: return URL(string: "https://gitee.com/cg-zhou/holiday-calendar/raw/main/data/CN/\(year).json")!
        case .timor: return URL(string: "https://timor.tech/api/holiday/year/\(year)/")!
        case .appworlds: return URL(string: "https://date.appworlds.cn/year/\(year)")!
        }
    }
}

public struct HolidayYearData: Codable, Equatable, Sendable {
    public let year: Int
    public let source: HolidayDataSource
    public let days: [String: Holiday]

    public func validated() throws -> Self {
        guard (2001...2100).contains(year), (20...110).contains(days.count) else { throw HolidayDataError.invalid }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        for (key, holiday) in days {
            guard key.utf8.count == 10, let date = formatter.date(from: key), formatter.string(from: date) == key,
                  key.hasPrefix("\(year)-") || key.hasPrefix("\(year - 1)-12-"),
                  !holiday.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  holiday.name.count <= 60 else { throw HolidayDataError.invalid }
        }
        let rest = days.filter { $0.key.hasPrefix("\(year)-") && $0.value.kind == .rest }
        guard (20...80).contains(rest.count), days.count - rest.count <= 30,
              days["\(year)-01-01"]?.kind == .rest,
              days["\(year)-05-01"]?.kind == .rest,
              days["\(year)-10-01"]?.kind == .rest else { throw HolidayDataError.invalid }
        return self
    }
}

public enum HolidayDataError: Error {
    case notPublished, invalid, oversized, http(Int)
}

public enum HolidayDataDecoder {
    private struct NamedDay: Decodable {
        let date: String
        let name: String
        let holiday: Bool
    }
    private struct Timor: Decodable { let code: Int; let holiday: [String: NamedDay] }
    private struct Appworlds: Decodable { let code: Int; let data: [NamedDay]? }
    private struct Gitee: Decodable {
        struct Day: Decodable { let date: String; let name: String; let type: String }
        let year: Int
        let region: String
        let dates: [Day]
    }

    public static func decode(_ data: Data, source: HolidayDataSource, year: Int) throws -> HolidayYearData {
        guard data.count <= 131_072 else { throw HolidayDataError.oversized }
        var days: [String: Holiday] = [:]
        func add(_ key: String, _ name: String, _ kind: Holiday.Kind) throws {
            guard days[key] == nil else { throw HolidayDataError.invalid }
            days[key] = Holiday(name: name, kind: kind)
        }
        let decoder = JSONDecoder()
        switch source {
        case .gitee:
            let response = try decoder.decode(Gitee.self, from: data)
            guard response.year == year, response.region == "CN" else { throw HolidayDataError.invalid }
            for day in response.dates {
                guard ["public_holiday", "transfer_workday"].contains(day.type) else { throw HolidayDataError.invalid }
                try add(day.date, day.name, day.type == "public_holiday" ? .rest : .work)
            }
        case .timor:
            let response = try decoder.decode(Timor.self, from: data)
            guard response.code == 0 else { throw HolidayDataError.invalid }
            for (key, day) in response.holiday {
                guard String(day.date.suffix(5)) == key else { throw HolidayDataError.invalid }
                try add(day.date, day.name, day.holiday ? .rest : .work)
            }
        case .appworlds:
            let response = try decoder.decode(Appworlds.self, from: data)
            guard response.code == 200, let entries = response.data else { throw HolidayDataError.invalid }
            for day in entries { try add(day.date, day.name, day.holiday ? .rest : .work) }
        }
        guard !days.isEmpty else { throw HolidayDataError.notPublished }
        return try HolidayYearData(year: year, source: source, days: days).validated()
    }
}

public enum HolidayFetchResult: Sendable {
    case available(HolidayYearData)
    case notPublished
    case failed
}

private final class HolidayRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url?.scheme == "https" && request.url?.host == task.originalRequest?.url?.host
        completionHandler(allowed ? request : nil)
    }
}

public struct HolidayFetcher: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport

    public init(transport: @escaping Transport) { self.transport = transport }

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: HolidayRedirectPolicy(), delegateQueue: nil)
        transport = { request in
            let (bytes, response) = try await session.bytes(for: request)
            var data = Data()
            for try await byte in bytes {
                guard data.count < 131_072 else { throw HolidayDataError.oversized }
                data.append(byte)
            }
            return (data, response)
        }
    }

    public func fetch(year: Int) async -> HolidayFetchResult {
        var unpublished = false
        for source in HolidayDataSource.allCases {
            guard !Task.isCancelled else { return .failed }
            var request = URLRequest(url: source.url(year: year), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue("CalDock/1 (macOS; holiday-calendar)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await transport(request)
                guard let http = response as? HTTPURLResponse else { throw HolidayDataError.invalid }
                if http.statusCode == 404 { unpublished = true; continue }
                guard http.statusCode == 200 else { throw HolidayDataError.http(http.statusCode) }
                // Redirects must not silently reintroduce GitHub or an insecure transport.
                guard http.url?.scheme == "https", http.url?.host == request.url?.host else { throw HolidayDataError.invalid }
                return .available(try HolidayDataDecoder.decode(data, source: source, year: year))
            } catch HolidayDataError.notPublished { unpublished = true }
            catch { continue }
        }
        return unpublished ? .notPublished : .failed
    }
}

public struct HolidayCheckState: Codable, Equatable {
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var attempts = 0
    public init() {}

    public mutating func recordAttempt(at date: Date, calendar: Calendar) {
        attempts = lastAttempt.map { calendar.isDate($0, inSameDayAs: date) } == true ? attempts + 1 : 1
        lastAttempt = date
    }

    public func nextCheck(after now: Date, timeZone: TimeZone = .current) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        func at(_ hour: Int, on day: Date) -> Date { cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)! }
        if let lastSuccess, cal.isDate(lastSuccess, inSameDayAs: now) { return at(10, on: tomorrow) }
        if let lastAttempt, cal.isDate(lastAttempt, inSameDayAs: now), attempts >= 3 { return at(10, on: tomorrow) }
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let overdue = lastSuccess == nil || lastSuccess! < yesterday
        var next = max(now, at(overdue ? 8 : 10, on: today))
        if let lastAttempt, lastAttempt <= now {
            next = max(next, lastAttempt.addingTimeInterval(30 * 60))
        }
        if next >= at(22, on: today) { return at(10, on: tomorrow) }
        return next
    }
}

public enum HolidayCache {
    public static var fileURL: URL? {
        SharedPreferences.fileURL?.deletingLastPathComponent().appendingPathComponent("holidays-v1.json")
    }
}
