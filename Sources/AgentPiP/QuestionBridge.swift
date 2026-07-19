import Darwin
import Foundation

@MainActor
final class QuestionBridgeServer: ObservableObject {
    @Published private(set) var requests: [AgentQuestionRequest] = []

    private struct Connection: Sendable {
        let descriptor: Int32
    }

    private let preferences: Preferences
    private let monitor: SessionMonitor
    private let queue = DispatchQueue(label: "local.agentpip.questions", qos: .userInitiated)
    private var listener: Int32 = -1
    private var connections: [UUID: Connection] = [:]
    private let socketURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".agentpip/run/agentpip.sock")

    init(preferences: Preferences, monitor: SessionMonitor) {
        self.preferences = preferences
        self.monitor = monitor
    }

    deinit {
        if listener >= 0 { close(listener) }
    }

    func start() {
        guard listener < 0 else { return }
        let url = socketURL
        queue.async { [weak self] in self?.listen(at: url) }
    }

    func answer(_ request: AgentQuestionRequest, answers: [String: String]) {
        guard let connection = connections.removeValue(forKey: request.id) else { return }
        requests.removeAll { $0.id == request.id }
        if requests.isEmpty, preferences.displayMode == .notch { preferences.notchExpanded = false }
        let response: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow", "updatedInput": ["answers": answers]]
            ]
        ]
        let responseData: Data? = {
            guard var data = try? JSONSerialization.data(withJSONObject: response) else { return nil }
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
        connections[request.id] = Connection(descriptor: descriptor)
        requests.append(request)
        if preferences.displayMode == .notch { preferences.notchExpanded = true }
        else { preferences.collapsed = false }
        monitor.showForQuestion()
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
        guard let rawQuestions = input?["questions"] as? [[String: Any]] else { return nil }
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
        return AgentQuestionRequest(id: UUID(), provider: provider, sessionID: sessionID, questions: questions)
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
