import AppKit
import SwiftUI
import CalendarCore
import WidgetKit

extension Notification.Name {
    static let calDockPreferencesChanged = Notification.Name("CalDockPreferencesChanged")
    static let calDockShowSettings = Notification.Name("CalDockShowSettings")
    static let calDockHolidaysChanged = Notification.Name("CalDockHolidaysChanged")
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings(defaults: ProcessInfo.processInfo.environment["CALDOCK_TEST_MODE"] == "1"
                                    ? UserDefaults(suiteName: "com.yuhuo.caldock.verification")! : .standard)
    @Published var persistenceError: String?
    @Published var shortcutError: String?
    @Published var value: AppPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "preferences.v1") }
            if value.widget != oldValue.widget { syncWidget() }
            NotificationCenter.default.post(name: .calDockPreferencesChanged, object: nil)
        }
    }
    private let defaults: UserDefaults
    private var widgetReload: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "preferences.v1"), let p = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            var restored = p.normalized()
            if defaults.integer(forKey: "compactLayoutVersion") < 2 {
                if restored.panelWidth == 350 || restored.panelWidth == 310 { restored.panelWidth = 280 }
                if restored.rowHeight == 44 || restored.rowHeight == 38 { restored.rowHeight = 32 }
                if restored.fontScale == 1 || restored.fontScale == 0.9 { restored.fontScale = 0.85 }
            }
            value = restored
        } else { value = AppPreferences() }
        defaults.set(2, forKey: "compactLayoutVersion")
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "preferences.v1") }
        syncWidget()
    }

    func reset() { value = AppPreferences() }

    private func syncWidget() {
        guard ProcessInfo.processInfo.environment["CALDOCK_TEST_MODE"] != "1",
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        do { try SharedPreferences.write(value); persistenceError = nil }
        catch { persistenceError = "无法同步通知中心小组件：\(error.localizedDescription)" }
        widgetReload?.cancel()
        widgetReload = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: SharedPreferences.widgetKind)
        }
    }
}

extension Color {
    init(hex: String) {
        let string = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(string, radix: 16) ?? 0x777777
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
    var hex: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#777777" }
        return String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                      Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
}
