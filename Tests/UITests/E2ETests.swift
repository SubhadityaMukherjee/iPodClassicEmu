import XCTest

/// End-to-end checks over real touch events for the newer features:
/// Reader, search hold-nav surface, alarm repeat segment, Now Playing.
final class E2ETests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(start: String, fakeLibrary: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RESET_DEFAULTS"] = "1"
        app.launchEnvironment["START_ROUTE"] = start
        if fakeLibrary { app.launchEnvironment["FAKE_LIBRARY"] = "1" }
        app.launch()
        return app
    }

    // MARK: Wheel helpers

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
    private func menu(_ wheel: XCUIElement) {
        wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: -96)).tap()
    }

    @MainActor
    private func wheelCenterTap(_ wheel: XCUIElement) {
        wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    // MARK: Reader

    @MainActor
    func testReaderEmptyStateRenders() throws {
        let app = launch(start: "reader")
        // Reader is now a Books/Articles selector; "Add from Files" lives
        // one level down in the Books list.
        XCTAssertTrue(app.staticTexts["Books"].waitForExistence(timeout: 5),
                      "Reader selector did not render its Books row")
        XCTAssertTrue(app.staticTexts["Articles"].waitForExistence(timeout: 3),
                      "Reader selector did not render its Articles row")
        XCTAssertTrue(app.staticTexts["Reader"].waitForExistence(timeout: 3),
                      "Reader title bar missing")
    }

    @MainActor
    func testHomeShowsRecentsSection() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RESET_DEFAULTS"] = "1"
        app.launchEnvironment["RECENTS_SEED"] = "1"
        app.launch()
        let wheelEl = wheel(app)
        // Recents rows sit below the standard home rows — scroll to them.
        // 11 ticks lands on the QA Book row; the binaural row is the next
        // one and only renders once selected (the menu shows a window).
        for _ in 0..<11 { tick(wheelEl) }
        XCTAssertTrue(app.staticTexts["Recents"].waitForExistence(timeout: 3),
                      "Recents header missing on home")
        XCTAssertTrue(app.staticTexts["QA Book"].exists, "recent book row missing")
        tick(wheelEl)
        XCTAssertTrue(app.staticTexts["QA Binaural"].exists, "recent binaural row missing")
    }

    @MainActor
    func testBinauralSessionJumpsBackFromRecents() throws {
        // Start on HOME (START_ROUTE replaces the stack — extras would leave
        // no home in it, and the two MENU pops would hit the root guard).
        let app = launch(start: "home")
        let wheelEl = wheel(app)

        // Home: Extras is the 7th row — six ticks, open it.
        for _ in 0..<6 { tick(wheelEl) }
        wheelCenterTap(wheelEl)
        XCTAssertTrue(app.staticTexts["Clocks"].waitForExistence(timeout: 3),
                      "Extras menu did not open")

        // Extras: Clocks, Calendar, Binaural — two ticks down, open it.
        for _ in 0..<2 { tick(wheelEl) }
        wheelCenterTap(wheelEl)
        XCTAssertTrue(app.staticTexts["Off"].waitForExistence(timeout: 3),
                      "Binaural screen did not open")

        // One tick selects Delta; center starts the session — the Off row
        // flips to Stop, and the preset is recorded into Recents.
        tick(wheelEl)
        wheelCenterTap(wheelEl)
        XCTAssertTrue(app.staticTexts["Stop"].waitForExistence(timeout: 3),
                      "starting a preset did not flip Off to Stop")

        // Back to home: MENU pops Binaural, MENU pops Extras. Home keeps
        // its selection (Extras, index 6) because buried routes stay alive.
        menu(wheelEl)
        menu(wheelEl)
        XCTAssertTrue(app.staticTexts["Music"].waitForExistence(timeout: 3),
                      "two MENU presses did not return home")

        // From selection 6 the Recents binaural row is 5 ticks away
        // (Settings, Shuffle All, Now Playing, Recents header, row).
        for _ in 0..<5 { tick(wheelEl) }
        XCTAssertTrue(app.staticTexts["Recents"].exists, "Recents header not reached on home")
        wheelCenterTap(wheelEl)
        XCTAssertTrue(app.staticTexts["Stop"].waitForExistence(timeout: 3),
                      "Recents binaural row did not reopen the Binaural screen (session still playing)")
    }

    @MainActor
    func testReaderReachableFromHome() throws {
        let app = launch(start: "home")
        let wheel = app.otherElements["clickwheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        let origin = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // Home rows: Music, Photos, Camera, Voice Memos, Notes, Reader, …
        // Five ticks down selects Reader; center opens it.
        func tick() {
            origin.withOffset(CGVector(dx: 64, dy: 64))
                .press(forDuration: 0.02, thenDragTo: origin.withOffset(CGVector(dx: 45, dy: 78)))
        }
        for _ in 0..<5 { tick() }
        origin.withOffset(CGVector(dx: 0, dy: 0)).tap()

        // Reader is a Books/Articles selector now — Books opens the list
        // with its "Add from Files" row.
        XCTAssertTrue(app.staticTexts["Books"].waitForExistence(timeout: 3),
                      "Home → Reader selector failed")
        origin.withOffset(CGVector(dx: 0, dy: 0)).tap()
        XCTAssertTrue(app.staticTexts["Add from Files"].waitForExistence(timeout: 3),
                      "Home → Reader → Books navigation failed")
    }

    @MainActor
    func testAlarmRepeatSegmentCyclesAndToggles() throws {
        let app = launch(start: "alarm")
        let wheel = app.otherElements["clickwheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        let center = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // Set Hour → (center) Set Minute → AM/PM → Repeat Days.
        XCTAssertTrue(app.staticTexts["Set Hour"].waitForExistence(timeout: 5))
        center.tap()
        XCTAssertTrue(app.staticTexts["Set Minute"].waitForExistence(timeout: 3), "center did not advance to minute")
        center.tap()
        XCTAssertTrue(app.staticTexts["AM / PM"].waitForExistence(timeout: 3), "center did not advance to AM/PM")
        center.tap()
        XCTAssertTrue(app.staticTexts["Repeat: Every Day"].waitForExistence(timeout: 3),
                      "center did not advance to the repeat segment")

        // Center now toggles Sunday on: the title must switch from the
        // every-day default to a weekday listing.
        center.tap()
        let summary = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Repeat: Sun")
        ).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 3),
                      "toggling a day did not update the repeat summary")
    }

    // MARK: Search / Now Playing

    @MainActor
    func testSearchEmptyStateRenders() throws {
        let app = launch(start: "search", fakeLibrary: true)
        XCTAssertTrue(app.staticTexts["Type to search"].waitForExistence(timeout: 5),
                      "Search screen did not render")
    }

    @MainActor
    func testNowPlayingIdleStateRenders() throws {
        let app = launch(start: "nowplaying")
        XCTAssertTrue(app.staticTexts["Not Playing"].waitForExistence(timeout: 5),
                      "Now Playing idle state missing")
    }

    // MARK: Songs list hold (queue)

    @MainActor
    func testSongsListRendersWithFakeLibrary() throws {
        let app = launch(start: "songs", fakeLibrary: true)
        XCTAssertTrue(app.staticTexts["Song 000"].waitForExistence(timeout: 5),
                      "Songs list did not load seed data")
        let wheel = app.otherElements["clickwheel"]
        let origin = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        func tick() {
            origin.withOffset(CGVector(dx: 64, dy: 64))
                .press(forDuration: 0.02, thenDragTo: origin.withOffset(CGVector(dx: 45, dy: 78)))
        }
        // Walk past the three header rows onto the first song row, then
        // hold center: the queue-options panel must open. Without playback
        // nothing can be queued and nothing may navigate — the screen must
        // stay put (no crash, no push).
        for _ in 0..<3 { tick() }
        let center = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["Play Next"].waitForExistence(timeout: 3),
                      "hold on a song row did not open the queue options panel")
        XCTAssertTrue(app.staticTexts["Add to Queue"].exists, "queue options panel missing Add to Queue")

        // Select "Play Next" (row 0): nothing is playing under FAKE_LIBRARY,
        // so it must toast "Nothing Playing" and close without navigating.
        center.tap()
        XCTAssertTrue(app.staticTexts["Nothing Playing"].waitForExistence(timeout: 3),
                      "Play Next without playback should toast Nothing Playing")
        XCTAssertTrue(app.staticTexts["Song 000"].waitForExistence(timeout: 2),
                      "hold on a song row kicked us off the songs screen")
        XCTAssertFalse(app.staticTexts["Not Playing"].exists || app.buttons["Done"].exists,
                       "hold on a song row unexpectedly navigated")
    }
}
