import Foundation
import MediaPlayer
import AVFoundation
import UIKit

/// Sets the app-audible playback volume. ApplicationMusicPlayer no longer
/// exposes `volume`, so we drive a hidden MPVolumeView slider (the supported
/// way to set volume from an app) and read back via AVAudioSession.
final class MediaVolumeController {
    static let shared = MediaVolumeController()

    private var volumeView: MPVolumeView?

    var systemVolume: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    func setVolume(_ value: Float) {
        let clamped = min(max(0, value), 1)
        guard let slider = volumeSlider() else { return }
        DispatchQueue.main.async {
            slider.setValue(clamped, animated: false)
        }
    }

    private func volumeSlider() -> UISlider? {
        if volumeView == nil {
            let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
            view.alpha = 0.01
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) {
                window.addSubview(view)
                volumeView = view
            }
        }
        // The slider appears asynchronously after MPVolumeView is added.
        if let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first {
            return slider
        }
        return nil
    }
}
