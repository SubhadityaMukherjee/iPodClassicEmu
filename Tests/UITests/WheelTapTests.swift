import XCTest

/// Drives the click wheel with real touch events through XCUI and asserts
/// the navigation/results — the ground-truth check for gesture wiring.
final class WheelTapTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    @MainActor
    func testCenterTapOpensMusicMenu() throws {
        let app = launchApp()

        // Wheel center: middle of the clickwheel element.
        let wheel = app.otherElements["clickwheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 5), "clickwheel element not found")
        let center = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()

        XCTAssertTrue(
            app.staticTexts["Cover Flow"].waitForExistence(timeout: 3),
            "Center tap did not push the Music menu"
        )

        // The pushed screen must fully COVER the home screen (opaque
        // background). Home's "Photos" row still exists in the hierarchy but
        // must not be tappable/visible through the new screen.
        let photosRow = app.staticTexts["Photos"]
        if photosRow.exists {
            XCTAssertFalse(photosRow.isHittable, "Home menu shows through the pushed screen (missing opaque background)")
        }
    }

    @MainActor
    func testWheelOnlyAffectsTopScreen() throws {
        let app = launchApp()
        let wheel = app.otherElements["clickwheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        let origin = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let center = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // Home → Photos (one tick down on the NE diagonal), open it.
        origin.withOffset(CGVector(dx: 64, dy: 64))
            .press(forDuration: 0.02, thenDragTo: origin.withOffset(CGVector(dx: 45, dy: 78)))
        center.tap()
        XCTAssertTrue(app.staticTexts["No Photos"].waitForExistence(timeout: 3)
                      || app.staticTexts["Allow photo access to see your gallery."].exists,
                      "Photos screen did not open")

        // Center again on the Photos screen (empty library → no-op). If a
        // buried screen still listened, home would push a duplicate Photos.
        center.tap()

        // MENU pops exactly one level: we must land back on HOME (its rows
        // visible), not on another Photos screen.
        origin.withOffset(CGVector(dx: 0, dy: -96)).tap()
        XCTAssertTrue(app.staticTexts["Now Playing"].waitForExistence(timeout: 3),
                      "MENU did not return home — a buried screen likely pushed a duplicate")
    }

    @MainActor
    func testScrollTickMovesSelection() throws {
        let app = launchApp()
        let wheel = app.otherElements["clickwheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))

        // One detent: start on the NE diagonal (a scroll sector at 45°) and
        // drag ~15° clockwise. 15°/tick → exactly one tick, Music → Photos.
        let wheelOrigin = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let start = wheelOrigin.withOffset(CGVector(dx: 64, dy: 64))
        let end = wheelOrigin.withOffset(CGVector(dx: 45, dy: 78))
        start.press(forDuration: 0.02, thenDragTo: end)

        // Selection should now be Photos; a center tap opens the Photos
        // screen, whose empty-library hint is unique to that screen.
        let center = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()

        XCTAssertTrue(
            app.staticTexts["Allow photo access to see your gallery."].waitForExistence(timeout: 3)
                || app.staticTexts["No Photos"].waitForExistence(timeout: 1),
            "One tick did not move selection Music → Photos (or select broke)"
        )
    }
}
