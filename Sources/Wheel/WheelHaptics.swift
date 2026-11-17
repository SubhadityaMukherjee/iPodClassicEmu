import Foundation
import CoreHaptics
import UIKit

/// Haptic feedback for the click wheel. Scroll detents use CoreHaptics for
/// precise, low-latency transients; buttons use UIImpactFeedbackGenerator.
///
/// The split is deliberate: CoreHaptics transients fire with precise
/// timing at tick rate (up to ~50/s) and expose continuous
/// intensity/sharpness, while UIKit's generators are system-tuned
/// one-shots that need no engine management — ideal for button
/// presses. When no haptic engine is available, everything degrades
/// to the UIKit generators.
///
/// Concept: CoreHaptics → docs/concepts/corehaptics.md
final class WheelHaptics {
    /// Process-wide instance; owns the app's single CHHapticEngine.
    static let shared = WheelHaptics()

    /// The shared engine; nil when creation or start failed (hardware
    /// without CoreHaptics support) — feedback then falls back to the
    /// UIKit generators below.
    private var engine: CHHapticEngine?
    /// Reusable players per intensity level. Building a CHHapticPattern +
    /// player on every detent (the old code) allocates at tick rate — up to
    /// ~50/s on a fast spin — and shows up as haptic latency on device.
    private var players: [Double: CHHapticPatternPlayer] = [:]
    /// Standard (medium) impacts for button presses below 0.8 strength.
    private let buttonGenerator = UIImpactFeedbackGenerator(style: .medium)
    /// Heavy impacts for strong button presses (strength >= 0.8).
    private let strongButtonGenerator = UIImpactFeedbackGenerator(style: .heavy)
    /// Notification buzz reused for the rubber-band edge hit.
    private let notifyGenerator = UINotificationFeedbackGenerator()

    /// Prepares the engine on first access so the earliest detent
    /// doesn't pay engine-start latency.
    private init() {
        prepare()
    }

    /// Creates and starts the engine. The reset handler restarts it
    /// when the system stops it (e.g. after backgrounding) and drops
    /// the cached players — they belonged to the old engine instance.
    /// Any throw leaves `engine` nil, switching all feedback to the
    /// UIKit fallbacks.
    private func prepare() {
        do {
            engine = try CHHapticEngine()
            engine?.resetHandler = { [weak self] in
                self?.players = [:]  // old players belong to the dead engine
                try? self?.engine?.start()
            }
            try engine?.start()
        } catch {
            engine = nil
        }
    }

    /// Makes sure the engine is started before feedback: the system
    /// may stop a CoreHaptics engine at any time, and starting an
    /// already-running engine is cheap, so callers can invoke this
    /// unconditionally.
    func ensureRunning() {
        if engine == nil { prepare(); return }
        try? engine?.start()
    }

    /// One scroll detent. intensity 0…1 mapped from the Scrolling Haptics
    /// setting. Intensity takes only a few distinct values (the settings
    /// ladder), so players are built once per level and reused.
    ///
    /// Falls back to a UIKit selection tick whenever the engine is
    /// nil or building the pattern/player throws.
    func tick(intensity: Double) {
        guard intensity > 0 else { return }
        guard let engine else {
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        let player: CHHapticPatternPlayer
        if let cached = players[intensity] {
            player = cached
        } else {
            let haptic = CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(max(0, min(1, intensity))))
            let sharp = CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(0.35 + intensity * 0.3))
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [haptic, sharp], relativeTime: 0)
            do {
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                player = try engine.makePlayer(with: pattern)
                players[intensity] = player
            } catch {
                UISelectionFeedbackGenerator().selectionChanged()
                return
            }
        }
        do {
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    /// Button press. strength 0…1.
    ///
    /// - Parameter strength: 0…1, from the Button Haptics setting;
    ///   >= 0.8 uses the heavy style, otherwise the medium style
    ///   scaled by strength.
    func buttonPress(strength: Double) {
        if strength >= 0.8 {
            strongButtonGenerator.impactOccurred(intensity: 1.0)
        } else {
            buttonGenerator.impactOccurred(intensity: max(0.3, strength))
        }
    }

    /// Warning-strength buzz marking a list hitting its edge
    /// (rubber-band bounce); callers gate it on the Rubber Band Tick
    /// setting.
    func rubberBand() {
        notifyGenerator.notificationOccurred(.warning)
    }
}
