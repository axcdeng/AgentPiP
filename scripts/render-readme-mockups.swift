#!/usr/bin/env swift

import AppKit
import SwiftUI

private enum MockProvider: String {
    case claude, codex, antigravity, cursor

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "ChatGPT"
        case .antigravity: "Antigravity"
        case .cursor: "Cursor"
        }
    }

    var applicationPath: String {
        switch self {
        case .claude: "/Applications/Claude.app"
        case .codex: "/Applications/ChatGPT.app"
        case .antigravity: "/Applications/Antigravity.app"
        case .cursor: "/Applications/Cursor.app"
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "circle.hexagongrid.fill"
        case .antigravity: "a.circle.fill"
        case .cursor: "cursorarrow"
        }
    }
}

private enum MockActivity {
    case editing, running, thinking, done

    var badgeSymbol: String? {
        switch self {
        case .editing: "pencil"
        case .running: "terminal.fill"
        case .thinking, .done: nil
        }
    }

    var tint: Color {
        switch self {
        case .done: Color(red: 0.31, green: 0.83, blue: 0.51)
        default: .white
        }
    }

    var trail: [Color] {
        switch self {
        case .editing: [Color(red: 0.98, green: 0.65, blue: 0.19), Color(red: 1.0, green: 0.38, blue: 0.33)]
        case .running: [Color(red: 0.38, green: 0.80, blue: 1.0), Color(red: 0.65, green: 0.45, blue: 1.0)]
        case .thinking: [Color(red: 0.94, green: 0.34, blue: 0.73), Color(red: 0.38, green: 0.72, blue: 1.0)]
        case .done: []
        }
    }
}

private struct MockSession: Identifiable {
    var id: MockProvider { provider }
    let provider: MockProvider
    let title: String
    let model: String?
    let activity: MockActivity
}

private final class MockIconStore {
    static let shared = MockIconStore()
    private var images: [MockProvider: NSImage] = [:]

    func image(for provider: MockProvider) -> NSImage {
        if let image = images[provider] { return image.copy() as? NSImage ?? image }
        let source: NSImage
        if FileManager.default.fileExists(atPath: provider.applicationPath) {
            source = NSWorkspace.shared.icon(forFile: provider.applicationPath)
        } else {
            source = NSImage(systemSymbolName: provider.fallbackSymbol, accessibilityDescription: provider.displayName) ?? NSImage()
        }
        let image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            return true
        }
        images[provider] = image
        return image.copy() as? NSImage ?? image
    }
}

private struct MockProviderMark: View {
    let provider: MockProvider
    let activity: MockActivity
    var size: CGFloat

    var body: some View {
        ZStack {
            let iconRadius = max(4, size * 0.24)
            let borderRadius = iconRadius + 1
            let side = size + 2
            let perimeter = max(1, 4 * (side - 2 * borderRadius) + 2 * .pi * borderRadius)
            let dashLength = max(3.5, size * 0.22)

            ForEach(Array(activity.trail.enumerated()), id: \.offset) { index, color in
                RoundedRectangle(cornerRadius: borderRadius, style: .continuous)
                    .strokeBorder(
                        color.opacity(1 - Double(index) * 0.075),
                        style: StrokeStyle(
                            lineWidth: max(1.65, size * 0.085),
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [dashLength, max(1, perimeter - dashLength)],
                            dashPhase: -perimeter * 0.17 + CGFloat(index) * dashLength * 0.80
                        )
                    )
            }

            Image(nsImage: MockIconStore.shared.image(for: provider))
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .saturation(activity == .done ? 0.35 : 1)
                .opacity(activity == .done ? 0.62 : 1)
                .clipShape(RoundedRectangle(cornerRadius: iconRadius, style: .continuous))
        }
        .frame(width: size + 2, height: size + 2)
    }
}

private struct MockActivityBadge: View {
    let symbol: String
    var size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .black))
            .foregroundStyle(Color.black)
            .frame(width: size, height: size)
            .background(Color.white, in: Circle())
            .overlay(Circle().strokeBorder(Color.black.opacity(0.9), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
    }
}

private struct TopAttachedNotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, min(rect.width / 2, rect.height))
        let bottom = min(bottomRadius, min(rect.width / 2, rect.height))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top), control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct MockCanvas<Notch: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var notch: Notch

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.92, green: 0.94, blue: 0.99), Color(red: 0.98, green: 0.95, blue: 0.90)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 10) {
                Spacer()
                Text(title)
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.78))
                Text(subtitle)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.48))
                Spacer().frame(height: 34)
            }
            notch
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Color.black.opacity(0.10)).frame(height: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.black.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.20), radius: 20, y: 10)
        .padding(34)
        .background(Color.clear)
    }
}

private struct CollapsedCompactNotch: View {
    private let sessions = [
        MockSession(provider: .claude, title: "Polish compact notch", model: "Sonnet 4", activity: .editing),
        MockSession(provider: .codex, title: "Run release checks", model: "GPT-5", activity: .running),
        MockSession(provider: .antigravity, title: "Review UI states", model: "Gemini", activity: .thinking),
        MockSession(provider: .cursor, title: "Finished tests", model: nil, activity: .done),
    ]
    private let physicalNotchWidth: CGFloat = 180

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(sessions) { session in
                    ZStack(alignment: .topTrailing) {
                        MockProviderMark(provider: session.provider, activity: session.activity, size: 23)
                        if let symbol = session.activity.badgeSymbol {
                            MockActivityBadge(symbol: symbol, size: 15)
                                .offset(x: 2, y: -2)
                        }
                    }
                }
            }
            .padding(.leading, 12)
            .frame(width: 124, alignment: .leading)

            Color.clear.frame(width: physicalNotchWidth)

            Text("3")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .padding(.leading, 2)
                .frame(width: 28, alignment: .leading)
        }
        .frame(width: 332, height: 36)
        .background(Color.black)
        .clipShape(TopAttachedNotchShape(topRadius: 6, bottomRadius: 14))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.black).frame(height: 1).padding(.horizontal, 6)
        }
        .shadow(color: .black.opacity(0.65), radius: 6)
    }
}

private struct MockCompactRow: View {
    let session: MockSession

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                MockProviderMark(provider: session.provider, activity: session.activity, size: 19)
                if let symbol = session.activity.badgeSymbol {
                    MockActivityBadge(symbol: symbol, size: 14)
                        .offset(x: 2, y: -2)
                }
            }
            .padding(.top, 1)
            HStack(spacing: 6) {
                Text(session.title)
                    .font(.system(size: 12.1, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                if let model = session.model {
                    Text(model)
                        .font(.system(size: 10.45, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.82))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer(minLength: 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct ExpandedCompactNotch: View {
    private let sessions = [
        MockSession(provider: .claude, title: "Polish compact notch", model: "Sonnet 4", activity: .editing),
        MockSession(provider: .codex, title: "Run release checks", model: "GPT-5", activity: .running),
        MockSession(provider: .antigravity, title: "Review UI states", model: "Gemini", activity: .thinking),
        MockSession(provider: .cursor, title: "Finished tests", model: nil, activity: .done),
    ]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                HStack(spacing: 12) {
                    limitGroup(provider: .claude, fiveHour: 82, weekly: 64)
                    limitGroup(provider: .codex, fiveHour: 71, weekly: 48)
                }
                .frame(width: 130, alignment: .leading)

                Color.clear.frame(width: 180)

                HStack(spacing: 10) {
                    Text("4")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.64))
                        .monospacedDigit()
                    Image(systemName: "gearshape").font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 130, alignment: .trailing)
            }
            .frame(height: 34)
            .padding(.horizontal, 5)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                ForEach(sessions) { session in
                    MockCompactRow(session: session)
                }
            }
        }
        .padding(.horizontal, 31)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .frame(width: 480, height: 124, alignment: .top)
        .background(Color.black)
        .clipShape(TopAttachedNotchShape(topRadius: 19, bottomRadius: 24))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.black).frame(height: 1).padding(.horizontal, 19)
        }
        .shadow(color: .black.opacity(0.65), radius: 6)
    }

    private func limitGroup(provider: MockProvider, fiveHour: Int, weekly: Int) -> some View {
        HStack(spacing: 5) {
            MockProviderMark(provider: provider, activity: .thinking, size: 15)
            HStack(spacing: 6) {
                limitText("5H", fiveHour)
                limitText("Wk", weekly)
            }
            .font(.system(size: 9.9, weight: .semibold, design: .rounded))
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private func limitText(_ label: String, _ value: Int) -> Text {
        Text("\(label) ").foregroundColor(.white.opacity(0.64))
            + Text("\(value)%").foregroundColor(Color(hue: Double(value) / 300.0, saturation: 0.78, brightness: 0.96))
    }
}

private struct MockPiPRow: View {
    let provider: MockProvider
    let title: String
    let model: String?
    let status: String
    let statusColor: Color
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: MockIconStore.shared.image(for: provider))
                .resizable()
                .scaledToFit()
                .frame(width: 23, height: 23)
                .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12.2, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.86))
                        .lineLimit(1)
                    if let model {
                        Text(model)
                            .font(.system(size: 9.4, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.82))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer(minLength: 2)
                }
                Text(status)
                    .font(.system(size: 10.7, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(tint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct MockPiPPanel: View {
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Spacer()
                Capsule()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: 28, height: 3)
                Spacer()
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                    Image(systemName: "chevron.up")
                }
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.48))
            }
            .frame(height: 12)

            MockPiPRow(
                provider: .claude,
                title: "Refactor authentication middleware",
                model: "Fable",
                status: "Done",
                statusColor: Color(red: 0.18, green: 0.70, blue: 0.39),
                tint: Color(red: 0.82, green: 0.91, blue: 0.84).opacity(0.78)
            )
            MockPiPRow(
                provider: .codex,
                title: "Add retry tests for API client",
                model: "Sol",
                status: "Needs input",
                statusColor: Color.black.opacity(0.82),
                tint: Color(red: 0.91, green: 0.83, blue: 0.70).opacity(0.78)
            )
            MockPiPRow(
                provider: .antigravity,
                title: "Investigate flaky CI build",
                model: "3.5 Flash",
                status: "1m 42s  Thinking...",
                statusColor: Color.black.opacity(0.68),
                tint: Color(red: 0.83, green: 0.84, blue: 0.93).opacity(0.78)
            )

            Text("Claude 5h 82% Wk 64%  \\  Codex 5h 71% Wk 48%")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.72))
                .lineLimit(1)
        }
        .padding(8)
        .frame(width: 364, height: 198)
        .background(Color(white: 0.94))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.8)
        )
    }
}

private struct OverviewMockup: View {

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.055, green: 0.065, blue: 0.09),
                    Color(red: 0.105, green: 0.115, blue: 0.15),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            display
                .frame(width: 1012, height: 610)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

            MockPiPPanel()
                .offset(y: 45)

            VStack(spacing: 5) {
                Text("Two ways to keep watch")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.78))
                Text("Compact notch or floating PiP")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.48))
            }
            .offset(y: 225)
        }
        .frame(width: 1112, height: 680)
    }

    private var display: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black)

            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color(red: 0.84, green: 0.89, blue: 0.98),
                        Color(red: 0.96, green: 0.91, blue: 0.84),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Rectangle()
                    .fill(Color.black)
                    .frame(height: 16)

                ExpandedCompactNotch()
                    .padding(.top, 16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
    }
}

@MainActor
private func render<V: View>(_ view: V, size: CGSize, to url: URL) throws {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let imageData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.90]) else {
        throw NSError(domain: "AgentPiPMockupRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create JPEG data"])
    }
    try imageData.write(to: url, options: .atomic)
}

@MainActor
private func renderReadmeMockups() throws {
    let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let assets = repository.appendingPathComponent("docs/assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    try render(
        MockCanvas(title: "Stay focused. Your agents stay visible.", subtitle: "Compact mode keeps live activity in the macOS notch.") {
            CollapsedCompactNotch()
        },
        size: CGSize(width: 1112, height: 460),
        to: assets.appendingPathComponent("agentpip-compact-collapsed.jpg")
    )

    try render(
        MockCanvas(title: "Every agent, one glance away.", subtitle: "Hover to expand the same compact view into a live session grid.") {
            ExpandedCompactNotch()
        },
        size: CGSize(width: 1112, height: 560),
        to: assets.appendingPathComponent("agentpip-compact-expanded.jpg")
    )

    try render(
        OverviewMockup(),
        size: CGSize(width: 1112, height: 680),
        to: assets.appendingPathComponent("agentpip-overview.jpg")
    )

    print(assets.appendingPathComponent("agentpip-compact-collapsed.jpg").path)
    print(assets.appendingPathComponent("agentpip-compact-expanded.jpg").path)
    print(assets.appendingPathComponent("agentpip-overview.jpg").path)
}

try await MainActor.run {
    try renderReadmeMockups()
}
