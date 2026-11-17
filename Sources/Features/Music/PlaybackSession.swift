import Foundation

/// Playback state persisted across launches: the queue's song IDs in play
/// order, the current index, and the position inside the current track.
/// Restoring re-fetches real `Song` objects by ID (a Song can't be
/// constructed app-side), so tracks removed from the library drop out.
struct PersistedPlayback: Codable, Equatable {
    /// Queue song IDs in play order — IDs (not Song values) are the
    /// persistable form; restore re-fetches real songs by ID.
    var songIDs: [String]
    /// Index into `songIDs` of the track that was playing.
    var index: Int
    /// Position inside the current track, in seconds.
    var playbackTime: Double
}

/// UserDefaults-backed store for `PersistedPlayback`. Written on
/// background/terminate and while playing (throttled); read once at launch.
enum PlaybackSessionStore {
    /// UserDefaults key holding the JSON-encoded session.
    private static let key = "playback.session"

    /// Encodes the session as JSON and stores it in UserDefaults.
    ///
    /// Concept: UserDefaults → docs/concepts/userdefaults.md
    /// - Parameter session: The session to persist; an empty queue is
    ///   ignored (it isn't restorable).
    static func save(_ session: PersistedPlayback) {
        // An empty queue is not a restorable session.
        guard !session.songIDs.isEmpty else { return }
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Reads and decodes the persisted session.
    /// - Returns: The saved session, or nil when nothing is stored or the
    ///   data fails to decode.
    static func load() -> PersistedPlayback? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedPlayback.self, from: data)
    }

    /// Removes the persisted session entirely.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
