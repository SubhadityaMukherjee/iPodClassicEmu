import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// Live binaural-beat synthesis: two pure sine tones, one per channel,
/// at carrier ± beat/2 — the brain perceives the difference as a slow
/// beat (same math as the classic web generators, carrier 200 Hz).
/// Rendered sample-by-sample by an AVAudioSourceNode; no audio files.
@Observable
final class BinauralModel {
    struct Preset: Identifiable, Equatable {
        let name: String
        let beat: Double
        let detail: String
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Delta", beat: 3, detail: "3 Hz · deep sleep"),
        Preset(name: "Theta", beat: 6, detail: "6 Hz · meditation"),
        Preset(name: "Schumann", beat: 7.83, detail: "7.83 Hz · earth resonance"),
        Preset(name: "Alpha", beat: 10, detail: "10 Hz · relaxed focus"),
        Preset(name: "Beta", beat: 18, detail: "18 Hz · alert"),
        Preset(name: "Gamma", beat: 40, detail: "40 Hz · high focus"),
    ]

    static let volumeLevels: [Float] = [0.25, 0.5, 0.75, 1.0]
    static let carrierHz = 200.0

    private(set) var active: Preset?
    private(set) var isPlaying = false
    /// Seconds since the current session started (drives the row readout).
    private(set) var elapsed: TimeInterval = 0

    private let engine: BinauralEngineType
    private var ticker: Timer?
    private let defaults: UserDefaults

    init(engine: BinauralEngineType = BinauralAudioEngine(), defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
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
        } else {
            center.nowPlayingInfo = nil
        }
    }
    /// Tests disable system remote-command registration.
    var usesSystemRemoteCommands = true
    private var remoteInstalled = false

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

    var volume: Float { Self.volumeLevels[volumeIndex] }

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

    func stop() {
        guard isPlaying else { return }
        isPlaying = false
        engine.stop()
        ticker?.invalidate()
        ticker = nil
        elapsed = 0
        publishNowPlaying()
    }

    var statusLine: String {
        guard isPlaying, let active else { return "Off" }
        return "\(active.name) · \(TimeFormat.hms(elapsed))"
    }

    private func startPlayback() {
        guard let active else { return }
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

protocol BinauralEngineType: AnyObject {
    func start(beat: Double, carrier: Double, volume: Float)
    func setVolume(_ volume: Float)
    func stop()
}

/// AVAudioEngine + AVAudioSourceNode rendering two sines (carrier ± beat/2)
/// with a short click-free gain ramp on start and stop.
final class BinauralAudioEngine: NSObject, BinauralEngineType {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var beat = 0.0
    private var carrier = BinauralModel.carrierHz
    private var volume: Float = 0.75
    private var gain: Float = 0
    private var targetGain: Float = 0
    private var phaseL = 0.0
    private var phaseR = 0.0
    private var sampleRate = 44100.0
    private var stopWork: DispatchWorkItem?

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

    func setVolume(_ volume: Float) {
        lock.lock()
        self.volume = volume
        lock.unlock()
    }

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

    private var source: AVAudioSourceNode?

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
