import XCTest
@testable import AgentPiP

final class SessionParserTests: XCTestCase {
    let codex = FlexibleEventParser(provider: .codex)
    let claude = FlexibleEventParser(provider: .claude)

    func testUserMessageStartsWork() throws {
        let event = codex.parse(line: Data(#"{"type":"user_message","thread_id":"abc","timestamp":"2026-07-12T12:00:00Z"}"#.utf8))
        XCTAssertEqual(event?.status, .working); XCTAssertTrue(event?.isUserMessage == true)
    }

    func testEditShowsShortPath() throws {
        let event = claude.parse(line: Data(#"{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/alex/Project/Sources/App.swift"}}"#.utf8))
        XCTAssertEqual(event?.activity, .editing("Sources/App.swift"))
    }

    func testCommandIsSanitized() throws {
        let event = codex.parse(line: Data(#"{"type":"tool_call","name":"exec_command","input":{"cmd":"npm   test\n-- --run"}}"#.utf8))
        XCTAssertEqual(event?.activity, .running("npm test -- --run"))
    }

    func testQuestionNeedsInput() throws {
        let event = codex.parse(line: Data(#"{"type":"request_user_input"}"#.utf8))
        XCTAssertEqual(event?.status, .needsInput)
    }

    func testPlanNeedsInput() throws {
        let event = claude.parse(line: Data(#"{"type":"plan_proposed"}"#.utf8))
        XCTAssertEqual(event?.status, .needsInput)
    }

    func testFinalIsDone() throws {
        let event = codex.parse(line: Data(#"{"type":"final_answer"}"#.utf8))
        XCTAssertEqual(event?.status, .done)
    }

    func testClaudeEndTurnIsDone() {
        let event = claude.parse(line: Data(#"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn"}}"#.utf8))
        XCTAssertEqual(event?.status, .done)
    }

    func testClaudeCustomTitle() {
        let event = claude.parse(line: Data(#"{"type":"custom-title","customTitle":"Product image backgrounds"}"#.utf8))
        XCTAssertEqual(event?.title, "Product image backgrounds")
    }

    func testToolResultDoesNotStartNewWork() {
        let event = claude.parse(line: Data(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]}}"#.utf8))
        XCTAssertNil(event)
    }

    func testSidechainIsMarkedAsSubagent() {
        let event = claude.parse(line: Data(#"{"type":"assistant","isSidechain":true,"message":{"role":"assistant"}}"#.utf8))
        XCTAssertTrue(event?.isSubagent == true)
    }

    func testClaudeNestedEditTool() {
        let event = claude.parse(line: Data(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/alex/App/Sources/View.swift"}}]}}"#.utf8))
        XCTAssertEqual(event?.activity, .editing("Sources/View.swift"))
    }

    func testClaudeNestedBashTool() {
        let event = claude.parse(line: Data(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}"#.utf8))
        XCTAssertEqual(event?.activity, .running("npm test"))
    }

    func testClaudeAskUserQuestionNeedsInput() {
        let event = claude.parse(line: Data(#"{"type":"assistant","sessionId":"49219a24-e728-44a6-8d4e-14a492ca2a90","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"What would you like to work on?"}]}}]}}"#.utf8))
        XCTAssertEqual(event?.status, .needsInput)
    }

    func testClaudePromptProvidesFallbackTitle() {
        let event = claude.parse(line: Data(#"{"type":"user","message":{"role":"user","content":"Ask me a question using Claude Code"}}"#.utf8))
        XCTAssertEqual(event?.title, "Ask me a question using Claude Code")
        XCTAssertFalse(event?.hasExplicitTitle == true)
    }

    func testCodexCustomExecExtractsCommand() {
        let event = codex.parse(line: Data(#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({cmd:\"swift test\",yield_time_ms:1000});"}}"#.utf8))
        XCTAssertEqual(event?.activity, .running("swift test"))
    }

    func testCodexPatchShowsEditedFile() {
        let event = codex.parse(line: Data(#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const patch = \"*** Begin Patch\\n*** Update File: Sources/App.swift\\n@@\"; await tools.apply_patch(patch);"}}"#.utf8))
        XCTAssertEqual(event?.activity, .editing("Sources/App.swift"))
    }

    func testCodexTurnContextExtractsSolModel() {
        let event = codex.parse(line: Data(#"{"type":"turn_context","model":"gpt-5.6-sol"}"#.utf8))
        XCTAssertEqual(event?.model, "gpt-5.6-sol")
    }

    func testCodexToolOutputDoesNotReplaceActivity() {
        let event = codex.parse(line: Data(#"{"type":"response_item","payload":{"type":"custom_tool_call_output","output":"done"}}"#.utf8))
        XCTAssertNil(event)
    }

    func testModelDisplayNames() {
        var session = AgentSession(id: "1", provider: .codex, title: "Test", projectPath: "/tmp", sourceKind: "codex", sourceApp: "ChatGPT", model: "gpt-5.6-sol", startedAt: .now, workingSince: .now, lastActivityAt: .now, status: .working, activity: .thinking, childAgents: [], canOpenExactThread: false, eventPath: "/tmp/test")
        XCTAssertEqual(session.modelDisplayName, "Sol")
        session.model = "claude-opus-4-8"
        XCTAssertEqual(session.modelDisplayName, "Opus")
        session.model = "claude-fable-5"
        XCTAssertEqual(session.modelDisplayName, "Fable")
        session.model = "gpt-5.6-terra"
        XCTAssertEqual(session.modelDisplayName, "Terra")
        session.model = "gpt-5.6-luna"
        XCTAssertEqual(session.modelDisplayName, "Luna")
        session.model = "claude-sonnet-4-6"
        XCTAssertEqual(session.modelDisplayName, "Sonnet")
        session.model = "claude-sonnet-5"
        XCTAssertEqual(session.modelDisplayName, "Sonnet")
    }

    func testMalformedEventIsIgnored() { XCTAssertNil(codex.parse(line: Data("nope".utf8))) }

    func testElapsedFormatting() {
        let now = Date(timeIntervalSince1970: 4_000)
        XCTAssertEqual(TimeText.elapsed(since: Date(timeIntervalSince1970: 3_935), now: now), "1m 5s")
        XCTAssertEqual(TimeText.elapsed(since: Date(timeIntervalSince1970: 300), now: now), "1h 1m")
    }

    func testCodexLimitParsingUsesRemainingPercentAndAvailableWindows() {
        let data = Data(#"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":19.0,"window_minutes":10080},"secondary":{"used_percent":42.0,"window_minutes":300}}}}"#.utf8)
        XCTAssertEqual(UsageMonitor.parseCodexLimits(line: data), ProviderLimits(fiveHourRemaining: 58, weeklyRemaining: 81))
    }

    func testClaudeLimitParsingHidesMissingWindow() {
        let data = Data(#"{"five_hour":{"utilization":27.0},"seven_day":null}"#.utf8)
        XCTAssertEqual(UsageMonitor.parseClaudeLimits(data: data), ProviderLimits(fiveHourRemaining: 73, weeklyRemaining: nil))
    }

    func testClaudeSessionKeyNormalization() {
        XCTAssertEqual(UsageMonitor.normalizedSessionKey("sessionKey=sk-ant-test-value-123456789; other=x"), "sk-ant-test-value-123456789")
        XCTAssertEqual(UsageMonitor.normalizedSessionKey("  sk-ant-test-value-123456789  "), "sk-ant-test-value-123456789")
        XCTAssertNil(UsageMonitor.normalizedSessionKey("not-a-session-key"))
    }

}
