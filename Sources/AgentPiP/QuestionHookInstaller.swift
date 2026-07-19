import Foundation

enum QuestionHookInstaller {
    static func install() {
        let fm = FileManager.default
        guard let bundled = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/AgentPiPHook") as URL?,
              fm.isExecutableFile(atPath: bundled.path) else { return }

        let home = fm.homeDirectoryForCurrentUser
        let installed = home.appending(path: ".agentpip/bin/agentpip-hook")
        do {
            try fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? Data(contentsOf: installed)) != (try? Data(contentsOf: bundled)) {
                if fm.fileExists(atPath: installed.path) { try fm.removeItem(at: installed) }
                try fm.copyItem(at: bundled, to: installed)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
            }
            let quoted = shellQuote(installed.path)
            try mergeHook(
                at: home.appending(path: ".claude/settings.json"),
                command: "\(quoted) --source claude",
                timeout: 86_400
            )
            try mergeHook(
                at: home.appending(path: ".codex/hooks.json"),
                command: "\(quoted) --source codex",
                timeout: 7_200
            )
        } catch {
            // Monitoring still works without interactive hooks. Diagnostics can
            // surface installation state in a future settings pass.
        }
    }

    private static func mergeHook(at url: URL, command: String, timeout: Int) throws {
        let fm = FileManager.default
        let root: [String: Any]
        if let data = try? Data(contentsOf: url),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = value
        } else {
            root = [:]
        }
        var updatedRoot = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var entries = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        var found = false
        for entryIndex in entries.indices {
            guard var commands = entries[entryIndex]["hooks"] as? [[String: Any]] else { continue }
            var entryHasAgentPiP = false
            for commandIndex in commands.indices where (commands[commandIndex]["command"] as? String)?.contains(".agentpip/bin/agentpip-hook") == true {
                commands[commandIndex]["command"] = command
                commands[commandIndex]["timeout"] = timeout
                commands[commandIndex]["type"] = "command"
                entryHasAgentPiP = true
                found = true
            }
            entries[entryIndex]["hooks"] = commands
            if entryHasAgentPiP { entries[entryIndex].removeValue(forKey: "matcher") }
        }
        if !found {
            entries.append([
                "hooks": [["type": "command", "command": command, "timeout": timeout]]
            ])
        }
        hooks["PermissionRequest"] = entries
        updatedRoot["hooks"] = hooks
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: updatedRoot, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
