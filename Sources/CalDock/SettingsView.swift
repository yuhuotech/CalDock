import AppKit
import CalendarCore
import Carbon
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "通用", events = "事件", style = "样式", status = "状态栏"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "switch.2"
        case .events: return "calendar.badge.clock"
        case .style: return "paintpalette"
        case .status: return "menubar.rectangle"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var page = SettingsPage.general
}

@MainActor
final class SettingsController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private var window: NSWindow?
    private let navigation = SettingsNavigation()

    func show() {
        if let window { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 414),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = navigation.page.rawValue
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "CalDockPreferences")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.sizeMode = .small
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(navigation.page.id)
        window.toolbar = toolbar
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: SettingsView(navigation: navigation))
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + SettingsPage.allCases.map { NSToolbarItem.Identifier($0.id) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPage.allCases.map { NSToolbarItem.Identifier($0.id) }
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let page = SettingsPage(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = page.rawValue
        item.paletteLabel = page.rawValue
        item.toolTip = page.rawValue
        item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.rawValue)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        item.target = self
        item.action = #selector(selectPage(_:))
        return item
    }

    @objc private func selectPage(_ sender: NSToolbarItem) {
        guard let page = SettingsPage(rawValue: sender.itemIdentifier.rawValue) else { return }
        navigation.page = page
        window?.title = page.rawValue
        window?.toolbar?.selectedItemIdentifier = sender.itemIdentifier
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var provider = EventProvider.shared
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var login = LoginItemController.shared
    @ObservedObject private var notifier = HolidayNotifier.shared
    @State private var recordingShortcut = false
    @State private var draggingModule: StatusModule?
    @State private var confirmReset = false
    @State private var showEventEditor = false
    @State private var showHelp = false
    @State private var editingDark = false
    @State private var styleTarget = "panel"
    private var p: Binding<AppPreferences> { $settings.value }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    switch navigation.page {
                    case .general: general
                    case .events: events
                    case .style: style
                    case .status: status
                    }
                }.padding(.horizontal, 22).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("CalDock").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("使用说明") { showHelp = true }
                Button("还原设置…") { confirmReset = true }
            }.controlSize(.small).padding(.horizontal, 18).padding(.vertical, 8)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .frame(width: 500, height: 414)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("还原 CalDock 的所有显示设置？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("还原", role: .destructive) { settings.reset() }
        } message: { Text("不会删除系统日历事件，也不会更改系统日历授权和开机启动状态。") }
        .alert("CalDock 使用说明", isPresented: $showHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("点击菜单栏日期图标打开日历，右键打开菜单。\n\n默认快捷键 ⌃⌘X，全屏时也可使用。面板内按 ← / → 切换月份，空格回到今天，Esc 关闭；A 展开日程，P 固定面板，⌘, 打开设置。\n\n点击月份标题跳转年月；右键日期可复制或在系统日历中打开。连接系统日历后可查看日程。")
        }
        .sheet(isPresented: $showEventEditor) { EventEditorView() }
        .onAppear { provider.refreshCalendars() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh(); provider.refreshCalendars(); HolidayNotifier.shared.refreshStatus()
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsRow("启动") {
                Toggle("开机后打开 CalDock", isOn: Binding(get: { login.enabled }, set: { login.setEnabled($0) }))
                    .disabled(login.updating)
            }
            if let message = login.message { note(message) }
            if login.needsApproval { Button("打开登录项设置") { login.openApproval() } }
            settingsRow("快捷键") {
                Toggle("", isOn: p.shortcutEnabled).labelsHidden()
                ShortcutRecorder(isRecording: $recordingShortcut, label: settings.value.shortcutLabel) { key, modifiers, label in
                    settings.value.shortcutKey = key
                    settings.value.shortcutModifiers = modifiers
                    settings.value.shortcutLabel = label
                }.frame(width: 140, height: 23).disabled(!settings.value.shortcutEnabled)
            }
            note("全屏时也可用快捷键打开。若与其他软件冲突，请重新录制。")
            if let error = settings.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
            settingsRow("面板动画") { Toggle("启用淡入", isOn: p[dynamicMember: \.animation]) }
            Divider().padding(.vertical, 3)
            settingsRow("日历事件") { Toggle("显示小圆点", isOn: p.showEventDots) }
            settingsRow("法定节假日") { Toggle("显示休 / 班角标", isOn: p.showHolidayBadges) }
            settingsRow("一周开始于") {
                Picker("", selection: p.firstWeekday) { Text("周日").tag(1); Text("周一").tag(2) }.labelsHidden().frame(width: 130)
            }
            settingsRow("提醒通知") {
                Toggle("节假日推送", isOn: p.holidayNotifications)
            }
            if let message = notifier.message { note(message) }
            if settings.value.holidayNotifications {
                settingsRow("通知测试") { Button("发送测试通知") { notifier.sendTest() } }
            }
            settingsRow("农历信息") { Toggle("隐藏", isOn: p.hideLunar) }
            settingsRow("面板底部") { Toggle("隐藏（⌘, 打开设置）", isOn: p.hideFooter) }
            settingsRow("鼠标悬浮") { Toggle("打开面板", isOn: p.openOnHover) }
            settingsRow("日程列表") { Toggle("打开面板时展开", isOn: p.showAgenda) }
        }.toggleStyle(.checkbox)
    }

    private var events: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("系统日历").font(.system(size: 14, weight: .semibold))
                    Text("选择要显示的日历，事件保留在系统日历中。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(provider.authorized ? "刷新" : "连接日历") {
                    if provider.authorized { provider.refresh() } else { provider.requestAccess() }
                }
            }
            if let error = provider.error { note(error) }
            if provider.authorized {
                if provider.calendars.isEmpty { note("尚无日历。请先在 macOS 日历 App 添加账户或日历。") }
                ForEach(provider.calendars) { calendar in
                    HStack {
                        Toggle(isOn: Binding(get: { !settings.value.disabledCalendarIDs.contains(calendar.id) }, set: { enabled in
                            if enabled { settings.value.disabledCalendarIDs.removeAll { $0 == calendar.id } }
                            else { settings.value.disabledCalendarIDs.append(calendar.id) }
                        })) {
                            HStack(spacing: 8) {
                                Circle().fill(calendar.color).frame(width: 8, height: 8)
                                Text(calendar.title)
                            }
                        }.toggleStyle(.checkbox)
                        Spacer()
                        if !calendar.writable { Text("只读").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                    Divider()
                }
                HStack {
                    Button("新建事件…") { showEventEditor = true }.disabled(!provider.calendars.contains { $0.writable })
                    Button("打开系统日历") { openSystemCalendar(Date()) }
                }
            } else {
                note("连接后，可查看事件圆点和每日议程、选择显示哪些日历，并创建系统日历事件。未授权时日历、农历、节气与调休照常使用。")
                Button("打开日历隐私设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            }
            Divider().padding(.vertical, 5)
            Text("节假日与节气").font(.system(size: 14, weight: .semibold))
            note("已内置 2026 年中国大陆官方放假调休安排。其他年份仍显示传统节日与节气，不推算补班。节气为本地算法计算的日期，非精确交节时刻。")
            Link("查看 2026 年官方放假通知 ↗", destination: URL(string: HolidayStore.shared.schedules.first?.source ?? "https://www.gov.cn")!)
                .font(.system(size: 12))
            note("节日通知在前一天 18:00 提醒，按本机时区安排。不会向任何服务器上传日程。")
        }
    }

    private var style: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("显示位置", selection: $styleTarget) {
                Text("菜单栏面板").tag("panel"); Text("通知中心小组件").tag("widget")
            }.pickerStyle(.segmented).labelsHidden()
            settingsRow("面板主题") {
                Picker("", selection: styleTarget == "panel" ? p.appearance : widgetBinding.appearance) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                }.labelsHidden().pickerStyle(.segmented).frame(width: 245)
            }
            settingsRow("编辑配色") {
                Picker("", selection: $editingDark) { Text("浅色配色").tag(false); Text("深色配色").tag(true) }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 245)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 10) {
                    colorRow("面板背景", role: .background)
                    colorRow("标题颜色", role: .title)
                    colorRow("一般日期", role: .date)
                    colorRow("周末日期", role: .weekend)
                    colorRow("节日日期", role: .festival)
                }
                VStack(spacing: 10) {
                    colorRow("当前日期", role: .today)
                    if styleTarget == "panel" { colorRow("日历事件", role: .event) }
                    colorRow("加班日期", role: .work)
                    colorRow("休假日期", role: .rest)
                }
            }.padding(.vertical, 6)
            Divider()
            if styleTarget == "panel" {
                sliderRow("面板宽度", binding: p.panelWidth, range: 260...500, label: "\(Int(settings.value.panelWidth)) pt")
                sliderRow("日期行高", binding: p.rowHeight, range: 28...62, label: "\(Int(settings.value.rowHeight)) pt")
                sliderRow("元素大小", binding: p.fontScale, range: 0.75...1.3, label: "\(Int(settings.value.fontScale * 100))%")
            } else {
                settingsRow("一周开始于") {
                    Picker("", selection: widgetBinding.firstWeekday) { Text("周日").tag(1); Text("周一").tag(2) }.labelsHidden().frame(width: 130)
                }
                settingsRow("农历") { Toggle("隐藏", isOn: widgetBinding.hideLunar).toggleStyle(.checkbox) }
                settingsRow("调休角标") { Toggle("显示休 / 班", isOn: widgetBinding.showHolidayBadges).toggleStyle(.checkbox) }
                sliderRow("元素大小", binding: widgetBinding.fontScale, range: 0.75...1.1, label: "\(Int(widgetBinding.wrappedValue.fontScale * 100))%")
                note("在通知中心或桌面的“编辑小组件”中添加 CalDock。小组件尺寸由系统选择，配色与显示选项单独保存。")
            }
            if let error = settings.persistenceError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("拖拽或使用箭头调整模块顺序").font(.system(size: 12, weight: .medium))
                Spacer()
                Toggle("显示秒", isOn: p.showSeconds).toggleStyle(.checkbox)
            }
            settingsRow("图标颜色") {
                Picker("", selection: p.iconMode) {
                    Text("自动适配").tag("auto"); Text("始终浅色").tag("light"); Text("始终深色").tag("dark")
                }.labelsHidden().pickerStyle(.segmented).frame(width: 245)
            }
            note("自动适配会跟随菜单栏实际明暗。全屏隐藏菜单栏时使用快捷键；刘海屏建议只保留图标，避免被其他菜单挤出。")
            VStack(spacing: 0) {
                ForEach(settings.value.modules) { module in
                    HStack(spacing: 9) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).font(.system(size: 11))
                        Toggle(module.title, isOn: Binding(get: { settings.value.enabledModules.contains(module) }, set: { settings.value.setEnabled(module, $0) }))
                            .toggleStyle(.checkbox).frame(width: 88, alignment: .leading)
                        Spacer(minLength: 2)
                        moduleOptions(module).frame(width: 165)
                        VStack(spacing: 2) {
                            Button { move(module, by: -1) } label: { Image(systemName: "chevron.up").font(.system(size: 8)) }
                            Button { move(module, by: 1) } label: { Image(systemName: "chevron.down").font(.system(size: 8)) }
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }.frame(height: 32).contentShape(Rectangle())
                        .onDrag { draggingModule = module; return NSItemProvider(object: module.rawValue as NSString) }
                        .onDrop(of: [.text], delegate: ModuleDropDelegate(target: module, dragging: $draggingModule, settings: settings))
                    Divider()
                }
            }
            HStack {
                Text("文字预览").foregroundStyle(.secondary)
                if settings.value.enabledModules.contains(.icon) { Image(systemName: "calendar") }
                Text(StatusFormatter().text(date: Date(), preferences: settings.value, engine: CalendarEngine()))
                    .lineLimit(1).truncationMode(.tail)
            }.font(.system(size: 12)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            note("按住 ⌘ 可拖动菜单栏图标。至少保留一个模块；默认仅显示日期图标。")
        }
    }

    @ViewBuilder private func moduleOptions(_ module: StatusModule) -> some View {
        switch module {
        case .icon:
            Picker("", selection: p.iconStyle) { Text("当日日期图标").tag("date"); Text("日历轮廓").tag("calendar") }.labelsHidden()
        case .solar:
            Picker("", selection: p.solarFormat) {
                Text("10月16日").tag("M月d日"); Text("10/16").tag("M/d"); Text("2026-10-16").tag("yyyy-MM-dd")
            }.labelsHidden()
        case .lunar:
            Picker("", selection: p.lunarFormat) { Text("初七").tag("day"); Text("九月初七").tag("full") }.labelsHidden()
        case .weekday: Text("周五").font(.system(size: 12)).foregroundStyle(.secondary)
        case .time:
            Picker("", selection: p.timeFormat) { Text("24 小时制").tag("24"); Text("12 小时制").tag("12") }.labelsHidden()
        case .custom: TextField("yyyy-MM-dd", text: p.customFormat).textFieldStyle(.roundedBorder).help("Unicode 日期格式，例如 yyyy-MM-dd EEEE HH:mm")
        }
    }

    private func move(_ module: StatusModule, by offset: Int) {
        guard let i = settings.value.modules.firstIndex(of: module), settings.value.modules.indices.contains(i + offset) else { return }
        settings.value.modules.swapAt(i, i + offset)
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title + "：").frame(width: 94, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }.font(.system(size: 12))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var widgetBinding: Binding<WidgetPreferences> {
        Binding(get: { settings.value.widget ?? WidgetPreferences() }, set: { settings.value.widget = $0 })
    }

    private func colorRow(_ title: String, role: PaletteRole) -> some View {
        HStack {
            Text(title + "：").font(.system(size: 12)).frame(width: 68, alignment: .trailing)
            ColorPicker("", selection: Binding(get: {
                let palette = styleTarget == "panel" ? settings.value.palette(dark: editingDark)
                    : (editingDark ? widgetBinding.wrappedValue.dark : widgetBinding.wrappedValue.light)
                return Color(hex: palette[role])
            }, set: { color in
                if styleTarget == "panel" { settings.value.setColor(color.hex, role: role, dark: editingDark) }
                else {
                    var widget = widgetBinding.wrappedValue
                    if editingDark { widget.dark[role] = color.hex } else { widget.light[role] = color.hex }
                    widgetBinding.wrappedValue = widget
                }
            }), supportsOpacity: false)
                .labelsHidden().frame(width: 66)
        }
    }

    private func sliderRow(_ title: String, binding: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        settingsRow(title) {
            Slider(value: binding, in: range).frame(width: 210)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().frame(width: 55, alignment: .trailing)
        }
    }
}

struct ModuleDropDelegate: DropDelegate {
    let target: StatusModule
    @Binding var dragging: StatusModule?
    let settings: AppSettings
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = settings.value.modules.firstIndex(of: dragging), let to = settings.value.modules.firstIndex(of: target) else { return }
        settings.value.modules.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var isRecording: Bool
    let label: String
    let onRecord: (UInt32, UInt32, String) -> Void
    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton()
        button.bezelStyle = .rounded
        return button
    }
    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.normalTitle = label
        button.title = button.recording ? "请按快捷键…（Esc 取消）" : label
        button.recorded = onRecord
    }
}

final class ShortcutButton: NSButton {
    var normalTitle = ""
    var recorded: ((UInt32, UInt32, String) -> Void)?
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        recording = true; title = "请按快捷键…（Esc 取消）"; window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { recording = false; title = normalTitle; return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { NSSound.beep(); return }
        var carbon: UInt32 = 0, label = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); label += "⌘" }
        label += (event.charactersIgnoringModifiers ?? "?").uppercased()
        recording = false; normalTitle = label; title = label
        recorded?(UInt32(event.keyCode), carbon, label)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func resignFirstResponder() -> Bool { recording = false; title = normalTitle; return super.resignFirstResponder() }
}

struct EventEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var provider = EventProvider.shared
    @State private var title = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var allDay = false
    @State private var calendarID = ""
    @State private var location = ""
    @State private var notes = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建日历事件").font(.title3.weight(.semibold))
            Form {
                TextField("标题", text: $title)
                Toggle("全天", isOn: $allDay)
                DatePicker("开始", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                DatePicker("结束", selection: $end, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                Picker("日历", selection: $calendarID) {
                    ForEach(provider.calendars.filter(\.writable)) { Text($0.title).tag($0.id) }
                }
                TextField("地点", text: $location)
                TextField("备注", text: $notes)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("创建") { save() }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || calendarID.isEmpty)
            }
        }.padding(24).frame(width: 430)
            .onAppear { calendarID = provider.calendars.first(where: \.writable)?.id ?? "" }
    }
    private func save() {
        do {
            let cal = Calendar.current
            if allDay && cal.startOfDay(for: end) < cal.startOfDay(for: start) { throw EventProvider.EventError.invalidRange }
            let startDate = allDay ? cal.startOfDay(for: start) : start
            let endDate = allDay ? cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: end))! : end
            try provider.create(title: title.trimmingCharacters(in: .whitespacesAndNewlines), start: startDate, end: endDate,
                                allDay: allDay, calendarID: calendarID, location: location, notes: notes)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
