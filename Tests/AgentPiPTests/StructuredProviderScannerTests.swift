import Foundation
import SQLite3
import XCTest
@testable import AgentPiP

final class StructuredProviderScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCursorComposerSnapshot() throws {
        let workspace = root.appending(path: "Project")
        let storage = root.appending(path: "User/workspaceStorage/abc")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try Data(#"{"folder":"file:///tmp/TestProject"}"#.utf8).write(to: storage.appending(path: "workspace.json"))
        let updated = Int(Date().timeIntervalSince1970 * 1000)
        let value = #"{"allComposers":[{"composerId":"cursor-1","name":"Fix tests","createdAt":\#(updated),"hasBlockingPendingActions":true}]}"#
        try makeDatabase(storage.appending(path: "state.vscdb"), key: "composer.composerData", value: value)

        let result = StructuredProviderScanner().scan(root: .init(provider: .cursor, url: root, kind: "sqlite"))
        XCTAssertEqual(result.0.first?.id, "cursor-1")
        XCTAssertEqual(result.0.first?.status, .needsInput)
        XCTAssertEqual(result.0.first?.projectPath, "/tmp/TestProject")
    }

    func testAntigravityBase64Snapshot() throws {
        let storage = root.appending(path: "User/globalStorage")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let payload = Data("agent 12345678-1234-1234-1234-123456789abc /tmp/MyProject".utf8).base64EncodedString()
        try makeDatabase(storage.appending(path: "state.vscdb"), key: "jetskiStateSync.agentManagerInitState", value: payload)

        let result = StructuredProviderScanner().scan(root: .init(provider: .antigravity, url: root, kind: "sqlite"))
        XCTAssertEqual(result.0.first?.provider, .antigravity)
        XCTAssertEqual(result.0.first?.id, "12345678-1234-1234-1234-123456789abc")
    }

    func testOpenCodeSessionAndAuthExclusion() throws {
        let storage = root.appending(path: "project/demo/storage")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try Data(#"{"id":"session-1","title":"Build dashboard","cwd":"/tmp/Demo","status":"permission"}"#.utf8)
            .write(to: storage.appending(path: "session.json"))
        try Data(#"{"id":"secret","title":"Must not appear"}"#.utf8).write(to: root.appending(path: "auth.json"))

        let result = StructuredProviderScanner().scan(root: .init(provider: .opencode, url: root, kind: "structured"))
        XCTAssertEqual(result.0.count, 1)
        XCTAssertEqual(result.0.first?.id, "session-1")
        XCTAssertEqual(result.0.first?.status, .needsInput)
    }

    private func makeDatabase(_ url: URL, key: String, value: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE, value BLOB)", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO ItemTable(key,value) VALUES(?,?)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
}
