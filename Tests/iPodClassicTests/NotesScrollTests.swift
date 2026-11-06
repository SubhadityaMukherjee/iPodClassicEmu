import XCTest
@testable import iPodClassic

/// The notes editor's wheel-scroll clamp: plain moves, both end stops, and
/// the short-document case (nothing to scroll → offset stays put).
final class NotesScrollTests: XCTestCase {
    func testPlainMoveWithinDocument() {
        XCTAssertEqual(
            clampedScrollOffset(current: 0, delta: 26, contentHeight: 1000, viewportHeight: 200, topInset: 0, bottomInset: 0),
            26
        )
        XCTAssertEqual(
            clampedScrollOffset(current: 100, delta: -26, contentHeight: 1000, viewportHeight: 200, topInset: 0, bottomInset: 0),
            74
        )
    }

    func testClampsAtBottomEnd() {
        // Max offset = contentHeight - viewport = 800; a big tick overshoots → 800.
        XCTAssertEqual(
            clampedScrollOffset(current: 790, delta: 26, contentHeight: 1000, viewportHeight: 200, topInset: 0, bottomInset: 0),
            800
        )
    }

    func testClampsAtTopEnd() {
        XCTAssertEqual(
            clampedScrollOffset(current: 10, delta: -26, contentHeight: 1000, viewportHeight: 200, topInset: 0, bottomInset: 0),
            0
        )
    }

    func testShortDocumentNeverMoves() {
        // Content shorter than the viewport: highest == lowest == 0.
        XCTAssertEqual(
            clampedScrollOffset(current: 0, delta: 26, contentHeight: 100, viewportHeight: 200, topInset: 0, bottomInset: 0),
            0
        )
    }

    func testKeyboardInsetExtendsRange() {
        // While typing, UITextView insets push the scrollable range negative.
        XCTAssertEqual(
            clampedScrollOffset(current: 0, delta: -26, contentHeight: 1000, viewportHeight: 200, topInset: 60, bottomInset: 0),
            -26,
            "The range extends above the document start while the keyboard inset is active"
        )
        XCTAssertEqual(
            clampedScrollOffset(current: -50, delta: -26, contentHeight: 1000, viewportHeight: 200, topInset: 60, bottomInset: 0),
            -60,
            "A tick past the inset-bounded floor must clamp at it"
        )
        XCTAssertEqual(
            clampedScrollOffset(current: -60, delta: 26, contentHeight: 1000, viewportHeight: 200, topInset: 60, bottomInset: 0),
            -34
        )
    }
}
