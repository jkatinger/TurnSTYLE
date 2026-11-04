import AppKit
import SwiftUI
import UserNotifications

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    var item: NSStatusItem!
    var model: QueueModel!
    private var windowPreferencesObserver: NSObjectProtocol?

    private func applyWindowPreferences() {
        let level: NSWindow.Level = UserDefaults.standard.bool(forKey: "turnstyle.alwaysOnTop") ? .floating : .normal
        if window.level != level { window.level = level }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.katinger.turnstyle").count > 1 {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.katinger.turnstyle")
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?.activate()
            NSApp.terminate(nil)
            return
        }
        (AppAppearance(rawValue: UserDefaults.standard.string(forKey: "turnstyle.appearance") ?? "System") ?? .system)
            .apply()
        model = QueueModel()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.title = "TurnSTYLE"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 980, height: 650)
        window.isReleasedWhenClosed = false
        applyWindowPreferences()
        windowPreferencesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyWindowPreferences() }
        }
        let host = NSHostingView(rootView: QueueView(model: model))
        // Keep changing queue content from resizing the user's window.
        host.sizingOptions = []
        window.contentView = host
        window.center()
        window.setFrameAutosaveName("TurnSTYLEQueue")
        if let screen = window.screen, window.frame.height > screen.visibleFrame.height {
            window.setFrame(
                NSRect(
                    x: screen.visibleFrame.midX - 560,
                    y: screen.visibleFrame.midY - 370, width: 1120, height: 740), display: false)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        model.onChange = { [weak self] in self?.updateMenu() }
        setupMainMenu()
        updateMenu()
        UNUserNotificationCenter.current().delegate = self
        showWindow()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.state.reconcileAfterRestart()
                self?.model.tick()
            }
        }
    }
    func setupMainMenu() {
        let menu = NSMenu()
        let root = NSMenuItem()
        menu.addItem(root)
        let app = NSMenu()
        root.submenu = app
        app.addItem(
            withTitle: "About TurnSTYLE", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Show queue", action: #selector(showWindow), keyEquivalent: "1").target = self
        app.addItem(withTitle: "Quit TurnSTYLE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        menu.addItem(editItem)
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }
    func updateMenu() {
        guard model != nil else { return }
        item.button?.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "TurnSTYLE")
        item.button?.title = " \(model.allReady.count)"
        item.button?.toolTip = "TurnSTYLE · \(model.allReady.count) conversations need attention"
        let menu = NSMenu()
        let heading = NSMenuItem(
            title: model.demo ? "TurnSTYLE · Sample queue" : "TurnSTYLE · \(model.allReady.count) ready", action: nil,
            keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open queue", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show next conversation", action: #selector(showNext), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit TurnSTYLE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        NSApp.dockTile.badgeLabel = model.allReady.isEmpty ? nil : String(model.allReady.count)
    }
    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showNext() {
        model.next()
        showWindow()
    }
    @objc func settings() {
        model.showSettings = true
        showWindow()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            self.showNext()
            completionHandler()
        }
    }
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
