import XCTest
@testable import iPodClassic

/// moveListSelection — the shared list-cursor stepper every wheel menu
/// uses: in-range moves, silent clamping at the ends, and Infinite Tick
/// wrapping. Selection must never land outside 0..<count.
final class MenuSelectionTests: XCTestCase {
    private var savedInfiniteTick: Bool = false

    override func setUp() {
        super.setUp()
        savedInfiniteTick = AppSettings.shared.infiniteTick
    }

    override func tearDown() {
        AppSettings.shared.infiniteTick = savedInfiniteTick
        super.tearDown()
    }

    func testMoveWithinRange() {
        var sel = 2
        let moved = moveListSelection(&sel, count: 10, delta: 1, settings: AppSettings.shared)
        XCTAssertEqual(sel, 3)
        XCTAssertTrue(moved)
        let back = moveListSelection(&sel, count: 10, delta: -2, settings: AppSettings.shared)
        XCTAssertEqual(sel, 1)
        XCTAssertTrue(back)
    }

    func testClampsAtEndsWithoutInfiniteTick() {
        AppSettings.shared.infiniteTick = false
        var sel = 9
        let atEnd = moveListSelection(&sel, count: 10, delta: 1, settings: AppSettings.shared)
        XCTAssertFalse(atEnd, "beyond the end must report not-moved")
        XCTAssertEqual(sel, 9, "selection must stay at the last row")
        sel = 0
        let beforeStart = moveListSelection(&sel, count: 10, delta: -1, settings: AppSettings.shared)
        XCTAssertFalse(beforeStart)
        XCTAssertEqual(sel, 0, "selection must stay at the first row")
    }

    func testInfiniteTickWrapsBothWays() {
        AppSettings.shared.infiniteTick = true
        var sel = 9
        XCTAssertTrue(moveListSelection(&sel, count: 10, delta: 1, settings: AppSettings.shared))
        XCTAssertEqual(sel, 0, "down past the end wraps to the top")
        XCTAssertTrue(moveListSelection(&sel, count: 10, delta: -1, settings: AppSettings.shared))
        XCTAssertEqual(sel, 9, "up past the start wraps to the bottom")
    }

    func testBigOvershootStillLandsInRange() {
        AppSettings.shared.infiniteTick = true
        var sel = 0
        _ = moveListSelection(&sel, count: 5, delta: 12, settings: AppSettings.shared)
        XCTAssertTrue((0..<5).contains(sel), "wrap arithmetic must land in range (got \(sel))")
    }

    func testEmptyListNeverMoves() {
        var sel = 0
        XCTAssertFalse(moveListSelection(&sel, count: 0, delta: 1, settings: AppSettings.shared))
        XCTAssertEqual(sel, 0)
    }
}
