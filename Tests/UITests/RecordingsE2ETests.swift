import XCTest

/// End-to-end checks over real wheel/touch events for the recorder's
/// Recently Deleted screen E2E (delete → restore, delete-forever).
/// Seeded via REC_SEED=1 (two fixed QA memos); navigation happens with
/// START_ROUTE. List rows are wheel-driven (no touch handlers), while
/// the modal panels' rows accept taps — the tests mirror that split.
final class RecordingsE2ETests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(start: String, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchEnvironment["RESET_DEFAULTS"] = "1"
        app.launchEnvironment["START_ROUTE"] = start
        for (k, v) in extra { app.launchEnvironment[k] = v }
        // Env-drop race on a warm relaunch: if the first-run tour shows
        // instead of the route, terminate and try once more.
        for _ in 0..<2 {
            app.launch()
            if !app.staticTexts["The iPod, rebuilt"].waitForExistence(timeout: 2) {
                return app
            }
            app.terminate()
            sleep(1)
        }
        return app
    }

    // MARK: Wheel helpers

    @MainActor
    private func wheel(_ app: XCUIApplication) -> XCUIElement {
        let wheel = app.otherElements["clickwheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 5), "clickwheel element not found")
        return wheel
    }

    /// One outward drag on the wheel's right side = one positive tick
    /// (selection moves down one row).
    @MainActor
    private func tick(_ wheel: XCUIElement) {
        let origin = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.withOffset(CGVector(dx: 64, dy: 64))
            .press(forDuration: 0.02, thenDragTo: origin.withOffset(CGVector(dx: 45, dy: 78)))
    }

    /// Center press = select/activate the selected row.
    @MainActor
    private func centerTap(_ wheel: XCUIElement) {
        wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Long center press = hold center (opens hold menus).
    @MainActor
    private func centerHold(_ wheel: XCUIElement) {
        wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
    }

    /// Bottom-left press = MENU (drops the keyboard / pops).
    @MainActor
    private func menu(_ wheel: XCUIElement) {
        wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: -96)).tap()
    }

    // MARK: Recently Deleted

    @MainActor
    func testDeleteMovesToTrashAndRestoreBringsItBack() {
        // 1. Seeded recordings list — one live memo ("QA Recording One"
        //    is the newest, so the wheel starts selected on it). Delete
        //    it through the hold menu's Delete + confirm panel (panel
        //    rows take taps).
        let list = launch(start: "recordings", extra: ["REC_SEED": "1"])
        XCTAssertTrue(list.staticTexts["QA Recording One"].waitForExistence(timeout: 5),
                      "seeded memo missing from the recordings list")
        centerHold(wheel(list))
        XCTAssertTrue(list.staticTexts["Delete"].waitForExistence(timeout: 3),
                      "hold menu did not open")
        list.staticTexts["Delete"].firstMatch.tap()
        // Confirm panel — Cancel is preselected; Delete sits above it.
        XCTAssertTrue(list.staticTexts["Delete"].waitForExistence(timeout: 3),
                      "delete confirm panel did not open")
        list.staticTexts["Delete"].firstMatch.tap()
        XCTAssertFalse(list.staticTexts["QA Recording One"].exists,
                       "deleted memo must leave the list")

        // 2. Trash (no seed needed — the trash lives on disk). Rows sort
        //    by creation: the seeded-trashed "Two" (created last) sits
        //    above the freshly trashed "One". The top row is selected,
        //    so a center tap restores "Two".
        let trash = launch(start: "recordingsTrash")
        XCTAssertTrue(trash.staticTexts["QA Recording Two"].waitForExistence(timeout: 5),
                      "trashed memos missing from Recently Deleted")
        XCTAssertTrue(trash.staticTexts["QA Recording One"].exists)
        centerTap(wheel(trash))
        XCTAssertFalse(trash.staticTexts["QA Recording Two"].exists,
                       "restore removes the row from the trash")

        // 3. The restored memo is back in the recordings list.
        let list2 = launch(start: "recordings")
        XCTAssertTrue(list2.staticTexts["QA Recording Two"].waitForExistence(timeout: 5),
                      "restored memo missing from the recordings list")
    }

    @MainActor
    func testDeleteForeverEmptiesTheTrash() {
        // Trash seeded directly: only "QA Recording Two" starts trashed.
        let trash = launch(start: "recordingsTrash", extra: ["REC_SEED": "1"])
        XCTAssertTrue(trash.staticTexts["QA Recording Two"].waitForExistence(timeout: 5),
                      "seeded trashed memo missing")
        // Hold center → Delete Forever panel → tap Delete Forever.
        centerHold(wheel(trash))
        XCTAssertTrue(trash.staticTexts["Delete Forever"].waitForExistence(timeout: 3),
                      "Delete Forever panel did not open")
        trash.staticTexts["Delete Forever"].firstMatch.tap()
        XCTAssertTrue(trash.staticTexts["Trash Empty"].waitForExistence(timeout: 3),
                      "the trash did not empty")
        // A fresh launch confirms nothing came back.
        let again = launch(start: "recordingsTrash")
        XCTAssertTrue(again.staticTexts["Trash Empty"].waitForExistence(timeout: 5))
    }
}
