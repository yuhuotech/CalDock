import AppKit
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    static let shared = LoginItemController()
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var message: String?
    @Published private(set) var updating = false
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
        if needsApproval { message = "请在系统设置 → 通用 → 登录项中允许 CalDock。" }
        else if status == .notRegistered || status == .enabled { message = nil }
    }

    func setEnabled(_ value: Bool) {
        guard !updating else { return }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            refresh()
            message = "请先将 CalDock 安装到“应用程序”后再开启登录启动。"
            return
        }
        updating = true
        Task { @MainActor in
            defer { updating = false }
            do {
                if value { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                refresh()
            } catch { refresh(); message = error.localizedDescription }
        }
    }

    func openApproval() { SMAppService.openSystemSettingsLoginItems() }
}
