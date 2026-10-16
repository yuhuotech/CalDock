import Foundation
import XCTest
@testable import CalendarCore

final class HolidayUpdateTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func fixture(_ source: HolidayDataSource) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: source.rawValue, withExtension: "json", subdirectory: "Fixtures")))
    }
    private func parsed(_ source: HolidayDataSource = .gitee) throws -> HolidayYearData {
        try HolidayDataDecoder.decode(fixture(source), source: source, year: 2026)
    }

    func testThreeRealSourceFormatsAgreeOnRestAndMakeupWork() throws {
        let reference = try parsed()
        XCTAssertEqual(reference.days.count, 39)
        XCTAssertEqual(reference.days.filter { $0.value.kind == .rest }.count, 33)
        for source in HolidayDataSource.allCases {
            let value = try parsed(source)
            XCTAssertEqual(value.days.mapValues(\.kind), reference.days.mapValues(\.kind), source.rawValue)
            XCTAssertEqual(value.days["2026-10-10"]?.kind, .work)
            XCTAssertEqual(value.days["2026-10-07"]?.kind, .rest)
            XCTAssertNil(value.days["2026-10-08"])
        }
    }

    func testRejectsWrongYearTruncationBadDatesDuplicateDaysAndErrorPages() throws {
        let reference = try parsed()
        XCTAssertThrowsError(try HolidayDataDecoder.decode(fixture(.gitee), source: .gitee, year: 2027))
        for days in [[:], ["2026-01-01": Holiday(name: "元旦", kind: .rest)],
                     reference.days.merging(["2026-02-30": Holiday(name: "错误", kind: .rest)]) { _, new in new },
                     reference.days.merging(["2025-01-01": Holiday(name: "错误年份", kind: .rest)]) { _, new in new }] {
            XCTAssertThrowsError(try HolidayYearData(year: 2026, source: .gitee, days: days).validated())
        }
        let duplicate = Data(#"{"year":2026,"region":"CN","dates":[{"date":"2026-01-01","name":"元旦","type":"public_holiday"},{"date":"2026-01-01","name":"补班","type":"transfer_workday"}]}"#.utf8)
        XCTAssertThrowsError(try HolidayDataDecoder.decode(duplicate, source: .gitee, year: 2026))
        XCTAssertThrowsError(try HolidayDataDecoder.decode(Data("<html>login</html>".utf8), source: .gitee, year: 2026))
        XCTAssertThrowsError(try HolidayDataDecoder.decode(Data(repeating: 0, count: 131_073), source: .gitee, year: 2026))
        for (source, json) in [(HolidayDataSource.timor, #"{"code":0,"holiday":{}}"#),
                               (.appworlds, #"{"code":200,"data":[]}"#)] {
            XCTAssertThrowsError(try HolidayDataDecoder.decode(Data(json.utf8), source: source, year: 2027)) {
                guard case HolidayDataError.notPublished = $0 else { return XCTFail("Empty year must be unpublished") }
            }
        }
    }

    func testFallsBackAcrossAllSourcesAfterTimeoutAndInvalidPayload() async throws {
        let recorder = Requests()
        let data = try fixture(.appworlds)
        let fetcher = HolidayFetcher { request in
            await recorder.add(request.url!)
            if request.url!.host == "gitee.com" { throw URLError(.timedOut) }
            let body = request.url!.host == "timor.tech" ? Data("{}".utf8) : data
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        guard case .available(let value) = await fetcher.fetch(year: 2026) else { return XCTFail("Backup failed") }
        XCTAssertEqual(value.source, .appworlds)
        let urls = await recorder.urls
        XCTAssertEqual(urls.map(\.host), ["gitee.com", "timor.tech", "date.appworlds.cn"])
        XCTAssertTrue(urls.allSatisfy { $0.scheme == "https" && !$0.absoluteString.contains("github") })
    }

    func testStopsAtFirstValidSourceAndDistinguishesUnpublishedFromFailure() async throws {
        let recorder = Requests()
        let data = try fixture(.gitee)
        let fetcher = HolidayFetcher { request in
            await recorder.add(request.url!)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        guard case .available = await fetcher.fetch(year: 2026) else { return XCTFail("Expected data") }
        let urls = await recorder.urls
        XCTAssertEqual(urls.count, 1)
        let unpublished = HolidayFetcher { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        guard case .notPublished = await unpublished.fetch(year: 2027) else { return XCTFail("Expected unpublished") }
        let failed = HolidayFetcher { _ in throw URLError(.notConnectedToInternet) }
        guard case .failed = await failed.fetch(year: 2026) else { return XCTFail("Expected failure") }
        let redirected = HolidayFetcher { _ in
            (data, HTTPURLResponse(url: URL(string: "https://raw.githubusercontent.com/data")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        guard case .failed = await redirected.fetch(year: 2026) else { return XCTFail("Unexpected redirect accepted") }
    }

    func testAtomicCacheRestoresOfflineAndNeverLosesOtherYearsOrAcceptsCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("holidays.json")
        let store = HolidayStore()
        let data = try parsed()
        XCTAssertTrue(try store.install([data], cacheURL: url))
        XCTAssertFalse(try store.install([data], cacheURL: url))
        let offline = HolidayStore()
        try offline.loadCache(from: url)
        XCTAssertEqual(offline.downloadedYears, [data])
        XCTAssertEqual(offline.holiday(on: date(10, 12), calendar: calendar)?.kind, .work)
        let future = HolidayYearData(year: 2027, source: .gitee,
            days: Dictionary(uniqueKeysWithValues: data.days.map { ($0.key.replacingOccurrences(of: "2026", with: "2027"), $0.value) }))
        XCTAssertTrue(try store.install([future], cacheURL: url))
        XCTAssertEqual(store.supportedYears, [2026, 2027])
        XCTAssertFalse(try store.install([], cacheURL: url))
        XCTAssertEqual(store.supportedYears, [2026, 2027])
        let original = try Data(contentsOf: url)
        let bad = HolidayYearData(year: 2027, source: .timor, days: [:])
        XCTAssertThrowsError(try store.install([bad], cacheURL: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try store.loadCache(from: url))
        XCTAssertEqual(store.supportedYears, [2026, 2027])
        let fallback = HolidayStore()
        XCTAssertThrowsError(try fallback.loadCache(from: url))
        XCTAssertEqual(fallback.supportedYears, [2026])
        let cannotWrite = directory.appendingPathComponent("plain-file")
        try Data().write(to: cannotWrite)
        let before = fallback.downloadedYears
        XCTAssertThrowsError(try fallback.install([data], cacheURL: cannotWrite.appendingPathComponent("cache.json")))
        XCTAssertEqual(fallback.downloadedYears, before)
    }

    func testReplacementRemovesObsoleteDatesAndNextYearCanOverrideDecember() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HolidayStore()
        let initial = try parsed()
        var corrected = initial.days
        corrected.removeValue(forKey: "2026-10-10")
        try store.install([initial], cacheURL: url)
        try store.install([HolidayYearData(year: 2026, source: .timor, days: corrected)], cacheURL: url)
        XCTAssertNil(store.holiday(on: date(10, 12), calendar: calendar))
        var nextDays = Dictionary(uniqueKeysWithValues: initial.days.map { ($0.key.replacingOccurrences(of: "2026", with: "2027"), $0.value) })
        nextDays["2026-12-31"] = Holiday(name: "元旦", kind: .rest)
        try store.install([HolidayYearData(year: 2027, source: .gitee, days: nextDays)], cacheURL: url)
        let december = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 12))!
        XCTAssertEqual(store.holiday(on: december, calendar: calendar)?.kind, .rest)
    }

    func testDaytimeSchedulingCatchUpDailyDeduplicationAndBoundedRetry() throws {
        var state = HolidayCheckState()
        func next(_ now: Date) -> Date { state.nextCheck(after: now, timeZone: calendar.timeZone) }
        XCTAssertEqual(next(date(17, 2)), date(17, 8))
        XCTAssertEqual(next(date(17, 9)), date(17, 9))
        XCTAssertEqual(next(date(17, 23)), date(18, 10))
        state.lastSuccess = date(16, 10)
        XCTAssertEqual(next(date(17, 9)), date(17, 10))
        XCTAssertEqual(next(date(17, 16)), date(17, 16))
        state.lastSuccess = date(15, 10)
        XCTAssertEqual(next(date(17, 9)), date(17, 9))
        state.lastSuccess = date(17, 11)
        XCTAssertEqual(next(date(17, 16)), date(18, 10))
        state.lastSuccess = date(16, 10)
        state.recordAttempt(at: date(17, 10), calendar: calendar)
        XCTAssertEqual(next(date(17, 10, 1)), date(17, 10, 30))
        state.recordAttempt(at: date(17, 10, 30), calendar: calendar)
        state.recordAttempt(at: date(17, 11), calendar: calendar)
        XCTAssertEqual(next(date(17, 12)), date(18, 10))
        state.recordAttempt(at: date(18, 10), calendar: calendar)
        XCTAssertEqual(state.attempts, 1)
        XCTAssertEqual(try JSONDecoder().decode(HolidayCheckState.self, from: JSONEncoder().encode(state)), state)
    }

    func testPreferencesMigrateWithoutResettingExistingCustomization() throws {
        var preferences = AppPreferences()
        preferences.panelWidth = 330
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        old.removeValue(forKey: "automaticallyUpdatesHolidays")
        let migrated = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(migrated.panelWidth, 330)
        XCTAssertTrue(migrated.automaticallyUpdatesHolidays ?? true)
        preferences.automaticallyUpdatesHolidays = false
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences)).automaticallyUpdatesHolidays, false)
    }

    func testScheduleUsesLocalGregorianDaysAcrossNewYearAndDST() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        var state = HolidayCheckState()
        state.lastSuccess = local(2026, 12, 31, 10)
        XCTAssertEqual(state.nextCheck(after: local(2026, 12, 31, 23), timeZone: cal.timeZone), local(2027, 1, 1, 10))
        state.lastSuccess = local(2026, 3, 7, 10)
        XCTAssertEqual(state.nextCheck(after: local(2026, 3, 7, 23), timeZone: cal.timeZone), local(2026, 3, 8, 10))
        state.lastSuccess = local(2026, 10, 31, 10)
        XCTAssertEqual(state.nextCheck(after: local(2026, 10, 31, 23), timeZone: cal.timeZone), local(2026, 11, 1, 10))
    }

    func testLiveDomesticSourcesWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CALDOCK_LIVE_HOLIDAYS"] == "1" else {
            throw XCTSkip("Opt-in network acceptance; unit tests stay offline")
        }
        for source in HolidayDataSource.allCases {
            var request = URLRequest(url: source.url(year: 2026), timeoutInterval: 12)
            request.setValue("CalDock/1 (macOS; holiday-calendar)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, source.name)
            XCTAssertEqual(try HolidayDataDecoder.decode(data, source: source, year: 2026).days.count, 39, source.name)
        }
        guard case .available = await HolidayFetcher().fetch(year: 2026) else { return XCTFail("Live fetch failed") }
    }
}

private actor Requests {
    var urls: [URL] = []
    func add(_ url: URL) { urls.append(url) }
}
