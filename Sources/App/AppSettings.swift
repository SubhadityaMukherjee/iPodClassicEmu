import Foundation
import SwiftUI

/// All user preferences, UserDefaults-backed. Rendered under Settings.
///
/// ObservableObject (not the newer @Observable macro) on purpose: these
/// are computed properties over UserDefaults, which macro-based tracking
/// cannot observe — so every setter fires `objectWillChange.send()` by
/// hand and views subscribe with `@EnvironmentObject`.
///
/// Concept: userdefaults → docs/concepts/userdefaults.md
final class AppSettings: ObservableObject {
    /// App-wide singleton so every screen reads and writes the same store.
    static let shared = AppSettings()

    /// Standard user defaults, kept as a one-letter shorthand below.
    private let d = UserDefaults.standard

    /// Reads a Bool, returning `def` when the key is unset (first launch).
    private func bool(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }
    /// Reads an Int, returning `def` when the key is unset (first launch).
    private func int(_ key: String, _ def: Int) -> Int { d.object(forKey: key) as? Int ?? def }
    /// Writes the value under its key.
    private func store(_ v: Any, _ key: String) { d.set(v, forKey: key) }

    /// UserDefaults key strings gathered as constants — one namespace,
    /// no typo'd magic strings at call sites; the trailing comments
    /// document each value's encoding.
    private enum K {
        static let crt = "display.crt"
        static let scanlines = "display.scanlines"
        static let dimAfter = "display.dimAfter"      // seconds; 0 = never
        static let haptics = "wheel.haptics"
        static let scrollHaptics = "wheel.scrollHaptics" // 0 off 1 light 2 medium 3 strong
        static let buttonHaptics = "wheel.buttonHaptics" // 0 light 1 medium 2 heavy
        static let tickSounds = "wheel.tickSounds"
        static let infiniteTick = "wheel.infiniteTick"
        static let rubberBand = "wheel.rubberBand"
        static let tickType = "wheel.tickType"        // 0 classic 1 soft
        static let shuffle = "playback.shuffle"
        static let repeatMode = "playback.repeat"     // 0 off 1 all 2 one
        static let volumeSteps = "playback.volumeSteps"
        static let cameraFlash = "camera.flash"       // 0 off 1 on 2 auto
        static let cameraAspect = "camera.aspect"     // index into aspect list
        static let cameraLens = "camera.lens"         // 0 back 1 front
        static let theme = "device.theme"             // 0 black 1 silver
        static let fontScale = "display.fontScale"    // 0 small 1 standard 2 large
        static let songSort = "music.sort.songs"      // 0 title 1 artist 2 duration 3 recent
        static let albumSort = "music.sort.albums"    // 0 title 1 artist 2 recent
        static let noteFont = "notes.fontSize"        // points; note editor text
        static let audiobookVoicePrefix = "audiobook.voice."  // + engine id → per-engine voice
        static let audiobookSpeed = "audiobook.speed"     // index into AudiobookModel.speeds
        static let audiobookVolume = "audiobook.volume"  // index into AudiobookModel.volumes
        static let readAloudEngine = "readaloud.engine"  // "paradee" default; "pocket18"|"pocket100"
    }

    // MARK: Display

    /// CRT screen glow effect on/off.
    var crtEnabled: Bool {
        get { bool(K.crt, true) } set { objectWillChange.send(); store(newValue, K.crt) }
    }
    /// Scanline intensity 0–3 (off, subtle, medium, strong).
    var scanlineIntensity: Int {
        get { int(K.scanlines, 2) } set { objectWillChange.send(); store(newValue, K.scanlines) }
    }
    /// Seconds of inactivity before the screen dims; 0 = never.
    var dimAfterSeconds: Int {
        get { int(K.dimAfter, 0) } set { objectWillChange.send(); store(newValue, K.dimAfter) }
    }

    // MARK: Audiobook (read aloud)

    /// Read Aloud TTS engine ("paradee" default — device-verified
    /// 2026-11-19, af_heart voice; "pocket18"/"pocket100" selectable).
    var readAloudEngine: String {
        get { d.string(forKey: K.readAloudEngine) ?? "paradee" }
        set { objectWillChange.send(); store(newValue, K.readAloudEngine) }
    }
    /// Read Aloud voice preset for ONE engine (key `audiobook.voice.<engine>`)
    /// so each engine remembers its own choice; "" = not chosen yet (use
    /// the engine's first preset).
    func audiobookVoice(engine: String) -> String {
        d.string(forKey: K.audiobookVoicePrefix + engine) ?? ""
    }
    /// Persists the chosen voice for an engine (see `audiobookVoice(engine:)`).
    func setAudiobookVoice(_ name: String, engine: String) {
        objectWillChange.send()
        store(name, K.audiobookVoicePrefix + engine)
    }
    /// Playback speed; index into AudiobookModel.speeds.
    var audiobookSpeedIndex: Int {
        get { int(K.audiobookSpeed, 1) }
        set { objectWillChange.send(); store(newValue, K.audiobookSpeed) }
    }
    /// Read-aloud volume; index into AudiobookModel.volumes.
    var audiobookVolumeIndex: Int {
        get { int(K.audiobookVolume, 2) }
        set { objectWillChange.send(); store(newValue, K.audiobookVolume) }
    }

    // MARK: Clickwheel

    /// Master switch for wheel haptics.
    var hapticsEnabled: Bool {
        get { bool(K.haptics, true) } set { objectWillChange.send(); store(newValue, K.haptics) }
    }
    /// Scroll-tick haptic strength: 0 off, 1 light, 2 medium, 3 strong.
    var scrollingHaptics: Int {
        get { int(K.scrollHaptics, 3) } set { objectWillChange.send(); store(newValue, K.scrollHaptics) }
    }
    /// Button-press haptic strength: 0 light, 1 medium, 2 heavy.
    var buttonHaptics: Int {
        get { int(K.buttonHaptics, 2) } set { objectWillChange.send(); store(newValue, K.buttonHaptics) }
    }
    /// Audible click on each wheel detent.
    var tickSounds: Bool {
        get { bool(K.tickSounds, false) } set { objectWillChange.send(); store(newValue, K.tickSounds) }
    }
    /// Allow the wheel to keep ticking past the end of a list (list wraps).
    /// Off by default: lists stop at the ends like a real iPod.
    var infiniteTick: Bool {
        get { bool(K.infiniteTick, false) } set { objectWillChange.send(); store(newValue, K.infiniteTick) }
    }
    /// Play the rubber-band sound when ticking past the end of a list.
    var rubberBandTick: Bool {
        get { bool(K.rubberBand, true) } set { objectWillChange.send(); store(newValue, K.rubberBand) }
    }
    /// Use the softer tick sound variant while scrolling (vs. the regular tick).
    var softTick: Bool {
        get { int(K.tickType, 0) == 1 } set { objectWillChange.send(); store(newValue ? 1 : 0, K.tickType) }
    }

    // MARK: Playback

    /// Shuffle the playback queue.
    var shuffle: Bool {
        get { bool(K.shuffle, false) } set { objectWillChange.send(); store(newValue, K.shuffle) }
    }
    /// 0 off, 1 all, 2 one.
    var repeatMode: Int {
        get { int(K.repeatMode, 0) } set { objectWillChange.send(); store(newValue, K.repeatMode) }
    }
    /// Volume change per wheel tick, in 0…1 volume units.
    var volumeStep: Double {
        get { Double(int(K.volumeSteps, 6)) / 100.0 } set { objectWillChange.send(); store(Int(newValue * 100), K.volumeSteps) }
    }

    // MARK: Camera

    /// 0 off, 1 on, 2 auto.
    var cameraFlash: Int {
        get { int(K.cameraFlash, 2) } set { objectWillChange.send(); store(newValue, K.cameraFlash) }
    }
    /// Selected capture aspect ratio; index into `aspectRatios`.
    var cameraAspectIndex: Int {
        get { int(K.cameraAspect, 0) } set { objectWillChange.send(); store(newValue, K.cameraAspect) }
    }
    /// True when the front lens is selected (persisted as the Int 0/1).
    var cameraFront: Bool {
        get { int(K.cameraLens, 0) == 1 } set { objectWillChange.send(); store(newValue ? 1 : 0, K.cameraLens) }
    }

    /// Capture aspect choices, display label paired with width/height.
    static let aspectRatios: [(label: String, value: CGFloat)] = [
        ("1:1", 1), ("4:3", 4.0 / 3.0), ("16:9", 16.0 / 9.0),
    ]

    // MARK: Text size

    /// 0 small, 1 standard, 2 large — scales menu text and row heights.
    var fontScale: Int {
        get { int(K.fontScale, 0) } set { objectWillChange.send(); store(min(2, max(0, newValue)), K.fontScale) }
    }
    /// Display names for the three text sizes.
    static let fontLabels = ["Small", "Standard", "Large"]
    /// Scale multipliers matching `fontLabels` by index.
    static let fontScales: [CGFloat] = [0.85, 1.0, 1.18]
    /// Ready-to-use text scale factor for the current `fontScale`
    /// (index clamped into range).
    var fontMultiplier: CGFloat {
        Self.fontScales[min(max(0, fontScale), Self.fontScales.count - 1)]
    }

    // MARK: Notes

    /// Note editor text size in points (11…24).
    var noteFontSize: Int {
        get { int(K.noteFont, 14) } set { objectWillChange.send(); store(min(24, max(11, newValue)), K.noteFont) }
    }

    // MARK: Music sorting

    /// Sort order for the Songs list: 0 Title, 1 Artist, 2 Duration, 3 Recently Added.
    var songSort: Int {
        get { int(K.songSort, 0) } set { objectWillChange.send(); store(min(3, max(0, newValue)), K.songSort) }
    }
    /// Sort order for the Albums list: 0 Title, 1 Artist, 2 Recently Added.
    var albumSort: Int {
        get { int(K.albumSort, 0) } set { objectWillChange.send(); store(min(2, max(0, newValue)), K.albumSort) }
    }

    /// Device theme: 0 black, 1 silver.
    var theme: Int {
        get { int(K.theme, 0) } set { objectWillChange.send(); store(min(1, max(0, newValue)), K.theme) }
    }
}
