import EventKit
import CalendarCore
import SwiftUI

enum QuickAddKind: String, CaseIterable, Identifiable {
    case event = "事件"
    case reminder = "提醒"
    var id: String { rawValue }
}

@MainActor
final class ReminderProvider: ObservableObject {
    static let shared = ReminderProvider()
    @Published private(set) var authorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    @Published private(set) var lists: [ReminderList] = []
    @Published var error: String?
    private var store: EKEventStore?
    private var observation: NSObjectProtocol?

    struct ReminderList: Identifiable {
        let id: String
        let title: String
        let writable: Bool
    }

    init() {
        observation = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshLists() }
        }
    }

    private func getStore() -> EKEventStore {
        if let store { return store }
        let store = EKEventStore()
        self.store = store
        return store
    }

    func requestAccess() {
        getStore().requestFullAccessToReminders { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.authorized = granted
                self.error = error?.localizedDescription ?? (granted ? nil : "提醒事项访问未授权。可在系统设置 → 隐私与安全性 → 提醒事项中允许 CalDock。")
                if granted { self.refreshLists() }
            }
        }
    }

    func refreshLists() {
        authorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        guard authorized else { lists = []; return }
        lists = getStore().calendars(for: .reminder).map {
            ReminderList(id: $0.calendarIdentifier, title: $0.title, writable: $0.allowsContentModifications)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func create(title: String, dueDate: Date, listID: String) throws {
        guard authorized else { throw ReminderError.noAccess }
        guard let list = getStore().calendar(withIdentifier: listID), list.allowsContentModifications else { throw ReminderError.noList }
        let reminder = EKReminder(eventStore: getStore())
        reminder.title = title
        reminder.calendar = list
        reminder.dueDateComponents = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        try getStore().save(reminder, commit: true)
    }

    enum ReminderError: LocalizedError {
        case noAccess, noList
        var errorDescription: String? {
            switch self {
            case .noAccess: return "请先允许访问提醒事项。"
            case .noList: return "请选择可写入的提醒列表。"
            }
        }
    }
}

struct QuickAddView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var events = EventProvider.shared
    @ObservedObject private var reminders = ReminderProvider.shared
    let date: Date
    @State private var kind: QuickAddKind = .event
    @State private var title = ""
    @State private var allDay = true
    @State private var start: Date
    @State private var end: Date
    @State private var dueDate: Date
    @State private var calendarID = ""
    @State private var listID = ""
    @State private var error: String?

    init(date: Date) {
        self.date = date
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: date)
        _start = State(initialValue: day.addingTimeInterval(10 * 3600))
        _end = State(initialValue: day.addingTimeInterval(11 * 3600))
        _dueDate = State(initialValue: day.addingTimeInterval(18 * 3600))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $kind) {
                ForEach(QuickAddKind.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            TextField(kind == .event ? "事件标题" : "提醒内容", text: $title)
                .textFieldStyle(.roundedBorder).onSubmit(save)
            if kind == .event { eventFields } else { reminderFields }
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加") { save() }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || targetID.isEmpty)
            }
        }
        .font(.system(size: 12)).controlSize(.small).padding(13).frame(width: 278)
        .onAppear {
            events.refreshCalendars(); reminders.refreshLists()
            calendarID = events.calendars.first(where: \.writable)?.id ?? ""
            listID = reminders.lists.first(where: \.writable)?.id ?? ""
        }
        .onChange(of: events.authorized) { _, granted in
            if granted {
                events.refreshCalendars()
                calendarID = events.calendars.first(where: \.writable)?.id ?? ""
            }
        }
        .onChange(of: reminders.authorized) { _, granted in
            if granted {
                reminders.refreshLists()
                listID = reminders.lists.first(where: \.writable)?.id ?? ""
            }
        }
        .onChange(of: kind) { _, _ in error = nil }
    }

    private var targetID: String { kind == .event ? calendarID : listID }

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
                Text("日期：" + StatusFormatter().string(date, pattern: "yyyy年M月d日")).foregroundStyle(.secondary)
            } else {
                DatePicker("开始", selection: $start, displayedComponents: [.date, .hourAndMinute])
                DatePicker("结束", selection: $end, displayedComponents: [.date, .hourAndMinute])
            }
            Picker("日历", selection: $calendarID) {
                ForEach(events.calendars.filter(\.writable)) { Text($0.title).tag($0.id) }
            }
        }
    }

    private var reminderFields: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !reminders.authorized {
                HStack {
                    Text("需要访问提醒事项").foregroundStyle(.secondary)
                    Spacer()
                    Button("连接") { reminders.requestAccess() }
                }
            }
            DatePicker("提醒时间", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
            Picker("列表", selection: $listID) {
                ForEach(reminders.lists.filter(\.writable)) { Text($0.title).tag($0.id) }
            }
        }
    }

    private func save() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            if kind == .event {
                guard events.authorized else { events.requestAccess(); throw EventProvider.EventError.noAccess }
                let calendar = Calendar.autoupdatingCurrent
                let startDate = allDay ? calendar.startOfDay(for: date) : start
                let endDate = allDay ? calendar.date(byAdding: .day, value: 1, to: startDate)! : end
                try events.create(title: value, start: startDate, end: endDate, allDay: allDay, calendarID: calendarID, location: "", notes: "")
            } else {
                guard reminders.authorized else { reminders.requestAccess(); throw ReminderProvider.ReminderError.noAccess }
                try reminders.create(title: value, dueDate: dueDate, listID: listID)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
