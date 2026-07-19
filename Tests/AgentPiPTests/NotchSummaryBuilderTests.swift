import XCTest
@testable import AgentPiP

final class NotchSummaryBuilderTests: XCTestCase {
    func testDoneAgentsFromSameProviderAreGrouped() {
        let items = NotchSummaryBuilder.items(from: [
            session("done-1", provider: .codex, status: .done),
            session("done-2", provider: .codex, status: .done)
        ])

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.session.provider, .codex)
        XCTAssertEqual(items.first?.session.status, .done)
        XCTAssertEqual(items.first?.count, 2)
    }

    func testDifferentDisplayStatesRemainSeparateGroups() {
        let items = NotchSummaryBuilder.items(from: [
            session("done-1", provider: .codex, status: .done),
            session("done-2", provider: .codex, status: .done),
            session("input-1", provider: .codex, status: .needsInput),
            session("input-2", provider: .codex, status: .needsInput)
        ])

        XCTAssertEqual(items.map(\.count), [2, 2])
        XCTAssertEqual(items.map(\.session.status), [.done, .needsInput])
    }

    func testCancelledAndFailedAgentsShareStoppedGroup() {
        let items = NotchSummaryBuilder.items(from: [
            session("cancelled", provider: .claude, status: .cancelled),
            session("failed", provider: .claude, status: .failed)
        ])

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.count, 2)
    }

    func testRunningAgentsRemainIndividual() {
        let items = NotchSummaryBuilder.items(from: [
            session("working-1", provider: .codex, status: .working),
            session("working-2", provider: .codex, status: .working)
        ])

        XCTAssertEqual(items.map(\.count), [1, 1])
        XCTAssertEqual(items.map(\.session.id), ["working-1", "working-2"])
    }

    func testGroupingHappensBeforeFourIconLimit() {
        let items = NotchSummaryBuilder.items(from: [
            session("working-1", provider: .codex, status: .working),
            session("working-2", provider: .claude, status: .working),
            session("done-1", provider: .codex, status: .done),
            session("done-2", provider: .codex, status: .done),
            session("stopped", provider: .claude, status: .cancelled)
        ])

        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items.contains { $0.session.status == .done && $0.count == 2 })
    }

    private func session(_ id: String, provider: AgentProvider, status: SessionStatus) -> AgentSession {
        AgentSession(
            id: id,
            provider: provider,
            title: id,
            projectPath: "/tmp",
            sourceKind: provider.rawValue,
            sourceApp: provider.displayName,
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
