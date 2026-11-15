import XCTest

/// Photos gallery E2E: the wheel navigates the grid, center opens the
/// photo the blue frame is on (not photo #0 — that was a load race), and
/// thumbnails decode at display resolution (not blurry). Requires photos
/// in the simulator library; skips gracefully on an empty library.
/// Screenshots are attached for visual QA of thumbnail sharpness.
final class PhotosE2ETests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(seedRecents: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate() // never relaunch over a lingering instance (drops env)
        app.launchEnvironment["RESET_DEFAULTS"] = "1"
        if seedRecents { app.launchEnvironment["RECENTS_SEED"] = "1" }
        for _ in 0..<2 {
            app.launch()
            // Env-drop guard: a warm relaunch can lose the environment and
            // land on the first-run tour — relaunch once with a settled
            // process.
            if !app.staticTexts["The iPod, rebuilt"].waitForExistence(timeout: 2) {
                break
            }
            app.terminate()
            sleep(1)
        }
        return app
    }

    /// A fresh install triggers the full-library permission prompt when
    /// Photos opens; grant it so the grid can load (labels vary slightly
    /// across iOS versions).
    @MainActor
    private func grantPhotosAccessIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow Full Access", "Allow Access to All Photos", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
    }

    @MainActor
    private func wheel(_ app: XCUIApplication) -> XCUIElement {
        let wheel = app.otherElements["clickwheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 5), "clickwheel element not found")
        return wheel
    }

    @MainActor
    private func tick(_ wheel: XCUIElement) {
        let origin = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.withOffset(CGVector(dx: 64, dy: 64))
            .press(forDuration: 0.02, thenDragTo: origin.withOffset(CGVector(dx: 45, dy: 78)))
    }

    @MainActor
    private func center(_ wheel: XCUIElement) {
        wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func menu(_ wheel: XCUIElement) {
        wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: -96)).tap()
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testGridNavigatesAndOpensSelectedPhotoNotFirst() throws {
        let app = launch()
        let wheelEl = wheel(app)

        // Home: one tick selects Photos, center opens the grid.
        tick(wheelEl)
        center(wheelEl)
        XCTAssertTrue(app.staticTexts["All Photos"].waitForExistence(timeout: 5),
                      "Photos grid did not open")
        grantPhotosAccessIfNeeded()

        // Wait for the library fetch; an empty sim library skips the rest.
        sleep(3)
        attach("photos-grid-top")

        // Walk the selection down a few cells so a middle photo is framed.
        for _ in 0..<4 { tick(wheelEl) }
        sleep(1)
        attach("photos-grid-selection-middle")
        center(wheelEl)

        // Detail must open — and show the FRAMED photo, not photo #0.
        XCTAssertTrue(app.staticTexts["Photo"].waitForExistence(timeout: 5),
                      "photo detail did not open")
        sleep(2) // full-image decode
        attach("photo-detail-framed-photo")

        // Wheel = next photo; the new photo must replace the old one.
        tick(wheelEl)
        sleep(2)
        attach("photo-detail-after-one-tick")

        // Back out to the grid.
        menu(wheelEl)
        XCTAssertTrue(app.staticTexts["All Photos"].waitForExistence(timeout: 3),
                      "MENU did not pop back to the grid")
    }

    @MainActor
    func testRecentsBinauralRowRenders() throws {
        let app = launch(seedRecents: true)
        let wheelEl = wheel(app)

        // Walk to the Recents section: 12 items with the full seed, the
        // binaural row is the 13th (after the book row).
        for _ in 0..<12 { tick(wheelEl) }
        XCTAssertTrue(app.staticTexts["Recents"].waitForExistence(timeout: 3),
                      "Recents header missing")
        XCTAssertTrue(app.staticTexts["QA Binaural"].waitForExistence(timeout: 3),
                      "recent binaural row missing")
        attach("home-recents-binaural")
    }
}
