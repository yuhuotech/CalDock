import AppKit
import CalendarCore
import Combine
import EventKit
import SwiftUI

struct CalendarSource: Identifiable {
    let id: String
    let title: String
    let color: Color
    let writable: Bool
}

struct CalendarEvent: Identifiable {
    let id: String
    let eventIdentifier: String?
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String
    let color: Color
    let calendarTitle: String
    let calendarIdentifier: String
    let writable: Bool
}

// Each EventKit store stays on its owning queue; EK objects never cross queues.
private final class EventReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CalDock.events", qos: .userInitiated)
    private var store: EKEventStore?

    func read(range: DateInterval, disabled: [String], completion: @escaping ([CalendarEvent]) -> Void) {
        queue.async { [self] in
            let store: EKEventStore
            if let existing = self.store { store = existing }
            else { store = EKEventStore(); self.store = store }
            // Refresh this queue's cache after writes from another EventKit store.
            store.reset()
            let calendars = store.calendars(for: .event).filter { !disabled.contains($0.calendarIdentifier) }
            guard !calendars.isEmpty else { completion([]); return }
            let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
            let matches = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            completion(matches.enumerated().map { index, event in
                CalendarEvent(id: "\(event.eventIdentifier ?? "event")-\(event.startDate.timeIntervalSince1970)-\(index)", eventIdentifier: event.eventIdentifier,
                              title: event.title ?? "未命名事件", start: event.startDate, end: event.endDate,
                              allDay: event.isAllDay, location: event.location ?? "",
                              color: Color(cgColor: event.calendar.cgColor), calendarTitle: event.calendar.title,
                              calendarIdentifier: event.calendar.calendarIdentifier,
                              writable: event.calendar.allowsContentModifications)
            })
        }
    }
}

@MainActor
final class EventProvider: ObservableObject {
    static let shared = EventProvider()
    @Published var authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published var calendars: [CalendarSource] = []
    @Published var events: [CalendarEvent] = []
    @Published var error: String?
    @Published var loading = false
    private var store: EKEventStore?
    private var observation: NSObjectProtocol?
    private var requestNumber = 0
    private let reader = EventReader()
    private var lastRange: DateInterval?
    private var lastDisabled: [String] = []
    private var active = false
    private var dirty = true
    private var refreshTask: Task<Void, Never>?

    init() {
        observation = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.dirty = true
                self.refreshTask?.cancel()
                self.refreshTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    self.store?.reset()
                    self.refreshCalendars()
                    if self.active, let range = self.lastRange { self.load(range: range, disabled: self.lastDisabled, force: true) }
                }
            }
        }
    }

    func requestAccess() {
        let store = getStore()
        NotificationCenter.default.post(name: .calDockInteractionBegan, object: nil)
        store.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                NotificationCenter.default.post(name: .calDockInteractionEnded, object: nil)
                guard let self else { return }
                self.authorized = granted
                self.error = error?.localizedDescription ?? (granted ? nil : "日历访问未授权。可在系统设置 → 隐私与安全性 → 日历中允许 CalDock。")
                if granted {
                    self.refreshCalendars()
                    if let range = self.lastRange { self.load(range: range, disabled: self.lastDisabled, force: true) }
                }
            }
        }
    }

    private func getStore() -> EKEventStore {
        if let store { return store }
        let store = EKEventStore()
        self.store = store
        return store
    }

    func refreshCalendars() {
        let allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        if allowed != authorized { dirty = true; requestNumber += 1 }
        authorized = allowed
        guard authorized else { calendars = []; events = []; return }
        calendars = getStore().calendars(for: .event).map {
            CalendarSource(id: $0.calendarIdentifier, title: $0.title,
                           color: Color(cgColor: $0.cgColor), writable: $0.allowsContentModifications)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func setActive(_ value: Bool) {
        active = value
        if value { refreshCalendars() }
    }

    func refresh() {
        store?.reset()
        refreshCalendars()
        if let range = lastRange { load(range: range, disabled: lastDisabled, force: true) }
    }

    func load(range: DateInterval, disabled: [String], force: Bool = false) {
        let allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        if allowed != authorized { dirty = true }
        authorized = allowed
        let changed = lastRange != range || lastDisabled != disabled
        lastRange = range; lastDisabled = disabled
        guard authorized else { requestNumber += 1; events = []; loading = false; return }
        guard force || changed || dirty else { return }
        dirty = false
        refreshCalendars()
        requestNumber += 1
        let number = requestNumber
        loading = true
        reader.read(range: range, disabled: disabled) { [weak self] values in
            Task { @MainActor in
                guard let self, self.requestNumber == number else { return }
                self.authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
                self.events = self.authorized ? values : []
                self.loading = false
            }
        }
    }

    func create(title: String, start: Date, end: Date, allDay: Bool, calendarID: String, location: String, notes: String) throws {
        guard authorized else { throw EventError.noAccess }
        guard end > start else { throw EventError.invalidRange }
        let store = getStore()
        guard let calendar = store.calendar(withIdentifier: calendarID), calendar.allowsContentModifications else { throw EventError.noCalendar }
        let event = EKEvent(eventStore: store)
        event.title = title; event.startDate = start; event.endDate = end
        event.isAllDay = allDay; event.calendar = calendar; event.location = location; event.notes = notes
        try store.save(event, span: .thisEvent, commit: true)
        dirty = true
        if let range = lastRange { load(range: range, disabled: lastDisabled, force: true) }
    }

    func delete(_ event: CalendarEvent) throws {
        guard authorized else { throw EventError.noAccess }
        let value = try storedEvent(event)
        guard value.calendar?.allowsContentModifications == true else { throw EventError.noCalendar }
        try getStore().remove(value, span: .thisEvent, commit: true)
        dirty = true
        if let range = lastRange { load(range: range, disabled: lastDisabled, force: true) }
    }

    func update(_ event: CalendarEvent, title: String, start: Date, end: Date, allDay: Bool, calendarID: String) throws {
        guard authorized else { throw EventError.noAccess }
        guard end > start else { throw EventError.invalidRange }
        let value = try storedEvent(event)
        guard value.calendar?.allowsContentModifications == true else { throw EventError.noCalendar }
        guard let calendar = getStore().calendar(withIdentifier: calendarID), calendar.allowsContentModifications else {
            throw EventError.noCalendar
        }
        value.title = title; value.startDate = start; value.endDate = end
        value.isAllDay = allDay; value.calendar = calendar
        try getStore().save(value, span: .thisEvent, commit: true)
        dirty = true
        if let range = lastRange { load(range: range, disabled: lastDisabled, force: true) }
    }

    private func storedEvent(_ event: CalendarEvent) throws -> EKEvent {
        guard let identifier = event.eventIdentifier, let value = getStore().event(withIdentifier: identifier) else {
            throw EventError.noEvent
        }
        // EventKit identifiers can refer to an entire recurring series. Resolve
        // the occurrence shown in this row before editing or deleting thisEvent.
        if value.hasRecurrenceRules || value.startDate != event.start {
            let predicate = getStore().predicateForEvents(withStart: event.start, end: max(event.end, event.start.addingTimeInterval(1)), calendars: [value.calendar])
            guard let occurrence = getStore().events(matching: predicate).first(where: {
                $0.eventIdentifier == identifier && $0.startDate == event.start
            }) else { throw EventError.noEvent }
            return occurrence
        }
        return value
    }

    enum EventError: LocalizedError {
        case noAccess, invalidRange, noCalendar, noEvent
        var errorDescription: String? {
            switch self {
            case .noAccess: return "请先允许访问系统日历。"
            case .invalidRange: return "结束时间必须晚于开始时间。"
            case .noCalendar: return "请选择可写入的日历。"
            case .noEvent: return "这个事件已在系统日历中被删除或不可编辑。"
            }
        }
    }
}

@MainActor
final class CalendarModel: ObservableObject {
    @Published var month: Date = Date()
    @Published var selected: Date = Date()
    @Published var days: [DayInfo] = []
    @Published var eventsByDay: [String: [CalendarEvent]] = [:]
    @Published var isPinned = false
    @Published var agendaVisible = false
    @Published var jumpVisible = false
    let settings = AppSettings.shared
    let provider = EventProvider.shared
    var engine: CalendarEngine { CalendarEngine(firstWeekday: settings.value.firstWeekday) }
    private var subscriptions = Set<AnyCancellable>()
    var active = false
    var resize: (() -> Void)?
    private var previousToday = Calendar.current.startOfDay(for: Date())

    init() {
        provider.$events.receive(on: RunLoop.main).sink { [weak self] events in self?.indexEvents(events) }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .calDockHolidaysChanged).receive(on: RunLoop.main)
            .sink { [weak self] _ in if self?.active == true { self?.refresh() } }.store(in: &subscriptions)
    }

    func open() {
        clockChanged()
        active = true; provider.setActive(true)
        agendaVisible = settings.value.showAgenda
        refresh()
    }

    func close() { active = false; provider.setActive(false); jumpVisible = false }

    func refresh() {
        days = engine.monthGrid(month)
        guard let start = days.first?.date, let last = days.last?.date,
              let end = engine.calendar.date(byAdding: .day, value: 1, to: last) else { return }
        provider.load(range: DateInterval(start: start, end: end), disabled: settings.value.disabledCalendarIDs)
        indexEvents(provider.events)
    }

    private func indexEvents(_ events: [CalendarEvent]) {
        var index: [String: [CalendarEvent]] = [:]
        let engine = self.engine
        for day in days {
            index[engine.dateKey(day.date)] = events.filter { engine.eventIntersectsDay(start: $0.start, end: $0.end, day: day.date) }
        }
        eventsByDay = index
        if active { DispatchQueue.main.async { [weak self] in self?.resize?() } }
    }

    func clockChanged(now: Date = Date()) {
        let cal = engine.calendar
        if !cal.isDate(previousToday, inSameDayAs: now), cal.isDate(selected, inSameDayAs: previousToday) {
            selected = now
            if cal.isDate(month, equalTo: previousToday, toGranularity: .month) { month = now }
        }
        previousToday = cal.startOfDay(for: now)
        if active { refresh() }
    }

    var selectedEvents: [CalendarEvent] { eventsByDay[engine.dateKey(selected)] ?? [] }

    func moveMonth(_ amount: Int) {
        let year = engine.calendar.component(.year, from: month)
        guard (1901...2099).contains(year + amount / 12),
              let next = engine.calendar.date(byAdding: .month, value: amount, to: engine.monthStart(month)),
              (1901...2099).contains(engine.calendar.component(.year, from: next)) else { return }
        month = next
        refresh()
    }

    func today() { month = Date(); selected = Date(); refresh() }

    func select(_ day: DayInfo) {
        selected = day.date
        if !day.inMonth { month = day.date; refresh() }
        if !selectedEvents.isEmpty { agendaVisible = true; resize?() }
    }

    func moveDay(_ amount: Int) {
        guard let date = engine.calendar.date(byAdding: .day, value: amount, to: selected),
              (1901...2099).contains(engine.calendar.component(.year, from: date)) else { return }
        selected = date
        if !engine.calendar.isDate(date, equalTo: month, toGranularity: .month) { month = date; refresh() }
    }
}
