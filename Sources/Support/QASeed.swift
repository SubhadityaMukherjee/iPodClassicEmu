import Foundation

/// QA-only seed data so UI tests can exercise long-list scrolling without an
/// Apple Music library (MusicKit items can't be constructed app-side).
/// Active only when launched with FAKE_LIBRARY=1.
enum QASeed {
    /// Plain-value stand-in for a MusicKit `Song`. The fake library is
    /// built from these because real library items cannot be constructed
    /// app-side.
    struct FakeSong {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: Double
    }

    /// The fake song library. Populated by `MusicService` (300 generated
    /// tracks) when launched with FAKE_LIBRARY=1; empty in normal runs.
    static var songs: [FakeSong] = []
    /// True while the fake library is loaded — screens branch on this to
    /// render QA data instead of MusicKit results.
    static var active: Bool { !songs.isEmpty }

    /// Static track info for QA screenshots of Now Playing (real playback
    /// is impossible in the simulator — ApplicationMusicPlayer is a no-op
    /// without a library).
    static let previewSong = (title: "Africa", artist: "Toto", album: "Toto IV")
    /// Fake track length matching `previewSong` (4:55).
    static let previewDuration = 295.0
    /// Fake playhead offset so the progress bar and time readout aren't
    /// at zero in screenshots.
    static let previewTime = 96.0

    /// Notes editor QA target (START_ROUTE=noteEditor + NOTES_QA=1): a fixed
    /// note name the editor fills with numbered scroll-test text.
    static let qaNoteName = "QA Note"
    /// Recording the transcript QA route opens (must exist in
    /// Documents/Recordings together with a done sidecar entry — seed
    /// both via SIMCTL before a transcript screenshot run).
    static let transcriptFileName = "Recording 2026-11-10 22-56-12.m4a"
}
