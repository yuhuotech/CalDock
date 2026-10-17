import EventKit
import CalendarCore
import SwiftUI
import Combine

enum QuickAddKind: String, CaseIterable, Identifiable {
    case event = "事件"
    case reminder = "提醒"
    var id: String { rawValue }
}

struct CalendarReminder: Identifiable {
    let id: String
    let title: String
    let dueDate: Date?
    let hasTime: Bool
    let listID: String
    let listTitle: String
    let writable: Bool
}

@MainActor
final class ReminderProvider: ObservableObject {
    static let shared = ReminderProvider()
    @Published private(set) var authorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    @Published private(set) var lists: [ReminderList] = []
    @Published private(set) var reminders: [CalendarReminder] = []
    @Published private(set) var requestingAccess = false
    @Published private(set) var loading = false
    @Published var error: String?
    private var store: EKEventStore?
    private var observation: NSObjectProtocol?
    private var lastInterval: DateInterval?
    private var fetchToken: Any?
    private var fetchGeneration = 0
    private var active = false
    private var grantedInSession = false

    struct ReminderList: Identifiable {
        let id: String
        let title: String
        let writable: Bool
    }

    init() {
        observation = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLists()
                if self?.active == true, let interval = self?.lastInterval { self?.load(interval: interval) }
            }
        }
    }

    private func getStore() -> EKEventStore {
        if let store { return store }
        let store = EKEventStore()
        self.store = store
        return store
    }

    func requestAccess() {
        guard !requestingAccess else { return }
        requestingAccess = true
        NotificationCenter.default.post(name: .calDockInteractionBegan, object: nil)
        getStore().requestFullAccessToReminders { [weak self] granted, error in
            Task { @MainActor in
                defer { NotificationCenter.default.post(name: .calDockInteractionEnded, object: nil) }
                guard let self else { return }
                self.requestingAccess = false
                self.grantedInSession = granted
                self.error = error?.localizedDescription ?? (granted ? nil : "提醒事项访问未授权。可在系统设置 → 隐私与安全性 → 提醒事项中允许 CalDock。")
                if granted {
                    // Discard the store's pre-authorization calendar cache.
                    self.stopFetch()
                    self.store = nil
                }
                self.refreshLists()
                if self.active, let interval = self.lastInterval { self.load(interval: interval) }
            }
        }
    }

    func refreshLists() {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .denied || status == .restricted { grantedInSession = false }
        let allowed = status == .fullAccess || (status == .notDetermined && grantedInSession)
        guard allowed else {
            authorized = false; lists = []; reminders = []; stopFetch()
            return
        }
        lists = getStore().calendars(for: .reminder).map {
            ReminderList(id: $0.calendarIdentifier, title: $0.title, writable: $0.allowsContentModifications)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        authorized = true
    }

    var defaultListID: String? { authorized ? getStore().defaultCalendarForNewReminders()?.calendarIdentifier : nil }

    func setActive(_ value: Bool, day: Date) {
        active = value
        if value { refreshLists(); load(day: day) }
        else { stopFetch(); lastInterval = nil; reminders = [] }
    }

    func load(day: Date) {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        load(interval: DateInterval(start: start, end: end))
    }

    private func load(interval: DateInterval) {
        stopFetch()
        lastInterval = interval
        guard authorized else { reminders = []; return }
        let calendars = getStore().calendars(for: .reminder)
        guard !calendars.isEmpty else { reminders = []; return }
        let predicate = getStore().predicateForIncompleteReminders(withDueDateStarting: interval.start, ending: interval.end, calendars: calendars)
        let generation = fetchGeneration
        loading = true
        fetchToken = getStore().fetchReminders(matching: predicate) { [weak self] values in
            Task { @MainActor in
                guard let self, generation == self.fetchGeneration else { return }
                self.loading = false; self.fetchToken = nil
                let calendar = Calendar.autoupdatingCurrent
                self.reminders = (values ?? []).compactMap { reminder -> CalendarReminder? in
                    guard !reminder.isCompleted, let components = reminder.dueDateComponents,
                          let due = calendar.date(from: components), due >= interval.start, due < interval.end,
                          let list = reminder.calendar else { return nil }
                    return CalendarReminder(id: reminder.calendarItemIdentifier, title: reminder.title ?? "未命名提醒",
                                            dueDate: due, hasTime: components.hour != nil, listID: list.calendarIdentifier,
                                            listTitle: list.title, writable: list.allowsContentModifications)
                }.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            }
        }
    }

    private func stopFetch() {
        fetchGeneration += 1
        if let fetchToken { store?.cancelFetchRequest(fetchToken) }
        fetchToken = nil; loading = false
    }

    private func changed() {
        refreshLists()
        if active, let interval = lastInterval { load(interval: interval) }
    }

    func create(title: String, dueDate: Date, listID: String) throws {
        refreshLists()
        guard authorized else { throw ReminderError.noAccess }
        guard let list = getStore().calendar(withIdentifier: listID), list.allowsContentModifications else { throw ReminderError.noList }
        let reminder = EKReminder(eventStore: getStore())
        reminder.title = title
        reminder.calendar = list
        reminder.dueDateComponents = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
        try getStore().save(reminder, commit: true)
        changed()
    }

    func update(_ reminder: CalendarReminder, title: String, dueDate: Date, listID: String) throws {
        refreshLists()
        guard authorized else { throw ReminderError.noAccess }
        guard let value = getStore().calendarItem(withIdentifier: reminder.id) as? EKReminder else { throw ReminderError.noReminder }
        guard value.calendar?.allowsContentModifications == true else { throw ReminderError.noList }
        guard let list = getStore().calendar(withIdentifier: listID), list.allowsContentModifications else { throw ReminderError.noList }
        value.title = title; value.calendar = list
        if reminder.dueDate != dueDate {
            value.dueDateComponents = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
            value.alarms = [EKAlarm(absoluteDate: dueDate)]
        }
        try getStore().save(value, commit: true)
        changed()
    }

    func delete(_ reminder: CalendarReminder) throws {
        refreshLists()
        guard authorized else { throw ReminderError.noAccess }
        guard let value = getStore().calendarItem(withIdentifier: reminder.id) as? EKReminder else { throw ReminderError.noReminder }
        guard value.calendar?.allowsContentModifications == true else { throw ReminderError.noList }
        try getStore().remove(value, commit: true)
        changed()
    }

    enum ReminderError: LocalizedError {
        case noAccess, noList, noReminder
        var errorDescription: String? {
            switch self {
            case .noAccess: return "请先允许访问提醒事项。"
            case .noList: return "请选择可写入的提醒列表。"
            case .noReminder: return "这个提醒已在系统提醒事项中被删除。"
            }
        }
    }
}

struct QuickAddView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var events = EventProvider.shared
    @ObservedObject private var reminders = ReminderProvider.shared
    let date: Date
    let editingEvent: CalendarEvent?
    let editingReminder: CalendarReminder?
    let onClose: (() -> Void)?
    @State private var kind: QuickAddKind = .event
    @State private var title = ""
    @State private var allDay = true
    @State private var start: Date
    @State private var end: Date
    @State private var dueDate: Date
    @State private var calendarID = ""
    @State private var listID = ""
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    init(date: Date, editing event: CalendarEvent? = nil, editingReminder reminder: CalendarReminder? = nil, onClose: (() -> Void)? = nil) {
        self.date = date
        self.editingEvent = event
        self.editingReminder = reminder
        self.onClose = onClose
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: date)
        _start = State(initialValue: event?.start ?? day.addingTimeInterval(10 * 3600))
        _end = State(initialValue: event?.end ?? day.addingTimeInterval(11 * 3600))
        _dueDate = State(initialValue: reminder?.dueDate ?? day.addingTimeInterval(18 * 3600))
        _title = State(initialValue: event?.title ?? reminder?.title ?? "")
        _kind = State(initialValue: reminder == nil ? .event : .reminder)
        _allDay = State(initialValue: event?.allDay ?? true)
        _calendarID = State(initialValue: event?.calendarIdentifier ?? "")
        _listID = State(initialValue: reminder?.listID ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editingEvent == nil && editingReminder == nil {
                Picker("", selection: $kind) {
                    ForEach(QuickAddKind.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            } else {
                Text(editingReminder == nil ? "编辑事件" : "编辑提醒").font(.system(size: 13, weight: .semibold))
            }
            TextField(kind == .event ? "事件标题" : "提醒内容", text: $title)
                .textFieldStyle(.roundedBorder).focused($titleFocused).onSubmit(save)
            if kind == .event { eventFields } else { reminderFields }
            if let message = error ?? (kind == .event ? events.error : reminders.error) {
                Text(message).font(.system(size: 10)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { close() }.keyboardShortcut(.cancelAction)
                Button(editingEvent == nil && editingReminder == nil ? "添加" : "保存") { save() }.keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .font(.system(size: 12)).controlSize(.small).padding(13).frame(width: 278)
        .onAppear {
            NotificationCenter.default.post(name: .calDockInteractionBegan, object: nil)
            events.refreshCalendars(); reminders.refreshLists()
            if let editingEvent { calendarID = editingEvent.calendarIdentifier }
            if let editingReminder { listID = editingReminder.listID }
            selectTargets()
            titleFocused = true
        }
        .onDisappear { NotificationCenter.default.post(name: .calDockInteractionEnded, object: nil) }
        .onReceive(events.$calendars) { calendars in
            if !calendars.contains(where: { $0.id == calendarID && $0.writable }) {
                calendarID = calendars.first(where: \.writable)?.id ?? ""
            }
        }
        .onReceive(reminders.$lists) { lists in
            if !lists.contains(where: { $0.id == listID && $0.writable }) {
                listID = lists.first(where: { $0.id == reminders.defaultListID && $0.writable })?.id
                    ?? lists.first(where: \.writable)?.id ?? ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            events.refreshCalendars(); reminders.refreshLists(); selectTargets()
        }
        .onChange(of: kind) { _, _ in error = nil }
    }

    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return kind == .event
            ? events.authorized && events.calendars.contains { $0.id == calendarID && $0.writable }
            : reminders.authorized && !reminders.requestingAccess && reminders.lists.contains { $0.id == listID && $0.writable }
    }

    private func selectTargets() {
        if !events.calendars.contains(where: { $0.id == calendarID && $0.writable }) {
            calendarID = events.calendars.first(where: \.writable)?.id ?? ""
        }
        if !reminders.lists.contains(where: { $0.id == listID && $0.writable }) {
            listID = reminders.lists.first(where: { $0.id == reminders.defaultListID && $0.writable })?.id
                ?? reminders.lists.first(where: \.writable)?.id ?? ""
        }
    }

    private var eventFields: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !events.authorized {
                HStack {
                    Text("需要访问系统日历").foregroundStyle(.secondary)
                    Spacer()
                    Button("连接") { events.requestAccess() }
                }
            }
            Toggle("全天", isOn: $allDay).toggleStyle(.checkbox)
            if allDay {
                DatePicker("日期", selection: $start, displayedComponents: .date)
            } else {
                DatePicker("开始", selection: $start, displayedComponents: [.date, .hourAndMinute])
                DatePicker("结束", selection: $end, displayedComponents: [.date, .hourAndMinute])
            }
            Picker("日历", selection: $calendarID) {
                ForEach(events.calendars.filter(\.writable)) { Text($0.title).tag($0.id) }
            }
            if events.authorized && calendarID.isEmpty {
                Text("没有可写日历，请先在系统日历中添加。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var reminderFields: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !reminders.authorized {
                HStack {
                    Text("需要访问提醒事项").foregroundStyle(.secondary)
                    Spacer()
                    Button(reminders.requestingAccess ? "连接中…" : "连接") { reminders.requestAccess() }
                        .disabled(reminders.requestingAccess)
                }
            }
            DatePicker("提醒时间", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
            Picker("列表", selection: $listID) {
                ForEach(reminders.lists.filter(\.writable)) { Text($0.title).tag($0.id) }
            }
            if reminders.authorized && listID.isEmpty {
                Text("已连接；没有可写列表，请先在系统提醒事项中添加列表。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSave else { return }
        do {
            if kind == .event {
                guard events.authorized else { events.requestAccess(); throw EventProvider.EventError.noAccess }
                let calendar = Calendar.autoupdatingCurrent
                let startDate = allDay ? calendar.startOfDay(for: start) : start
                let duration = editingEvent.flatMap { event -> Int? in
                    guard event.allDay else { return nil }
                    return calendar.dateComponents([.day], from: event.start, to: event.end).day
                } ?? 1
                let endDate = allDay ? calendar.date(byAdding: .day, value: max(1, duration), to: startDate)! : end
                if let editingEvent {
                    try events.update(editingEvent, title: value, start: startDate, end: endDate, allDay: allDay, calendarID: calendarID)
                } else {
                    try events.create(title: value, start: startDate, end: endDate, allDay: allDay, calendarID: calendarID, location: "", notes: "")
                }
            } else {
                guard reminders.authorized else { reminders.requestAccess(); throw ReminderProvider.ReminderError.noAccess }
                if let editingReminder {
                    try reminders.update(editingReminder, title: value, dueDate: dueDate, listID: listID)
                } else {
                    try reminders.create(title: value, dueDate: dueDate, listID: listID)
                }
            }
            close()
        } catch { self.error = error.localizedDescription }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}
