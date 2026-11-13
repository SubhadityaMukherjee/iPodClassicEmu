import XCTest
@testable import iPodClassic

/// Home-screen Recents: one jump-back entry per activity type, persisted
/// across launches, seeded rows via RECENTS_SEED for QA.
final class RecentActivityTests: XCTestCase {
    func testRecordPersistsAcrossInstances() {
        let name = "recents-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        defer { d.removePersistentDomain(forName: name) }

        let store = RecentActivity(defaults: d)
        store.record(book: .init(id: "b1", title: "A Book"))
        store.record(playlist: .init(id: "p1", title: "Chill"))
        store.record(album: .init(id: "a1", title: "An Album"))
        store.record(recording: .init(id: "r.m4a", title: "Memo"))
        store.record(clock: "stopwatch")

        let again = RecentActivity(defaults: d)
        XCTAssertEqual(again.book?.title, "A Book")
        XCTAssertEqual(again.playlist?.title, "Chill")
        XCTAssertEqual(again.album?.title, "An Album")
        XCTAssertEqual(again.recording?.title, "Memo")
        XCTAssertEqual(again.clock, "stopwatch")
    }

    func testLatestRecordWins() {
        let name = "recents-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        defer { d.removePersistentDomain(forName: name) }

        let store = RecentActivity(defaults: d)
        store.record(book: .init(id: "b1", title: "First"))
        store.record(book: .init(id: "b2", title: "Second"))
        let again = RecentActivity(defaults: d)
        XCTAssertEqual(again.book?.id, "b2", "the last book opened is the one remembered")
    }
}
