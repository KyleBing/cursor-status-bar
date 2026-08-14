import AppKit
import SwiftUI

// 不用自定义圆角/箭头：系统 NSPanel 自带边框和阴影，不会被 clip。
final class StatusPanelController: NSObject {
    private let store: UsageStore
    private var panel: KeyablePanel?
    private var host: NSHostingController<AnyView>?
    private var clickMonitor: Any?

    init(store: UsageStore) {
        self.store = store
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func hide() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        panel?.orderOut(nil)
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame
        let width: CGFloat = 360
        let maxHeight = min(700, max(280, visible.height - 16))
        var x = mouse.x - width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        let y = visible.maxY - maxHeight
        let frame = NSRect(x: x, y: y, width: width, height: maxHeight)

        let host = NSHostingController(
            rootView: AnyView(
                PopoverView()
                    .environmentObject(store)
                    .frame(width: width, height: maxHeight)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .ignoresSafeArea()
            )
        )
        self.host = host
        host.safeAreaRegions = []
        host.view.frame = NSRect(origin: .zero, size: frame.size)
        host.view.autoresizingMask = [.width, .height]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let panel = KeyablePanel(
            contentRect: frame,
            styleMask: [.titled, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hasShadow = true
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = host.view
        panel.setFrame(frame, display: true)
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // 打开时不要把焦点落到 GitHub 按钮等控件上
        panel.makeFirstResponder(nil)

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.handleOutsideClick()
        }
        Task { await store.refreshDetails() }
    }

    private func handleOutsideClick() {
        let mouse = NSEvent.mouseLocation
        if let panel, panel.frame.contains(mouse) { return }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           mouse.y >= screen.visibleFrame.maxY {
            return
        }
        DispatchQueue.main.async { self.hide() }
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
