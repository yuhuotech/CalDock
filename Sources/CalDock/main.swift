import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        controller = StatusItemController()
        let args = ProcessInfo.processInfo.arguments
        if !args.contains("--verify-settings") && !args.contains("--verify-system") {
            SoftwareUpdater.shared.start()
        }
        if let index = args.firstIndex(of: "--verify-settings") ?? args.firstIndex(of: "--verify-system"), args.count > index + 1, let controller {
            let output = URL(fileURLWithPath: args[index + 1])
            Task { @MainActor in
                let passed = await Verification.run(controller: controller, system: args.contains("--verify-system"), output: output)
                print("CalDock verification: \(passed ? "PASS" : "FAIL") → \(output.path)")
                NSApp.terminate(nil)
            }
        }
        if args.contains("--show-calendar") { controller?.openPanel() }
        if args.contains("--settings") { controller?.showSettings() }
        if args.contains("--about") { controller?.settingsController.show(page: .about) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.openPanel(); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "caldock" }) else { return }
        controller?.panel.model.today()
        controller?.openPanel()
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu()
        let preferences = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self; appMenu.addItem(preferences)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 CalDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
    @objc private func showSettings() { controller?.showSettings() }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
