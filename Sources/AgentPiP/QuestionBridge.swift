import Darwin
import Foundation

@MainActor
final class QuestionBridgeServer: ObservableObject {
    @Published private(set) var requests: [AgentQuestionRequest] = []

    private struct Connection: Sendable {
        let descriptor: Int32
        let disconnectSource: DispatchSourceRead
    }

    private let preferences: Preferences
    private let monitor: SessionMonitor
    private let queue = DispatchQueue(label: "local.agentpip.questions", qos: .userInitiated)
    private var listener: Int32 = -1
    private var connections: [UUID: Connection] = [:]
    private var resolutionTask: Task<Void, Never>?
    private let socketURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".agentpip/run/agentpip.sock")

    init(preferences: Preferences, monitor: SessionMonitor) {
        self.preferences = preferences
        self.monitor = monitor
    }

    deinit {
        resolutionTask?.cancel()
        if listener >= 0 { close(listener) }
    }

    func start() {
        guard listener < 0 else { return }
        if resolutionTask == nil {
            resolutionTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self?.discardResolvedClaudeRequests()
                }
            }
        }
        let url = socketURL
        queue.async { [weak self] in self?.listen(at: url) }
    }

    func answer(_ request: AgentQuestionRequest, answers: [String: String]) {
        guard let connection = connections.removeValue(forKey: request.id) else { return }
        connection.disconnectSource.cancel()
        requests.removeAll { $0.id == request.id }
        if requests.isEmpty, preferences.displayMode == .notch { preferences.notchExpanded = false }
        let responseData: Data? = {
            guard var data = Self.responseData(for: request, answers: answers) else { return nil }
            data.append(0x0A)
            return data
        }()
        DispatchQueue.global(qos: .userInitiated).async {
            if let data = responseData {
                _ = data.withUnsafeBytes { write(connection.descriptor, $0.baseAddress, data.count) }
            }
            close(connection.descriptor)
        }
    }

    private nonisolated func listen(at url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        unlink(url.path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0, var address = Self.unixAddress(url.path) else { return }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 8) == 0 else { close(descriptor); return }
        chmod(url.path, S_IRUSR | S_IWUSR)
        Task { @MainActor [weak self] in self?.listener = descriptor }
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { break }
            Self.readRequest(from: client) { [weak self] request in
                guard let self else { close(client); return }
                Task { @MainActor in self.receive(request, descriptor: client) }
            }
        }
    }

    private func receive(_ request: AgentQuestionRequest?, descriptor: Int32) {
        guard let request else { close(descriptor); return }
        let disconnectSource = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        disconnectSource.setEventHandler { [weak self] in
            var byte: UInt8 = 0
            let count = read(descriptor, &byte, 1)
            guard count <= 0 else { return }
            Task { @MainActor [weak self] in
                self?.discardDisconnectedRequest(id: request.id, descriptor: descriptor)
            }
        }
        connections[request.id] = Connection(descriptor: descriptor, disconnectSource: disconnectSource)
        disconnectSource.resume()
        requests.append(request)
        if preferences.displayMode == .notch { preferences.notchExpanded = true }
        else { preferences.collapsed = false }
        monitor.showForQuestion()
    }

    private func discardDisconnectedRequest(id: UUID, descriptor: Int32) {
        guard let connection = connections[id], connection.descriptor == descriptor else { return }
        connections.removeValue(forKey: id)
        connection.disconnectSource.cancel()
        close(connection.descriptor)
        requests.removeAll { $0.id == id }
        if requests.isEmpty, preferences.displayMode == .notch { preferences.notchExpanded = false }
    }

    private func discardResolvedClaudeRequests() {
        let resolvedIDs = requests.compactMap { request -> UUID? in
            guard request.provider == .claude,
                  let transcriptPath = request.transcriptPath,
                  let toolUseID = request.toolUseID,
                  let tail = Self.transcriptTail(at: transcriptPath),
                  Self.transcriptContainsResult(tail, toolUseID: toolUseID) else { return nil }
            return request.id
        }
        guard !resolvedIDs.isEmpty else { return }

        for id in resolvedIDs {
            if let connection = connections.removeValue(forKey: id) {
                connection.disconnectSource.cancel()
                close(connection.descriptor)
            }
        }
        let resolved = Set(resolvedIDs)
        requests.removeAll { resolved.contains($0.id) }
        if requests.isEmpty, preferences.displayMode == .notch { preferences.notchExpanded = false }
    }

    private nonisolated static func readRequest(from descriptor: Int32, completion: @escaping @Sendable (AgentQuestionRequest?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while data.count < 1_048_576 {
                let count = read(descriptor, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
                if data.contains(0x0A) { break }
            }
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            completion(payload.flatMap(parse))
        }
    }

    nonisolated static func parse(_ payload: [String: Any]) -> AgentQuestionRequest? {
        let source = (payload["source"] as? String)?.lowercased()
        let provider: AgentProvider = source == "claude" ? .claude : .codex
        let input = (payload["tool_input"] as? [String: Any]) ?? (payload["toolInput"] as? [String: Any])
        guard let input,
              let originalToolInput = try? JSONSerialization.data(withJSONObject: input),
              let rawQuestions = input["questions"] as? [[String: Any]] else { return nil }
        let questions = rawQuestions.compactMap { raw -> AgentQuestion? in
            guard let prompt = raw["question"] as? String, !prompt.isEmpty else { return nil }
            let header = (raw["header"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Question"
            let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentQuestionOption? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                return AgentQuestionOption(label: label, description: option["description"] as? String)
            }
            return AgentQuestion(
                header: header,
                prompt: prompt,
                options: options,
                allowsMultiple: (raw["multiSelect"] as? Bool) == true || (raw["multiple"] as? Bool) == true,
                allowsOther: true
            )
        }
        guard !questions.isEmpty else { return nil }
        let sessionID = (payload["session_id"] as? String) ?? (payload["thread_id"] as? String) ?? UUID().uuidString
        let transcriptPath = (payload["transcript_path"] as? String) ?? (payload["transcriptPath"] as? String)
        let toolUseID = (payload["tool_use_id"] as? String)
            ?? (payload["toolUseID"] as? String)
            ?? transcriptPath.flatMap { path in
                transcriptTail(at: path).flatMap {
                    latestQuestionToolUseID($0, prompts: questions.map(\.prompt))
                }
            }
        return AgentQuestionRequest(
            id: UUID(),
            provider: provider,
            sessionID: sessionID,
            questions: questions,
            originalToolInput: originalToolInput,
            transcriptPath: transcriptPath,
            toolUseID: toolUseID
        )
    }

    nonisolated static func responseData(for request: AgentQuestionRequest, answers: [String: String]) -> Data? {
        guard var updatedInput = try? JSONSerialization.jsonObject(with: request.originalToolInput) as? [String: Any] else {
            return nil
        }
        updatedInput["answers"] = answers
        let response: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow", "updatedInput": updatedInput]
            ]
        ]
        return try? JSONSerialization.data(withJSONObject: response)
    }

    nonisolated static func latestQuestionToolUseID(_ transcript: Data, prompts: [String]) -> String? {
        let expected = Set(prompts)
        guard !expected.isEmpty else { return nil }
        var latest: String?
        for line in transcript.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for item in content where (item["type"] as? String) == "tool_use" {
                guard ((item["name"] as? String)?.lowercased() ?? "").contains("askuserquestion"),
                      let input = item["input"] as? [String: Any],
                      let rawQuestions = input["questions"] as? [[String: Any]],
                      Set(rawQuestions.compactMap { $0["question"] as? String }) == expected,
                      let id = item["id"] as? String else { continue }
                latest = id
            }
        }
        return latest
    }

    nonisolated static func transcriptContainsResult(_ transcript: Data, toolUseID: String) -> Bool {
        for line in transcript.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            if content.contains(where: {
                ($0["type"] as? String) == "tool_result" && ($0["tool_use_id"] as? String) == toolUseID
            }) { return true }
        }
        return false
    }

    private nonisolated static func transcriptTail(at path: String, maximumBytes: UInt64 = 1_048_576) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > maximumBytes ? size - maximumBytes : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }

    private nonisolated static func unixAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: bytes)
        }
        return address
    }
}
