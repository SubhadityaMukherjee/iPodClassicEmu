import XCTest

/// First-run setup wizard: renders on first launch, walks forward with
/// center/MENU (never starting the optional voice-model download), and
/// lands on home at the end.
final class SetupUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchSetup() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RESET_DEFAULTS"] = "1"
        app.launchEnvironment["SHOW_SETUP"] = "1"
        app.launch()
        return app
    }

    @MainActor
    private func center(_ app: XCUIApplication) {
        let wheel = app.otherElements["clickwheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func menu(_ app: XCUIApplication) {
        let wheel = app.otherElements["clickwheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: -96)).tap()
    }

    @MainActor
    func testSetupWalksThroughAndLandsOnHome() throws {
        let app = launchSetup()

        XCTAssertTrue(app.staticTexts["Welcome"].waitForExistence(timeout: 5),
                      "Setup wizard did not render")

        center(app) // welcome → permissions
        XCTAssertTrue(app.staticTexts["Permissions"].waitForExistence(timeout: 3),
                      "Permissions page did not appear")

        menu(app) // permissions → voice model (skip granting in tests)
        XCTAssertTrue(app.staticTexts["Voice Model"].waitForExistence(timeout: 3),
                      "Voice model page did not appear")

        // Selection defaults to "Download Now" — MENU skips instead so the
        // test never starts a 600 MB download.
        menu(app)
        XCTAssertTrue(app.staticTexts["Preferences Set"].waitForExistence(timeout: 3),
                      "Preferences page did not appear")

        center(app) // preferences → done
        XCTAssertTrue(app.staticTexts["All Set!"].waitForExistence(timeout: 3),
                      "Done page did not appear")

        center(app) // done → home
        XCTAssertTrue(app.staticTexts["Music"].waitForExistence(timeout: 3),
                      "Setup finish did not land on the home screen")
        XCTAssertFalse(app.staticTexts["All Set!"].exists,
                       "Setup screen leaked through to home")
    }
}
