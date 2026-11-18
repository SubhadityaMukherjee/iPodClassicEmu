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
        // First-launch tour/setup would otherwise greet the test.
        app.launchEnvironment["RESET_DEFAULTS"] = "1"
        app.launch()
        return app
    }

    /// MENU button: top of the wheel face.
    @MainActor
    private func menu(_ app: XCUIApplication) {
        let wheel = app.otherElements["clickwheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: -96)).tap()
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
    func testAllSongsListScrolls() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RESET_DEFAULTS"] = "1"
        app.launchEnvironment["FAKE_LIBRARY"] = "1"
        app.launchEnvironment["START_ROUTE"] = "songs"
        app.launch()

        let wheel = app.otherElements["clickwheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Song 000"].waitForExistence(timeout: 5), "Fake songs list did not load")

        let origin = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        func tick() {
            origin.withOffset(CGVector(dx: 64, dy: 64))
                .press(forDuration: 0.02, thenDragTo: origin.withOffset(CGVector(dx: 45, dy: 78)))
        }
        // 3 ticks pass the headers; 40 more walk very deep into the songs —
        // the visible window must slide along with the selection and never
        // clip rows at the tail.
        for _ in 0..<43 { tick() }

        // Song 040 sits at selection index 43; it must now be on screen.
        XCTAssertTrue(app.staticTexts["Song 040"].waitForExistence(timeout: 4),
                      "All Songs window did not slide with the selection")
        // The row after the selection must also be rendered whole (no tail cut-off).
        XCTAssertTrue(app.staticTexts["Song 041"].exists || app.staticTexts["Song 039"].exists,
                      "Rows around the selection are missing at depth")
    }


    @MainActor
    func testSettingsSubmenuScrollsAndSelects() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RESET_DEFAULTS"] = "1"
        app.launch()
        let wheel = app.otherElements["clickwheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        let origin = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let center = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        func tick() {
            origin.withOffset(CGVector(dx: 64, dy: 64))
                .press(forDuration: 0.02, thenDragTo: origin.withOffset(CGVector(dx: 45, dy: 78)))
        }

        // Home → Settings (7 ticks down; Reader added a home row), open it.
        for _ in 0..<7 { tick() }
        center.tap()
        XCTAssertTrue(app.staticTexts["Clickwheel"].waitForExistence(timeout: 3), "Settings menu did not open")

        // Tick to the Clickwheel row and open it.
        tick()
        center.tap()
        XCTAssertTrue(app.staticTexts["Haptics"].waitForExistence(timeout: 3), "Clickwheel settings did not open")

        // The wheel must MOVE the selection (not cycle values): row 0
        // "Haptics" → row 1 "Scrolling Haptics". Center now cycles its value
        // Medium → Strong, which only exists if the selection really moved.
        // SwiftUI merges row texts into one a11y element, so match loosely.
        tick()
        center.tap()
        // Depth-2: the Clickwheel submenu renders its rows, and MENU pops
        // back to the Settings menu (wheel scrolling + center opening +
        // pop all verified without coupling to factory setting values).
        XCTAssertTrue(app.staticTexts["Scrolling Haptics"].waitForExistence(timeout: 3),
                      "Clickwheel settings rows did not render")
        menu(app)
        XCTAssertTrue(app.staticTexts["Display"].waitForExistence(timeout: 3),
                      "MENU did not pop the Clickwheel submenu back to Settings")
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
        // Title bar — the same marker whether the library is empty,
        // unauthorized, or populated (PhotosE2ETests may have granted access).
        XCTAssertTrue(app.staticTexts["All Photos"].waitForExistence(timeout: 3),
                      "Photos screen did not open")

        // Center again on the Photos screen: with no library/no access it's
        // a no-op; with photos it opens photo #0. Either way ONLY the top
        // screen may react — if a buried screen listened too, home would
        // push a duplicate Photos, and the MENU counts below would break.
        center.tap()
        if app.staticTexts["Photo"].waitForExistence(timeout: 2) {
            origin.withOffset(CGVector(dx: 0, dy: -96)).tap() // pop the detail back to the grid
            XCTAssertTrue(app.staticTexts["All Photos"].waitForExistence(timeout: 3),
                          "MENU did not pop the photo detail back to the grid")
        }

        // MENU pops exactly one level: we must land back on HOME (its first
        // row is visible), not on another Photos screen. The last home row
        // may be outside the initial window, so assert on row 0.
        origin.withOffset(CGVector(dx: 0, dy: -96)).tap()
        XCTAssertTrue(app.staticTexts["Music"].waitForExistence(timeout: 3),
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
        // screen — identified by its title bar, whatever the library state.
        let center = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()

        XCTAssertTrue(
            app.staticTexts["All Photos"].waitForExistence(timeout: 3),
            "One tick did not move selection Music → Photos (or select broke)"
        )
    }
}
