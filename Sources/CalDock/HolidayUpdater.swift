import AppKit
import CalendarCore
import Combine
import WidgetKit

@MainActor
final class HolidayUpdater: ObservableObject {
    static let shared = HolidayUpdater()
    @Published private(set) var isChecking = false
    @Published private(set) var state: HolidayCheckState
    @Published private(set) var message = "使用内置节假日数据，等待首次检查。"
    @Published private(set) var years = HolidayStore.shared.supportedYears
    @Published private(set) var sourceSummary = "内置官方安排"
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var work: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var automaticRequest = false
    private lazy var fetcher = HolidayFetcher()
    private var automaticEnabled: Bool { AppSettings.shared.value.automaticallyUpdatesHolidays ?? true }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "holidayChecks.v1"),
           let saved = try? JSONDecoder().decode(HolidayCheckState.self, from: data) { state = saved }
        else { state = HolidayCheckState() }
    }

    func start() {
        guard !started else { return }
        started = true
        if let url = HolidayCache.fileURL {
            do { try HolidayStore.shared.loadCache(from: url) }
            catch {
                message = "本地节假日缓存无法读取，继续使用内置数据；下次检查将重新下载。"
                state = HolidayCheckState()
            }
        }
        if HolidayStore.shared.downloadedYears.isEmpty, state.lastSuccess != nil { state = HolidayCheckState() }
        refreshSummary()
        if !HolidayStore.shared.downloadedYears.isEmpty { message = "已载入本地节假日数据。" }
        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                     NSApplication.didBecomeActiveNotification, NSNotification.Name("NSSystemClockDidChangeNotification")] {
            center.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.schedule() }
            }.store(in: &subscriptions)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.schedule() } }.store(in: &subscriptions)
        center.publisher(for: .calDockPreferencesChanged).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.automaticEnabled && self.automaticRequest { self.work?.cancel() }
                self.schedule()
            }
        }.store(in: &subscriptions)
        schedule()
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard started, automaticEnabled, !isChecking else { return }
        let now = Date()
        let next = state.nextCheck(after: now)
        if next <= now { check(manual: false); return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            // Re-evaluate after sleep or a clock change, including the daytime restriction.
            Task { @MainActor in self?.schedule() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkNow() { check(manual: true) }

    private func check(manual: Bool) {
        guard started, !isChecking else { return }
        timer?.invalidate(); timer = nil
        automaticRequest = !manual
        isChecking = true
        state.recordAttempt(at: Date(), calendar: Calendar(identifier: .gregorian))
        persistState()
        message = "正在检查中国法定节假日…"
        work = Task { @MainActor in
            defer {
                isChecking = false
                automaticRequest = false
                work = nil
                schedule()
            }
            let year = Calendar(identifier: .gregorian).component(.year, from: Date())
            let current = await fetcher.fetch(year: year)
            guard !Task.isCancelled else { message = "已停止自动检查，保留现有数据。"; return }
            // The backup API allows one request per second. Space annual requests even on a fast connection.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { message = "已停止自动检查，保留现有数据。"; return }
            let upcoming = await fetcher.fetch(year: year + 1)
            guard !Task.isCancelled else { message = "已停止自动检查，保留现有数据。"; return }
            var entries: [HolidayYearData] = []
            if case .available(let data) = current { entries.append(data) }
            if case .available(let data) = upcoming { entries.append(data) }
            do {
                guard let url = HolidayCache.fileURL else { throw CocoaError(.fileNoSuchFile) }
                let changed = try HolidayStore.shared.install(entries, cacheURL: url)
                refreshSummary()
                if changed {
                    NotificationCenter.default.post(name: .calDockHolidaysChanged, object: nil)
                    WidgetCenter.shared.reloadTimelines(ofKind: SharedPreferences.widgetKind)
                    if AppSettings.shared.value.holidayNotifications { HolidayNotifier.shared.schedule() }
                }
                if case .available = current {
                    state.lastSuccess = Date()
                    message = changed ? "节假日数据已更新。" : "已检查，当前节假日数据已是最新。"
                } else {
                    message = "\(year) 年数据暂未获取成功，保留原有安排；白天最多重试 3 次，间隔 30 分钟。"
                }
                switch upcoming {
                case .available: break
                case .notPublished: message += " \(year + 1) 年安排尚未发布到数据源，继续保留已有数据。"
                case .failed: message += " \(year + 1) 年数据源暂不可用，下次检查时重试。"
                }
                persistState()
            } catch {
                message = "节假日数据保存失败，保留原有安排；稍后重试。"
            }
        }
    }

    private func refreshSummary() {
        years = HolidayStore.shared.supportedYears
        let downloaded = HolidayStore.shared.downloadedYears
        sourceSummary = downloaded.isEmpty ? "内置官方安排" : downloaded.map { "\($0.year)：\($0.source.name)" }.joined(separator: "；")
    }

    private func persistState() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: "holidayChecks.v1") }
    }
}
