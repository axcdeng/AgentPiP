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

    func testClaudeResponsePreservesOriginalQuestionsWhenAddingAnswers() throws {
        let questions: [[String: Any]] = [
            ["header": "Timing", "question": "How timely?", "multiSelect": false,
             "options": [["label": "Default 24h", "description": "Use Stripe expiry"]]],
            ["header": "Noise", "question": "Which sessions?", "multiSelect": false,
             "options": [["label": "All of them", "description": "Every session"]]],
            ["header": "Channel", "question": "Where should alerts go?", "multiSelect": false,
             "options": [["label": "Same channel", "description": "Reuse webhook"]]]
        ]
        let payload: [String: Any] = [
            "source": "claude",
            "session_id": "claude-multi-question",
            "tool_input": ["questions": questions]
        ]
        let request = try XCTUnwrap(QuestionBridgeServer.parse(payload))
        let responseData = try XCTUnwrap(QuestionBridgeServer.responseData(for: request, answers: [
            "How timely?": "Default 24h",
            "Which sessions?": "All of them",
            "Where should alerts go?": "Same channel"
        ]))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookOutput = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookOutput["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        let preservedQuestions = try XCTUnwrap(updatedInput["questions"] as? [[String: Any]])
        let answers = try XCTUnwrap(updatedInput["answers"] as? [String: String])

        XCTAssertEqual(preservedQuestions.count, 3)
        XCTAssertEqual(preservedQuestions[0]["header"] as? String, "Timing")
        XCTAssertEqual(answers["Which sessions?"], "All of them")
        XCTAssertNil(answers["Noise"])
    }

    func testClaudeTranscriptTracksQuestionUntilToolResultArrives() throws {
        let toolUseID = "toolu_question_1"
        let question = "How far should the switch to percentage go?"
        let pending = Data("""
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"\(toolUseID)","name":"AskUserQuestion","input":{"questions":[{"header":"P/L display","question":"\(question)","options":[]}]}}]}}
        """.utf8)
        let resolved = pending + Data("""

        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"\(toolUseID)","content":"The user did not answer the questions."}]}}
        """.utf8)

        XCTAssertEqual(
            QuestionBridgeServer.latestQuestionToolUseID(pending, prompts: [question]),
            toolUseID
        )
        XCTAssertFalse(QuestionBridgeServer.transcriptContainsResult(pending, toolUseID: toolUseID))
        XCTAssertTrue(QuestionBridgeServer.transcriptContainsResult(resolved, toolUseID: toolUseID))
    }
}
