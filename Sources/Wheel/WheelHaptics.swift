import Foundation
import CoreHaptics
import UIKit

/// Haptic feedback for the click wheel. Scroll detents use CoreHaptics for
/// precise, low-latency transients; buttons use UIImpactFeedbackGenerator.
final class WheelHaptics {
    static let shared = WheelHaptics()

    private var engine: CHHapticEngine?
    private let buttonGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let strongButtonGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let notifyGenerator = UINotificationFeedbackGenerator()

    private init() {
        prepare()
    }

    private func prepare() {
        do {
            engine = try CHHapticEngine()
            engine?.resetHandler = { [weak self] in
                try? self?.engine?.start()
            }
            try engine?.start()
        } catch {
            engine = nil
        }
    }

    func ensureRunning() {
        if engine == nil { prepare(); return }
        try? engine?.start()
    }

    /// One scroll detent. intensity 0…1 mapped from the Scrolling Haptics setting.
    func tick(intensity: Double) {
        guard intensity > 0 else { return }
        let haptic = CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(max(0, min(1, intensity))))
        let sharp = CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(0.35 + intensity * 0.3))
        guard let engine else {
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        do {
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [haptic, sharp], relativeTime: 0)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try engine.start()
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    /// Button press. strength 0…1.
    func buttonPress(strength: Double) {
        if strength >= 0.8 {
            strongButtonGenerator.impactOccurred(intensity: 1.0)
        } else {
            buttonGenerator.impactOccurred(intensity: max(0.3, strength))
        }
    }

    func rubberBand() {
        notifyGenerator.notificationOccurred(.warning)
    }
}
