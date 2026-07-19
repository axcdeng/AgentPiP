import XCTest
@testable import AgentPiP

final class NotchActivityLabelTests: XCTestCase {
    func testThinkingUsesRequestedText() {
        XCTAssertEqual(NotchActivityLabel.text(for: .thinking), "Thinking...")
        XCTAssertEqual(NotchActivityLabel.text(for: .searching("sessions")), "Thinking...")
    }

    func testEditingUsesFilenameAndNineCharacters() {
        XCTAssertEqual(
            NotchActivityLabel.text(for: .editing("/Users/alex/Project/QuestionBridge.swift")),
            "Editing Q..."
        )
    }

    func testRunningUsesNineCharactersAndCollapsesWhitespace() {
        XCTAssertEqual(
            NotchActivityLabel.text(for: .running("swift   test --quiet")),
            "Running s..."
        )
    }

    func testRunningDoesNotRepeatExistingActionPrefix() {
        XCTAssertEqual(
            NotchActivityLabel.text(for: .running("Running command")),
            "Running c..."
        )
    }

    func testEditingDoesNotRepeatExistingActionPrefix() {
        XCTAssertEqual(
            NotchActivityLabel.text(for: .editing("Editing App.swift")),
            "Editing A..."
        )
    }

    func testCompactActivityBadgesOnlyAppearForCommandsAndEdits() {
        XCTAssertEqual(NotchActivityBadgeKind.badge(for: .running("swift test")), .command)
        XCTAssertEqual(NotchActivityBadgeKind.badge(for: .editing("App.swift")), .editing)
        XCTAssertNil(NotchActivityBadgeKind.badge(for: .thinking))
        XCTAssertNil(NotchActivityBadgeKind.badge(for: .searching("tests")))
    }
}
