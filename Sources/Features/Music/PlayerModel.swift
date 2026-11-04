import Foundation
import MusicKit

/// Playback over ApplicationMusicPlayer: queue bookkeeping, transport
/// controls, volume, and scrubbing, with a timer polling player state.
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

    // MARK: Queue

    func play(_ songs: [Song], startingAt index: Int = 0) {
        guard !songs.isEmpty else { return }
        queue = songs
        queueIndex = min(max(0, index), songs.count - 1)
        guard let start = currentSong else { return }
        player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: start)
        MediaVolumeController.shared.setVolume(Float(volume))
        Task {
            try? await player.play()
            self.isPlaying = true
        }
        startTimer()
    }

    func shufflePlay(_ songs: [Song]) {
        let shuffled = songs.shuffled()
        play(shuffled, startingAt: 0)
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
        guard queueIndex < queue.count - 1 else {
            // At the end: stop.
            Task { try? await player.pause() }
            isPlaying = false
            return
        }
        queueIndex += 1
        restartCurrent()
    }

    func previous() {
        if playbackTime > 3 {
            scrub(to: 0)
            return
        }
        guard queueIndex > 0 else { return }
        queueIndex -= 1
        restartCurrent()
    }

    private func restartCurrent() {
        guard let start = currentSong else { return }
        player.queue = ApplicationMusicPlayer.Queue(for: queue, startingAt: start)
        playbackTime = 0
        Task {
            try? await player.play()
            self.isPlaying = true
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
            let status = self.player.state.playbackStatus
            self.isPlaying = status == .playing
            self.playbackTime = self.player.playbackTime

            // Track ended: advance (MusicKit usually auto-advances; this is a backstop).
            if self.isPlaying, self.duration > 0, self.playbackTime >= self.duration - 0.35 {
                // Nothing to do: MusicKit advances the queue itself; refresh bookkeeping.
            }
        }
    }
}
