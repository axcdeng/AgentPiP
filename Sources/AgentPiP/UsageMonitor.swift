import Foundation
import Security

struct ProviderLimits: Equatable, Sendable {
    var fiveHourRemaining: Int?
    var weeklyRemaining: Int?

    var isEmpty: Bool { fiveHourRemaining == nil && weeklyRemaining == nil }
}

@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var claude = ProviderLimits()
    @Published private(set) var codex = ProviderLimits()
    @Published private(set) var hasClaudeCookie = false
    @Published private(set) var claudeCookieStatus: String?

    private var timer: Timer?
    private var claudeSessionKey: String?
    nonisolated private static let keychainService = "com.agentpip.claude-web-session"
    nonisolated private static let keychainAccount = "sessionKey"

    func start() {
        claudeSessionKey = Self.readClaudeSessionKey()
        hasClaudeCookie = claudeSessionKey != nil
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func saveClaudeCookie(_ input: String) -> Bool {
        guard let key = Self.normalizedSessionKey(input), Self.writeClaudeSessionKey(key) else {
            claudeCookieStatus = "Could not save this session cookie."
            return false
        }
        claudeSessionKey = key
        hasClaudeCookie = true
        claudeCookieStatus = "Saved securely in macOS Keychain."
        refresh()
        return true
    }

    func removeClaudeCookie() {
        Self.deleteClaudeSessionKey()
        claudeSessionKey = nil
        hasClaudeCookie = false
        claude = ProviderLimits()
        claudeCookieStatus = "Removed from macOS Keychain."
    }

    private func refresh() {
        Task {
            async let codexValue = Task.detached { Self.loadCodexLimits() }.value
            let sessionKey = claudeSessionKey
            async let claudeValue = Self.loadClaudeLimits(sessionKey: sessionKey)
            let (newCodex, newClaude) = await (codexValue, claudeValue)
            if let newCodex { codex = newCodex }
            if let newClaude {
                claude = newClaude
                claudeCookieStatus = nil
            } else if sessionKey != nil {
                claude = ProviderLimits()
                claudeCookieStatus = "Claude could not verify this cookie. It may have expired."
            }
        }
    }

    nonisolated static func parseCodexLimits(line: Data) -> ProviderLimits? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let rateLimits = payload["rate_limits"] as? [String: Any] else { return nil }
        var result = ProviderLimits()
        for key in ["primary", "secondary"] {
            guard let window = rateLimits[key] as? [String: Any],
                  let minutes = window["window_minutes"] as? Double,
                  let used = window["used_percent"] as? Double else { continue }
            let remaining = max(0, min(100, Int((100 - used).rounded())))
            if minutes >= 6_000 { result.weeklyRemaining = remaining }
            else if minutes >= 240 && minutes <= 360 { result.fiveHourRemaining = remaining }
        }
        return result.isEmpty ? nil : result
    }

    nonisolated static func parseClaudeLimits(data: Data) -> ProviderLimits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func remaining(_ key: String) -> Int? {
            guard let window = root[key] as? [String: Any], let used = window["utilization"] as? Double else { return nil }
            return max(0, min(100, Int((100 - used).rounded())))
        }
        let result = ProviderLimits(fiveHourRemaining: remaining("five_hour"), weeklyRemaining: remaining("seven_day"))
        return result.isEmpty ? nil : result
    }

    nonisolated private static func loadCodexLimits() -> ProviderLimits? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }
        for (url, _) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(12) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
            guard let data = try? handle.readToEnd() else { continue }
            for line in data.split(separator: 0x0A).reversed() {
                if let limits = parseCodexLimits(line: Data(line)) { return limits }
            }
        }
        return nil
    }

    nonisolated static func normalizedSessionKey(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let value: String
        if let range = trimmed.range(of: #"(?:^|;\s*)sessionKey=([^;]+)"#, options: .regularExpression) {
            let match = String(trimmed[range])
            value = match.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
        } else { value = trimmed }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("sk-ant-"), clean.count >= 24, !clean.contains("\n"), !clean.contains("\r") else { return nil }
        return clean
    }

    nonisolated private static func loadClaudeLimits(sessionKey: String?) async -> ProviderLimits? {
        guard let sessionKey else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        guard let organizationsURL = URL(string: "https://claude.ai/api/organizations"),
              let organizationsData = await requestClaudeWeb(url: organizationsURL, sessionKey: sessionKey, session: session),
              let organizations = try? JSONSerialization.jsonObject(with: organizationsData) as? [[String: Any]],
              let organizationID = organizations.compactMap({ $0["uuid"] as? String }).first,
              let usageURL = URL(string: "https://claude.ai/api/organizations/\(organizationID)/usage"),
              let usageData = await requestClaudeWeb(url: usageURL, sessionKey: sessionKey, session: session) else { return nil }
        return parseClaudeLimits(data: usageData)
    }

    nonisolated private static func requestClaudeWeb(url: URL, sessionKey: String, session: URLSession) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentPiP/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    nonisolated private static func readClaudeSessionKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func writeClaudeSessionKey(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    nonisolated private static func deleteClaudeSessionKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
