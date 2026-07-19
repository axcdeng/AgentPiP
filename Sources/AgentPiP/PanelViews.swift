import AppKit
import SwiftUI

struct NotchGeometry {
    static func collapsedWidth(hardwareWidth: CGFloat, leftWingWidth: CGFloat, rightWingWidth: CGFloat) -> CGFloat {
        hardwareWidth + leftWingWidth + rightWingWidth
    }

    static func horizontalOffset(leftWingWidth: CGFloat, rightWingWidth: CGFloat) -> CGFloat {
        (rightWingWidth - leftWingWidth) / 2
    }

    static func centeredWingWidth(
        totalWidth: CGFloat,
        hardwareWidth: CGFloat,
        contentInset: CGFloat,
        railInset: CGFloat
    ) -> CGFloat {
        max(0, (totalWidth - hardwareWidth - 2 * contentInset - 2 * railInset) / 2)
    }
}

struct AgentPanelView: View {
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var preferences: Preferences
    @ObservedObject var usageMonitor: UsageMonitor
    @ObservedObject var questionBridge: QuestionBridgeServer
    let onOpenSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var notchHoverTask: Task<Void, Never>?
    @State private var isHoveringNotch = false

    private let notchAnimation = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.80, blendDuration: 0)

    @ViewBuilder
    var body: some View {
        if preferences.displayMode == .notch {
            notchWindowCanvas
        } else {
            Group {
                if preferences.collapsed { collapsedView }
                else { expandedView }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
        }
    }

    private var notchWindowCanvas: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                collapsedNotchView
                    .frame(width: notchWidth, height: notchHeight, alignment: .top)
                    .opacity(preferences.notchExpanded ? 0 : 1)
                    .allowsHitTesting(!preferences.notchExpanded)
                expandedNotchView
                    .frame(width: notchWidth, height: notchHeight, alignment: .top)
                    .opacity(preferences.notchExpanded ? 1 : 0)
                    .allowsHitTesting(preferences.notchExpanded)
            }
            .frame(width: notchWidth, height: notchHeight, alignment: .top)
            .background(Color.black)
            .clipShape(TopAttachedNotchShape(
                topRadius: notchTopRadius,
                bottomRadius: notchBottomRadius
            ))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.black)
                    .frame(height: 1)
                    .padding(.horizontal, notchTopRadius)
            }
            .shadow(color: isHoveringNotch || preferences.notchExpanded ? .black.opacity(0.65) : .clear, radius: 6)
            .contentShape(TopAttachedNotchShape(
                topRadius: notchTopRadius,
                bottomRadius: notchBottomRadius
            ))
            .onHover(perform: handleNotchHover)
            .onTapGesture { openNotch() }
            .offset(x: notchHorizontalOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Color.white)
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : notchAnimation, value: preferences.notchExpanded)
        .onDisappear {
            notchHoverTask?.cancel()
            notchHoverTask = nil
        }
    }

    private var collapsedNotchView: some View {
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(notchSummarySessions) { session in
                        ProviderMark(
                            provider: session.provider,
                            size: 23,
                            state: preferences.notchLayout == .compact ? markState(for: session.status) : .active
                        )
                    }
                }
                if preferences.notchLayout == .detailed, !activelyRunningSessions.isEmpty {
                    Text("Working…")
                        .font(.system(size: 12.1, weight: .semibold, design: .rounded))
                }
            }
            .padding(.leading, 12)
            .frame(width: collapsedLeftWingWidth, alignment: .leading)

            Color.clear
                .frame(width: physicalNotchWidth)

            Text("\(collapsedSessionCount)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(activelyRunningSessions.isEmpty ? Color.gray : Color.white)
                .padding(.leading, 2)
                .frame(width: collapsedRightWingWidth, alignment: .leading)
        }
        .frame(height: collapsedNotchHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activelyRunningSessions.isEmpty
            ? "\(monitor.visibleSessions.count) recent sessions"
            : "\(activelyRunningSessions.count) running sessions")
    }

    private var expandedNotchView: some View {
        VStack(spacing: 8) {
            notchTopRail
            if let request = questionBridge.requests.first {
                AgentQuestionCard(request: request, bridge: questionBridge)
                    .id(request.id)
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: notchColumns, spacing: 7) {
                    ForEach(monitor.visibleSessions) { session in
                        SessionRow(
                            session: session,
                            monitor: monitor,
                            preferences: preferences,
                            reduceMotion: reduceMotion,
                            darkSurface: true,
                            compact: true,
                            hideActivity: preferences.notchLayout == .compact,
                            tintLogoForStatus: preferences.notchLayout == .compact
                        )
                    }
                }
            }
        }
        .padding(.horizontal, expandedContentHorizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 9)
    }

    private var notchColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)]
    }

    private var notchTopRail: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    notchLimitGroups
                }
                .fixedSize(horizontal: true, vertical: true)

                VStack(alignment: .leading, spacing: 2) {
                    notchLimitGroups
                }
                .fixedSize(horizontal: true, vertical: true)
            }
            .frame(width: expandedLeftWingWidth, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(limitsAccessibilityText)

            Color.clear.frame(width: physicalNotchWidth)

            HStack(spacing: 10) {
                Text("\(monitor.visibleSessions.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.64))
                    .monospacedDigit()

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                }
                .help("Settings")

                Button(action: closeNotch) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                }
                .help("Collapse")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.72))
            .frame(width: expandedRightWingWidth, alignment: .trailing)
        }
        .frame(height: notchHeaderHeight)
        .padding(.horizontal, notchTopRailHorizontalPadding)
    }

    @ViewBuilder
    private var notchLimitGroups: some View {
        if !usageMonitor.claude.isEmpty {
            notchLimitWing(provider: .claude, limits: usageMonitor.claude)
        }
        if !usageMonitor.codex.isEmpty {
            notchLimitWing(provider: .codex, limits: usageMonitor.codex)
        }
    }

    @ViewBuilder
    private func notchLimitWing(provider: AgentProvider, limits: ProviderLimits) -> some View {
        if !limits.isEmpty {
            HStack(spacing: 5) {
                ProviderMark(provider: provider, size: 15)
                HStack(spacing: 6) {
                    if let value = limits.fiveHourRemaining {
                        notchLimitValue("5H", value)
                    }
                    if let value = limits.weeklyRemaining {
                        notchLimitValue("Wk", value)
                    }
                }
                .font(.system(size: 9.9, weight: .semibold, design: .rounded))
                .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: true)
        }
    }

    private func notchLimitValue(_ label: String, _ value: Int) -> Text {
        Text("\(label) ").foregroundColor(.white.opacity(0.64))
            + Text("\(value)%").foregroundColor(limitColor(value))
    }

    private func limitColor(_ value: Int) -> Color {
        let percent = min(100, max(0, value))
        return Color(hue: Double(percent) / 300.0, saturation: 0.78, brightness: 0.96)
    }

    private var activelyRunningSessions: [AgentSession] {
        monitor.visibleSessions.filter { $0.status == .working || $0.status == .waitingForSubagents }
    }

    private var notchSummarySessions: [AgentSession] {
        let sessions = activelyRunningSessions.isEmpty ? monitor.visibleSessions : activelyRunningSessions
        return Array(sessions.prefix(4))
    }

    private var collapsedSessionCount: Int {
        activelyRunningSessions.isEmpty ? monitor.visibleSessions.count : activelyRunningSessions.count
    }

    private var notchWidth: CGFloat {
        if preferences.notchExpanded { return 480 }
        return NotchGeometry.collapsedWidth(
            hardwareWidth: physicalNotchWidth,
            leftWingWidth: collapsedLeftWingWidth,
            rightWingWidth: collapsedRightWingWidth
        )
    }

    private var notchHeight: CGFloat {
        guard preferences.notchExpanded else { return collapsedNotchHeight }
        let rows = max(1, Int(ceil(Double(monitor.visibleSessions.count) / 2.0)))
        let rowHeight: CGFloat = preferences.notchLayout == .compact ? 36 : 50
        let headerHeight = notchHeaderHeight
        let questionHeight = questionBridge.requests.first.map(questionCardHeight) ?? 0
        return min(400, 25 + headerHeight + questionHeight + CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * 7)
    }

    private func questionCardHeight(_ request: AgentQuestionRequest) -> CGFloat {
        guard let question = request.questions.first else { return 0 }
        let rows = min(4, question.options.count + (question.allowsOther ? 1 : 0))
        return min(238, 74 + CGFloat(rows) * 39)
    }

    private var collapsedLeftWingWidth: CGFloat {
        let icons = CGFloat(notchSummarySessions.count) * 27
        if preferences.notchLayout == .compact { return max(50, 16 + icons) }
        return max(120, 88 + icons)
    }

    private var collapsedRightWingWidth: CGFloat { 28 }

    private var collapsedNotchHeight: CGFloat { max(36, physicalNotchHeight) }

    private var notchTopRadius: CGFloat { preferences.notchExpanded ? 19 : 6 }

    private var notchBottomRadius: CGFloat { preferences.notchExpanded ? 24 : 14 }

    private var expandedContentHorizontalPadding: CGFloat { notchTopRadius + 12 }

    private var notchTopRailHorizontalPadding: CGFloat { 5 }

    private var notchHorizontalOffset: CGFloat {
        guard !preferences.notchExpanded else { return 0 }
        return NotchGeometry.horizontalOffset(
            leftWingWidth: collapsedLeftWingWidth,
            rightWingWidth: collapsedRightWingWidth
        )
    }

    private var notchHeaderHeight: CGFloat {
        let hasBothProviders = !usageMonitor.claude.isEmpty && !usageMonitor.codex.isEmpty
        return max(22, physicalNotchHeight, hasBothProviders ? 34 : 22)
    }

    private var expandedLeftWingWidth: CGFloat {
        expandedWingWidth
    }

    private var expandedRightWingWidth: CGFloat {
        expandedWingWidth
    }

    private var expandedWingWidth: CGFloat {
        NotchGeometry.centeredWingWidth(
            totalWidth: notchWidth,
            hardwareWidth: physicalNotchWidth,
            contentInset: expandedContentHorizontalPadding,
            railInset: notchTopRailHorizontalPadding
        )
    }

    private var physicalNotchWidth: CGFloat {
        guard let screen = NSScreen.activeNotchScreen,
              let left = screen.auxiliaryTopLeftArea?.width,
              let right = screen.auxiliaryTopRightArea?.width else { return 0 }
        return max(0, screen.frame.width - left - right + 4)
    }

    private var physicalNotchHeight: CGFloat {
        guard let screen = NSScreen.activeNotchScreen else { return 0 }
        return screen.safeAreaInsets.top
    }

    private func handleNotchHover(_ hovering: Bool) {
        notchHoverTask?.cancel()
        isHoveringNotch = hovering
        if hovering {
            guard !preferences.notchExpanded else { return }
            notchHoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, isHoveringNotch, preferences.displayMode == .notch else { return }
                openNotch()
            }
        } else {
            notchHoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, !isHoveringNotch, preferences.notchExpanded,
                      questionBridge.requests.isEmpty else { return }
                closeNotch()
            }
        }
    }

    private func openNotch() {
        guard !preferences.notchExpanded else { return }
        withAnimation(reduceMotion ? nil : notchAnimation) { preferences.notchExpanded = true }
    }

    private func closeNotch() {
        guard preferences.notchExpanded else { return }
        withAnimation(reduceMotion ? nil : notchAnimation) { preferences.notchExpanded = false }
    }

    private func markState(for status: SessionStatus) -> ProviderMarkState {
        switch status {
        case .working, .waitingForSubagents: .active
        case .needsInput: .needsInput
        case .done: .done
        case .cancelled, .failed: .stopped
        case .stale: .inactive
        }
    }

    private var expandedView: some View {
        VStack(spacing: 5) {
            topRail
            if let request = questionBridge.requests.first {
                AgentQuestionCard(request: request, bridge: questionBridge)
                    .id(request.id)
            }
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

private struct AgentQuestionCard: View {
    let request: AgentQuestionRequest
    @ObservedObject var bridge: QuestionBridgeServer
    @State private var questionIndex = 0
    @State private var answers: [String: String] = [:]
    @State private var selections: Set<String> = []
    @State private var showingOther = false
    @State private var otherText = ""
    @FocusState private var otherFocused: Bool

    private var question: AgentQuestion { request.questions[min(questionIndex, request.questions.count - 1)] }
    private var standardOptions: [AgentQuestionOption] {
        question.options.filter { $0.label.caseInsensitiveCompare("Other") != .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderMark(provider: request.provider, size: 15)
                Text("\(request.provider.displayName) asks")
                    .font(.system(size: 10.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                if request.questions.count > 1 {
                    Text("\(questionIndex + 1)/\(request.questions.count)")
                        .font(.system(size: 9.9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            Text(question.prompt)
                .font(.system(size: 12.1, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 5) {
                ForEach(Array(standardOptions.enumerated()), id: \.element) { index, option in
                    optionButton(option, index: index)
                }
                if question.allowsOther { otherControl(index: standardOptions.count) }
            }

            if question.allowsMultiple {
                HStack {
                    if questionIndex > 0 { previousButton }
                    Spacer()
                    Button("Submit \(selections.count) selected") { submitMultiple() }
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.18))
                        .disabled(selections.isEmpty)
                }
                .font(.system(size: 10.45, weight: .semibold, design: .rounded))
            } else if questionIndex > 0 {
                previousButton
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    private func optionButton(_ option: AgentQuestionOption, index: Int) -> some View {
        let selected = selections.contains(option.label)
        return Button {
            if question.allowsMultiple {
                if selected { selections.remove(option.label) } else { selections.insert(option.label) }
            } else {
                accept(option.label)
            }
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Text("⌘\(index + 1)")
                    .font(.system(size: 9.35, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(width: 20, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 9.35, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 2)
                if question.allowsMultiple, selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.green.opacity(0.14) : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(min(9, index + 1))")), modifiers: .command)
    }

    @ViewBuilder
    private func otherControl(index: Int) -> some View {
        if showingOther {
            HStack(spacing: 6) {
                TextField("Other answer", text: $otherText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .focused($otherFocused)
                    .onSubmit { submitOther() }
                Button("Send") { submitOther() }
                    .font(.system(size: 10.45, weight: .semibold, design: .rounded))
                    .disabled(otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        } else {
            Button {
                showingOther = true
                otherFocused = true
            } label: {
                HStack(spacing: 7) {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 9.35, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 20, alignment: .leading)
                    Text("Other")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(KeyEquivalent(Character("\(min(9, index + 1))")), modifiers: .command)
        }
    }

    private var previousButton: some View {
        Button("Previous") {
            guard questionIndex > 0 else { return }
            questionIndex -= 1
            selections.removeAll()
            showingOther = false
            otherText = ""
        }
        .buttonStyle(.plain)
        .font(.system(size: 9.9, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.55))
    }

    private func accept(_ answer: String) {
        var updated = answers
        updated[question.header] = answer
        advance(with: updated)
    }

    private func submitOther() {
        let value = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        accept(value)
    }

    private func submitMultiple() {
        guard !selections.isEmpty else { return }
        var updated = answers
        updated[question.header] = selections.sorted().joined(separator: ", ")
        advance(with: updated)
    }

    private func advance(with updated: [String: String]) {
        answers = updated
        if questionIndex + 1 < request.questions.count {
            questionIndex += 1
            selections.removeAll()
            showingOther = false
            otherText = ""
        } else {
            bridge.answer(request, answers: updated)
        }
    }
}

/// The top corners are concave shoulders: the narrow body curves outward into
/// the screen edge instead of clipping inward like a rounded rectangle.
private struct TopAttachedNotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, min(rect.width / 2, rect.height))
        let bottom = min(bottomRadius, min(rect.width / 2, rect.height))
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
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
                Toggle("Always show AgentPiP when an agent is started", isOn: $preferences.alwaysShowPIPOnAgentStart)
            }
            Section("Appearance") {
                Picker("Display mode", selection: $preferences.displayMode) {
                    ForEach(Preferences.DisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                if preferences.displayMode == .notch {
                    Picker("Notch layout", selection: $preferences.notchLayout) {
                        ForEach(Preferences.NotchLayout.allCases) { layout in
                            Text(layout.label).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                }
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
    var darkSurface = false
    var compact = false
    var hideActivity = false
    var tintLogoForStatus = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderMark(
                provider: session.provider,
                size: compact ? 19 : 21,
                state: tintLogoForStatus ? markState : .active
            )
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.title.isEmpty ? session.projectName : session.title)
                        .font(.system(size: compact ? 12.1 : 12, weight: .semibold)).foregroundStyle(darkSurface ? Color.white : .primary).lineLimit(1)
                    if !session.childAgents.isEmpty {
                        SubagentBadge(count: session.childAgents.count, textScale: compact ? 1.1 : 1)
                    }
                    if let model = session.modelDisplayName {
                        Text(model).font(.system(size: compact ? 10.45 : 9.5, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.82))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer(minLength: 4)
                    if hovering { controls.transition(.opacity) }
                }
                if !hideActivity {
                    TimelineView(.periodic(from: .now, by: refreshInterval)) { timeline in
                        HStack(spacing: 5) {
                            Text(primaryText(now: timeline.date)).font(.system(size: compact ? 11.55 : 11.5, weight: .medium)).foregroundStyle(primaryColor)
                            if session.status == .working, let detail = session.activity.detail {
                                ShimmerText(text: detail, active: session.status == .working && !reduceMotion, darkSurface: darkSurface, fontSize: compact ? 12.65 : 11.5)
                            }
                        }.lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, compact ? 8 : 9).padding(.vertical, hideActivity ? 6 : (compact ? 7 : (preferences.comfortableDensity ? 11 : 8)))
        .background(hideActivity && darkSurface ? Color.white.opacity(0.055) : rowTint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle()).onTapGesture { monitor.open(session) }
        .onHover { isHovering in withAnimation(.easeOut(duration: 0.14)) { hovering = isHovering } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.provider.displayName), \(primaryText(now: .now)), \(session.activity.detail ?? "")")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if let value = session.activity.copyValue {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("Copy")
            }
            if !session.status.isActive {
                Button { preferences.dismiss(session.id) } label: { Image(systemName: "xmark") }.help("Dismiss")
            } else {
                Button { preferences.hide(session.id) } label: { Image(systemName: "eye.slash") }.help("Hide thread")
            }
        }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(darkSurface ? Color.white.opacity(0.62) : Color.secondary)
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
    private var primaryColor: Color { session.status == .done ? Color(red: 0.33, green: 0.82, blue: 0.47) : (darkSurface ? .white : .primary) }
    private var markState: ProviderMarkState {
        switch session.status {
        case .working, .waitingForSubagents: .active
        case .needsInput: .needsInput
        case .done: .done
        case .cancelled, .failed: .stopped
        case .stale: .inactive
        }
    }
    private var rowTint: Color {
        if darkSurface {
            switch session.status {
            case .needsInput: return Color.orange.opacity(0.20)
            case .waitingForSubagents: return Color.purple.opacity(0.18)
            case .done: return Color.green.opacity(0.13)
            case .failed: return Color.red.opacity(0.16)
            default: return Color.white.opacity(0.075)
            }
        }
        switch session.status {
        case .needsInput: return Color.orange.opacity(0.10)
        case .waitingForSubagents: return Color.purple.opacity(0.09)
        case .done: return Color.green.opacity(0.07)
        case .cancelled: return Color.gray.opacity(0.07)
        case .failed: return Color.red.opacity(0.08)
        default:
            switch session.provider {
            case .claude: return Color.orange.opacity(0.045)
            case .antigravity: return Color.indigo.opacity(0.055)
            case .opencode: return Color.green.opacity(0.05)
            case .cursor: return Color.gray.opacity(0.07)
            case .codex: return Color.blue.opacity(0.04)
            }
        }
    }
}

private enum ProviderMarkState {
    case active, inactive, stopped, needsInput, done

    var saturation: Double {
        switch self {
        case .active: 1
        case .inactive: 0
        default: 0.32
        }
    }

    var opacity: Double { self == .inactive ? 0.48 : 1 }

    var color: Color {
        switch self {
        case .active, .inactive: .white
        case .stopped: Color(red: 1.0, green: 0.56, blue: 0.56)
        case .needsInput: Color(red: 1.0, green: 0.72, blue: 0.20)
        case .done: Color(red: 0.48, green: 1.0, blue: 0.58)
        }
    }
}

@MainActor
private final class ProviderIconStore {
    static let shared = ProviderIconStore()
    private var images: [AgentProvider: NSImage] = [:]

    func image(for provider: AgentProvider) -> NSImage {
        if let image = images[provider] { return image }
        let image = load(provider)
        images[provider] = image
        return image
    }

    private func load(_ provider: AgentProvider) -> NSImage {
        for id in provider.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        if let url = Bundle.module.url(forResource: provider.rawValue, withExtension: "svg", subdirectory: "ProviderIcons"),
           let image = NSImage(contentsOf: url) { return image }
        if let url = Bundle.main.resourceURL?.appending(path: "ProviderIcons/\(provider.rawValue).svg"),
           let image = NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: provider.displayName) ?? NSImage()
    }
}

private struct ProviderMark: View {
    let provider: AgentProvider
    var size: CGFloat = 21
    var state: ProviderMarkState = .active
    var body: some View {
        Image(nsImage: appIcon)
            .resizable().scaledToFit().frame(width: size, height: size)
            .saturation(state.saturation)
            .colorMultiply(state.color)
            .opacity(state.opacity)
            .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.24), style: .continuous))
            .accessibilityLabel(provider.displayName)
    }

    private var appIcon: NSImage { ProviderIconStore.shared.image(for: provider) }
}

private struct SubagentBadge: View {
    let count: Int
    var textScale: CGFloat = 1
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            Image(systemName: "cpu").font(.system(size: 9, weight: .semibold))
            Text("×\(count)").font(.system(size: 10 * textScale, weight: .bold, design: .rounded))
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
    var darkSurface = false
    var fontSize: CGFloat = 11.5
    @State private var phase = false
    var body: some View {
        Text(text).font(.system(size: fontSize)).foregroundStyle(darkSurface ? Color.white.opacity(0.62) : Color.secondary).lineLimit(1).truncationMode(.middle)
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
