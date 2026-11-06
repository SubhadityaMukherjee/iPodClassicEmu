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

    /// Static track info for QA screenshots of Now Playing (real playback
    /// is impossible in the simulator — ApplicationMusicPlayer is a no-op
    /// without a library).
    static let previewSong = (title: "Africa", artist: "Toto", album: "Toto IV")
    static let previewDuration = 295.0
    static let previewTime = 96.0

    /// Notes editor QA target (START_ROUTE=noteEditor + NOTES_QA=1): a fixed
    /// note name the editor fills with numbered scroll-test text.
    static let qaNoteName = "QA Note"
}
