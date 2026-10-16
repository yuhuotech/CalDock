import CalendarCore
import Foundation
import UserNotifications

@MainActor
final class HolidayNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = HolidayNotifier()
    private let center = UNUserNotificationCenter.current()
    private let prefix = "caldock.holiday."
    private var task: Task<Void, Never>?
    @Published private(set) var message: String?

    override init() { super.init(); center.delegate = self }

    func refreshStatus() {
        Task { @MainActor in
            let status = await center.notificationSettings()
            if status.authorizationStatus == .denied && AppSettings.shared.value.holidayNotifications {
                AppSettings.shared.value.holidayNotifications = false
                message = "通知已在系统设置中关闭，节日推送已停用。"
                clear()
            }
        }
    }

    func requestAndSchedule(completion: @escaping (String?) -> Void) {
        message = nil
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                guard AppSettings.shared.value.holidayNotifications else { return }
                if granted { self.schedule(); completion("已启用：节假日前一天 18:00 提醒。") }
                else {
                    AppSettings.shared.value.holidayNotifications = false
                    self.message = error?.localizedDescription ?? "通知未获允许，请在系统设置 → 通知中允许 CalDock。"
                    completion(self.message)
                }
            }
        }
    }

    func clear() {
        let previous = task
        previous?.cancel()
        task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            let pending = await center.pendingNotificationRequests()
            guard !Task.isCancelled else { return }
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier))
        }
    }

    func schedule() {
        let previous = task
        previous?.cancel()
        task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            let status = await center.notificationSettings()
            guard !Task.isCancelled, AppSettings.shared.value.holidayNotifications else { return }
            guard status.authorizationStatus == .authorized || status.authorizationStatus == .provisional else { refreshStatus(); return }
            let reminders = HolidayReminderPlanner.reminders(after: Date())
            let ids = Set(reminders.map(\.identifier))
            let pending = await center.pendingNotificationRequests()
            guard !Task.isCancelled else { return }
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix(prefix) && !ids.contains($0.identifier) }.map(\.identifier))
            do {
                for reminder in reminders {
                    guard !Task.isCancelled, AppSettings.shared.value.holidayNotifications else { return }
                    let content = UNMutableNotificationContent()
                    content.title = reminder.title; content.body = reminder.body; content.sound = .default
                    let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate), repeats: false)
                    try await center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger))
                    if Task.isCancelled || !AppSettings.shared.value.holidayNotifications { return }
                }
                message = "已安排 \(reminders.count) 个节日提醒，前一天 18:00 推送。"
            } catch { message = "安排通知失败：\(error.localizedDescription)" }
        }
    }

    func sendTest() {
        Task { @MainActor in
            let content = UNMutableNotificationContent()
            content.title = "CalDock 通知测试"; content.body = "节日通知已接入系统通知中心。"; content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: "caldock.test", content: content,
                                                           trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
                message = "测试通知将在 3 秒后发送，请留意通知中心。"
            } catch { message = "测试通知失败：\(error.localizedDescription)" }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
