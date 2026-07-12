import AppKit
import SwiftUI

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
    private let hosting: NSHostingView<Content>
    private let left = PanelResizeHandle(edge: .left), right = PanelResizeHandle(edge: .right)
    private let top = PanelResizeHandle(edge: .top), bottom = PanelResizeHandle(edge: .bottom)

    init(rootView: Content) {
        hosting = NSHostingView(rootView: rootView)
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
    private let panel: NSPanel
    private var visibilityObservation: NSKeyValueObservation?

    init(monitor: SessionMonitor, preferences: Preferences, usageMonitor: UsageMonitor, onOpenSettings: @escaping () -> Void) {
        self.monitor = monitor; self.preferences = preferences; self.usageMonitor = usageMonitor
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90), styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
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
        panel.contentView = PanelContentView(rootView: AgentPanelView(monitor: monitor, preferences: preferences, usageMonitor: usageMonitor, onOpenSettings: onOpenSettings))
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.masksToBounds = true
        panel.setFrameAutosaveName("AgentPiPPanel")
        if !panel.setFrameUsingName("AgentPiPPanel") { placeInitially() }
        visibilityObservation = panel.observe(\.occlusionState, options: [.new]) { _, _ in }
    }

    func syncVisibility() {
        if monitor.panelVisible && !monitor.visibleSessions.isEmpty {
            resizeToContent(); ensureOnScreen(); panel.orderFrontRegardless()
        } else { panel.orderOut(nil) }
    }

    private func resizeToContent() {
        let hasLimits = !usageMonitor.claude.isEmpty || !usageMonitor.codex.isEmpty
        let targetHeight: CGFloat = preferences.collapsed ? 45 : CGFloat(max(1, monitor.visibleSessions.count)) * (preferences.comfortableDensity ? 62 : 54) + 17 + (hasLimits ? 22 : 0)
        let clamped = min(targetHeight, 460)
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = clamped
        frame.origin.y = top - clamped
        panel.setFrame(frame, display: true, animate: false)
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
}
