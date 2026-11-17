import Foundation
import AudioToolbox
import AVFoundation

/// Plays the wheel tick / rubber-band sounds via AudioServices, which mix
/// cleanly over music without touching the audio session.
///
/// AudioServices (AudioToolbox) is chosen over AVAudioPlayer on
/// purpose: system sounds play through the system mixer, so ticks
/// overlay MusicKit playback without configuring AVAudioSession —
/// the app owns exactly one audio session (held by music playback),
/// and touching it here could interrupt that playback.
///
/// Concept: AudioToolbox → docs/concepts/audiotoolbox.md
/// Concept: AVAudioSession → docs/concepts/avfoundation-audio-session.md
final class TickSounds {
    /// Process-wide instance; the sounds load once on first access.
    static let shared = TickSounds()

    /// Regular tick sound handle; 0 means the bundle resource is missing.
    private var tickID: SystemSoundID = 0
    /// Quieter tick variant (the Soft Tick setting); 0 = missing resource.
    private var softTickID: SystemSoundID = 0
    /// Rubber-band edge-bounce sound handle; 0 = missing resource.
    private var rubberID: SystemSoundID = 0

    /// Loads all three sounds from the app bundle on first access.
    private init() {
        tickID = Self.load("Tick")
        softTickID = Self.load("TickSoft")
        rubberID = Self.load("RubberBand")
    }

    /// Creates a playable system-sound handle for a `.caf` resource in
    /// the main bundle.
    ///
    /// Returns 0 when the resource is missing — an invalid ID that
    /// callers treat as skip-playback — so a missing file degrades to
    /// silence, not a crash.
    ///
    /// - Parameter name: bundle resource base name, e.g. `Tick` for
    ///   Tick.caf.
    /// - Returns: a ready-to-play SystemSoundID, or 0 if the resource
    ///   is absent.
    private static func load(_ name: String) -> SystemSoundID {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else { return 0 }
        var id = SystemSoundID(0)
        AudioServicesCreateSystemSoundID(url as CFURL, &id)
        return id
    }

    /// Plays one scroll-detent tick.
    ///
    /// - Parameter soft: `true` selects the quieter TickSoft variant
    ///   (the Soft Tick setting).
    func tick(soft: Bool) {
        let id = soft ? softTickID : tickID
        guard id != 0 else { return }
        AudioServicesPlaySystemSound(id)
    }

    /// Plays the rubber-band sound for a list bouncing off its end;
    /// callers gate this on the Rubber Band Tick setting.
    func rubberBand() {
        guard rubberID != 0 else { return }
        AudioServicesPlaySystemSound(rubberID)
    }
}
