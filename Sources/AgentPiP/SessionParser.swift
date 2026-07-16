import Foundation

struct ParsedEvent: Sendable {
    var id: String?
    var title: String?
    var projectPath: String?
    var model: String?
    var date: Date?
    var status: SessionStatus?
    var activity: SessionActivity?
    var child: ChildAgent?
    var isUserMessage = false
    var isSubagent = false
    var hasExplicitTitle = false
    var openTargetID: String?
}

protocol ProviderEventParsing: Sendable {
    var provider: AgentProvider { get }
    func parse(line: Data) -> ParsedEvent?
}

struct FlexibleEventParser: ProviderEventParsing {
    let provider: AgentProvider

    func parse(line: Data) -> ParsedEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let payload = dictionary(object["payload"]) ?? object
        let message = dictionary(payload["message"])
        let type = strings([object["type"], payload["type"], payload["subtype"], message?["type"]]).joined(separator: " ").lowercased()
        let role = strings([payload["role"], message?["role"]]).joined(separator: " ").lowercased()
        let content = message?["content"] as? [[String: Any]]
        let nestedToolUse = content?.first(where: { ($0["type"] as? String) == "tool_use" })
        let tool = strings([payload["tool_name"], payload["name"], dictionary(payload["tool"])?["name"], nestedToolUse?["name"]]).joined(separator: " ").lowercased()
        let text = firstString([payload["text"], message?["text"], payload["content"], object["message"]]) ?? ""
        let input = dictionary(payload["input"]) ?? dictionary(dictionary(payload["tool"])?.value(for: "input")) ?? dictionary(nestedToolUse?["input"])
        let rawToolInput = payload["input"] as? String
        let isSidechain = (object["isSidechain"] as? Bool) == true || (payload["isSidechain"] as? Bool) == true
        let timestamp = date(from: firstString([object["timestamp"], payload["timestamp"], object["created_at"]]))

        var event = ParsedEvent(
            id: firstString([object["session_id"], object["sessionId"], payload["session_id"], object["thread_id"]]),
            title: firstString([object["thread_name"], payload["title"]]),
            projectPath: firstString([object["cwd"], payload["cwd"]]),
            model: firstString([message?["model"], payload["model"], object["model"]]),
            date: timestamp,
            status: nil,
            activity: nil,
            child: nil
        )
        event.isSubagent = isSidechain

        let messageText = firstString([message?["content"], payload["content"], payload["text"]]) ?? ""
        if messageText.localizedCaseInsensitiveContains("request interrupted by user") ||
            type.contains("turn_aborted") || type.contains("aborted") ||
            type.contains("cancelled") || type.contains("canceled") || type.contains("interrupted") {
            event.status = .cancelled
            event.activity = SessionActivity.none
            return event
        }

        if type.contains("custom-title") {
            event.title = firstString([object["customTitle"], payload["customTitle"]])
            event.hasExplicitTitle = true
            return event
        }

        let isToolResult = content?.contains(where: { ($0["type"] as? String) == "tool_result" }) == true
        if (role == "user" && !isToolResult) || type.contains("user_message") || type.contains("turn_started") || type.contains("task_started") {
            event.isUserMessage = true
            if let prompt = firstString([message?["content"]]) { event.title = promptTitle(prompt) }
            event.status = .working
            event.activity = .thinking
            return event
        }

        if type.contains("permission") || type.contains("request_user_input") || type.contains("plan_proposed") || type.contains("askuserquestion") || tool.contains("askuserquestion") || type.contains("approval") {
            event.status = .needsInput
            event.activity = .waiting
            return event
        }

        if type.contains("error") || type.contains("failed") {
            event.status = .failed
            return event
        }

        if type.contains("agent") && (type.contains("spawn") || tool.contains("spawn")) {
            let childID = firstString([payload["agent_id"], payload["id"], input?["id"]]) ?? UUID().uuidString
            event.child = ChildAgent(id: childID, isRunning: true)
            event.status = .working
            return event
        }

        if type.contains("agent") && (type.contains("complete") || type.contains("finish")) {
            if let childID = firstString([payload["agent_id"], payload["id"]]) {
                event.child = ChildAgent(id: childID, isRunning: false)
            }
            return event
        }

        if type.contains("turn_completed") || type.contains("final_answer") || type == "result" || type.contains("task_complete") {
            event.status = .done
            event.activity = SessionActivity.none
            return event
        }

        if role == "assistant", firstString([message?["stop_reason"]]) == "end_turn" {
            event.status = .done
            event.activity = SessionActivity.none
            return event
        }

        if type.contains("custom_tool_call_output") || type.contains("function_call_output") || type.contains("tool_result") {
            return event.model != nil ? event : nil
        }

        if let rawToolInput, tool.contains("exec") {
            if rawToolInput.contains("apply_patch"), let path = patchFile(from: rawToolInput) {
                event.status = .working
                event.activity = .editing(shortPath(path))
                return event
            }
            event.status = .working
            event.activity = .running(sanitize(embeddedCommand(from: rawToolInput) ?? commandLabel(from: rawToolInput), fallback: "command"))
            return event
        }

        if tool.contains("write") || tool.contains("edit") || tool.contains("patch") || type.contains("file_change") {
            let path = firstString([input?["path"], input?["file_path"], input?["file"], payload["path"]]) ?? "file"
            event.status = .working
            event.activity = .editing(shortPath(path))
            return event
        }

        if tool.contains("bash") || tool.contains("shell") || tool.contains("exec") || tool.contains("terminal") || type.contains("command") {
            let command = firstString([input?["cmd"], input?["command"], payload["command"]]) ?? text
            event.status = .working
            event.activity = .running(sanitize(command, fallback: "command"))
            return event
        }

        if tool.contains("search") || tool.contains("grep") || tool == "glob" || tool == "find" {
            let query = firstString([input?["query"], input?["pattern"], payload["query"]]) ?? "project"
            event.status = .working
            event.activity = .searching(sanitize(query, fallback: "project"))
            return event
        }

        if type.contains("reasoning") || type.contains("thinking") {
            event.status = .working
            event.activity = .thinking
            return event
        }
        if event.isSubagent || event.model != nil || event.title != nil || event.projectPath != nil { return event }
        return nil
    }

    private func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    private func strings(_ values: [Any?]) -> [String] { values.compactMap { $0 as? String } }
    private func firstString(_ values: [Any?]) -> String? {
        for value in values {
            if let string = value as? String, !string.isEmpty { return string }
            if let array = value as? [[String: Any]], let text = array.compactMap({ $0["text"] as? String }).first { return text }
        }
        return nil
    }
    private func date(from value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
    private func shortPath(_ path: String) -> String {
        let parts = URL(fileURLWithPath: path).pathComponents
        return parts.suffix(2).joined(separator: "/")
    }
    private func sanitize(_ value: String, fallback: String) -> String {
        let single = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !single.isEmpty else { return fallback }
        return single.count > 96 ? String(single.prefix(93)) + "…" : single
    }

    private func patchFile(from value: String) -> String? {
        guard let range = value.range(of: #"\*\*\* (?:Update|Add|Delete) File:\s*([^\\n\n]+)"#, options: .regularExpression) else { return nil }
        let match = String(value[range])
        return match.components(separatedBy: "File:").last?.replacingOccurrences(of: "\\n", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func embeddedCommand(from value: String) -> String? {
        guard let range = value.range(of: #"cmd:\s*\"((?:\\\\.|[^\"])*)\""#, options: .regularExpression) else { return nil }
        let match = String(value[range])
        guard let first = match.firstIndex(of: "\"") else { return nil }
        let encoded = String(match[match.index(after: first)..<match.index(before: match.endIndex)])
        return encoded.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: " ")
    }

    private func commandLabel(from value: String) -> String {
        if value.contains("write_stdin") { return "Waiting for command" }
        if value.contains("web__run") { return "Searching the web" }
        return "Running command"
    }

    private func promptTitle(_ prompt: String) -> String {
        let clean = prompt.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 48 else { return clean }
        return String(clean.prefix(45)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

private extension Dictionary where Key == String, Value == Any {
    func value(for key: String) -> Any? { self[key] }
}
