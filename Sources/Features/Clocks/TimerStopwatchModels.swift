import Foundation
import UserNotifications
import AVFoundation
import UIKit

/// Countdown timer. Keeps running when you leave the screen; fires a local
/// notification and the in-app ringer when it hits zero.
@Observable
final class TimerModel {
    /// True between start and pause/finish.
    private(set) var isRunning = false
    /// Seconds left, recomputed from `fireDate` on every poll tick.
    private(set) var remaining: TimeInterval = 0
    /// Seconds the current countdown was armed with; drives the dial
    /// fraction (`remaining / total`).
    private(set) var total: TimeInterval = 0

    // Persisted duration
    /// Default duration, hours part (persisted on change).
    var durationHours: Int { didSet { persist() } }
    /// Default duration, minutes part (persisted on change).
    var durationMinutes: Int { didSet { persist() } }
    /// Default duration, seconds part (persisted on change).
    var durationSeconds: Int { didSet { persist() } }

    private let d = UserDefaults.standard
    /// UserDefaults keys for the persisted duration parts.
    private enum K {
        static let h = "timer.h"; static let m = "timer.m"; static let s = "timer.s"
    }

    /// 0.25 s poll that refreshes `remaining` and detects the fire.
    private var timer: Timer?
    /// Absolute fire deadline — the source of truth. `remaining` is always
    /// re-derived from it, so missed ticks can never shorten the timer.
    private var fireDate: Date?

    /// Loads the persisted default duration (5:00 on a fresh install).
    init() {
        durationHours = d.object(forKey: K.h) as? Int ?? 0
        durationMinutes = d.object(forKey: K.m) as? Int ?? 5
        durationSeconds = d.object(forKey: K.s) as? Int ?? 0
    }

    /// Writes the three duration parts; called from every `didSet`.
    ///
    /// Concept: UserDefaults → docs/concepts/userdefaults.md
    private func persist() {
        d.set(durationHours, forKey: K.h)
        d.set(durationMinutes, forKey: K.m)
        d.set(durationSeconds, forKey: K.s)
    }

    /// Arms a fresh countdown: sets the absolute deadline, starts the
    /// poll, schedules the system notification (rings even if iOS has
    /// suspended the app) and starts the Live Activity card.
    ///
    /// - Parameter duration: seconds to count down; values <= 0 are ignored.
    ///
    /// Concept: UNUserNotificationCenter → docs/concepts/usernotifications.md
    /// Concept: Live Activities → docs/concepts/activitykit-live-activities.md
    func start(duration: TimeInterval) {
        guard duration > 0 else { return }
        total = duration
        remaining = duration
        isRunning = true
        fireDate = Date().addingTimeInterval(duration)
        startTimer()
        scheduleNotification(after: duration)
        if let fire = fireDate {
            LiveActivityManager.shared.timerStarted(endDate: fire, total: duration)
        }
    }

    /// Freezes the countdown (`remaining` keeps its value), cancels the
    /// pending notification and pauses the Live Activity card.
    func pause() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        cancelNotification()
        LiveActivityManager.shared.timerPaused(remaining: remaining)
    }

    /// Continues a paused countdown by re-deriving the deadline from the
    /// frozen `remaining`, then re-scheduling the notification and the
    /// Live Activity end date.
    func resume() {
        guard !isRunning, remaining > 0 else { return }
        isRunning = true
        fireDate = Date().addingTimeInterval(remaining)
        startTimer()
        scheduleNotification(after: remaining)
        if let fire = fireDate {
            LiveActivityManager.shared.timerResumed(endDate: fire)
        }
    }

    /// Clears everything: stops the poll, drops the pending notification
    /// and ends the Live Activity.
    func reset() {
        isRunning = false
        remaining = 0
        total = 0
        fireDate = nil
        timer?.invalidate()
        timer = nil
        cancelNotification()
        LiveActivityManager.shared.timerEnded()
    }

    /// Runs the 0.25 s poll: `remaining` is recomputed from `fireDate`
    /// (never decremented — drift-proof), and at zero it finishes the
    /// Live Activity, resets and raises the in-app timer ringer.
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let fire = self.fireDate else { return }
            self.remaining = max(0, fire.timeIntervalSinceNow)
            if self.remaining <= 0 {
                LiveActivityManager.shared.timerFinished()
                self.reset()
                RingerManager.shared.startTimerRinger()
            }
        }
    }

    // MARK: Notification (fires even if the app is backgrounded)

    /// One-shot "Timer finished" local notification — the background
    /// fallback that rings when the app is not on screen.
    ///
    /// Concept: UNUserNotificationCenter → docs/concepts/usernotifications.md
    private func scheduleNotification(after seconds: TimeInterval) {
        cancelNotification()
        let content = UNMutableNotificationContent()
        content.title = "Timer"
        content.body = "iPodClassic Timer finished"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("AlarmBeep.caf"))
        content.categoryIdentifier = "TIMER"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: "timer.fire", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    /// Drops the pending "Timer finished" request (on pause/reset).
    private func cancelNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["timer.fire"])
    }
}

/// Stopwatch with laps.
@Observable
final class StopwatchModel {
    /// Registers this instance as the elapsed-time provider so Live
    /// Activity retries can re-derive a true count-up base after
    /// first-launch races (see LiveActivityManager).
    init() {
        // Live Activities retry on first-launch races with the true
        // elapsed base, provided here.
        LiveActivityManager.stopwatchElapsedProvider = { [weak self] in self?.elapsed ?? 0 }
    }

    /// Total elapsed seconds across run/pause cycles, refreshed ~30×/s
    /// while running.
    private(set) var elapsed: TimeInterval = 0
    /// True while the 30 fps tick timer runs.
    private(set) var isRunning = false
    /// Cumulative split times, oldest first — each lap is the TOTAL clock
    /// at the press, not the interval since the previous lap.
    private(set) var laps: [TimeInterval] = []

    /// 30 fps tick that refreshes `elapsed`.
    private var timer: Timer?
    /// When the current run started (nil while paused).
    private var startDate: Date?
    /// Elapsed time banked by earlier run/pause cycles. `elapsed` is
    /// always `base + now - startDate`, which is what makes stop/start a
    /// resume instead of a restart.
    private var base: TimeInterval = 0

    /// Starts (or resumes) the clock. A fresh start opens the Live
    /// Activity at 0:00; a start after stop must continue from the banked
    /// `base` — the distinction matters for the lock-screen card's
    /// count-up.
    ///
    /// Concept: Live Activities → docs/concepts/activitykit-live-activities.md
    func start() {
        guard !isRunning else { return }
        isRunning = true
        startDate = Date()
        // Fresh start opens the card at 0:00; start-after-stop is a resume —
        // the card must continue from the accumulated base, not restart.
        if base > 0 {
            LiveActivityManager.shared.stopwatchResumed(base: base)
        } else {
            LiveActivityManager.shared.stopwatchStarted()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self, let start = self.startDate else { return }
            self.elapsed = self.base + Date().timeIntervalSince(start)
        }
    }

    /// Pauses: folds the current run into `base` so nothing is lost.
    func stop() {
        guard isRunning else { return }
        if let start = startDate { base += Date().timeIntervalSince(start) }
        startDate = nil
        isRunning = false
        timer?.invalidate()
        timer = nil
        LiveActivityManager.shared.stopwatchPaused(elapsed: base)
    }

    /// Zeroes everything (stopping first) and ends the Live Activity.
    func reset() {
        stop()
        elapsed = 0
        base = 0
        laps = []
        LiveActivityManager.shared.stopwatchEnded()
    }

    /// Records a split: the cumulative clock at the press.
    func lap() {
        laps.append(elapsed)
        LiveActivityManager.shared.stopwatchLap(count: laps.count)
    }
}

/// Shows the in-app ringer overlay via AppModel AND always plays the
/// audible tone loop (2026-11-18 fix). The loop is MEDIA audio: it plays
/// through the hardware mute switch and Focus modes that silence the
/// system notification's sound — with notifications authorized it used
/// to be suppressed ("the notification already rang"), which made
/// mute-switch mornings totally silent. The notification is now the
/// redundant killed-app path; the app's own voice is the ringer. Note
/// media audio follows MEDIA volume — the one variable an app cannot
/// override (no public API plays at Ringer & Alerts volume).
@Observable
final class RingerManager {
    /// Process-wide instance — the timer model and the ringer UI both
    /// drive the same overlay.
    static let shared = RingerManager()

    /// Raises the ringer overlay for a finished countdown timer.
    func startTimerRinger() {
        startRinger(.init(kind: .timer, title: "Timer"))
    }

    /// Raises the overlay via AppModel unless one is already up; hops to
    /// the main queue because AppModel state drives UI.
    ///
    /// - Parameter context: what is ringing (alarm/timer) and its title.
    private func startRinger(_ context: RingerContext) {
        DispatchQueue.main.async {
            guard AppModelRouter.shared.model?.ringer == nil else { return }
            AppModelRouter.shared.model?.startRinger(context)
            self.startSound()
        }
    }

    /// Media-volume loop. ALWAYS started when the ringer raises — this is
    /// the app's own voice, and media audio punches through the hardware
    /// mute switch that silences the notification sound (and through
    /// Focus, which can still banner a time-sensitive alarm silently).
    /// The system notification remains the redundant sound for the
    /// killed-app case; when the process is alive, THIS is the ringer.
    /// (The old shape guarded on `permissionDenied` — with notifications
    /// authorized, mute-switch users got total silence: the muted
    /// notification plus a deliberately-silent overlay. Reported as
    /// "the notification comes, nothing rings".)
    var soundStarter: () -> Void = { RingerManager.startToneLoop() }

    /// Launches the looping alarm tone on the shared audio session.
    /// Static + internal so tests can restore the injectable seam.
    static func startToneLoop() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)
        guard let url = Bundle.main.url(forResource: "AlarmTone", withExtension: "caf") else { return }
        RingerManager.shared.tonePlayer = try? AVAudioPlayer(contentsOf: url)
        RingerManager.shared.tonePlayer?.numberOfLoops = -1
        RingerManager.shared.tonePlayer?.volume = 1.0
        RingerManager.shared.tonePlayer?.play()
    }

    /// Looping alarm tone player (media audio; see `soundStarter`).
    var tonePlayer: AVAudioPlayer?

    /// Raises the ringer overlay via AppModel and always starts the
    /// audible tone loop.
    func startSound() {
        soundStarter()
    }

    /// Dismisses the ringer: stops the fallback tone, clears the overlay,
    /// and re-arms the alarm schedule so tomorrow's request exists again
    /// after the fire cycle.
    func stop() {
        tonePlayer?.stop()
        tonePlayer = nil
        DispatchQueue.main.async {
            AppModelRouter.shared.model?.ringer = nil
        }
        // Reconfigure back to the music-shaped session the ringer's
        // ducking displaced, then re-arm the alarm window after the
        // ringer is dismissed.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        AlarmStore.shared.schedule()
    }
}
