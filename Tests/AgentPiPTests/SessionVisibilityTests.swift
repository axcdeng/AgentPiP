import XCTest
@testable import AgentPiP

final class SessionVisibilityTests: XCTestCase {
    func testTerminalSessionsAreTemporarilyHiddenWithThreeRunningAgents() {
        let sessions = [
            session("working-1", status: .working),
            session("done", status: .done),
            session("working-2", status: .working),
            session("failed", status: .failed),
            session("waiting", status: .waitingForSubagents),
            session("needs-input", status: .needsInput)
        ]

        XCTAssertEqual(
            SessionMonitor.sessionsForDisplay(sessions).map(\.id),
            ["working-1", "working-2", "waiting", "needs-input"]
        )
    }

    func testTerminalSessionsReturnBelowThreeRunningAgents() {
        let sessions = [
            session("working-1", status: .working),
            session("done", status: .done),
            session("working-2", status: .working),
            session("cancelled", status: .cancelled)
        ]

        XCTAssertEqual(
            SessionMonitor.sessionsForDisplay(sessions).map(\.id),
            ["working-1", "done", "working-2", "cancelled"]
        )
    }

    func testManuallyHiddenRunningAgentDoesNotTriggerSuppression() {
        let sessions = [
            session("working-1", status: .working),
            session("working-2", status: .working),
            session("working-hidden", status: .working),
            session("done", status: .done)
        ]

        XCTAssertEqual(
            SessionMonitor.sessionsForDisplay(sessions, hiddenIDs: ["working-hidden"]).map(\.id),
            ["working-1", "working-2", "done"]
        )
    }

    private func session(_ id: String, status: SessionStatus) -> AgentSession {
        AgentSession(
            id: id,
            provider: .codex,
            title: id,
            projectPath: "/tmp",
            sourceKind: "codex",
            sourceApp: "ChatGPT",
            model: nil,
            startedAt: .now,
            workingSince: .now,
            lastActivityAt: .now,
            status: status,
            activity: .none,
            childAgents: [],
            canOpenExactThread: false,
            eventPath: "/tmp/\(id)"
        )
    }
}
