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
    case working, needsInput, waitingForSubagents, done, cancelled, failed, stale

    var isActive: Bool {
        self == .working || self == .needsInput || self == .waitingForSubagents
    }
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

struct AgentQuestionOption: Codable, Hashable, Sendable {
    let label: String
    let description: String?
}

struct AgentQuestion: Codable, Hashable, Sendable {
    let header: String
    let prompt: String
    let options: [AgentQuestionOption]
    let allowsMultiple: Bool
    let allowsOther: Bool
}

struct AgentQuestionRequest: Identifiable, Sendable {
    let id: UUID
    let provider: AgentProvider
    let sessionID: String
    let questions: [AgentQuestion]
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
    var openTargetID: String? = nil

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
        if lower.contains("sonnet-4-6") { return "Sonnet 4.6" }
        if lower.contains("sonnet-5") { return "Sonnet 5" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("haiku") { return "Haiku" }
        if lower.contains("gemini-3.5-flash") { return "3.5 Flash" }
        if lower.contains("gemini-3-flash") { return "3 Flash" }
        if lower.contains("gemini-3.1-pro") { return "3.1 Pro" }
        if lower.contains("composer-2.5") || lower.contains("composer 2.5") { return "Composer" }
        if lower.contains("grok-4.5") { return "Grok 4.5" }

        // Popular Chinese and open model IDs used by coding-agent providers.
        if lower.contains("glm-5.2") { return "GLM-5.2" }
        if lower.contains("glm-5.1") { return "GLM-5.1" }
        if lower.contains("glm-5-turbo") { return "GLM-5 Turbo" }
        if lower.contains("glm-5") { return "GLM-5" }
        if lower.contains("glm-4.7-flashx") { return "GLM-4.7 FlashX" }
        if lower.contains("glm-4.7-flash") { return "GLM-4.7 Flash" }
        if lower.contains("glm-4.7") { return "GLM-4.7" }
        if lower.contains("glm-4.6") { return "GLM-4.6" }
        if lower.contains("glm-4.5") { return "GLM-4.5" }

        if lower.contains("kimi-k2.7-code-highspeed") { return "Kimi K2.7 Code Highspeed" }
        if lower.contains("kimi-k2.7-code") { return "Kimi K2.7 Code" }
        if lower.contains("kimi-k2.6") { return "Kimi K2.6" }
        if lower.contains("kimi-k2.5") { return "Kimi K2.5" }
        if lower.contains("kimi-k2") { return "Kimi K2" }
        if lower.contains("moonshot-v1") { return "Kimi" }

        if lower.contains("qwen3.7-plus") { return "Qwen3.7 Plus" }
        if lower.contains("qwen3.6-plus") { return "Qwen3.6 Plus" }
        if lower.contains("qwen3.6-flash") { return "Qwen3.6 Flash" }
        if lower.contains("qwen3.5-plus") { return "Qwen3.5 Plus" }
        if lower.contains("qwen3.5-flash") { return "Qwen3.5 Flash" }
        if lower.contains("qwen3-coder-next") { return "Qwen3 Coder Next" }
        if lower.contains("qwen3-coder-plus") { return "Qwen3 Coder Plus" }
        if lower.contains("qwen3-max") { return "Qwen3 Max" }
        if lower.contains("qwen3.5") { return "Qwen3.5" }
        if lower.contains("qwen3") { return "Qwen3" }
        if lower.contains("qwen2.5-coder") { return "Qwen2.5 Coder" }
        if lower.contains("qwen2.5") { return "Qwen2.5" }
        if lower.contains("qwen") { return "Qwen" }

        if lower.contains("deepseek-v4-pro") { return "DeepSeek V4 Pro" }
        if lower.contains("deepseek-v4-flash") { return "DeepSeek V4 Flash" }
        if lower.contains("deepseek-v3.2") { return "DeepSeek V3.2" }
        if lower.contains("deepseek-r1") { return "DeepSeek R1" }
        if lower.contains("deepseek-reasoner") { return "DeepSeek Reasoner" }
        if lower.contains("deepseek-chat") { return "DeepSeek Chat" }
        if lower.contains("deepseek") { return "DeepSeek" }

        if lower.contains("minimax-m3") { return "MiniMax M3" }
        if lower.contains("minimax-m2.7-highspeed") { return "MiniMax M2.7 Highspeed" }
        if lower.contains("minimax-m2.7") { return "MiniMax M2.7" }
        if lower.contains("minimax-m2.5-highspeed") { return "MiniMax M2.5 Highspeed" }
        if lower.contains("minimax-m2.5") { return "MiniMax M2.5" }
        if lower.contains("minimax-m2.1") { return "MiniMax M2.1" }
        if lower.contains("minimax-m2") { return "MiniMax M2" }

        if lower.contains("doubao-seed-2-0-code") || lower.contains("doubao-seed-2.0-code") { return "Doubao Seed 2.0 Code" }
        if lower.contains("doubao-seed-2-0-pro") || lower.contains("doubao-seed-2.0-pro") { return "Doubao Seed 2.0 Pro" }
        if lower.contains("doubao-seed-2-0-lite") || lower.contains("doubao-seed-2.0-lite") { return "Doubao Seed 2.0 Lite" }
        if lower.contains("doubao-seed-2-0-mini") || lower.contains("doubao-seed-2.0-mini") { return "Doubao Seed 2.0 Mini" }
        if lower.contains("doubao") { return "Doubao" }

        if lower.contains("ernie-5.1") { return "ERNIE 5.1" }
        if lower.contains("ernie-5.0-thinking") { return "ERNIE 5.0 Thinking" }
        if lower.contains("ernie-5.0") { return "ERNIE 5.0" }
        if lower.contains("ernie-x1.1") { return "ERNIE X1.1" }
        if lower.contains("ernie") { return "ERNIE" }
        if lower.contains("hy3") { return "Hunyuan 3" }
        if lower.contains("hunyuan-a13b") { return "Hunyuan A13B" }
        if lower.contains("hunyuan") { return "Hunyuan" }
        if lower.contains("step-3.5-flash") { return "Step 3.5 Flash" }
        if lower.contains("step-") { return "Step" }
        if lower.contains("yi-lightning") { return "Yi Lightning" }
        if lower.contains("yi-large") { return "Yi Large" }
        if lower.contains("baichuan") { return "Baichuan" }
        if lower.contains("internlm") { return "InternLM" }

        if lower.contains("muse-spark-1.1") || lower.contains("muse spark 1.1") { return "Muse Spark 1.1" }
        if lower.contains("muse-spark") || lower.contains("muse spark") { return "Muse Spark" }
        if lower.contains("spark-x1") { return "Spark X1" }
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
