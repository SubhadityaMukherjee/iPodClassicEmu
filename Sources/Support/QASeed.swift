import Foundation

/// QA-only seed data so UI tests can exercise long-list scrolling without an
/// Apple Music library (MusicKit items can't be constructed app-side).
/// Active only when launched with FAKE_LIBRARY=1.
enum QASeed {
    struct FakeSong {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: Double
    }

    static var songs: [FakeSong] = []
    static var active: Bool { !songs.isEmpty }
}
