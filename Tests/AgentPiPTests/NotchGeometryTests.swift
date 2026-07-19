import CoreGraphics
import XCTest
@testable import AgentPiP

final class NotchGeometryTests: XCTestCase {
    func testCollapsedWidthIsExactSumOfHardwareAndWings() {
        XCTAssertEqual(
            NotchGeometry.collapsedWidth(hardwareWidth: 183, leftWingWidth: 196, rightWingWidth: 28),
            407
        )
    }

    func testLeftWingGrowthKeepsRightEdgeFixed() {
        let hardwareWidth: CGFloat = 183
        let rightWingWidth: CGFloat = 28

        func rightEdge(leftWingWidth: CGFloat) -> CGFloat {
            let width = NotchGeometry.collapsedWidth(
                hardwareWidth: hardwareWidth,
                leftWingWidth: leftWingWidth,
                rightWingWidth: rightWingWidth
            )
            let offset = NotchGeometry.horizontalOffset(
                leftWingWidth: leftWingWidth,
                rightWingWidth: rightWingWidth
            )
            return offset + width / 2
        }

        XCTAssertEqual(rightEdge(leftWingWidth: 120), rightEdge(leftWingWidth: 196))
        XCTAssertEqual(rightEdge(leftWingWidth: 196), hardwareWidth / 2 + rightWingWidth)
    }

    func testExpandedWingsRespectShoulderAndRailInsets() {
        let wing = NotchGeometry.centeredWingWidth(
            totalWidth: 480,
            hardwareWidth: 183,
            contentInset: 31,
            railInset: 5
        )

        XCTAssertEqual(wing, 112.5)
        XCTAssertEqual(2 * wing + 183 + 2 * 31 + 2 * 5, 480)
    }
}
