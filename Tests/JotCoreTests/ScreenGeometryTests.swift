import XCTest
@testable import JotCore

final class ScreenGeometryTests: XCTestCase {
    func testFieldOnPrimaryDisplayFlipsOnlyY() {
        let rect = ScreenGeometry.appKitRect(accessibilityOrigin: CGPoint(x: 100, y: 200), size: CGSize(width: 300, height: 40), primaryScreenHeight: 1000)
        XCTAssertEqual(rect, CGRect(x: 100, y: 760, width: 300, height: 40))
    }

    func testDisplayToTheLeftKeepsNegativeX() {
        let rect = ScreenGeometry.appKitRect(accessibilityOrigin: CGPoint(x: -1500, y: 200), size: CGSize(width: 300, height: 40), primaryScreenHeight: 1000)
        XCTAssertEqual(rect, CGRect(x: -1500, y: 760, width: 300, height: 40))
    }

    func testDisplayAboveLandsAbovePrimaryHeight() {
        let rect = ScreenGeometry.appKitRect(accessibilityOrigin: CGPoint(x: 100, y: -800), size: CGSize(width: 300, height: 40), primaryScreenHeight: 1000)
        XCTAssertEqual(rect, CGRect(x: 100, y: 1760, width: 300, height: 40))
        XCTAssertGreaterThan(rect.minY, 1000)
    }
}
