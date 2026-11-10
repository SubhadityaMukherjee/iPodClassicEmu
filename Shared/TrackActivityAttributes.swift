import Foundation
import ActivityKit

/// Data shared between the app and the widget extension for the Live
/// Activity that mirrors the timer, stopwatch, or voice-memo recording on
/// the lock screen / Dynamic Island.
///
/// The ticking time itself comes from `Text(timerInterval:)` in the widget,
/// so the app only posts updates on start / pause / resume / lap / end —
/// no push token or frequent updates needed.
struct TrackActivityAttributes: ActivityAttributes {
    enum Kind: String, Codable, Hashable {
        case timer, stopwatch, recorder, transcription, modelDownload

        var title: String {
            switch self {
            case .timer: return "Timer"
            case .stopwatch: return "Stopwatch"
            case .recorder: return "Voice Memo"
            case .transcription: return "Transcribing"
            case .modelDownload: return "Speech Model"
            }
        }
    }

    struct ContentState: Codable, Hashable {
        /// Timer: the moment the countdown hits zero. Count-up kinds: the
        /// far end of the display interval so the text ticks up forever.
        /// Transcription: the projected finish, re-estimated per update.
        var endDate: Date
        /// Start of the current run segment, shifted back by the time
        /// accumulated before it, so a count-up displays elapsed continuously.
        var segmentStart: Date
        /// Frozen remaining (timer) or elapsed (count-up) while paused.
        var pausedValue: TimeInterval?
        var laps: Int
        var done: Bool
        /// Transcription progress 0…1 (nil for the clock kinds).
        var progress: Double?
        /// Transcription: the memo name (running) or status text (final).
        var label: String?
    }

    var kind: Kind
    /// Timer's full duration (for readouts); 0 for the other kinds.
    var total: TimeInterval
}

extension TimeInterval {
    /// "1:02:03" / "12:34" for Live Activity static (paused/done) text.
    var liveClock: String {
        let t = Int(rounded())
        let h = t / 3600, m = (t / 60) % 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
