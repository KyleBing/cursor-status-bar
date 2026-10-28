import AppKit
import Combine
import SwiftUI

@main
enum CursorStatusBarMain {
    static func main() {
        terminateOtherInstances()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    // 本机同时只允许一个实例；新启动的会结束旧进程
    private static func terminateOtherInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        let bundle = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.processIdentifier != me && (
                (bundle != nil && app.bundleIdentifier == bundle) ||
                app.localizedName == "CursorStatusBar"
            )
        }
        for app in apps {
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let still = NSWorkspace.shared.runningApplications.contains { app in
                app.processIdentifier != me && bundle != nil && app.bundleIdentifier == bundle
            }
            if !still { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != me {
            if bundle != nil && app.bundleIdentifier == bundle {
                app.forceTerminate()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    var store: UsageStore!
    // DeepSeek tab 独立状态，避免每次开面板丢失对话
    var deepSeekStore: DeepSeekStore!
    private var statusItem: NSStatusItem?
    private var panel: StatusPanelController?
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        store = UsageStore()
        deepSeekStore = DeepSeekStore()
        panel = StatusPanelController(store: store, deepSeek: deepSeekStore)
        Task { @MainActor in
            self.installStatusItem()
        }
        cancellable = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItem()
            }
        }
        Task { @MainActor in
            await self.store.refreshPeriod(forceAuth: true)
            self.updateStatusItem()
        }
    }

    // accessory 应用默认没有主菜单，Cmd+V / Cmd+A 等编辑快捷键会失效。
    // 补一个标准 Edit 菜单，输入框才能正常粘贴。
    @MainActor
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: String(localized: "Quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            self.installStatusItem()
        }
        return false
    }

    private var quitMenu: NSMenu = {
        let menu = NSMenu()
        // 标题跟随界面语言，语言切换后重启即生效
        let quit = NSMenuItem(title: String(localized: "Quit"), action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }()

    @MainActor
    func installStatusItem() {
        if let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
            statusItem = nil
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "CursorUsageBarStatusItem"
        item.isVisible = true
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.toolTip = "Cursor / DeepSeek usage"
            button.target = self
            button.action = #selector(handleStatusClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        quitMenu.items.first?.target = self
        statusItem = item
        updateStatusItem()
    }

    @MainActor
    func updateStatusItem() {
        let usage = store.usage
        let extra = store.showExtraRings
        // 三柱比圆环宽，占位跟着图标走
        let iconWidth = extra ? StatusRingImage.barIconSize.width : StatusRingImage.pieIconSize.width
        statusItem?.length = iconWidth + 2
        // 融合套餐没有 Auto/API 拆分，中间 API 柱不画，避免一直满格
        let showApi = extra && usage?.planKind != .unified
        statusItem?.button?.image = StatusRingImage.make(
            autoPercent: usage.map(\.autoRemaining),
            apiPercent: showApi ? usage.map(\.apiRemaining) : nil,
            ondPercent: extra ? usage?.ondRemaining : nil,
            showExtraRings: extra
        )
        statusItem?.button?.title = ""
    }

    @objc private func handleStatusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            panel?.hide()
            guard let button = statusItem?.button else { return }
            quitMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
            return
        }
        panel?.toggle()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
