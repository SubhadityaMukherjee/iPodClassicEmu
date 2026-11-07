import XCTest
@testable import iPodClassic

/// The shared song-row hold panel (Play Next / Add to Queue): event
/// consumption, selection movement, and the toast for each choice while
/// nothing is playing (the only reachable state in unit tests).
@MainActor
final class SongHoldStateTests: XCTestCase {
    private func makeHold() -> SongHoldState { SongHoldState() }

    func testClosedStateDoesNotConsumeEvents() {
        let hold = makeHold()
        let player = PlayerModel()
        var toasts: [String] = []
        XCTAssertFalse(hold.handle(.select, player: player, toast: { toasts.append($0) }),
                       "with no panel up the screen must keep the event")
        XCTAssertTrue(toasts.isEmpty)
    }

    func testTicksMoveSelectionWithClamp() {
        let hold = makeHold()
        let player = PlayerModel()
        hold.beginQA(title: "Song 000")
        hold.handle(.tick(1), player: player, toast: { _ in })
        XCTAssertEqual(hold.selection, 1)
        hold.handle(.tick(1), player: player, toast: { _ in })
        XCTAssertEqual(hold.selection, 2)
        hold.handle(.tick(1), player: player, toast: { _ in })
        XCTAssertEqual(hold.selection, 2, "selection must clamp at Cancel")
        hold.handle(.tick(-1), player: player, toast: { _ in })
        hold.handle(.tick(-1), player: player, toast: { _ in })
        hold.handle(.tick(-1), player: player, toast: { _ in })
        XCTAssertEqual(hold.selection, 0, "selection must clamp at Play Next")
    }

    func testPlayNextWithoutPlaybackToastsAndCloses() {
        let hold = makeHold()
        let player = PlayerModel()
        var toasts: [String] = []
        hold.beginQA(title: "Song 000")
        XCTAssertTrue(hold.handle(.select, player: player, toast: { toasts.append($0) }))
        XCTAssertEqual(toasts, ["Nothing Playing"])
        XCTAssertFalse(hold.isShowing, "selecting an option must close the panel")
    }

    func testAddToQueueWithoutPlaybackToastsAndCloses() {
        let hold = makeHold()
        let player = PlayerModel()
        var toasts: [String] = []
        hold.beginQA(title: "Song 001")
        hold.handle(.tick(1), player: player, toast: { _ in })  // → Add to Queue
        XCTAssertTrue(hold.handle(.select, player: player, toast: { toasts.append($0) }))
        XCTAssertEqual(toasts, ["Nothing Playing"])
        XCTAssertFalse(hold.isShowing)
    }

    func testMenuClosesPanelWithoutToast() {
        let hold = makeHold()
        let player = PlayerModel()
        var toasts: [String] = []
        hold.beginQA(title: "Song 002")
        XCTAssertTrue(hold.handle(.menu, player: player, toast: { toasts.append($0) }))
        XCTAssertFalse(hold.isShowing)
        XCTAssertTrue(toasts.isEmpty)
    }
}
