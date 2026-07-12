import Foundation

enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case codex, claude, antigravity, opencode, cursor

    var displayName: String {
        switch self {
        case .codex: "ChatGPT"
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        case .opencode: "OpenCode"
        case .cursor: "Cursor"
        }
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .codex: ["com.openai.codex", "com.openai.chat"]
        case .claude: ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .antigravity: ["com.google.antigravity"]
        case .opencode: ["ai.opencode.desktop", "com.opencode.desktop"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        }
    }

    var sourceApp: String { displayName }
}

enum SessionStatus: String, Codable, Sendable {
    case working, needsInput, waitingForSubagents, done, failed, stale
}

enum SessionActivity: Codable, Equatable, Sendable {
    case editing(String), running(String), searching(String), thinking, waiting, none

    var detail: String? {
        switch self {
        case .editing(let path): "Editing \(path)"
        case .running(let command): "Running \(command)"
        case .searching(let text): "Searching \(text)"
        case .thinking: "Thinking…"
        case .waiting: "Waiting…"
        case .none: nil
        }
    }

    var copyValue: String? {
        switch self {
        case .editing(let value), .running(let value), .searching(let value): value
        default: nil
        }
    }
}

struct ChildAgent: Codable, Hashable, Sendable {
    let id: String
    var isRunning: Bool
}

struct AgentSession: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var provider: AgentProvider
    var title: String
    var projectPath: String
    var sourceKind: String
    var sourceApp: String
    var model: String?
    var startedAt: Date
    var workingSince: Date
    var lastActivityAt: Date
    var status: SessionStatus
    var activity: SessionActivity
    var childAgents: [ChildAgent]
    var canOpenExactThread: Bool
    var eventPath: String

    var hasRunningChildren: Bool { childAgents.contains(where: \.isRunning) }
    var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }
    var modelDisplayName: String? {
        guard let model, !model.isEmpty else { return nil }
        let lower = model.lowercased()
        if lower.contains("fable") { return "Fable" }
        if lower.contains("sol") { return "Sol" }
        if lower.contains("terra") { return "Terra" }
        if lower.contains("luna") { return "Luna" }
        if lower.contains("opus") { return "Opus" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("haiku") { return "Haiku" }
        if lower.contains("gpt-5.6") { return "GPT-5.6" }
        if lower.contains("gpt-5.5") { return "GPT-5.5" }
        if lower.contains("gpt-5.4") { return "GPT-5.4" }
        if lower.contains("codex") { return "Codex" }
        return model.split(separator: "/").last.map(String.init)
    }
}

struct ProviderHealth: Identifiable, Equatable, Sendable {
    var id: AgentProvider { provider }
    let provider: AgentProvider
    var rootPath: String
    var watched: Bool
    var sessionCount: Int
    var lastError: String?
}

struct ProviderRoot: Sendable {
    let provider: AgentProvider
    let url: URL
    let kind: String
}

enum TimeText {
    static func elapsed(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }
}
