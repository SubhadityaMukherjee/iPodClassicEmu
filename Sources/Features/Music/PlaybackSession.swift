import Foundation

/// Playback state persisted across launches: the queue's song IDs in play
/// order, the current index, and the position inside the current track.
/// Restoring re-fetches real `Song` objects by ID (a Song can't be
/// constructed app-side), so tracks removed from the library drop out.
struct PersistedPlayback: Codable, Equatable {
    var songIDs: [String]
    var index: Int
    var playbackTime: Double
}

/// UserDefaults-backed store for `PersistedPlayback`. Written on
/// background/terminate and while playing (throttled); read once at launch.
enum PlaybackSessionStore {
    private static let key = "playback.session"

    static func save(_ session: PersistedPlayback) {
        // An empty queue is not a restorable session.
        guard !session.songIDs.isEmpty else { return }
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> PersistedPlayback? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedPlayback.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
