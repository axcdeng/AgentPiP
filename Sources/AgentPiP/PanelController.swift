import AppKit
import SwiftUI

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    var isBuiltInDisplay: Bool {
        guard let displayID else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }

    var hasPhysicalNotch: Bool {
        isBuiltInDisplay
            && safeAreaInsets.top > 0
            && auxiliaryTopLeftArea != nil
            && auxiliaryTopRightArea != nil
    }

    static var activeNotchScreen: NSScreen? {
        screens.first(where: \.hasPhysicalNotch)
    }
}

private final class AgentPiPPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

private final class PanelResizeHandle: NSView {
    enum Edge { case left, right, top, bottom }
    let edge: Edge
    private var tracking: NSTrackingArea?

    init(edge: Edge) { self.edge = edge; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: edge == .left || edge == .right ? .resizeLeftRight : .resizeUpDown)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { resizeCursor.set() }
    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    private var resizeCursor: NSCursor { edge == .left || edge == .right ? .resizeLeftRight : .resizeUpDown }
}

private final class PanelContentView<Content: View>: NSView {
    private let hosting: FirstMouseHostingView<Content>
    private let left = PanelResizeHandle(edge: .left), right = PanelResizeHandle(edge: .right)
    private let top = PanelResizeHandle(edge: .top), bottom = PanelResizeHandle(edge: .bottom)

    init(rootView: Content) {
        hosting = FirstMouseHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        [hosting, left, right, top, bottom].forEach(addSubview)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        hosting.frame = bounds
        let thickness: CGFloat = 8
        left.frame = NSRect(x: 0, y: thickness, width: thickness, height: max(0, bounds.height - thickness * 2))
        right.frame = NSRect(x: bounds.width - thickness, y: thickness, width: thickness, height: max(0, bounds.height - thickness * 2))
        bottom.frame = NSRect(x: thickness, y: 0, width: max(0, bounds.width - thickness * 2), height: thickness)
        top.frame = NSRect(x: thickness, y: bounds.height - thickness, width: max(0, bounds.width - thickness * 2), height: thickness)
        window?.invalidateCursorRects(for: left); window?.invalidateCursorRects(for: right)
        window?.invalidateCursorRects(for: top); window?.invalidateCursorRects(for: bottom)
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let monitor: SessionMonitor
    private let preferences: Preferences
    private let usageMonitor: UsageMonitor
    private let questionBridge: QuestionBridgeServer
    private let panel: NSPanel
    private var visibilityObservation: NSKeyValueObservation?
    private var lastMode: Preferences.DisplayMode?
    private var pipFrame: NSRect?

    init(monitor: SessionMonitor, preferences: Preferences, usageMonitor: UsageMonitor, questionBridge: QuestionBridgeServer, onOpenSettings: @escaping () -> Void) {
        self.monitor = monitor; self.preferences = preferences; self.usageMonitor = usageMonitor; self.questionBridge = questionBridge
        panel = AgentPiPPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90), styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.acceptsMouseMovedEvents = true
        panel.hasShadow = true
        panel.minSize = NSSize(width: 210, height: 38)
        panel.contentView = PanelContentView(rootView: AgentPanelView(monitor: monitor, preferences: preferences, usageMonitor: usageMonitor, questionBridge: questionBridge, onOpenSettings: onOpenSettings))
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.masksToBounds = true
        panel.setFrameAutosaveName("AgentPiPPanel")
        if !panel.setFrameUsingName("AgentPiPPanel") { placeInitially() }
        if preferences.displayMode == .pip { pipFrame = panel.frame }
        visibilityObservation = panel.observe(\.occlusionState, options: [.new]) { _, _ in }
    }

    func syncVisibility() {
        updatePanelModeIfNeeded()
        if preferences.displayMode == .notch {
            guard let screen = NSScreen.activeNotchScreen else {
                panel.orderOut(nil)
                return
            }
            positionNotchWindow(on: screen)
        } else {
            panel.minSize = preferences.collapsed
                ? NSSize(width: 210, height: 45)
                : NSSize(width: 300, height: 76)
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        if monitor.panelVisible {
            resizeToContent()
            if preferences.displayMode == .pip { ensureOnScreen() }
            panel.orderFrontRegardless()
        } else { panel.orderOut(nil) }
    }

    private func resizeToContent() {
        if preferences.displayMode == .notch { return }
        let hasLimits = !usageMonitor.claude.isEmpty || !usageMonitor.codex.isEmpty
        let questionHeight: CGFloat = questionBridge.requests.isEmpty ? 0 : 230
        let targetHeight: CGFloat = preferences.collapsed ? 45 : CGFloat(max(1, monitor.visibleSessions.count)) * (preferences.comfortableDensity ? 62 : 54) + 17 + (hasLimits ? 22 : 0) + questionHeight
        let clamped = min(targetHeight, 460)
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = clamped
        frame.origin.y = top - clamped
        panel.setFrame(frame, display: true, animate: false)
    }

    private func updatePanelModeIfNeeded() {
        guard preferences.displayMode != lastMode else { return }
        if lastMode == .pip { pipFrame = panel.frame }
        lastMode = preferences.displayMode

        if preferences.displayMode == .notch {
            panel.setFrameAutosaveName("")
            panel.styleMask.remove(.resizable)
            panel.isMovableByWindowBackground = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
            panel.hasShadow = false
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.contentView?.layer?.cornerRadius = 0
            panel.contentView?.layer?.masksToBounds = false
            if let screen = NSScreen.activeNotchScreen {
                positionNotchWindow(on: screen)
            }
        } else {
            preferences.notchExpanded = false
            panel.styleMask.insert(.resizable)
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.hasShadow = true
            panel.appearance = nil
            panel.contentView?.layer?.cornerRadius = 12
            panel.contentView?.layer?.masksToBounds = true
            panel.setFrameAutosaveName("AgentPiPPanel")
            if let pipFrame { panel.setFrame(pipFrame, display: true) }
        }
    }

    /// boring.notch keeps a single transparent panel at its maximum size and
    /// animates only the black SwiftUI surface inside it. Avoiding NSWindow
    /// frame animation prevents the hover feedback loop and geometry flicker.
    private func positionNotchWindow(on screen: NSScreen) {
        let width = min(640, screen.frame.width)
        let height = min(420, screen.frame.height)
        let frame = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
        panel.minSize = frame.size
        panel.maxSize = frame.size
        if !panel.frame.equalTo(frame) { panel.setFrame(frame, display: true) }
    }

    private func placeInitially() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 18, y: visible.maxY - panel.frame.height - 18))
    }

    private func ensureOnScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        var frame = panel.frame; let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { monitor.hidePanel(); return false }

    func windowDidResize(_ notification: Notification) {
        if preferences.displayMode == .pip { pipFrame = panel.frame }
    }
}
