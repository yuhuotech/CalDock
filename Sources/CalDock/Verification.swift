import AppKit
import CalendarCore
import EventKit
import ServiceManagement
import UserNotifications
import Darwin

@MainActor
enum Verification {
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
    static func run(controller: StatusItemController, system: Bool, output: URL) async -> Bool {
        var checks: [[String: Any]] = []
        let settings = AppSettings.shared
        let original = settings.value
        func record(_ name: String, _ success: Bool, _ detail: String = "") {
            checks.append(["check": name, "passed": success, "detail": detail])
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(100)) }
        func waitUntil(_ predicate: () -> Bool) async {
            for _ in 0..<50 { if predicate() { return }; await settle() }
        }
        if system {
            let store = EKEventStore()
            record("calendar.authorization", EKEventStore.authorizationStatus(for: .event) == .fullAccess)
            if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
                let local = store.sources.first { $0.sourceType == .local }
                let calendar = EKCalendar(for: .event, eventStore: store)
                calendar.title = "CalDock 临时验收 \(UUID().uuidString.prefix(6))"
                calendar.source = local ?? store.defaultCalendarForNewEvents?.source
                do {
                    try store.saveCalendar(calendar, commit: true)
                    let event = EKEvent(eventStore: store)
                    event.title = "CalDock 临时读写测试"
                    event.calendar = calendar
                    event.startDate = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
                    event.endDate = event.startDate.addingTimeInterval(3600)
                    try EventProvider.shared.create(title: event.title, start: event.startDate, end: event.endDate, allDay: false,
                                                    calendarID: calendar.calendarIdentifier, location: "", notes: "CalDock 自动验收临时事件，测试结束自动清理。")
                    let predicate = store.predicateForEvents(withStart: event.startDate, end: event.endDate, calendars: [calendar])
                    let created = store.events(matching: predicate).first { $0.title == event.title }
                    record("calendar.create-and-read", created != nil)
                    EventProvider.shared.refresh()
                    controller.panel.model.today()
                    controller.openPanel()
                    await waitUntil { EventProvider.shared.events.contains { $0.title == event.title } }
                    record("calendar.provider-read", EventProvider.shared.events.contains { $0.title == event.title })
                    settings.value.disabledCalendarIDs.append(calendar.calendarIdentifier)
                    await waitUntil { !EventProvider.shared.loading && !EventProvider.shared.events.contains { $0.title == event.title } }
                    record("calendar.filter-excludes", !EventProvider.shared.events.contains { $0.title == event.title })
                    settings.value.disabledCalendarIDs.removeAll { $0 == calendar.calendarIdentifier }
                    await waitUntil { EventProvider.shared.events.contains { $0.title == event.title } }
                    record("calendar.filter-restores", EventProvider.shared.events.contains { $0.title == event.title })
                    if let created { try store.remove(created, span: .thisEvent, commit: true) }
                    try store.removeCalendar(calendar, commit: true)
                    record("calendar.cleanup", store.calendar(withIdentifier: calendar.calendarIdentifier) == nil)
                } catch {
                    record("calendar.read-write", false, error.localizedDescription)
                    do { if store.calendar(withIdentifier: calendar.calendarIdentifier) != nil { try store.removeCalendar(calendar, commit: true) } }
                    catch { record("calendar.cleanup", false, error.localizedDescription) }
                }
            }
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings()
            record("notification.authorization", status.authorizationStatus == .authorized || status.authorizationStatus == .provisional,
                   "status=\(status.authorizationStatus.rawValue), alert=\(status.alertSetting.rawValue)")
            if status.authorizationStatus == .authorized || status.authorizationStatus == .provisional {
                settings.value.holidayNotifications = true
                HolidayNotifier.shared.schedule()
                try? await Task.sleep(for: .seconds(2))
                let pending = await center.pendingNotificationRequests()
                let expected = HolidayReminderPlanner.reminders(after: Date())
                record("notification.holiday-schedule", Set(expected.map(\.identifier)).isSubset(of: Set(pending.map(\.identifier))), "\(pending.count) pending")
                HolidayNotifier.shared.sendTest()
                try? await Task.sleep(for: .seconds(5))
                let delivered = await center.deliveredNotifications()
                record("notification.delivery", delivered.contains { $0.request.identifier == "caldock.test" }, "\(delivered.count) delivered")
                center.removeDeliveredNotifications(withIdentifiers: ["caldock.test"])
                settings.value.holidayNotifications = false
                HolidayNotifier.shared.clear()
                await settle(); await settle()
                record("notification.disable-cancels", !(await center.pendingNotificationRequests()).contains { $0.identifier.hasPrefix("caldock.holiday.") })
            }
            let wasEnabled = SMAppService.mainApp.status == .enabled
            do {
                try SMAppService.mainApp.register()
                record("login.registration", SMAppService.mainApp.status == .enabled, "status=\(SMAppService.mainApp.status.rawValue)")
                try await SMAppService.mainApp.unregister()
                record("login.unregistration", SMAppService.mainApp.status == .notRegistered)
                if wasEnabled { try SMAppService.mainApp.register() }
            } catch { record("login.registration", false, error.localizedDescription) }
            do {
                try SharedPreferences.write(original)
                record("widget.shared-settings", SharedPreferences.read() == original)
            } catch { record("widget.shared-settings", false, error.localizedDescription) }
        } else {
            let updater = SoftwareUpdater.shared
            let automaticChecks = updater.automaticallyChecksForUpdates
            updater.setAutomaticallyChecksForUpdates(false)
            updater.start()
            await settle()
            record("updater.manual-check-available", updater.canCheckForUpdates)
            record("updater.hourly-interval", updater.checkInterval == 3600)
            record("updater.disable-automatic", !updater.automaticallyChecksForUpdates
                   && UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool == false)
            updater.setAutomaticallyChecksForUpdates(true)
            await settle()
            record("updater.enable-and-persist", updater.automaticallyChecksForUpdates
                   && UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool == true)
            updater.setAutomaticallyChecksForUpdates(automaticChecks)
            record("updater.version-from-bundle", updater.currentVersion == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            controller.settingsController.show(page: .about)
            await settle()
            record("settings.about-page", NSApp.windows.contains { $0.title == "关于" && $0.contentView != nil })
            record("settings.all-five-tabs-visible", controller.settingsController.allPagesVisible)
            if let image = controller.settingsController.renderedPNG() {
                try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? image.write(to: output.deletingLastPathComponent().appendingPathComponent("settings-about.png"))
            }
            NSApp.windows.first { $0.title == "关于" }?.close()
            var testDefaults = AppPreferences()
            testDefaults.shortcutKey = 80 // F19, isolated from the user's shortcut.
            testDefaults.shortcutModifiers = 6912
            testDefaults.shortcutLabel = "⌃⌥⇧⌘F19"
            settings.value = testDefaults
            controller.openPanel()
            controller.panel.model.isPinned = true
            await settle()
            let base = controller.panel.panel?.frame.size ?? .zero
            record("panel.compact-default", base.width == 280 && base.height < 300, "\(base)")
            settings.value.panelWidth = 400
            await settle()
            record("panel.width", controller.panel.panel?.frame.width == 400)
            settings.value.rowHeight = 48
            await settle()
            let tall = controller.panel.panel?.frame.height ?? 0
            record("panel.height", tall > base.height + 80)
            settings.value.hideFooter = true
            await settle()
            record("panel.hide-footer-reduces-height", (controller.panel.panel?.frame.height ?? 0) < tall - 15)
            let lunarImage = controller.panel.renderedPNG()
            settings.value.hideLunar = true
            await settle()
            record("panel.hide-lunar", lunarImage != nil && controller.panel.renderedPNG() != lunarImage)
            settings.value.hideLunar = false
            settings.value.hideFooter = false
            settings.value.rowHeight = 32
            await settle()
            let holidayImage = controller.panel.renderedPNG()
            settings.value.showHolidayBadges = false
            await settle()
            record("panel.holiday-badges", holidayImage != nil && controller.panel.renderedPNG() != holidayImage)
            settings.value.showHolidayBadges = true
            let fixtureDate = controller.panel.model.days.first { $0.holiday?.kind == .work }?.date ?? Date()
            let fixture = CalendarEvent(id: "verification", title: "本地渲染测试", start: fixtureDate, end: fixtureDate.addingTimeInterval(3600), allDay: false, location: "", color: .red, calendarTitle: "测试")
            for dark in [false, true] {
                settings.value.appearance = dark ? "dark" : "light"
                for role in PaletteRole.allCases {
                    controller.panel.model.eventsByDay[controller.panel.model.engine.dateKey(fixtureDate)] = [fixture]
                    await settle()
                    let before = controller.panel.renderedPNG()
                    settings.value.setColor("#00FF00", role: role, dark: dark)
                    await settle()
                    record("palette.\(dark ? "dark" : "light").\(role.rawValue)", before != nil && controller.panel.renderedPNG() != before)
                }
            }
            settings.value.appearance = "light"
            for role in PaletteRole.allCases {
                settings.value.setColor(CalendarPalette()[role], role: role, dark: false)
                settings.value.setColor(CalendarPalette(dark: true)[role], role: role, dark: true)
            }
            await settle()
            let dots = controller.panel.renderedPNG()
            settings.value.showEventDots = false
            await settle()
            record("panel.event-dots", dots != nil && controller.panel.renderedPNG() != dots)
            settings.value.showEventDots = true
            let smallFont = controller.panel.renderedPNG()
            settings.value.fontScale = 1.3
            await settle()
            record("panel.font-size", smallFont != nil && controller.panel.renderedPNG() != smallFont)
            settings.value.fontScale = 0.85
            settings.value.firstWeekday = 2
            await settle()
            record("calendar.first-weekday", controller.panel.model.days.first.map { Calendar.current.component(.weekday, from: $0.date) == 2 } ?? false)
            settings.value.showAgenda = true
            await settle()
            record("panel.agenda-setting", controller.panel.model.agendaVisible)
            settings.value.appearance = "dark"
            await settle()
            record("panel.dark-appearance", controller.panel.panel?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            settings.value.appearance = "light"
            await settle()
            record("panel.light-appearance", controller.panel.panel?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
            settings.value.appearance = "system"
            await settle()
            record("panel.system-appearance", controller.panel.panel?.appearance == nil)
            settings.value.openOnHover = true
            await settle()
            record("hover.enabled", controller.verificationState["hoverTracking"] as? Bool == true)
            settings.value.openOnHover = false
            await settle()
            record("hover.disabled", controller.verificationState["hoverTracking"] as? Bool == false)
            settings.value.iconMode = "auto"
            await settle()
            record("status.automatic-template", controller.verificationState["imageTemplate"] as? Bool == true)
            let dateIcon = controller.verificationState["imageData"] as? Data
            settings.value.iconStyle = "calendar"
            await settle()
            record("status.icon-style", dateIcon != nil && controller.verificationState["imageData"] as? Data != dateIcon)
            for mode in ["light", "dark"] {
                settings.value.iconMode = mode
                await settle()
                record("status.fixed-\(mode)", controller.verificationState["hasImage"] as? Bool == true && controller.verificationState["imageTemplate"] as? Bool == false)
            }
            settings.value.enabledModules = [.solar, .lunar, .weekday, .time, .custom]
            settings.value.customFormat = "'CalDock' yyyy-MM-dd"
            await settle()
            let text = controller.verificationState["title"] as? String ?? ""
            record("status.all-text-modules", text.contains("CalDock") && text.contains("周") && text.contains(":"), text)
            record("status.icon-disabled", controller.verificationState["hasImage"] as? Bool == false)
            settings.value.enabledModules = [.solar, .icon]
            settings.value.modules = [.solar, .icon, .lunar, .weekday, .time, .custom]
            await settle()
            let firstOrder = controller.verificationState["imageData"] as? Data
            settings.value.modules = [.icon, .solar, .lunar, .weekday, .time, .custom]
            await settle()
            record("status.module-order", firstOrder != nil && controller.verificationState["imageData"] as? Data != firstOrder)
            settings.value.enabledModules = [.time, .custom]
            settings.value.showSeconds = true
            await settle()
            record("status.seconds-timer", controller.verificationState["timerInterval"] as? Double == 1)
            settings.value.showSeconds = false
            settings.value.customFormat = "HH:mm:ss"
            await settle()
            record("status.custom-seconds-timer", controller.verificationState["timerInterval"] as? Double == 1)
            settings.value.enabledModules = [.icon]
            await settle()
            record("status.idle-minute-timer", controller.verificationState["timerInterval"] as? Double == 60)
            settings.value.shortcutEnabled = false
            await settle()
            record("shortcut.disabled", controller.verificationState["shortcutRegistered"] as? Bool == false)
            settings.value.shortcutEnabled = true
            await settle()
            record("shortcut.registered", controller.verificationState["shortcutRegistered"] as? Bool == true)
            let beforePersistence = settings.value
            record("settings.persistence", AppSettings(defaults: UserDefaults(suiteName: "com.yuhuo.caldock.verification")!).value == beforePersistence)
            settings.reset()
            await settle()
            var resetExpected = AppPreferences()
            resetExpected.shortcutEnabled = controller.verificationState["shortcutRegistered"] as? Bool ?? false
            if settings.shortcutError != nil {
                resetExpected.shortcutKey = testDefaults.shortcutKey
                resetExpected.shortcutModifiers = testDefaults.shortcutModifiers
                resetExpected.shortcutLabel = testDefaults.shortcutLabel
            }
            record("settings.reset", settings.value == resetExpected,
                   settings.shortcutError ?? "")
            settings.value.animation = true
            controller.panel.close(); controller.openPanel()
            let initialAlpha = controller.panel.panel?.alphaValue ?? 1
            try? await Task.sleep(for: .milliseconds(250))
            record("panel.animation", initialAlpha < 1 && controller.panel.panel?.alphaValue == 1)
            controller.panel.model.today()
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
            controller.panel.model.clockChanged(now: nextDay)
            record("calendar.midnight-follows-today", Calendar.current.isDate(controller.panel.model.selected, inSameDayAs: nextDay))
            controller.panel.model.today()
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            await settle()
            record("lifecycle.wake-refresh", controller.verificationState["timerInterval"] as? Double == 60 && controller.panel.model.days.count == 42)
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            await settle()
            record("lifecycle.timezone-refresh", controller.panel.model.days.count == 42)
            for _ in 0..<25 { autoreleasepool { controller.panel.close(); controller.openPanel() } }
            await settle()
            let beforeStress = footprint()
            for index in 0..<100 {
                autoreleasepool { controller.panel.close(); controller.openPanel() }
                if index % 10 == 0 { await settle() }
            }
            controller.panel.close()
            await settle(); await settle()
            let afterStress = footprint()
            record("panel.stress-125-cycles", beforeStress > 0 && afterStress < beforeStress + 25 * 1024 * 1024,
                   "physical footprint \(beforeStress) → \(afterStress) bytes")
            record("panel.release-on-close", controller.panel.panel?.contentView == nil && !controller.panel.model.active)
        }
        settings.value = original
        controller.panel.close()
        let result: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "system": system,
                                     "passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        } catch { print("Unable to write verification report: \(error)"); return false }
        return result["passed"] as? Bool == true
    }
}
