import AppKit
import Foundation

private struct ScanResult: @unchecked Sendable {
    var changes: [(AgentProvider, URL, ParsedEvent)]
    var snapshots: [ProviderSnapshot]
    var counts: [AgentProvider: Int]
    var errors: [AgentProvider: String]
}

private struct ClaudeDesktopMetadata {
    var title: String?
    var model: String?
    var openTargetID: String?
    var isPrimaryDesktopSession: Bool
    var lastActivityAt: Date
}

private final class SessionScanner: @unchecked Sendable {
    private var offsets: [String: UInt64] = [:]
    private var knownModificationDates: [String: Date] = [:]
    private var cachedCodexTitles: [String: String] = [:]
    private var cachedCodexTitlesModificationDate: Date?
    private var cachedClaudeMetadata: [String: ClaudeDesktopMetadata] = [:]
    private var lastClaudeMetadataLoad = Date.distantPast
    let roots: [ProviderRoot]
    private let structured = StructuredProviderScanner()

    init(roots: [ProviderRoot]) { self.roots = roots }

    func scan(changedPaths: Set<String>? = nil) -> ScanResult {
        let fm = FileManager.default
        var changes: [(AgentProvider, URL, ParsedEvent)] = []
        var counts: [AgentProvider: Int] = [:]
        var errors: [AgentProvider: String] = [:]
        let now = Date()

        lazy var codexTitles = loadCodexTitles()
        lazy var claudeMetadata = loadClaudeDesktopMetadata()
        var snapshots: [ProviderSnapshot] = []
        for providerRoot in roots {
            let provider = providerRoot.provider, root = providerRoot.url
            let relevantPaths = changedPaths?.filter { $0.hasPrefix(root.path) }
            if changedPaths != nil, relevantPaths?.isEmpty != false { continue }
            if [.antigravity, .opencode, .cursor].contains(provider) {
                let scanned = structured.scan(root: providerRoot)
                snapshots.append(contentsOf: scanned.0)
                counts[provider, default: 0] += scanned.0.count
                if let error = scanned.1 { errors[provider] = error }
                continue
            }
            let parser = FlexibleEventParser(provider: provider)
            let directFiles = relevantPaths?.compactMap { path -> URL? in
                let url = URL(fileURLWithPath: path)
                return url.pathExtension == "jsonl" ? url : nil
            } ?? []
            let files: [URL]
            if let relevantPaths, !directFiles.isEmpty, directFiles.count == relevantPaths.count {
                files = directFiles
            } else {
                guard let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                var discovered: [URL] = []
                for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                    discovered.append(file)
                    if discovered.count >= 160 { break }
                }
                files = discovered
            }
            for file in files {
                guard file.pathExtension == "jsonl" else { continue }
                if provider == .codex {
                    guard file.path.contains("/.codex/sessions/"), file.lastPathComponent.hasPrefix("rollout-") else { continue }
                    // Codex also writes short-lived internal classifier/helper rollouts
                    // beside real chats. Only user-owned chats are registered in the
                    // session index; waiting for that registration avoids phantom cards
                    // without relying on unstable rollout names or prompt contents.
                    let sessionID = String(file.deletingPathExtension().lastPathComponent.suffix(36))
                    guard codexTitles[sessionID] != nil else { continue }
                } else {
                    guard file.path.contains("/.claude/projects/") else { continue }
                }
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
                let modified = values.contentModificationDate ?? .distantPast
                let isKnown = knownModificationDates[file.path] != nil
                guard modified > now.addingTimeInterval(-1_800) || isKnown else { continue }
                knownModificationDates[file.path] = modified
                let size = UInt64(values.fileSize ?? 0)
                var offset = offsets[file.path] ?? (size > 262_144 ? size - 262_144 : 0)
                if size < offset { offset = 0 }
                guard size > offset, let handle = try? FileHandle(forReadingFrom: file) else { continue }
                do {
                    try handle.seek(toOffset: offset)
                    let data = try handle.readToEnd() ?? Data()
                    offsets[file.path] = size
                    for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).suffix(300) {
                        if var event = parser.parse(line: Data(line)) {
                            if event.isSubagent { continue }
                            if provider == .codex {
                                let sessionID = event.id ?? file.deletingPathExtension().lastPathComponent.components(separatedBy: "-").suffix(5).joined(separator: "-")
                                if let title = codexTitles[sessionID] { event.title = title }
                            } else if let sessionID = event.id, let metadata = claudeMetadata[sessionID] {
                                if let title = metadata.title { event.title = title; event.hasExplicitTitle = true }
                                if event.model == nil { event.model = metadata.model }
                                event.openTargetID = metadata.openTargetID
                            }
                            changes.append((provider, file, event))
                        }
                    }
                    counts[provider, default: 0] += 1
                } catch { errors[provider] = error.localizedDescription }
                try? handle.close()
            }
        }
        return ScanResult(changes: changes, snapshots: snapshots, counts: counts, errors: errors)
    }

    private func loadCodexTitles() -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/session_index.jsonl")
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if modified == cachedCodexTitlesModificationDate { return cachedCodexTitles }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = value["id"] as? String, let title = value["thread_name"] as? String else { continue }
            result[id] = title
        }
        cachedCodexTitles = result
        cachedCodexTitlesModificationDate = modified
        return result
    }

    private func loadClaudeDesktopMetadata() -> [String: ClaudeDesktopMetadata] {
        let now = Date()
        if now.timeIntervalSince(lastClaudeMetadataLoad) < 5 { return cachedClaudeMetadata }
        lastClaudeMetadataLoad = now
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Claude/claude-code-sessions")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            cachedClaudeMetadata = [:]
            return cachedClaudeMetadata
        }
        var result: [String: ClaudeDesktopMetadata] = [:]
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) > Date().addingTimeInterval(-7 * 86_400),
                  let data = try? Data(contentsOf: url),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = value["cliSessionId"] as? String else { continue }
            let bridgeIDs = value["bridgeSessionIds"] as? [String]
            let directID = value["sessionId"] as? String
            let lastActivityAt = Self.dateFromMilliseconds(value["lastActivityAt"])
                ?? values.contentModificationDate ?? .distantPast
            let metadata = ClaudeDesktopMetadata(
                title: value["title"] as? String,
                model: value["model"] as? String,
                openTargetID: directID,
                isPrimaryDesktopSession: bridgeIDs?.isEmpty == false,
                lastActivityAt: lastActivityAt
            )
            if let existing = result[id] {
                let metadataHasTitle = metadata.title?.isEmpty == false
                let existingHasTitle = existing.title?.isEmpty == false
                let metadataIsBetter = (metadata.isPrimaryDesktopSession && !existing.isPrimaryDesktopSession)
                    || (metadata.isPrimaryDesktopSession == existing.isPrimaryDesktopSession
                        && metadataHasTitle && !existingHasTitle)
                    || (metadata.isPrimaryDesktopSession == existing.isPrimaryDesktopSession
                        && metadataHasTitle == existingHasTitle
                        && metadata.lastActivityAt > existing.lastActivityAt)
                if metadataIsBetter { result[id] = metadata }
            } else {
                result[id] = metadata
            }
        }
        cachedClaudeMetadata = result
        return result
    }

    private static func dateFromMilliseconds(_ value: Any?) -> Date? {
        guard let milliseconds = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
    }
}

@MainActor
final class SessionMonitor: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var health: [ProviderHealth] = []
    @Published var panelVisible = false

    private let preferences: Preferences
    private let worker = DispatchQueue(label: "local.agentpip.monitor", qos: .utility)
    private var watchers: [DirectoryWatcher] = []
    private var watchedPaths: Set<String> = []
    private var debounce: DispatchWorkItem?
    private var pendingScanPaths: Set<String> = []
    private var fullScanPending = false
    private var lastNestedWatcherRefresh = Date.distantPast
    private var manuallyHidden = false
    private let roots: [ProviderRoot] = [
        .init(provider: .codex, url: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex"), kind: "jsonl"),
        .init(provider: .claude, url: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude"), kind: "jsonl"),
        .init(provider: .claude, url: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Claude/claude-code-sessions"), kind: "jsonl"),
        .init(provider: .antigravity, url: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Antigravity"), kind: "sqlite"),
        .init(provider: .opencode, url: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share/opencode"), kind: "structured"),
        .init(provider: .cursor, url: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Cursor"), kind: "sqlite")
    ]
    private lazy var scanner = SessionScanner(roots: roots)

    init(preferences: Preferences = .shared) { self.preferences = preferences }

    var visibleSessions: [AgentSession] {
        sessions.filter { !preferences.hiddenIDs.contains($0.id) && !preferences.dismissedIDs.contains($0.id) }
    }

    var hiddenSessions: [AgentSession] { sessions.filter { preferences.hiddenIDs.contains($0.id) } }

    func start() {
        guard watchers.isEmpty else { return }
        var healthByProvider: [AgentProvider: ProviderHealth] = [:]
        for entry in roots {
            let provider = entry.provider, root = entry.url
            var item = ProviderHealth(provider: provider, rootPath: root.path, watched: false, sessionCount: 0, lastError: nil)
            if FileManager.default.fileExists(atPath: root.path) {
                do { try addWatcher(path: root.path); item.watched = true }
                catch { item.lastError = error.localizedDescription }
            } else { item.lastError = "Folder not found" }
            if var existing = healthByProvider[provider] {
                existing.rootPath += "\n" + root.path
                existing.watched = existing.watched || item.watched
                existing.lastError = existing.lastError ?? item.lastError
                healthByProvider[provider] = existing
            } else { healthByProvider[provider] = item }
        }
        health = AgentProvider.allCases.compactMap { healthByProvider[$0] }
        refreshNestedWatchers(force: true)
        scheduleScan(immediate: true)
    }

    func stop() { watchers.forEach { $0.cancel() }; watchers.removeAll(); watchedPaths.removeAll() }

    private func addWatcher(path: String) throws {
        guard !watchedPaths.contains(path), watchers.count < 512 else { return }
        let watcher = DirectoryWatcher(path: path, queue: worker) { [weak self] in
            self?.scheduleScan(changedPath: path)
        }
        try watcher.start(); watchers.append(watcher); watchedPaths.insert(path)
    }

    private func refreshNestedWatchers(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastNestedWatcherRefresh) >= 60 else { return }
        lastNestedWatcherRefresh = now
        let fm = FileManager.default
        let preferred = roots.flatMap { entry in
            let root = entry.url
            return [root, root.appending(path: "sessions"), root.appending(path: "projects"), root.appending(path: "archived_sessions")]
        }.filter { fm.fileExists(atPath: $0.path) }

        var candidates: [(url: URL, modified: Date)] = []
        for base in preferred {
            try? addWatcher(path: base.path)
            guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                      values.isDirectory == true else { continue }
                let modified = values.contentModificationDate ?? .distantPast
                if modified > Date().addingTimeInterval(-30 * 86_400) { candidates.append((url, modified)) }
            }
        }

        // The filesystem enumerator is commonly oldest-first. Sorting prevents
        // the descriptor cap from excluding today's live session directories.
        // Keep most descriptors available for the live JSONL files themselves.
        for candidate in candidates.sorted(by: { $0.modified > $1.modified }).prefix(120) {
            try? addWatcher(path: candidate.url.path)
        }
    }

    nonisolated private func scheduleScan(immediate: Bool = false, changedPath: String? = nil) {
        Task { @MainActor [weak self] in
            guard let self, !self.preferences.paused else { return }
            if let changedPath { self.pendingScanPaths.insert(changedPath) }
            else { self.fullScanPending = true }
            self.debounce?.cancel()
            let scanner = self.scanner
            let scanAll = self.fullScanPending
            let requestedPaths = self.pendingScanPaths
            let work = DispatchWorkItem { @Sendable [weak self, scanner] in
                let result = scanner.scan(changedPaths: scanAll ? nil : requestedPaths)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if scanAll {
                        self.fullScanPending = false
                        self.pendingScanPaths.removeAll()
                    } else {
                        self.pendingScanPaths.subtract(requestedPaths)
                    }
                    self.apply(changes: result.changes, snapshots: result.snapshots, counts: result.counts, errors: result.errors)
                }
            }
            self.debounce = work
            self.worker.asyncAfter(deadline: .now() + (immediate ? 0 : 0.18), execute: work)
        }
    }

    private func apply(changes: [(AgentProvider, URL, ParsedEvent)], snapshots: [ProviderSnapshot], counts: [AgentProvider: Int], errors: [AgentProvider: String]) {
        refreshNestedWatchers()
        // Directory notifications catch file creation, but not reliably every
        // append. Watch each discovered live transcript directly thereafter.
        for file in Set(changes.map { $0.1.path }) { try? addWatcher(path: file) }
        var didReceiveNewWork = false
        for (provider, file, event) in changes {
            let filename = file.deletingPathExtension().lastPathComponent
            let fallbackID = provider == .codex && filename.hasPrefix("rollout-")
                ? String(filename.suffix(36)) : filename
            let id = event.id ?? fallbackID
            let date = event.date ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
            let index = sessions.firstIndex(where: { $0.id == id && $0.provider == provider })
            let isNewSession = index == nil
            var session = index.map { sessions[$0] } ?? AgentSession(
                id: id, provider: provider, title: event.title ?? inferredTitle(file), projectPath: event.projectPath ?? inferredProject(file),
                sourceKind: inferredSourceKind(file, provider), sourceApp: provider.sourceApp, model: event.model, startedAt: date,
                workingSince: date, lastActivityAt: date, status: .working, activity: .thinking, childAgents: [], canOpenExactThread: false, eventPath: file.path
            )
            if let title = event.title, event.hasExplicitTitle || session.title.isEmpty || looksLikeIdentifier(session.title) { session.title = title }
            if let path = event.projectPath { session.projectPath = path }
            if let model = event.model { session.model = model }
            if let openTargetID = event.openTargetID {
                session.openTargetID = openTargetID
                session.canOpenExactThread = true
            }
            if event.isUserMessage {
                session.workingSince = date
                preferences.dismissedIDs.remove(id)
                if isNewSession {
                    if preferences.automaticallyShowNewThreads { preferences.hiddenIDs.remove(id) }
                    else { preferences.hiddenIDs.insert(id) }
                } else if preferences.automaticallyRevealHiddenThreads {
                    preferences.hiddenIDs.remove(id)
                }
                didReceiveNewWork = true
            }
            if let child = event.child {
                if let childIndex = session.childAgents.firstIndex(where: { $0.id == child.id }) { session.childAgents[childIndex] = child }
                else { session.childAgents.append(child) }
            }
            if let status = event.status {
                session.status = status == .done && session.hasRunningChildren ? .waitingForSubagents : status
                if status == .needsInput { didReceiveNewWork = true }
            }
            if let activity = event.activity {
                let isConcrete: Bool
                switch session.activity {
                case .editing, .running, .searching: isConcrete = true
                default: isConcrete = false
                }
                // Streaming reasoning and tool-output records must not erase
                // the most recent user-visible operation.
                if activity != .thinking || !isConcrete || event.isUserMessage { session.activity = activity }
            }
            session.lastActivityAt = max(session.lastActivityAt, date)
            if let index { sessions[index] = session } else { sessions.append(session) }
        }

        for snapshot in snapshots {
            let index = sessions.firstIndex { $0.id == snapshot.id && $0.provider == snapshot.provider }
            var session = index.map { sessions[$0] } ?? AgentSession(
                id: snapshot.id, provider: snapshot.provider, title: snapshot.title, projectPath: snapshot.projectPath,
                sourceKind: snapshot.provider.rawValue, sourceApp: snapshot.provider.sourceApp, model: snapshot.model,
                startedAt: snapshot.date, workingSince: snapshot.date, lastActivityAt: snapshot.date,
                status: snapshot.status, activity: snapshot.activity, childAgents: [], canOpenExactThread: false,
                eventPath: snapshot.eventPath)
            if snapshot.date >= session.lastActivityAt {
                if snapshot.title != snapshot.provider.displayName + " Agent" { session.title = snapshot.title }
                session.projectPath = snapshot.projectPath; session.model = snapshot.model ?? session.model
                session.lastActivityAt = snapshot.date; session.status = snapshot.status; session.activity = snapshot.activity
            }
            if let index { sessions[index] = session } else { sessions.append(session) }
        }

        sessions = sessions.filter { $0.lastActivityAt > Date().addingTimeInterval(-1_800) || $0.status == .needsInput }
        for index in health.indices {
            let provider = health[index].provider
            health[index].sessionCount = sessions.filter { $0.provider == provider }.count
            health[index].lastError = errors[provider]
        }
        if didReceiveNewWork && preferences.alwaysShowPIPOnAgentStart { manuallyHidden = false; panelVisible = true }
        if visibleSessions.isEmpty { panelVisible = false }
    }

    func hidePanel() { manuallyHidden = true; panelVisible = false }
    func showPanel() { manuallyHidden = false; panelVisible = !visibleSessions.isEmpty }
    func showForQuestion() { manuallyHidden = false; panelVisible = true }
    func togglePanel() { panelVisible ? hidePanel() : showPanel() }

    func open(_ session: AgentSession) {
        if session.provider == .codex,
           let url = URL(string: "codex://threads/\(session.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? session.id)") {
            openAndActivate(url)
            return
        }
        if session.provider == .claude {
            _ = activateApplication(for: .claude)
            return
        }
        if [.antigravity, .cursor].contains(session.provider), FileManager.default.fileExists(atPath: session.projectPath) {
            let scheme = session.provider == .antigravity ? "antigravity" : "cursor"
            if let url = URL(string: "\(scheme)://file\(session.projectPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? session.projectPath)") {
                openAndActivate(url); return
            }
        }
        if activateApplication(for: session.provider) { return }
        if session.provider == .opencode, FileManager.default.fileExists(atPath: session.projectPath) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [URL(fileURLWithPath: session.projectPath)],
                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                configuration: configuration
            ) { application, _ in
                Task { @MainActor in self.confirmActivation(of: application) }
            }
        }
    }

    private func openAndActivate(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { application, _ in
            Task { @MainActor in self.confirmActivation(of: application) }
        }
    }

    private func activateApplication(for provider: AgentProvider) -> Bool {
        for bundleID in provider.bundleIdentifiers {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, _ in
                Task { @MainActor in self.confirmActivation(of: application) }
            }
            return true
        }
        return false
    }

    private func confirmActivation(of application: NSRunningApplication?) {
        guard let application else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if !application.isActive {
                application.activate(options: [.activateAllWindows])
            }
        }
    }

    private func inferredTitle(_ file: URL) -> String { file.deletingPathExtension().lastPathComponent }
    private func inferredProject(_ file: URL) -> String { file.deletingLastPathComponent().path }
    private func inferredSourceKind(_ file: URL, _ provider: AgentProvider) -> String {
        if provider == .codex { return file.path.contains("Application Support") ? "desktop" : "codex" }
        if provider == .claude { return file.path.contains("local-agent-mode") ? "desktop" : "claude-code" }
        return provider.rawValue
    }

    private func looksLikeIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{8}-[0-9a-f-]{27}$"#, options: [.regularExpression, .caseInsensitive]) != nil || value.hasPrefix("rollout-")
    }
}
