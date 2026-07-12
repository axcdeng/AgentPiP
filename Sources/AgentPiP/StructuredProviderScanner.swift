import Foundation
import SQLite3

struct ProviderSnapshot: Sendable {
    var id: String
    var provider: AgentProvider
    var title: String
    var projectPath: String
    var model: String?
    var date: Date
    var status: SessionStatus
    var activity: SessionActivity
    var eventPath: String
}

/// Read-only adapters for providers that persist snapshots instead of JSONL streams.
final class StructuredProviderScanner: @unchecked Sendable {
    private let fm = FileManager.default

    func scan(root: ProviderRoot) -> ([ProviderSnapshot], String?) {
        do {
            switch root.provider {
            case .cursor: return (try scanCursor(root.url), nil)
            case .antigravity: return (try scanAntigravity(root.url), nil)
            case .opencode: return (try scanOpenCode(root.url), nil)
            default: return ([], nil)
            }
        } catch { return ([], error.localizedDescription) }
    }

    private func scanCursor(_ root: URL) throws -> [ProviderSnapshot] {
        let storage = root.appending(path: "User/workspaceStorage")
        let databases = recentFiles(in: storage, named: "state.vscdb", limit: 80)
        var result: [ProviderSnapshot] = []
        for database in databases {
            guard let value = try SQLiteReadOnly.value(database: database, table: "ItemTable", key: "composer.composerData"),
                  let data = value.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let composers = object["allComposers"] as? [[String: Any]] else { continue }
            let workspace = workspacePath(for: database.deletingLastPathComponent())
            for composer in composers where composer["isArchived"] as? Bool != true && composer["isDraft"] as? Bool != true {
                guard let id = string(composer["composerId"]) else { continue }
                let updated = date(composer["lastUpdatedAt"]) ?? date(composer["createdAt"]) ?? modified(database)
                guard updated > Date().addingTimeInterval(-1_800) else { continue }
                let needsInput = composer["hasBlockingPendingActions"] as? Bool == true
                let title = string(composer["name"]) ?? string(composer["subtitle"]) ?? "Cursor Agent"
                result.append(.init(id: id, provider: .cursor, title: title, projectPath: workspace,
                    model: string(composer["model"]), date: updated,
                    status: needsInput ? .needsInput : .working,
                    activity: needsInput ? .waiting : .thinking, eventPath: database.path))
            }
        }
        return newestUnique(result)
    }

    private func scanAntigravity(_ root: URL) throws -> [ProviderSnapshot] {
        let database = root.appending(path: "User/globalStorage/state.vscdb")
        guard fm.fileExists(atPath: database.path),
              let encoded = try SQLiteReadOnly.value(database: database, table: "ItemTable", key: "jetskiStateSync.agentManagerInitState") else { return [] }
        let changed = modified(database)
        guard changed > Date().addingTimeInterval(-1_800) else { return [] }

        // Current Antigravity builds store the manager snapshot as base64 protobuf.
        // Pull only identifiers, paths and short labels from printable fields; unknown
        // schema revisions safely degrade to one generic active-agent row.
        let decoded = Data(base64Encoded: encoded) ?? Data(encoded.utf8)
        let fields = printableFields(decoded)
        let ids = fields.flatMap { regexMatches(#"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, in: $0) }
        let paths = fields.flatMap { regexMatches(#"/(?:[^\x00-\x20/]+/)*[^\x00-\x20]+"#, in: $0) }.filter { $0.count < 512 }
        let project = paths.first(where: { fm.fileExists(atPath: $0) }) ?? paths.first ?? NSHomeDirectory()
        let labels = fields.filter { $0.count >= 4 && $0.count <= 80 && !$0.hasPrefix("/") && !$0.contains("http") }
        let title = labels.last(where: { !$0.contains("google") && !$0.contains("proto") }) ?? "Antigravity Agent"
        let id = ids.last ?? "antigravity-" + stableHash(project)
        return [.init(id: id, provider: .antigravity, title: title, projectPath: project, model: nil,
            date: changed, status: .working, activity: .thinking, eventPath: database.path)]
    }

    private func scanOpenCode(_ root: URL) throws -> [ProviderSnapshot] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        var sessions: [String: ProviderSnapshot] = [:]
        for file in recentFiles(in: root, extensions: ["json", "jsonl"], limit: 600) {
            guard !file.path.contains("/auth.json"), !file.path.contains("/log/") else { continue }
            let records = jsonRecords(file)
            for object in records {
                let id = deepString(object, keys: ["sessionID", "sessionId", "session_id", "id"])
                    ?? file.deletingPathExtension().lastPathComponent
                guard id.count >= 4 else { continue }
                let timestamp = deepDate(object, keys: ["updated", "updatedAt", "time", "createdAt", "created_at"]) ?? modified(file)
                guard timestamp > Date().addingTimeInterval(-1_800) else { continue }
                let type = (deepString(object, keys: ["type", "status", "event"]) ?? "").lowercased()
                let tool = (deepString(object, keys: ["tool", "toolName", "name"]) ?? "").lowercased()
                let status: SessionStatus = type.contains("permission") || type.contains("question") ? .needsInput
                    : type.contains("error") || type.contains("fail") ? .failed
                    : type.contains("complete") || type.contains("finish") || type == "done" ? .done : .working
                let path = deepString(object, keys: ["directory", "cwd", "projectPath", "path"])
                    ?? inferredOpenCodeProject(file, root: root)
                let title = deepString(object, keys: ["title", "name", "summary"]) ?? URL(fileURLWithPath: path).lastPathComponent
                let activity: SessionActivity = status == .needsInput ? .waiting
                    : tool.contains("edit") || tool.contains("write") ? .editing(URL(fileURLWithPath: path).lastPathComponent)
                    : tool.contains("shell") || tool.contains("bash") ? .running(tool)
                    : tool.contains("search") ? .searching(tool) : status == .done ? .none : .thinking
                let snapshot = ProviderSnapshot(id: id, provider: .opencode, title: title, projectPath: path,
                    model: deepString(object, keys: ["modelID", "modelId", "model"]), date: timestamp,
                    status: status, activity: activity, eventPath: file.path)
                if sessions[id] == nil || sessions[id]!.date <= timestamp { sessions[id] = snapshot }
            }
        }
        return Array(sessions.values)
    }

    private func recentFiles(in root: URL, named: String? = nil, extensions: Set<String> = [], limit: Int) -> [URL] {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [(URL, Date)] = []
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]), values.isRegularFile == true else { continue }
            if let named, file.lastPathComponent != named { continue }
            if !extensions.isEmpty && !extensions.contains(file.pathExtension.lowercased()) { continue }
            files.append((file, values.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private func recentFiles(in root: URL, extensions: [String], limit: Int) -> [URL] {
        recentFiles(in: root, extensions: Set(extensions), limit: limit)
    }

    private func workspacePath(for directory: URL) -> String {
        let file = directory.appending(path: "workspace.json")
        guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = object["folder"] as? String else { return directory.path }
        return URL(string: folder)?.path ?? folder
    }

    private func jsonRecords(_ file: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file), data.count < 8_000_000 else { return [] }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return [object] }
        return data.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    private func deepString(_ value: Any, keys: Set<String>) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in keys { if let found = string(dictionary[key]) { return found } }
            for child in dictionary.values { if let found = deepString(child, keys: keys) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = deepString(child, keys: keys) { return found } }
        }
        return nil
    }

    private func deepString(_ value: Any, keys: [String]) -> String? { deepString(value, keys: Set(keys)) }
    private func deepDate(_ value: Any, keys: [String]) -> Date? { deepString(value, keys: keys).flatMap(date) }
    private func string(_ value: Any?) -> String? { if let value = value as? String, !value.isEmpty { return value }; return nil }
    private func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue > 10_000_000_000 ? number.doubleValue / 1000 : number.doubleValue) }
        guard let text = value as? String else { return nil }
        if let number = Double(text) { return date(number as NSNumber) }
        return ISO8601DateFormatter().date(from: text)
    }
    private func modified(_ file: URL) -> Date { (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
    private func inferredOpenCodeProject(_ file: URL, root: URL) -> String {
        let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
        let component = relative.split(separator: "/").first.map(String.init) ?? "OpenCode"
        return root.appending(path: component).path
    }
    private func newestUnique(_ values: [ProviderSnapshot]) -> [ProviderSnapshot] {
        var result: [String: ProviderSnapshot] = [:]
        for value in values where result[value.id] == nil || result[value.id]!.date < value.date { result[value.id] = value }
        return Array(result.values)
    }
    private func printableFields(_ data: Data) -> [String] {
        var values: [String] = [], bytes: [UInt8] = []
        func flush() { if bytes.count >= 4, let value = String(bytes: bytes, encoding: .utf8) { values.append(value) }; bytes.removeAll(keepingCapacity: true) }
        for byte in data { if byte >= 0x20 && byte <= 0x7e { bytes.append(byte) } else { flush() } }; flush()
        return values
    }
    private func stableHash(_ value: String) -> String { String(value.utf8.reduce(UInt64(5381)) { ($0 &* 33) ^ UInt64($1) }, radix: 16) }
    private func regexMatches(_ pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).compactMap { Range($0.range, in: value).map { String(value[$0]) } }
    }
}

private enum SQLiteReadOnly {
    static func value(database: URL, table: String, key: String) throws -> String? {
        var db: OpaquePointer?
        let uri = "file:\(database.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            defer { if db != nil { sqlite3_close(db) } }
            throw NSError(domain: "AgentPiP.SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read \(database.lastPathComponent)"])
        }
        defer { sqlite3_close(db) }
        guard ["ItemTable"].contains(table) else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM \(table) WHERE key = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        return String(data: Data(bytes: bytes, count: count), encoding: .utf8)
    }
}
