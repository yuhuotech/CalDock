import AppKit
import CalendarCore
import SwiftUI

struct CalendarView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var model: CalendarModel
    @ObservedObject var provider = EventProvider.shared
    @ObservedObject private var reminders = ReminderProvider.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoverDate: Date?
    @State private var quickAddPresented = false
    @State private var editingEvent: CalendarEvent?
    @State private var editingReminder: CalendarReminder?
    @State private var confirmingDeleteID: String?
    @State private var agendaError: String?
    private var p: AppPreferences { settings.value }
    private var dark: Bool { p.appearance == "dark" || (p.appearance == "system" && colorScheme == .dark) }
    private var palette: CalendarPalette { p.palette(dark: dark) }
    private var primary: Color { Color(hex: palette[.date]) }
    private var secondary: Color { Color(hex: palette[.title]) }
    private var background: Color { Color(hex: palette[.background]) }

    var body: some View {
        VStack(spacing: 0) {
            header
            weekdayHeader.padding(.top, 3).padding(.bottom, 5)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(model.days) { day in dayCell(day) }
            }
            .padding(.horizontal, 10)
            if model.jumpVisible { jumpControls.padding(.horizontal, 14).padding(.vertical, 8) }
            if model.agendaVisible { agenda }
            if !p.hideFooter { footer.padding(.top, 4).padding(.bottom, 6) }
            else { Color.clear.frame(height: 6) }
        }
        .foregroundStyle(primary)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.14), lineWidth: 0.5))
        .frame(width: p.panelWidth)
        .onAppear { reminders.setActive(model.agendaVisible, day: model.selected) }
        .onDisappear { reminders.setActive(false, day: model.selected) }
        .onChange(of: model.agendaVisible) { _, visible in reminders.setActive(visible, day: model.selected) }
        .onChange(of: model.selected) { _, date in
            confirmingDeleteID = nil; agendaError = nil
            if model.agendaVisible { reminders.load(day: date) }
        }
        .onChange(of: reminders.reminders.count) { _, _ in model.resize?() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.agendaVisible { reminders.setActive(true, day: model.selected) }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            action("chevron.left", help: "上个月（←）；按住 Option 切换上一年") { model.moveMonth(NSEvent.modifierFlags.contains(.option) ? -12 : -1) }
            Spacer(minLength: 0)
            Button { model.jumpVisible.toggle(); model.resize?() } label: {
                Text(StatusFormatter().string(model.month, pattern: "yyyy / MM"))
                    .font(.system(size: 19 * p.fontScale, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary).monospacedDigit()
            }.buttonStyle(.plain).help("跳转年月")
            Spacer(minLength: 0)
            action("chevron.right", help: "下个月（→）；按住 Option 切换下一年") { model.moveMonth(NSEvent.modifierFlags.contains(.option) ? 12 : 1) }
        }.padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 3)
    }

    private var weekdayHeader: some View {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                Text(names[(i + p.firstWeekday - 1) % 7])
                    .font(.system(size: 13 * p.fontScale, weight: .medium))
                    .foregroundStyle(secondary).frame(maxWidth: .infinity)
            }
        }.padding(.horizontal, 10)
    }

    private func dayCell(_ day: DayInfo) -> some View {
        let today = model.engine.calendar.isDateInToday(day.date)
        let selected = model.engine.calendar.isDate(day.date, inSameDayAs: model.selected)
        let hasEvent = !(model.eventsByDay[model.engine.dateKey(day.date)] ?? []).isEmpty
        let accent = Color(hex: palette[.today])
        let textColor: Color = today ? .white : (day.isWeekend ? Color(hex: palette[.weekend]) : primary)
        let festive = day.festival != nil || day.solarTerm != nil || day.lunar.day == 1
        return Button { model.select(day) } label: {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if today { Circle().fill(accent).frame(width: min(p.effectiveRowHeight - 1, 45), height: min(p.effectiveRowHeight - 1, 45)) }
                    else if selected { RoundedRectangle(cornerRadius: 8).fill(primary.opacity(0.09)).padding(2) }
                    else if hoverDate == day.date { RoundedRectangle(cornerRadius: 8).fill(primary.opacity(0.045)).padding(2) }
                    VStack(spacing: p.hideLunar ? 3 : 0) {
                        Text("\(day.day)").font(.system(size: 15 * p.fontScale, weight: .medium, design: .rounded)).monospacedDigit()
                        if !p.hideLunar {
                            Text(day.label).font(.system(size: 10 * p.fontScale, weight: festive ? .medium : .regular))
                                .foregroundStyle(today ? .white : (festive ? Color(hex: palette[.festival]) : textColor))
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    if p.showEventDots && hasEvent {
                        Circle().fill(today ? .white : Color(hex: palette[.event])).frame(width: 3.5, height: 3.5)
                            .offset(y: p.effectiveRowHeight / 2 - 3)
                    }
                }.frame(maxWidth: .infinity).frame(height: p.effectiveRowHeight)
                if p.showHolidayBadges, let holiday = day.holiday {
                    Text(holiday.badge).font(.system(size: 7.5 * p.fontScale, weight: .semibold))
                        .foregroundStyle(Color(hex: palette[holiday.kind == .work ? .work : .rest]))
                        .padding(.trailing, 1).padding(.top, 1)
                }
            }
            .foregroundStyle(textColor)
            .opacity(day.inMonth ? 1 : 0.38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverDate = $0 ? day.date : nil }
        .help(dayHelp(day))
        .accessibilityLabel(dayHelp(day))
        .contextMenu {
            Button("在系统日历中打开") { openSystemCalendar(day.date) }
            Button("复制日期") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.engine.dateKey(day.date), forType: .string)
            }
        }
    }

    private func dayHelp(_ day: DayInfo) -> String {
        let detail = [day.lunar.fullLabel, day.festival, day.solarTerm, day.holiday.map { $0.name + " · " + ($0.kind == .rest ? "休息" : "上班") }]
            .compactMap { $0 }.joined(separator: " · ")
        let count = model.eventsByDay[model.engine.dateKey(day.date)]?.count ?? 0
        return model.engine.dateKey(day.date) + " " + detail + (count > 0 ? " · \(count) 个事件" : "")
    }

    private var jumpControls: some View {
        HStack {
            Picker("年", selection: Binding(get: { model.engine.calendar.component(.year, from: model.month) }, set: { year in jump(year: year) })) {
                ForEach(1901...2099, id: \.self) { Text(String($0)).tag($0) }
            }.labelsHidden().frame(width: 110)
            Picker("月", selection: Binding(get: { model.engine.calendar.component(.month, from: model.month) }, set: { month in jump(month: month) })) {
                ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) }
            }.labelsHidden().frame(width: 95)
            Spacer()
            Button("今天") { model.today(); model.jumpVisible = false; model.resize?() }
        }.controlSize(.small)
    }

    private func jump(year: Int? = nil, month: Int? = nil) {
        let cal = model.engine.calendar
        let parts = DateComponents(year: year ?? cal.component(.year, from: model.month), month: month ?? cal.component(.month, from: model.month), day: 1)
        if let date = cal.date(from: parts) { model.month = date; model.refresh() }
    }

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text(StatusFormatter().string(model.selected, pattern: "M月d日 EEEE")).font(.system(size: 12, weight: .semibold))
                Spacer()
                if provider.loading || reminders.loading { ProgressView().controlSize(.mini) }
                Button {
                    editingEvent = nil; editingReminder = nil
                    quickAddPresented = true
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("快速添加事件或提醒")
                    .background(QuickEditorPopover(isPresented: $quickAddPresented) {
                        QuickAddView(date: model.selected, onClose: { quickAddPresented = false })
                    })
                Button { openSystemCalendar(model.selected) } label: { Image(systemName: "arrow.up.forward.app") }.buttonStyle(.plain).help("在系统日历中打开或添加事件")
                Button { model.agendaVisible = false; model.resize?() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("收起日程")
            }
            if !provider.authorized {
                HStack(spacing: 8) {
                    Text("连接系统日历，显示事件与日程").font(.system(size: 11)).foregroundStyle(secondary)
                    Spacer(minLength: 0)
                    Button("连接") { provider.requestAccess() }.controlSize(.small)
                }
            }
            if model.selectedEvents.isEmpty && reminders.reminders.isEmpty {
                Text("当天没有日程").font(.system(size: 12)).foregroundStyle(secondary).padding(.vertical, 3)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(model.selectedEvents) { event in eventRow(event) }
                        ForEach(reminders.reminders) { reminder in reminderRow(reminder) }
                    }
                }.frame(height: min(CGFloat(model.selectedEvents.count + reminders.reminders.count) * 51, 166))
            }
            if let agendaError {
                Text(agendaError).font(.system(size: 10)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.top, 5).padding(.bottom, 7)
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5).fill(event.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text(event.allDay ? "全天 · \(event.calendarTitle)" : "\(StatusFormatter().string(event.start, pattern: "M/d HH:mm")) – \(StatusFormatter().string(event.end, pattern: "M/d HH:mm"))")
                    .font(.system(size: 10)).foregroundStyle(secondary)
                if !event.location.isEmpty { Text(event.location).font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if event.writable && event.eventIdentifier != nil {
                rowActions(id: "event-" + event.id, label: "事件", edit: {
                    quickAddPresented = false; editingReminder = nil; editingEvent = event
                }, delete: { try provider.delete(event) })
                    .background(QuickEditorPopover(isPresented: Binding(get: { editingEvent?.id == event.id }, set: { if !$0 { editingEvent = nil } })) {
                        QuickAddView(date: event.start, editing: event, onClose: { editingEvent = nil })
                    })
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func reminderRow(_ reminder: CalendarReminder) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checklist").font(.system(size: 10)).foregroundStyle(secondary).frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text("提醒 · " + (reminder.hasTime ? StatusFormatter().string(reminder.dueDate!, pattern: "HH:mm") : "全天") + " · " + reminder.listTitle)
                    .font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if reminder.writable {
                rowActions(id: "reminder-" + reminder.id, label: "提醒", edit: {
                    quickAddPresented = false; editingEvent = nil; editingReminder = reminder
                }, delete: { try reminders.delete(reminder) })
                    .background(QuickEditorPopover(isPresented: Binding(get: { editingReminder?.id == reminder.id }, set: { if !$0 { editingReminder = nil } })) {
                        QuickAddView(date: model.selected, editingReminder: reminder, onClose: { editingReminder = nil })
                    })
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func rowActions(id: String, label: String, edit: @escaping () -> Void, delete: @escaping () throws -> Void) -> some View {
        HStack(spacing: 2) {
            if confirmingDeleteID == id {
                Button("删除") {
                    do { try delete(); confirmingDeleteID = nil; agendaError = nil }
                    catch { agendaError = error.localizedDescription; model.resize?() }
                }.foregroundStyle(.red).help("确认删除" + label + "，同步到系统")
                Button { confirmingDeleteID = nil } label: { Image(systemName: "xmark").frame(width: 18, height: 20) }
                    .help("取消删除")
            } else {
                Button { confirmingDeleteID = nil; agendaError = nil; edit() } label: { Image(systemName: "pencil").frame(width: 18, height: 20) }
                    .help("编辑" + label).accessibilityLabel("编辑" + label)
                Button { confirmingDeleteID = id } label: { Image(systemName: "trash").frame(width: 18, height: 20) }
                    .help("删除" + label).accessibilityLabel("删除" + label)
            }
        }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(secondary)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            action("slider.horizontal.3", help: "设置（⌘,）") { NotificationCenter.default.post(name: .calDockShowSettings, object: nil) }
            Button { model.today() } label: {
                HStack(spacing: 5) {
                    Circle().fill(Color(hex: palette[.event])).frame(width: 5, height: 5)
                    Text(footerLabel).font(.system(size: 11 * p.fontScale)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }.buttonStyle(.plain).help("回到今天（空格）")
            Spacer(minLength: 0)
            action(model.agendaVisible ? "list.bullet.rectangle.fill" : "list.bullet.rectangle", help: "显示或隐藏日程") {
                model.agendaVisible.toggle(); model.resize?()
            }
            action(model.isPinned ? "pin.fill" : "pin", help: "固定面板；按 Esc 仍可关闭") { model.isPinned.toggle() }
        }.foregroundStyle(secondary).padding(.horizontal, 14)
    }

    private var footerLabel: String {
        let date = model.selected
        let week = model.engine.calendar.component(.weekOfYear, from: date)
        let solar = StatusFormatter().string(date, pattern: "M月d日")
        return solar + " 第\(week)周" + (p.hideLunar ? "" : " " + model.engine.lunarInfo(date).fullLabel)
    }

    private func action(_ symbol: String, help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 20, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(help)
    }
}

func openSystemCalendar(_ date: Date) {
    let calendar = NSWorkspace.shared
    if let url = URL(string: "calshow:\(date.timeIntervalSinceReferenceDate)"),
       let handler = calendar.urlForApplication(toOpen: url),
       handler.pathExtension == "app" {
        calendar.open(url)
        return
    }

    // Some macOS installations have no registered calshow handler. Opening the
    // Calendar app directly avoids LaunchServices showing an app-picker dialog.
    let candidates = [
        URL(fileURLWithPath: "/System/Applications/Calendar.app"),
        URL(fileURLWithPath: "/Applications/Calendar.app")
    ]
    if let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
        calendar.open(app)
    }
}
