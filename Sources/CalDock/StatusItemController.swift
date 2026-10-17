import AppKit
import CalendarCore
import Carbon
import SwiftUI

final class CalendarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model = CalendarModel()
    private(set) var panel: CalendarPanel?
    private var host: NSHostingView<CalendarView>?
    private var scroll: NSScrollView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var interactionObservation: NSObjectProtocol?
    private var interactionEndObservation: NSObjectProtocol?
    private var interactionDepth = 0
    private var anchor: NSRect?
    private var previousApplication: NSRunningApplication?
    var visible: Bool { panel?.isVisible == true }
    func renderedPNG() -> Data? {
        guard let host, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
    var visibilityChanged: ((Bool) -> Void)?

    override init() {
        super.init()
        model.resize = { [weak self] in self?.resize() }
        interactionObservation = NotificationCenter.default.addObserver(forName: .calDockInteractionBegan, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interactionDepth += 1 }
        }
        interactionEndObservation = NotificationCenter.default.addObserver(forName: .calDockInteractionEnded, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interactionDepth = max(0, (self?.interactionDepth ?? 1) - 1) }
        }
    }

    func toggle(anchor: NSRect?) { if visible { close() } else { show(anchor: anchor) } }

    func show(anchor: NSRect?, activate: Bool = true) {
        if visible { return }
        self.anchor = anchor
        previousApplication = NSWorkspace.shared.frontmostApplication
        if panel == nil {
            let panel = CalendarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.title = "CalDock 日历"
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            self.panel = panel
        }
        model.open()
        // Drop the SwiftUI tree when hidden so there are no offscreen view updates.
        let host = NSHostingView(rootView: CalendarView(model: model))
        self.host = host
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = host
        self.scroll = scroll
        panel?.contentView = scroll
        resize()
        panel?.alphaValue = AppSettings.shared.value.animation ? 0 : 1
        panel?.orderFrontRegardless()
        if activate { panel?.makeKey() }
        if AppSettings.shared.value.animation {
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.12; panel?.animator().alphaValue = 1 }
        }
        installMonitors()
        visibilityChanged?(true)
    }

    func resize() {
        guard let panel, let host else { return }
        switch AppSettings.shared.value.appearance {
        case "dark": panel.appearance = NSAppearance(named: .darkAqua)
        case "light": panel.appearance = NSAppearance(named: .aqua)
        default: panel.appearance = nil
        }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let width = AppSettings.shared.value.panelWidth
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(anchor?.origin ?? pointer) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let full = screen.frame
        let menuHeight = NSStatusBar.system.thickness
        let frame = PanelPlacement.frame(content: CGSize(width: width, height: size.height), screen: full, anchor: anchor, menuHeight: menuHeight)
        host.setFrameSize(NSSize(width: width, height: size.height))
        panel.setFrame(frame, display: true)
    }

    func close() {
        guard visible else { return }
        panel?.orderOut(nil)
        panel?.contentView = nil
        host = nil
        scroll = nil
        model.close()
        for monitor in [localMonitor, globalMonitor, keyMonitor, mouseMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        localMonitor = nil; globalMonitor = nil; keyMonitor = nil; mouseMonitor = nil
        interactionDepth = 0
        visibilityChanged?(false)
        // A nonactivating panel normally preserves the foreground app already.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication.activate()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Outside clicks are handled explicitly, allowing color/date controls to work.
    }

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            let point = NSEvent.mouseLocation
            if self.shouldClose(at: point, window: event.window) { self.close() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if self.shouldClose(at: NSEvent.mouseLocation, window: nil) { self.close() }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            if self.shouldClose(at: NSEvent.mouseLocation, window: nil) { self.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            // Let text fields, date pickers and the popover's field editor
            // consume their own keys; otherwise typing "A" triggers the
            // agenda shortcut and resizes the panel under the editor.
            if let responder = event.window?.firstResponder,
               responder is NSTextView || responder is NSTextField || responder is NSSearchField {
                return event
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                NotificationCenter.default.post(name: .calDockShowSettings, object: nil); return nil
            }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                switch event.keyCode {
                case 53: self.close(); return nil
                case 49: self.model.today(); return nil
                case 123: self.model.moveMonth(-1); return nil
                case 124: self.model.moveMonth(1); return nil
                case 125: self.model.moveDay(7); return nil
                case 126: self.model.moveDay(-7); return nil
                case 0: self.model.agendaVisible.toggle(); self.resize(); return nil
                case 35: self.model.isPinned.toggle(); return nil
                default: break
                }
            }
            return event
        }
    }

    private func shouldClose(at point: NSPoint, window: NSWindow?) -> Bool {
        guard visible, !model.isPinned, interactionDepth == 0 else { return false }
        if panel?.frame.contains(point) == true || anchor?.contains(point) == true { return false }
        // Popovers and other CalDock windows are outside the main panel frame,
        // but interaction inside them must not be treated as an outside click.
        if let window, NSApp.windows.contains(where: { $0 === window && $0.isVisible }) { return false }
        if NSApp.windows.contains(where: { $0 !== panel && $0.isVisible && $0.frame.contains(point) }) { return false }
        return true
    }
}

@MainActor
final class HotKeyController {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registeredKey: UInt32?
    private var registeredModifiers: UInt32?
    var isRegistered: Bool { reference != nil }
    var pressed: (() -> Void)?

    func register(preferences: AppPreferences) -> OSStatus {
        guard preferences.shortcutEnabled else {
            if let reference { UnregisterEventHotKey(reference) }
            reference = nil; registeredKey = nil; registeredModifiers = nil
            return noErr
        }
        if reference != nil && registeredKey == preferences.shortcutKey && registeredModifiers == preferences.shortcutModifiers { return noErr }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let object = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { object.pressed?() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: 0x43444F43, id: 1)
        var replacement: EventHotKeyRef?
        let result = RegisterEventHotKey(preferences.shortcutKey, preferences.shortcutModifiers, id, GetApplicationEventTarget(), 0, &replacement)
        if result == noErr {
            if let reference { UnregisterEventHotKey(reference) }
            reference = replacement; registeredKey = preferences.shortcutKey; registeredModifiers = preferences.shortcutModifiers
        }
        return result
    }
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let panel = PanelController()
    let settingsController = SettingsController()
    private let item: NSStatusItem
    private let hotKey = HotKeyController()
    private let formatter = StatusFormatter()
    private var timer: Timer?
    private var tracking: NSTrackingArea?
    private var hoverWork: DispatchWorkItem?
    private var observations: [NSObjectProtocol] = []
    private var applied = AppPreferences()
    private var lastDay = ""
    private var shortcutError: OSStatus = noErr
    private var iconCacheKey = ""
    private var cachedIcon: NSImage?
    private var renderedClock = ""
    private var renderedPreferences: AppPreferences?

    var verificationState: [String: Any] {
        ["title": item.button?.title ?? "", "imageTemplate": item.button?.image?.isTemplate ?? false,
         "hasImage": item.button?.image != nil, "timerInterval": timer?.timeInterval ?? 0,
         "hoverTracking": tracking != nil, "shortcutRegistered": hotKey.isRegistered,
         "imageData": item.button?.image?.tiffRepresentation ?? Data(),
         "iconPosition": AppSettings.shared.value.modules.firstIndex(of: .icon) ?? -1]
    }

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "CalDockStatusItem"
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        button.setAccessibilityLabel("CalDock 日历")
        panel.visibilityChanged = { [weak self] visible in self?.item.button?.highlight(visible) }
        hotKey.pressed = { [weak self] in guard let self else { return }; self.panel.toggle(anchor: self.buttonRect()) }
        // Template images and semantic label colors adapt in AppKit itself.
        // Observing effectiveAppearance here causes replica redraw feedback loops.
        let center = NotificationCenter.default
        observations.append(center.addObserver(forName: .calDockPreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyPreferences() }
        })
        observations.append(center.addObserver(forName: .calDockShowSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showSettings() }
        })
        for name in [NSApplication.didChangeScreenParametersNotification, NSNotification.Name.NSSystemTimeZoneDidChange, NSNotification.Name.NSCalendarDayChanged] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.clockChanged() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observations.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.clockChanged() }
        })
        observations.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; if self.panel.visible { self.panel.resize() }; self.updateStatus() }
        })
        applied = AppSettings.shared.value
        applyPreferences(force: true)
        if applied.holidayNotifications { HolidayNotifier.shared.schedule() }
    }

    private func applyPreferences(force: Bool = false) {
        let p = AppSettings.shared.value
        if force || applied.shortcutEnabled != p.shortcutEnabled || applied.shortcutKey != p.shortcutKey || applied.shortcutModifiers != p.shortcutModifiers {
            shortcutError = hotKey.register(preferences: p)
            AppSettings.shared.shortcutError = shortcutError == noErr ? nil : "快捷键已被占用或无法注册（\(shortcutError)），请重新录制。原有快捷键继续有效。"
            if shortcutError != noErr {
                var restored = p
                restored.shortcutKey = applied.shortcutKey
                restored.shortcutModifiers = applied.shortcutModifiers
                restored.shortcutLabel = applied.shortcutLabel
                restored.shortcutEnabled = hotKey.isRegistered
                applied = restored
                AppSettings.shared.value = restored
                return
            }
        }
        if force || applied.needsSecondTicks != p.needsSecondTicks { configureTimer() }
        if force || applied.openOnHover != p.openOnHover { configureTracking() }
        if panel.visible {
            if applied.showAgenda != p.showAgenda { panel.model.agendaVisible = p.showAgenda }
            if applied.firstWeekday != p.firstWeekday || applied.disabledCalendarIDs != p.disabledCalendarIDs { panel.model.refresh() }
            DispatchQueue.main.async { [weak self] in self?.panel.resize() }
        }
        if applied.holidayNotifications && !p.holidayNotifications { HolidayNotifier.shared.clear() }
        if !applied.holidayNotifications && p.holidayNotifications {
            HolidayNotifier.shared.requestAndSchedule { _ in }
        }
        applied = p
        updateStatus()
    }

    private func configureTimer() {
        timer?.invalidate()
        let seconds = AppSettings.shared.value.needsSecondTicks
        let interval: TimeInterval = seconds ? 1 : 60
        let now = Date().timeIntervalSince1970
        let first = Date(timeIntervalSince1970: (floor(now / interval) + 1) * interval)
        let timer = Timer(fire: first, interval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
        timer.tolerance = seconds ? 0.05 : 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func clockChanged() {
        configureTimer(); updateStatus()
        panel.model.clockChanged()
        EventProvider.shared.refreshCalendars()
        if panel.visible { panel.resize() }
        if AppSettings.shared.value.holidayNotifications { HolidayNotifier.shared.schedule() }
    }

    private func updateStatus() {
        guard let button = item.button else { return }
        let now = Date(), p = AppSettings.shared.value
        let engine = CalendarEngine()
        let key = engine.dateKey(now)
        if key != lastDay {
            let hadDate = !lastDay.isEmpty
            lastDay = key
            if hadDate { panel.model.clockChanged(now: now) }
            if hadDate && p.holidayNotifications { HolidayNotifier.shared.schedule() }
        }
        let showsClock = p.enabledModules.contains(.time) || p.enabledModules.contains(.custom)
        let clock = showsClock ? formatter.string(now, pattern: p.needsSecondTicks ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm") : key
        guard renderedClock != clock || renderedPreferences != p else { return }
        renderedClock = clock
        renderedPreferences = p
        var title = formatter.text(date: now, preferences: p, engine: engine)
        let hasIcon = p.enabledModules.contains(.icon)
        if !hasIcon && title.isEmpty { title = formatter.string(now, pattern: "d") }
        let image = hasIcon ? statusIcon(date: now, preferences: p) : nil
        // Render as one image so drag ordering also works when icon is not first.
        if hasIcon, let image {
            let before = p.modules.prefix(while: { $0 != .icon }).filter { p.enabledModules.contains($0) }
            if !before.isEmpty && !title.isEmpty {
                button.image = combinedStatus(date: now, preferences: p)
                button.title = ""
            } else { button.image = image; button.title = title.isEmpty ? "" : " " + title }
        } else { button.image = nil; button.title = title }
        if p.iconMode == "auto" {
            button.contentTintColor = nil
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: button.font!, .foregroundColor: NSColor.labelColor])
        } else {
            let color: NSColor = p.iconMode == "light" ? .white : .black
            button.contentTintColor = color
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: button.font!, .foregroundColor: color])
        }
        button.toolTip = "CalDock · \(formatter.string(now, pattern: "yyyy年M月d日 EEEE")) · \(engine.lunarInfo(now).fullLabel)\n\(p.shortcutEnabled ? p.shortcutLabel + " 打开日历；" : "")右键打开菜单" + (shortcutError == noErr ? "" : "\n快捷键注册失败（\(shortcutError)），请在设置重新录制")
    }

    private func statusIcon(date: Date, preferences p: AppPreferences) -> NSImage {
        let day = Calendar.current.component(.day, from: date)
        let key = "\(day)-\(p.iconStyle)-\(p.iconMode)"
        if key == iconCacheKey, let cachedIcon { return cachedIcon }
        let color: NSColor = p.iconMode == "light" ? .white : .black
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            color.setStroke()
            let outline = NSBezierPath(roundedRect: NSRect(x: 3, y: 3.5, width: 16, height: 14), xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.5; outline.stroke()
            let line = NSBezierPath()
            line.lineWidth = 1.5
            line.move(to: NSPoint(x: 3.5, y: 14.5)); line.line(to: NSPoint(x: 18.5, y: 14.5))
            for x in [7.0, 15.0] { line.move(to: NSPoint(x: x, y: 16.5)); line.line(to: NSPoint(x: x, y: 19.5)) }
            line.stroke()
            if p.iconStyle == "date" {
                let text = "\(day)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: color]
                let size = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: 3.4), withAttributes: attrs)
            } else {
                color.setFill()
                for x in [7.0, 11.0, 15.0] { for y in [7.0, 10.5] { NSBezierPath(ovalIn: NSRect(x: x - 1, y: y - 1, width: 2, height: 2)).fill() } }
            }
            return true
        }
        image.isTemplate = p.iconMode == "auto"
        iconCacheKey = key; cachedIcon = image
        return image
    }

    private func combinedStatus(date: Date, preferences p: AppPreferences) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: p.iconMode == "light" ? NSColor.white : NSColor.black]
        let parts: [(NSImage?, NSString?)] = p.modules.filter { p.enabledModules.contains($0) }.map { module in
            if module == .icon { return (statusIcon(date: date, preferences: p), nil) }
            var one = p; one.enabledModules = [module]
            return (nil, formatter.text(date: date, preferences: one, engine: CalendarEngine()) as NSString)
        }
        let widths = parts.map { $0.0?.size.width ?? $0.1?.size(withAttributes: attrs).width ?? 0 }
        let total = widths.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * 5
        let image = NSImage(size: NSSize(width: min(total, 900), height: 22), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, part) in parts.enumerated() {
                if let icon = part.0 { icon.draw(in: NSRect(x: x, y: 0, width: 22, height: 22)) }
                else { part.1?.draw(at: NSPoint(x: x, y: 3), withAttributes: attrs) }
                x += widths[i] + 5
            }
            return true
        }
        image.isTemplate = p.iconMode == "auto"
        return image
    }

    private func configureTracking() {
        guard let button = item.button else { return }
        if let tracking { button.removeTrackingArea(tracking) }
        hoverWork?.cancel()
        guard AppSettings.shared.value.openOnHover else { tracking = nil; return }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        button.addTrackingArea(tracking); self.tracking = tracking
    }
    @objc func mouseEntered(with event: NSEvent) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.buttonRect()?.contains(NSEvent.mouseLocation) == true else { return }
            self.panel.show(anchor: self.buttonRect(), activate: false)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.shared.value.hoverDelay, execute: work)
    }
    @objc func mouseExited(with event: NSEvent) { hoverWork?.cancel() }

    private func buttonRect() -> NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        // A status item can be on a different desktop/display; fall back to active screen.
        let active = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        if let active, !active.frame.contains(rect.origin) { return nil }
        return rect
    }

    @objc private func clicked() {
        hoverWork?.cancel()
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() }
        else { panel.toggle(anchor: buttonRect()) }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开日历", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(withTitle: "回到今天", action: #selector(goToday), keyEquivalent: "t")
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "关于 CalDock", action: #selector(about), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 CalDock", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        menu.delegate = self
        item.menu = menu
        item.button?.performClick(nil)
    }
    func menuDidClose(_ menu: NSMenu) { item.menu = nil }
    @objc func openPanel() { panel.show(anchor: buttonRect()) }
    @objc private func goToday() { panel.model.today(); openPanel() }
    @objc func showSettings() { panel.close(); settingsController.show() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func about() {
        panel.close()
        settingsController.show(page: .about)
    }
}
