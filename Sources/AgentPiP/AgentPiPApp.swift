import AppKit
import Combine
import SwiftUI

@main
enum AgentPiPMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences.shared
    private lazy var monitor = SessionMonitor(preferences: preferences)
    private lazy var questionBridge = QuestionBridgeServer(preferences: preferences, monitor: monitor)
    private let usageMonitor = UsageMonitor()
    private var panelController: PanelController?
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    private var diagnosticsWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        panelController = PanelController(monitor: monitor, preferences: preferences, usageMonitor: usageMonitor, questionBridge: questionBridge) { [weak self] in
            self?.showSettings()
        }
        applyAppearance(preferences.appearance)
        configureMenuBar()
        Publishers.CombineLatest4(monitor.$panelVisible, monitor.$sessions, preferences.$collapsed, preferences.$hiddenIDs)
            .combineLatest(preferences.$dismissedIDs)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.panelController?.syncVisibility(); self?.rebuildMenu() }.store(in: &cancellables)
        Publishers.CombineLatest(preferences.$displayMode, preferences.$notchExpanded)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.panelController?.syncVisibility(); self?.rebuildMenu() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.panelController?.syncVisibility() }
            .store(in: &cancellables)
        preferences.$appearance.removeDuplicates().sink { [weak self] appearance in self?.applyAppearance(appearance) }.store(in: &cancellables)
        Publishers.CombineLatest(usageMonitor.$claude, usageMonitor.$codex)
            .sink { [weak self] _ in self?.panelController?.syncVisibility() }.store(in: &cancellables)
        questionBridge.$requests
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.panelController?.syncVisibility() }
            .store(in: &cancellables)
        monitor.start()
        monitor.showPanel()
        usageMonitor.start()
        questionBridge.start()
        QuestionHookInstaller.install()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.monitor.hidePanel(); return nil }
            return event
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        monitor.showPanel()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func configureMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.inset.filled.and.person.filled", accessibilityDescription: "AgentPiP")
        statusItem = item; rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: monitor.panelVisible ? "Hide AgentPiP" : "Show AgentPiP", action: #selector(togglePanel), keyEquivalent: "p")
        let modeItem = NSMenuItem(title: "Display Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in Preferences.DisplayMode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.state = preferences.displayMode == mode ? .on : .off
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        let isCollapsed = preferences.displayMode == .notch ? !preferences.notchExpanded : preferences.collapsed
        menu.addItem(withTitle: isCollapsed ? "Expand" : "Collapse", action: #selector(toggleCollapsed), keyEquivalent: "")
        menu.addItem(.separator())
        let pause = menu.addItem(withTitle: preferences.paused ? "Resume Monitoring" : "Pause Monitoring", action: #selector(togglePaused), keyEquivalent: "")
        pause.state = preferences.paused ? .on : .off
        let hidden = NSMenuItem(title: "Hidden Threads", action: nil, keyEquivalent: "")
        let hiddenMenu = NSMenu()
        if monitor.hiddenSessions.isEmpty { let empty = hiddenMenu.addItem(withTitle: "None", action: nil, keyEquivalent: ""); empty.isEnabled = false }
        for session in monitor.hiddenSessions.prefix(20) {
            let item = NSMenuItem(title: session.title, action: #selector(restoreThread(_:)), keyEquivalent: ""); item.representedObject = session.id; hiddenMenu.addItem(item)
        }
        if !monitor.hiddenSessions.isEmpty { hiddenMenu.addItem(.separator()); hiddenMenu.addItem(withTitle: "Restore All", action: #selector(restoreAll), keyEquivalent: "") }
        hidden.submenu = hiddenMenu; menu.addItem(hidden)
        menu.addItem(withTitle: "Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AgentPiP", action: #selector(quit), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    @objc private func togglePanel() { monitor.togglePanel() }
    @objc private func toggleCollapsed() {
        if preferences.displayMode == .notch { preferences.notchExpanded.toggle() }
        else { preferences.collapsed.toggle() }
        panelController?.syncVisibility()
    }
    @objc private func setDisplayMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = Preferences.DisplayMode(rawValue: rawValue) else { return }
        preferences.notchExpanded = false
        preferences.displayMode = mode
    }
    @objc private func togglePaused() { preferences.paused.toggle(); preferences.paused ? monitor.stop() : monitor.start(); rebuildMenu() }
    @objc private func restoreThread(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { preferences.restore(id); monitor.showPanel() } }
    @objc private func restoreAll() { preferences.hiddenIDs.removeAll(); monitor.showPanel() }
    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "AgentPiP Settings"
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, usageMonitor: usageMonitor))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func applyAppearance(_ appearance: Preferences.Appearance) {
        NSApp.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    }
    @objc private func showDiagnostics() {
        if diagnosticsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "AgentPiP Diagnostics"; window.contentView = NSHostingView(rootView: DiagnosticsView(monitor: monitor)); window.center(); diagnosticsWindow = window
        }
        diagnosticsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
