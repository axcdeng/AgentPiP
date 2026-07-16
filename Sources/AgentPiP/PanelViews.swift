import AppKit
import SwiftUI

struct AgentPanelView: View {
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var preferences: Preferences
    @ObservedObject var usageMonitor: UsageMonitor
    let onOpenSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if preferences.collapsed { collapsedView }
            else { expandedView }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }

    private var expandedView: some View {
        VStack(spacing: 5) {
            topRail
            ForEach(monitor.visibleSessions) { session in
                SessionRow(session: session, monitor: monitor, preferences: preferences, reduceMotion: reduceMotion)
            }
            if let text = limitsText {
                text
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 1)
                    .padding(.bottom, 2)
                    .accessibilityLabel(limitsAccessibilityText)
            }
        }
        .padding(5)
        .frame(minWidth: 300, idealWidth: 360, maxWidth: 540)
    }

    private var topRail: some View {
        ZStack {
            Capsule().fill(Color.primary.opacity(0.14)).frame(width: 22, height: 2)
            HStack(spacing: 2) {
                Spacer()
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                }
                .help("Settings")
                Button { withAnimation(.easeOut(duration: 0.18)) { preferences.collapsed = true } } label: {
                    Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }
                .help("Collapse")
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 7)
    }

    private var limitsText: Text? {
        func provider(_ name: String, _ limits: ProviderLimits) -> Text? {
            var result = Text(name)
            var hasLimit = false
            if let value = limits.fiveHourRemaining {
                result = result + Text(" 5h ") + Text("\(value)%").bold(); hasLimit = true
            }
            if let value = limits.weeklyRemaining {
                result = result + Text(" Wk ") + Text("\(value)%").bold(); hasLimit = true
            }
            return hasLimit ? result : nil
        }
        let values = [provider("Claude", usageMonitor.claude), provider("Codex", usageMonitor.codex)].compactMap { $0 }
        guard let first = values.first else { return nil }
        return values.dropFirst().reduce(first) { $0 + Text("  \\  ") + $1 }
    }

    private var limitsAccessibilityText: String {
        func provider(_ name: String, _ limits: ProviderLimits) -> String? {
            let values = [("5 hours", limits.fiveHourRemaining), ("week", limits.weeklyRemaining)]
                .compactMap { label, value in value.map { "\(label) \($0) percent remaining" } }
            return values.isEmpty ? nil : "\(name), \(values.joined(separator: ", "))"
        }
        return [provider("Claude", usageMonitor.claude), provider("Codex", usageMonitor.codex)].compactMap { $0 }.joined(separator: "; ")
    }

    private var collapsedView: some View {
        let active = monitor.visibleSessions.filter { $0.status.isActive }.count
        return VStack(spacing: 0) {
            dragRail
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(AgentProvider.allCases, id: \.self) { provider in
                        if monitor.visibleSessions.contains(where: { $0.provider == provider }) { ProviderMark(provider: provider) }
                    }
                }
                Text(active > 0 ? "\(active) agent\(active == 1 ? "" : "s") working…" : "\(monitor.visibleSessions.count) finished")
                    .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if monitor.visibleSessions.contains(where: { $0.status == .needsInput }) {
                    Circle().fill(Color.orange).frame(width: 6, height: 6).accessibilityLabel("An agent needs help")
                }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11).frame(height: 38).contentShape(Rectangle())
        }
        .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { preferences.collapsed = false } }
        .frame(minWidth: 210, idealWidth: 250)
    }

    private var dragRail: some View {
        Capsule().fill(Color.primary.opacity(0.14)).frame(width: 22, height: 2).frame(maxWidth: .infinity).frame(height: 7)
            .accessibilityHidden(true)
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var usageMonitor: UsageMonitor
    @State private var claudeCookie = ""

    var body: some View {
        Form {
            Section("Threads") {
                Toggle("Automatically show previously hidden chats on new thread", isOn: $preferences.automaticallyRevealHiddenThreads)
                Toggle("Automatically show new threads", isOn: $preferences.automaticallyShowNewThreads)
                Toggle("Always show the PiP when an agent is started", isOn: $preferences.alwaysShowPIPOnAgentStart)
            }
            Section("Appearance") {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(Preferences.Appearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Claude limits") {
                HStack(spacing: 8) {
                    Button {
                        if let url = URL(string: "https://claude.ai") { NSWorkspace.shared.open(url) }
                    } label: {
                        Label("Open Claude.ai", systemImage: "safari")
                    }
                    Button {
                        guard let value = NSPasteboard.general.string(forType: .string) else { return }
                        if usageMonitor.saveClaudeCookie(value) { claudeCookie = "" }
                    } label: {
                        Label("Paste & Save", systemImage: "doc.on.clipboard")
                    }
                    Spacer()
                }
                SecureField("Claude.ai sessionKey", text: $claudeCookie)
                    .textFieldStyle(.roundedBorder)
                Text("In your browser's developer tools, open Application → Cookies → https://claude.ai, then copy sessionKey. Paste its value here, or copy the whole Cookie header and use Paste & Save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Save Securely") {
                        if usageMonitor.saveClaudeCookie(claudeCookie) { claudeCookie = "" }
                    }
                    .disabled(claudeCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if usageMonitor.hasClaudeCookie {
                        Button("Remove", role: .destructive) { usageMonitor.removeClaudeCookie() }
                    }
                    Spacer()
                    Text(usageMonitor.hasClaudeCookie ? "Configured" : "Not configured")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let status = usageMonitor.claudeCookieStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 500, height: 470)
    }
}

private struct SessionRow: View {
    let session: AgentSession
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var preferences: Preferences
    let reduceMotion: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderMark(provider: session.provider).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.title.isEmpty ? session.projectName : session.title)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    if !session.childAgents.isEmpty {
                        SubagentBadge(count: session.childAgents.count)
                    }
                    if let model = session.modelDisplayName {
                        Text(model).font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.82))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer(minLength: 4)
                    if hovering { controls.transition(.opacity) }
                }
                TimelineView(.periodic(from: .now, by: refreshInterval)) { timeline in
                    HStack(spacing: 5) {
                        Text(primaryText(now: timeline.date)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(primaryColor)
                        if session.status == .working, let detail = session.activity.detail {
                            ShimmerText(text: detail, active: session.status == .working && !reduceMotion)
                        }
                    }.lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, preferences.comfortableDensity ? 11 : 8)
        .background(rowTint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle()).onTapGesture { monitor.open(session) }
        .onHover { isHovering in withAnimation(.easeOut(duration: 0.14)) { hovering = isHovering } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.provider.displayName), \(primaryText(now: .now)), \(session.activity.detail ?? "")")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { monitor.open(session) } label: { Image(systemName: "arrow.up.forward.app") }.help("Open thread")
            if let value = session.activity.copyValue {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("Copy")
            }
            if !session.status.isActive {
                Button { preferences.dismiss(session.id) } label: { Image(systemName: "xmark") }.help("Dismiss")
            } else {
                Button { preferences.hide(session.id) } label: { Image(systemName: "eye.slash") }.help("Hide thread")
            }
        }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private var refreshInterval: TimeInterval {
        let elapsed = Date().timeIntervalSince(session.workingSince)
        return elapsed < 60 ? 1 : elapsed < 3_600 ? 10 : 60
    }
    private func primaryText(now: Date) -> String {
        switch session.status {
        case .working: TimeText.elapsed(since: session.workingSince, now: now)
        case .needsInput: "Needs input"
        case .waitingForSubagents: "Waiting for subagents…"
        case .done: "Done"
        case .cancelled: "Stopped"
        case .failed: "Stopped with an error"
        case .stale: "Connection lost"
        }
    }
    private var primaryColor: Color { session.status == .done ? Color(red: 0.18, green: 0.52, blue: 0.29) : .primary }
    private var rowTint: Color {
        switch session.status {
        case .needsInput: Color.orange.opacity(0.10)
        case .waitingForSubagents: Color.purple.opacity(0.09)
        case .done: Color.green.opacity(0.07)
        case .cancelled: Color.gray.opacity(0.07)
        case .failed: Color.red.opacity(0.08)
        default:
            switch session.provider {
            case .claude: Color.orange.opacity(0.045)
            case .antigravity: Color.indigo.opacity(0.055)
            case .opencode: Color.green.opacity(0.05)
            case .cursor: Color.gray.opacity(0.07)
            case .codex: Color.blue.opacity(0.04)
            }
        }
    }
}

private struct ProviderMark: View {
    let provider: AgentProvider
    var body: some View {
        Image(nsImage: appIcon)
            .resizable().scaledToFit().frame(width: 21, height: 21)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(provider.displayName)
    }

    private var appIcon: NSImage {
        for id in provider.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return NSWorkspace.shared.icon(forFile: url.path) }
        }
        if let url = Bundle.module.url(forResource: provider.rawValue, withExtension: "svg", subdirectory: "ProviderIcons"),
           let image = NSImage(contentsOf: url) { return image }
        if let url = Bundle.main.resourceURL?.appending(path: "ProviderIcons/\(provider.rawValue).svg"),
           let image = NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: provider.displayName) ?? NSImage()
    }
}

private struct SubagentBadge: View {
    let count: Int
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            Image(systemName: "cpu").font(.system(size: 9, weight: .semibold))
            Text("×\(count)").font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(Color(red: 0.79, green: 0.34, blue: 0.96))
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.purple.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel("\(count) subagents")
    }
}

private struct ShimmerText: View {
    let text: String
    let active: Bool
    @State private var phase = false
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            .opacity(active ? (phase ? 0.48 : 0.78) : 0.68)
            .animation(active ? .easeInOut(duration: 1.35).repeatForever(autoreverses: true) : nil, value: phase)
            .onAppear { phase = active }
            .onChange(of: active) { _, value in phase = value }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var monitor: SessionMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Diagnostics").font(.system(size: 17, weight: .semibold))
            ForEach(monitor.health) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(item.provider.displayName).fontWeight(.medium); Spacer(); Text(item.watched ? "Watching" : "Unavailable").foregroundStyle(item.watched ? .green : .secondary) }
                    Text(item.rootPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Text("\(item.sessionCount) detected sessions").font(.caption).foregroundStyle(.secondary)
                    if let error = item.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Divider()
            }
            Text("AgentPiP reads local event metadata. If Claude limits are configured, it contacts claude.ai using the Keychain-protected session cookie.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 420)
    }
}
