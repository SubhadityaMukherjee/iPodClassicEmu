import Foundation
import SwiftUI

/// All user preferences, UserDefaults-backed. Rendered under Settings.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard

    private func bool(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }
    private func int(_ key: String, _ def: Int) -> Int { d.object(forKey: key) as? Int ?? def }
    private func store(_ v: Any, _ key: String) { d.set(v, forKey: key) }

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
    }

    // MARK: Display

    var crtEnabled: Bool {
        get { bool(K.crt, true) } set { objectWillChange.send(); store(newValue, K.crt) }
    }
    /// Scanline intensity 0–3 (off, subtle, medium, strong).
    var scanlineIntensity: Int {
        get { int(K.scanlines, 1) } set { objectWillChange.send(); store(newValue, K.scanlines) }
    }
    /// Seconds of inactivity before the screen dims; 0 = never.
    var dimAfterSeconds: Int {
        get { int(K.dimAfter, 0) } set { objectWillChange.send(); store(newValue, K.dimAfter) }
    }

    // MARK: Clickwheel

    var hapticsEnabled: Bool {
        get { bool(K.haptics, true) } set { objectWillChange.send(); store(newValue, K.haptics) }
    }
    var scrollingHaptics: Int {
        get { int(K.scrollHaptics, 2) } set { objectWillChange.send(); store(newValue, K.scrollHaptics) }
    }
    var buttonHaptics: Int {
        get { int(K.buttonHaptics, 2) } set { objectWillChange.send(); store(newValue, K.buttonHaptics) }
    }
    var tickSounds: Bool {
        get { bool(K.tickSounds, true) } set { objectWillChange.send(); store(newValue, K.tickSounds) }
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
    var softTick: Bool {
        get { int(K.tickType, 0) == 1 } set { objectWillChange.send(); store(newValue ? 1 : 0, K.tickType) }
    }

    // MARK: Playback

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
    var cameraAspectIndex: Int {
        get { int(K.cameraAspect, 0) } set { objectWillChange.send(); store(newValue, K.cameraAspect) }
    }
    var cameraFront: Bool {
        get { int(K.cameraLens, 0) == 1 } set { objectWillChange.send(); store(newValue ? 1 : 0, K.cameraLens) }
    }

    static let aspectRatios: [(label: String, value: CGFloat)] = [
        ("1:1", 1), ("4:3", 4.0 / 3.0), ("16:9", 16.0 / 9.0),
    ]

    // MARK: Text size

    /// 0 small, 1 standard, 2 large — scales menu text and row heights.
    var fontScale: Int {
        get { int(K.fontScale, 1) } set { objectWillChange.send(); store(min(2, max(0, newValue)), K.fontScale) }
    }
    static let fontLabels = ["Small", "Standard", "Large"]
    static let fontScales: [CGFloat] = [0.85, 1.0, 1.18]
    var fontMultiplier: CGFloat {
        Self.fontScales[min(max(0, fontScale), Self.fontScales.count - 1)]
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
