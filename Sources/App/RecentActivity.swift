import Foundation
import SwiftUI

/// Remembers the last item touched per activity type (book, playlist,
/// album, recording, clock) so the home screen's Recents section can
/// jump straight back with one click. Not a tracker — just the last
/// entry per type, persisted in UserDefaults.
///
/// @Observable so a screen writing a field re-renders the home Recents
/// rows automatically; a singleton because many screens record into it.
///
/// Concept: userdefaults → docs/concepts/userdefaults.md
@Observable
final class RecentActivity {
    /// Process-wide singleton; feature screens record into it as they open.
    static let shared = RecentActivity()

    /// One remembered item: an opaque identifier (book id, playlist id,
    /// recording file name…) plus the title shown on the Recents row.
    struct Entry: Codable, Equatable {
        var id: String
        var title: String
    }

    /// Last book opened (Recents jumps back into it in the reader).
    private(set) var book: Entry?
    /// Last playlist opened.
    private(set) var playlist: Entry?
    /// Last album opened.
    private(set) var album: Entry?
    /// Last voice memo opened.
    private(set) var recording: Entry?
    /// Last binaural preset played.
    private(set) var binaural: Entry?
    /// "timer" or "stopwatch" — whichever screen was opened last.
    private(set) var clock: String?

    /// UserDefaults key holding the JSON blob of all six fields.
    private let key = "recents.activity"
    /// Backing store; injectable so unit tests can pass an isolated suite.
    private let defaults: UserDefaults

    /// Loads the persisted recents (skipped gracefully on a fresh install)
    /// and honors the RECENTS_SEED QA hook.
    ///
    /// - Parameter defaults: backing user-defaults instance (`.standard`
    ///   in the app).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            book = saved.book
            playlist = saved.playlist
            album = saved.album
            recording = saved.recording
            binaural = saved.binaural
            clock = saved.clock
        }
        // QA hook: seed entries so the home Recents rows render in tests
        // and screenshots without real library data.
        if ProcessInfo.processInfo.environment["RECENTS_SEED"] == "1" {
            book = Entry(id: "qa.book", title: "QA Book")
            playlist = Entry(id: "qa.playlist", title: "QA Playlist")
            album = Entry(id: "qa.album", title: "QA Album")
            recording = Entry(id: "qa-recording.m4a", title: "QA Recording")
            binaural = Entry(id: "qa.binaural", title: "QA Binaural")
            clock = "timer"
        }
    }

    /// Codable snapshot of the six fields — exactly the shape persisted
    /// under `key`.
    private struct Saved: Codable {
        var book: Entry?
        var playlist: Entry?
        var album: Entry?
        var recording: Entry?
        var binaural: Entry?
        var clock: String?
    }

    /// Encodes all six fields to JSON and persists them in one write.
    private func save() {
        let saved = Saved(book: book, playlist: playlist, album: album,
                          recording: recording, binaural: binaural, clock: clock)
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: key)
        }
    }

    /// Remembers the last-opened book and persists immediately.
    func record(book: Entry) { self.book = book; save() }
    /// Remembers the last-opened playlist and persists immediately.
    func record(playlist: Entry) { self.playlist = playlist; save() }
    /// Remembers the last-opened album and persists immediately.
    func record(album: Entry) { self.album = album; save() }
    /// Remembers the last-opened voice memo and persists immediately.
    func record(recording: Entry) { self.recording = recording; save() }
    /// Remembers the last-played binaural preset and persists immediately.
    func record(binaural: Entry) { self.binaural = binaural; save() }
    /// Remembers "timer"/"stopwatch" (last clock screen) and persists.
    func record(clock: String) { self.clock = clock; save() }
}
