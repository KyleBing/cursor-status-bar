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
    private var statusItem: NSStatusItem?
    private var panel: StatusPanelController?
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store = UsageStore()
        panel = StatusPanelController(store: store)
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            self.installStatusItem()
        }
        return false
    }

    private var quitMenu: NSMenu = {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
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
            button.toolTip = "Cursor usage"
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
        statusItem?.length = extra ? 30 : 23
        statusItem?.button?.image = StatusRingImage.make(
            autoPercent: usage.map(\.autoRemaining),
            apiPercent: extra ? usage.map(\.apiRemaining) : nil,
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
