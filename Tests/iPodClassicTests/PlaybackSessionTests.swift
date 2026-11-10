import XCTest
@testable import iPodClassic

/// Persisted playback session codec + store round trip (launch restore
/// rebuilds the queue from these values).
final class PlaybackSessionTests: XCTestCase {
    private let key = "playback.session"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testRoundTrip() {
        let saved = PersistedPlayback(songIDs: ["a", "b", "c"], index: 1, playbackTime: 42.5)
        PlaybackSessionStore.save(saved)
        XCTAssertEqual(PlaybackSessionStore.load(), saved)
    }

    func testOverwriteKeepsLatest() {
        PlaybackSessionStore.save(PersistedPlayback(songIDs: ["x"], index: 0, playbackTime: 0))
        let latest = PersistedPlayback(songIDs: ["y", "z"], index: 1, playbackTime: 7)
        PlaybackSessionStore.save(latest)
        XCTAssertEqual(PlaybackSessionStore.load(), latest)
    }

    func testLoadMissingReturnsNil() {
        XCTAssertNil(PlaybackSessionStore.load())
    }

    func testClearRemovesSession() {
        PlaybackSessionStore.save(PersistedPlayback(songIDs: ["a"], index: 0, playbackTime: 1))
        PlaybackSessionStore.clear()
        XCTAssertNil(PlaybackSessionStore.load())
    }

    func testEmptyQueueIsNeverSaved() {
        // saveSession guards on an empty queue; mirror that here so the
        // store can't hold a session with no songs.
        let empty = PersistedPlayback(songIDs: [], index: 0, playbackTime: 0)
        PlaybackSessionStore.save(empty)
        XCTAssertNil(PlaybackSessionStore.load(), "an empty queue must not persist as a restorable session")
    }
}
