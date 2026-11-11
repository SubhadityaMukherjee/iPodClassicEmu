import XCTest
@testable import iPodClassic

/// The QA navigation harness and title bar: every documented START_ROUTE
/// name must resolve to a route (a broken mapping silently strands UI
/// tests on the home screen), unknown names must fail cleanly, and every
/// route must have a non-empty title-bar string.
final class RouteTests: XCTestCase {
    /// All names accepted by AppModel.route(named:) — keep in sync with
    /// the START_ROUTE documentation in AGENTS.md.
    static let documentedRoutes = [
        "home", "music", "coverflow", "albums", "songs", "playlists",
        "nowplaying", "photos", "camera", "recorder", "recordings",
        "notes", "noteEditor", "clocks", "calendar", "extras",
        "flashlight", "reader", "search", "alarm", "timer",
        "stopwatch", "settings", "clickwheel", "display", "playback",
    ]

    func testEveryDocumentedRouteNameResolves() {
        for name in Self.documentedRoutes {
            XCTAssertNotNil(AppModel.route(named: name),
                            "START_ROUTE=\(name) no longer resolves — QA/UI tests would strand on home")
        }
    }

    func testUnknownRouteNameReturnsNil() {
        XCTAssertNil(AppModel.route(named: "bogus"))
        XCTAssertNil(AppModel.route(named: ""))
    }

    @MainActor
    func testEveryRouteHasATitle() {
        let model = AppModel()
        let sample: [Route] = [
            .home, .music, .coverFlow, .musicAlbums, .musicSongs,
            .musicPlaylists, .nowPlaying, .photos, .camera, .recorder,
            .recordings, .notes, .noteEditor("QA Note"), .clocks,
            .calendar, .extras, .flashlight, .reader, .musicSearch,
            .alarm, .timer, .stopwatch, .settings,
            .settingsClickwheel, .settingsDisplay, .settingsPlayback,
            .artistSearch("x"), .transcript("Recording 2026-01-01.m4a"),
        ]
        for route in sample {
            model.stack = [route]
            let title = ScreenRouter.title(for: model)
            XCTAssertFalse(title.isEmpty, "\(route) has an empty title")
        }
    }

    @MainActor
    func testTitlesDistinguishSampleRoutes() {
        // Two obvious cases: the title bar must reflect the pushed screen.
        let model = AppModel()
        model.stack = [.music]
        let musicTitle = ScreenRouter.title(for: model)
        model.stack = [.settings]
        let settingsTitle = ScreenRouter.title(for: model)
        XCTAssertNotEqual(musicTitle, settingsTitle)
    }
}
