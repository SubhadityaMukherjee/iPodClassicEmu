import Foundation
import SwiftUI

/// Remembers the last item touched per activity type (book, playlist,
/// album, recording, clock) so the home screen's Recents section can
/// jump straight back with one click. Not a tracker — just the last
/// entry per type, persisted in UserDefaults.
@Observable
final class RecentActivity {
    static let shared = RecentActivity()

    struct Entry: Codable, Equatable {
        var id: String
        var title: String
    }

    private(set) var book: Entry?
    private(set) var playlist: Entry?
    private(set) var album: Entry?
    private(set) var recording: Entry?
    /// "timer" or "stopwatch" — whichever screen was opened last.
    private(set) var clock: String?

    private let key = "recents.activity"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            book = saved.book
            playlist = saved.playlist
            album = saved.album
            recording = saved.recording
            clock = saved.clock
        }
        // QA hook: seed entries so the home Recents rows render in tests
        // and screenshots without real library data.
        if ProcessInfo.processInfo.environment["RECENTS_SEED"] == "1" {
            book = Entry(id: "qa.book", title: "QA Book")
            playlist = Entry(id: "qa.playlist", title: "QA Playlist")
            album = Entry(id: "qa.album", title: "QA Album")
            recording = Entry(id: "qa-recording.m4a", title: "QA Recording")
            clock = "timer"
        }
    }

    private struct Saved: Codable {
        var book: Entry?
        var playlist: Entry?
        var album: Entry?
        var recording: Entry?
        var clock: String?
    }

    private func save() {
        let saved = Saved(book: book, playlist: playlist, album: album,
                          recording: recording, clock: clock)
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: key)
        }
    }

    func record(book: Entry) { self.book = book; save() }
    func record(playlist: Entry) { self.playlist = playlist; save() }
    func record(album: Entry) { self.album = album; save() }
    func record(recording: Entry) { self.recording = recording; save() }
    func record(clock: String) { self.clock = clock; save() }
}
