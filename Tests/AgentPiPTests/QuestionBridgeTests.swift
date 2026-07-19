import XCTest
@testable import AgentPiP

final class QuestionBridgeTests: XCTestCase {
    func testClaudeQuestionPayloadPreservesOptionsAndOtherAnswer() {
        let payload: [String: Any] = [
            "source": "claude",
            "session_id": "claude-1",
            "tool_input": ["questions": [[
                "header": "Target",
                "question": "Which deployment target?",
                "multiSelect": false,
                "options": [
                    ["label": "Production", "description": "Deploy live"],
                    ["label": "Staging", "description": "Deploy test"]
                ]
            ]]]
        ]
        let request = QuestionBridgeServer.parse(payload)
        XCTAssertEqual(request?.provider, .claude)
        XCTAssertEqual(request?.sessionID, "claude-1")
        XCTAssertEqual(request?.questions.first?.prompt, "Which deployment target?")
        XCTAssertEqual(request?.questions.first?.options.map(\.label), ["Production", "Staging"])
        XCTAssertTrue(request?.questions.first?.allowsOther == true)
    }

    func testCodexQuestionPayloadSupportsMultipleSelection() {
        let payload: [String: Any] = [
            "source": "codex",
            "thread_id": "codex-1",
            "toolInput": ["questions": [[
                "header": "Files",
                "question": "Which files?",
                "multiple": true,
                "options": [["label": "Tests"], ["label": "Sources"]]
            ]]]
        ]
        let request = QuestionBridgeServer.parse(payload)
        XCTAssertEqual(request?.provider, .codex)
        XCTAssertEqual(request?.sessionID, "codex-1")
        XCTAssertTrue(request?.questions.first?.allowsMultiple == true)
    }
}
