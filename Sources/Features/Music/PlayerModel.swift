import Foundation
import MusicKit

/// Playback over ApplicationMusicPlayer: queue bookkeeping, transport
/// controls, volume, and scrubbing, with a timer polling player state.
///
/// The player owns the real queue (including MusicKit's internal shuffle
/// order); `queue`/`queueIndex` are bookkeeping that follows
/// `player.queue.currentEntry`, so auto-advance — including in the
/// background — keeps the UI in sync.
@Observable
final class PlayerModel {
    private let player = ApplicationMusicPlayer.shared

    private(set) var queue: [Song] = []
    private(set) var queueIndex = 0
    private(set) var isPlaying = false
    private(set) var playbackTime: Double = 0
    private(set) var volume: Double = 0.5

    var currentSong: Song? {
        queue.indices.contains(queueIndex) ? queue[queueIndex] : nil
    }

    var duration: Double { currentSong?.duration ?? 0 }

    private var timer: Timer?

    init() {
        // Start from the real system volume so the wheel doesn't snap it.
        let sys = MediaVolumeController.shared.systemVolume
        volume = Double(min(max(sys, 0), 1))
    }

    // MARK: Queue

    func play(_ songs: [Song], startingAt index: Int = 0) {
        guard !songs.isEmpty else { return }
        queue = songs
        queueIndex = min(max(0, index), songs.count - 1)
        guard let start = currentSong else { return }
        applyPlaybackSettings()
        player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: start)
        Task {
            try? await player.play()
            self.isPlaying = true
        }
        startTimer()
    }

    /// Applies the Settings choices (shuffle/repeat) to the player state.
    private func applyPlaybackSettings() {
        let s = AppSettings.shared
        player.state.repeatMode = {
            switch s.repeatMode {
            case 1: return .all
            case 2: return .one
            default: return .none
            }
        }()
        player.state.shuffleMode = s.shuffle ? .songs : .off
    }

    func shufflePlay(_ songs: [Song]) {
        let shuffled = songs.shuffled()
        play(shuffled, startingAt: 0)
    }

    /// Song carried by a queue entry, if any.
    private func entrySong(_ entry: MusicPlayer.Queue.Entry) -> Song? {
        if case .song(let song) = entry.item { return song }
        return nil
    }

    /// Position of `currentEntry` in the play queue (play order, so this
    /// follows MusicKit's internal shuffle).
    private func currentEntryPosition() -> Int? {
        guard let current = player.queue.currentEntry else { return nil }
        return player.queue.entries.firstIndex { $0.id == current.id }
    }

    /// Reconciles the UI bookkeeping with the player's real position.
    /// Matched by song identity, not entry IDs (entry IDs captured at
    /// queue-assignment time don't survive skip/auto-advance reliably).
    private func syncFromPlayer() {
        guard let current = player.queue.currentEntry,
              let song = entrySong(current),
              let qi = queue.firstIndex(where: { $0.id == song.id }),
              qi != queueIndex else { return }
        queueIndex = qi
        playbackTime = player.playbackTime
    }

    // MARK: Queue feature ("hold to add to queue")

    /// One row of the Up Next list (queue entries in play order).
    struct UpNextItem: Identifiable {
        let id: String
        let title: String
        let artist: String
        let isCurrent: Bool
    }

    /// Everything in the play queue, current entry first highlighted.
    var upNext: [UpNextItem] {
        let currentID = player.queue.currentEntry?.id
        return player.queue.entries.map { entry in
            let title: String
            let artist: String
            if case .song(let song) = entry.item {
                title = song.title
                artist = song.artistName
            } else {
                title = entry.title
                artist = entry.subtitle ?? ""
            }
            return UpNextItem(id: entry.id, title: title, artist: artist, isCurrent: entry.id == currentID)
        }
    }

    /// Adds a song to play immediately after the current one.
    /// Returns false when nothing is playing (no queue to attach to).
    @discardableResult
    func addToQueue(_ song: Song) -> Bool {
        guard isPlaying else { return false }
        Task { try? await player.queue.insert(song, position: .afterCurrentEntry) }
        return true
    }

    /// Jumps playback to an entry (Up Next selection).
    func jump(to entryID: String) {
        let entries = player.queue.entries
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else { return }
        player.queue.currentEntry = entries[idx]
        Task {
            try? await player.play()
            self.syncFromPlayer()
        }
    }

    // MARK: Transport

    func togglePlayPause() {
        if isPlaying {
            Task {
                try? await player.pause()
                self.isPlaying = false
            }
        } else {
            Task {
                try? await player.play()
                self.isPlaying = true
            }
        }
        startTimer()
    }

    func next() {
        // Walk the player's own entry list (play order, so this follows
        // its internal shuffle); never rebuild the queue here — that
        // would reshuffle what's left.
        let entries = player.queue.entries
        if let pos = currentEntryPosition(), entries.index(after: pos) < entries.endIndex {
            player.queue.currentEntry = entries[entries.index(after: pos)]
            Task {
                try? await player.play()
                self.syncFromPlayer()
            }
        } else {
            Task { try? await player.pause() }
            isPlaying = false
        }
    }

    func previous() {
        if playbackTime > 3 {
            scrub(to: 0)
            return
        }
        let entries = player.queue.entries
        if let pos = currentEntryPosition(), pos > entries.startIndex {
            player.queue.currentEntry = entries[entries.index(before: pos)]
            Task {
                try? await player.play()
                self.syncFromPlayer()
            }
        } else {
            scrub(to: 0)
        }
    }

    func scrub(to time: Double) {
        let t = min(max(0, time), duration)
        player.playbackTime = t
        playbackTime = t
    }

    func setVolume(_ v: Double) {
        volume = min(1, max(0, v))
        MediaVolumeController.shared.setVolume(Float(volume))
    }

    func bumpVolume(_ delta: Double) {
        setVolume(volume + delta)
    }

    // MARK: State polling

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.isPlaying = self.player.state.playbackStatus == .playing
            self.playbackTime = self.player.playbackTime
            // Follow MusicKit's auto-advance (works while backgrounded too).
            self.syncFromPlayer()
        }
    }
}
