import XCTest

/// Notes editor E2E: the click wheel scrolls the note body (proving the
/// UITextView probe + scroll path), and the Done capsule drops the keyboard.
final class NotesEditorTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWheelScrollsNoteAndDoneDismissesKeyboard() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RESET_DEFAULTS"] = "1"
        app.launchEnvironment["START_ROUTE"] = "noteEditor"
        app.launchEnvironment["NOTES_QA"] = "1"
        app.launch()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Note editor did not open")

        // QA readout: the backing UITextView's content offset ("y=…").
        let readout = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "y=")
        ).firstMatch
        XCTAssertTrue(readout.waitForExistence(timeout: 3), "QA scroll readout missing")
        let startY = Int(readout.label.dropFirst(2)) ?? -999

        // Three clockwise ticks on the scroll sector must scroll the note.
        let wheel = app.otherElements["clickwheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        let origin = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for _ in 0..<3 {
            origin.withOffset(CGVector(dx: 64, dy: 64))
                .press(forDuration: 0.02, thenDragTo: origin.withOffset(CGVector(dx: 45, dy: 78)))
        }

        var scrolledY = -999
        for _ in 0..<10 {
            if readout.exists, let y = Int(readout.label.dropFirst(2)), y > startY {
                scrolledY = y
                break
            }
            usleep(200_000)
        }
        XCTAssertTrue(scrolledY > startY,
                      "Wheel ticks did not scroll the note (start y=\(startY), end y=\(scrolledY))")

        // Typing mode: tap into the text view → keyboard → Done appears.
        editor.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 6), "Done button did not appear with the keyboard")

        // Done must drop the keyboard (probe → resignFirstResponder).
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Done did not dismiss the keyboard")
    }
}
