import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// Live binaural-beat synthesis: two pure sine tones, one per channel,
/// at carrier ± beat/2 — the brain perceives the difference as a slow
/// beat (same math as the classic web generators, carrier 200 Hz).
/// Rendered sample-by-sample by an AVAudioSourceNode; no audio files.
///
/// Concept: AVAudioSourceNode → docs/concepts/avfoundation-playback.md
@Observable
final class BinauralModel {
    /// A named beat frequency: one row of the preset list, and exactly the
    /// parameter the synthesizer needs — the Hz difference between the ears.
    struct Preset: Identifiable, Equatable {
        /// Display name ("Delta", "Schumann"…).
        let name: String
        /// Beat frequency in Hz — the left/right offset the brain perceives as a beat.
        let beat: Double
        /// Subtitle under the name in the list (e.g. "6 Hz · meditation").
        let detail: String
        /// Identity derived from `name`; Recents stores it to jump back to a preset.
        var id: String { name }
    }

    /// Factory presets from deep sleep up to high focus; Schumann is the
    /// classic 7.83 Hz "earth resonance" web-generator frequency.
    static let presets: [Preset] = [
        Preset(name: "Delta", beat: 3, detail: "3 Hz · deep sleep"),
        Preset(name: "Theta", beat: 6, detail: "6 Hz · meditation"),
        Preset(name: "Schumann", beat: 7.83, detail: "7.83 Hz · earth resonance"),
        Preset(name: "Alpha", beat: 10, detail: "10 Hz · relaxed focus"),
        Preset(name: "Beta", beat: 18, detail: "18 Hz · alert"),
        Preset(name: "Gamma", beat: 40, detail: "40 Hz · high focus"),
    ]

    /// The discrete volume steps the Volume row cycles through.
    static let volumeLevels: [Float] = [0.25, 0.5, 0.75, 1.0]
    /// Base frequency both ears sit around; 200 Hz, as in the classic generators.
    static let carrierHz = 200.0

    /// Preset of the current session, nil when off.
    private(set) var active: Preset?
    /// Whether a session is running and tones are audible.
    private(set) var isPlaying = false
    /// Seconds since the current session started (drives the row readout).
    private(set) var elapsed: TimeInterval = 0

    /// Audio backend; a protocol seam so unit tests can substitute a fake
    /// and never touch AVAudioEngine.
    private let engine: BinauralEngineType
    /// 1 Hz timer that advances `elapsed` while a session runs.
    private var ticker: Timer?
    /// UserDefaults suite persisting the volume index (injectable for tests).
    private let defaults: UserDefaults
    /// Home-screen Recents store; every session start records the preset
    /// so the home screen can jump back. Injectable so unit tests can
    /// redirect it (nil disables recording).
    private let recents: RecentActivity?

    /// Creates the model; every dependency is injectable for unit tests.
    /// - Parameter engine: audio backend (the real AVAudioEngine-based one by default).
    /// - Parameter defaults: persistence for the volume index.
    /// - Parameter recents: home-screen Recents store; nil disables session recording.
    init(engine: BinauralEngineType = BinauralAudioEngine(),
         defaults: UserDefaults = .standard,
         recents: RecentActivity? = RecentActivity.shared) {
        self.engine = engine
        self.defaults = defaults
        self.recents = recents
    }

    // MARK: Lock screen (Now Playing)

    /// Publishes the session to the system Now Playing card (lock screen /
    /// Control Center); nil clears it. Seam for unit tests.
    var nowPlayingPublisher: (_ title: String?, _ elapsed: TimeInterval) -> Void = { title, elapsed in
        let center = MPNowPlayingInfoCenter.default()
        if let title {
            center.nowPlayingInfo = [
                MPMediaItemPropertyTitle: title,
                MPMediaItemPropertyArtist: "iPod Classic",
                MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
                MPNowPlayingInfoPropertyPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            ]
            center.playbackState = .playing
        } else {
            center.nowPlayingInfo = nil
            // The audio session stays active (shared with music), and with
            // state .unknown the system keeps the app in the Now Playing
            // stack — the card lingered showing "playing" after stop.
            // .stopped explicitly removes it.
            center.playbackState = .stopped
        }
    }
    /// Tests disable system remote-command registration.
    var usesSystemRemoteCommands = true
    /// Guards `installRemoteCommands()` so handlers register only once
    /// per process (re-registering would stack duplicate handlers).
    private var remoteInstalled = false

    /// Registers lock-screen / Control Center handlers once per process:
    /// toggle/pause stop the session, play restarts the active preset.
    /// Next/previous and scrub are disabled — a fixed sine has no tracks
    /// or timeline.
    ///
    /// Concept: MPRemoteCommandCenter → docs/concepts/remote-commands.md
    private func installRemoteCommands() {
        guard usesSystemRemoteCommands, !remoteInstalled else { return }
        remoteInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if isPlaying { stop() } else if let active { toggle(active) }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.stop()
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            guard let self, !isPlaying, let active else { return .commandFailed }
            toggle(active)
            return .success
        }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    /// Pushes the current session (or a clear) to the lock-screen card.
    private func publishNowPlaying() {
        if isPlaying, let active {
            nowPlayingPublisher("Binaural · \(active.name)", elapsed)
        } else {
            nowPlayingPublisher(nil, 0)
        }
    }

    // MARK: Volume

    /// Persisted index into `volumeLevels`.
    var volumeIndex: Int {
        get { min(Self.volumeLevels.count - 1, max(0, defaults.integer(forKey: "binaural.volume"))) }
        set { defaults.set(newValue, forKey: "binaural.volume") }
    }

    /// Absolute volume of the current step in `volumeLevels`.
    var volume: Float { Self.volumeLevels[volumeIndex] }

    /// Advances to the next volume step (wrapping to the first) and
    /// applies it to the engine immediately.
    func cycleVolume() {
        volumeIndex = (volumeIndex + 1) % Self.volumeLevels.count
        engine.setVolume(volume)
    }

    // MARK: Playback

    /// Center on a preset row: starts it, stops it, or switches presets.
    func toggle(_ preset: Preset) {
        if isPlaying, active == preset {
            stop()
        } else {
            active = preset
            startPlayback()
        }
    }

    /// Recents jump-back: make sure this preset is playing — starts it or
    /// switches presets, but never stops an already-playing session.
    func resume(_ preset: Preset) {
        if isPlaying, active == preset { return }
        toggle(preset)
    }

    /// Ends the session: stops the engine (after its short fade), kills
    /// the ticker, zeroes `elapsed`, and clears the lock-screen card.
    func stop() {
        guard isPlaying else { return }
        isPlaying = false
        engine.stop()
        ticker?.invalidate()
        ticker = nil
        elapsed = 0
        publishNowPlaying()
    }

    /// Row readout: "Off", or "Delta · 0:42" while a session runs.
    var statusLine: String {
        guard isPlaying, let active else { return "Off" }
        return "\(active.name) · \(TimeFormat.hms(elapsed))"
    }

    /// Starts a session for `active` (set by the caller first): records
    /// the preset in Recents, zeroes the elapsed counter, starts the
    /// engine and the 1 Hz ticker, installs remote commands, and publishes
    /// the lock-screen card. The model is UI-driven — this all runs on the
    /// main thread and the ticker fires on the main run loop.
    private func startPlayback() {
        guard let active else { return }
        recents?.record(binaural: .init(id: active.name, title: active.name))
        elapsed = 0
        isPlaying = true
        engine.start(beat: active.beat, carrier: Self.carrierHz, volume: volume)
        installRemoteCommands()
        publishNowPlaying()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            elapsed += 1
            publishNowPlaying()
        }
    }
}

// MARK: - Engine seam

/// Audio-backend seam the model drives playback through, so unit tests
/// can substitute a silent fake for the real engine. Constrained to
/// `AnyObject` so holders share one engine instance rather than copying it.
protocol BinauralEngineType: AnyObject {
    /// Begins (or switches to) a beat/carrier pair at the given volume.
    /// - Parameter beat: beat frequency in Hz.
    /// - Parameter carrier: base frequency in Hz.
    /// - Parameter volume: amplitude, 0–1.
    func start(beat: Double, carrier: Double, volume: Float)
    /// Changes volume while running; takes effect on the next render call.
    func setVolume(_ volume: Float)
    /// Stops rendering; implementations should fade out to avoid a click.
    func stop()
}

/// AVAudioEngine + AVAudioSourceNode rendering two sines (carrier ± beat/2)
/// with a short click-free gain ramp on start and stop.
///
/// Concept: AVAudioSourceNode → docs/concepts/avfoundation-playback.md
final class BinauralAudioEngine: NSObject, BinauralEngineType {
    /// The AVAudioEngine the source node renders into (lazily started).
    private let engine = AVAudioEngine()
    /// Guards the render parameters below — the only state shared between
    /// the main thread and the real-time audio render callback.
    private let lock = NSLock()
    /// Beat frequency in Hz (clamped to 0.1–40 in `start`).
    private var beat = 0.0
    /// Carrier frequency in Hz (clamped to 50–2000 in `start`).
    private var carrier = BinauralModel.carrierHz
    /// Peak amplitude 0–1, pushed in from the model.
    private var volume: Float = 0.75
    /// Current amplitude after ramping; moves toward `targetGain` every frame.
    private var gain: Float = 0
    /// Amplitude the ramp aims at: 1 while playing, 0 while stopping.
    private var targetGain: Float = 0
    /// Left-ear sine phase accumulator, radians.
    private var phaseL = 0.0
    /// Right-ear sine phase accumulator, radians.
    private var phaseR = 0.0
    /// Output sample rate, captured when the node is installed.
    private var sampleRate = 44100.0
    /// Pending delayed engine stop (see `stop()`); cancelled when playback
    /// restarts during the fade window.
    private var stopWork: DispatchWorkItem?

    /// Sets the render parameters (clamped to the classic-generator
    /// ranges), targets full gain, resets both phases, and starts the
    /// engine if it is not running. Calling while already playing simply
    /// switches the tone — which is how preset changes work.
    func start(beat: Double, carrier: Double, volume: Float) {
        stopWork?.cancel()
        lock.lock()
        // The classic generators clamp beat 0.1–40 Hz, carrier 50–2000 Hz.
        self.beat = min(40, max(0.1, beat))
        self.carrier = min(2000, max(50, carrier))
        self.volume = volume
        targetGain = 1
        phaseL = 0
        phaseR = 0
        lock.unlock()
        if !engine.isRunning {
            if source == nil { installNode() }
            try? engine.start()
        }
    }

    /// Stores the new volume under the lock; the render loop snapshots it
    /// on its next callback.
    func setVolume(_ volume: Float) {
        lock.lock()
        self.volume = volume
        lock.unlock()
    }

    /// Fades toward silence, then stops the engine ~0.3 s later on the
    /// main queue so the fade is actually heard; a restart during that
    /// window cancels the pending stop.
    func stop() {
        lock.lock()
        targetGain = 0
        lock.unlock()
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            engine.stop()
            lock.lock()
            gain = 0
            phaseL = 0
            phaseR = 0
            lock.unlock()
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// The installed source node, kept so the engine is wired only once.
    private var source: AVAudioSourceNode?

    /// Creates the AVAudioSourceNode rendering in the output node's native
    /// format (so no sample-rate conversion is needed) and attaches +
    /// connects it to the engine — once per engine lifetime.
    private func installNode() {
        let output = engine.outputNode
        let format = output.inputFormat(forBus: 0)
        sampleRate = format.sampleRate
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            self.render(frames: Int(frameCount), into: audioBufferList)
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: output, format: format)
    }

    /// Real-time render: params are snapshotted under a brief lock, then
    /// the per-frame loop runs LOCK-FREE — the real-time audio thread must
    /// never hold a lock across work (priority inversion against the main
    /// thread showed up as a periodic artifact under the tones). Gain
    /// ramps per frame (~60 ms) for click-free start/stop; separate phase
    /// accumulators per ear.
    private func render(frames: Int, into bufferList: UnsafeMutablePointer<AudioBufferList>) {
        lock.lock()
        let beatHz = beat
        let carrierHz = carrier
        let vol = volume
        var g = gain
        let target = targetGain
        let stepL = 2 * Double.pi * (carrierHz - beatHz / 2) / sampleRate
        let stepR = 2 * Double.pi * (carrierHz + beatHz / 2) / sampleRate
        var l = phaseL
        var r = phaseR
        lock.unlock()

        let rampStep = Float(1.0 / max(0.06 * sampleRate, 1))
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        // Standard stereo output: buffer 0 = left, buffer 1 = right.
        if abl.count >= 2,
           let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
           let right = abl[1].mData?.assumingMemoryBound(to: Float.self) {
            for i in 0..<frames {
                if g < target { g = min(target, g + rampStep) }
                else if g > target { g = max(target, g - rampStep) }
                left[i] = Float(sin(l) * Double(vol) * Double(g))
                right[i] = Float(sin(r) * Double(vol) * Double(g))
                l += stepL
                r += stepR
                if l > 2 * Double.pi { l -= 2 * Double.pi }
                if r > 2 * Double.pi { r -= 2 * Double.pi }
            }
        }
        lock.lock()
        gain = g
        phaseL = l
        phaseR = r
        lock.unlock()
    }
}
