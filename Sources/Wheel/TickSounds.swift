import Foundation
import AudioToolbox
import AVFoundation

/// Plays the wheel tick / rubber-band sounds via AudioServices, which mix
/// cleanly over music without touching the audio session.
final class TickSounds {
    static let shared = TickSounds()

    private var tickID: SystemSoundID = 0
    private var softTickID: SystemSoundID = 0
    private var rubberID: SystemSoundID = 0

    private init() {
        tickID = Self.load("Tick")
        softTickID = Self.load("TickSoft")
        rubberID = Self.load("RubberBand")
    }

    private static func load(_ name: String) -> SystemSoundID {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else { return 0 }
        var id = SystemSoundID(0)
        AudioServicesCreateSystemSoundID(url as CFURL, &id)
        return id
    }

    func tick(soft: Bool) {
        let id = soft ? softTickID : tickID
        guard id != 0 else { return }
        AudioServicesPlaySystemSound(id)
    }

    func rubberBand() {
        guard rubberID != 0 else { return }
        AudioServicesPlaySystemSound(rubberID)
    }
}
