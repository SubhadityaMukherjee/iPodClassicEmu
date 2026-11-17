import Foundation
import MediaPlayer
import AVFoundation
import UIKit

/// Sets the app-audible playback volume. ApplicationMusicPlayer no longer
/// exposes `volume`, so we drive a hidden MPVolumeView slider (the supported
/// way to set volume from an app) and read back via AVAudioSession.
final class MediaVolumeController {
    /// Process-wide instance; the hidden MPVolumeView must stay attached
    /// to a window to keep working, so exactly one owner creates and keeps
    /// it.
    static let shared = MediaVolumeController()

    /// Offscreen MPVolumeView lazily attached to the key window; owns the
    /// UISlider we drive.
    private var volumeView: MPVolumeView?

    /// The system-wide output volume (0–1) — ApplicationMusicPlayer exposes
    /// no volume of its own, so this is the effective playback volume.
    ///
    /// Concept: AVAudioSession → docs/concepts/avfoundation-audio-session.md
    var systemVolume: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    /// Sets the app-audible volume by setting the hidden slider's value —
    /// the only supported programmatic path. The system volume HUD stays
    /// suppressed because the view sits far offscreen.
    ///
    /// Concept: MPVolumeView → docs/concepts/mpvolumeview.md
    /// - Parameter value: Target volume, clamped to 0–1.
    func setVolume(_ value: Float) {
        let clamped = min(max(0, value), 1)
        guard let slider = volumeSlider() else { return }
        DispatchQueue.main.async {
            slider.setValue(clamped, animated: false)
        }
    }

    /// Lazily creates the MPVolumeView (it must be attached to a window —
    /// a detached view never builds its slider) and returns its UISlider.
    /// The slider appears asynchronously after the view mounts, so calls
    /// in that window return nil and that particular change is dropped.
    /// - Returns: The volume slider, or nil while it doesn't exist yet.
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
