import XCTest
@testable import iPodClassic

/// Letter-group snapping for music lists: a fast spin jumps to the next
/// letter group; edges clamp to nil so the caller falls back to a normal
/// single-row move.
final class LetterSnapTests: XCTestCase {
    private let titles = ["Alpha", "Antler", "Bee", "Cat", "Cedar", "Dog", "Dog 2", "Echo"]

    func testForwardSnapsToNextLetterGroup() {
        // From inside the A group → first row of B.
        XCTAssertEqual(MusicListScreen.letterSnapTarget(titles: titles, from: 0, dir: 1), 2)
        XCTAssertEqual(MusicListScreen.letterSnapTarget(titles: titles, from: 1, dir: 1), 2)
        // From inside the C group → first row of D.
        XCTAssertEqual(MusicListScreen.letterSnapTarget(titles: titles, from: 4, dir: 1), 5)
    }

    func testBackwardSnapsToPreviousLetterGroup() {
        // From the first row of B → last row of the A group.
        XCTAssertEqual(MusicListScreen.letterSnapTarget(titles: titles, from: 2, dir: -1), 1)
        // From the first row of C → last row of B.
        XCTAssertEqual(MusicListScreen.letterSnapTarget(titles: titles, from: 3, dir: -1), 2)
    }

    func testEdgesReturnNilSoCallerFallsBack() {
        XCTAssertNil(MusicListScreen.letterSnapTarget(titles: titles, from: 0, dir: -1))
        XCTAssertNil(MusicListScreen.letterSnapTarget(titles: titles, from: titles.count - 1, dir: 1))
    }

    func testCaseInsensitiveAndNonLetterKeys() {
        let mixed = ["apple", "Bear", "1st", "2nd", "Cherry"]
        XCTAssertEqual(MusicListScreen.letterSnapTarget(titles: mixed, from: 0, dir: 1), 1)
        // Groups are per leading character (case-insensitive): "1st" and
        // "2nd" are distinct groups, each its own snap target.
        XCTAssertEqual(MusicListScreen.letterSnapTarget(titles: mixed, from: 1, dir: 1), 2)
        XCTAssertEqual(MusicListScreen.letterSnapTarget(titles: mixed, from: 2, dir: 1), 3)
        XCTAssertEqual(MusicListScreen.letterSnapTarget(titles: mixed, from: 3, dir: 1), 4)
    }
}
