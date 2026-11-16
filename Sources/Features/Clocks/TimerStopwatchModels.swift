import Foundation
import UserNotifications
import AVFoundation
import UIKit

/// Countdown timer. Keeps running when you leave the screen; fires a local
/// notification and the in-app ringer when it hits zero.
@Observable
final class TimerModel {
    private(set) var isRunning = false
    private(set) var remaining: TimeInterval = 0
    private(set) var total: TimeInterval = 0

    // Persisted duration
    var durationHours: Int { didSet { persist() } }
    var durationMinutes: Int { didSet { persist() } }
    var durationSeconds: Int { didSet { persist() } }

    private let d = UserDefaults.standard
    private enum K {
        static let h = "timer.h"; static let m = "timer.m"; static let s = "timer.s"
    }

    private var timer: Timer?
    private var fireDate: Date?

    init() {
        durationHours = d.object(forKey: K.h) as? Int ?? 0
        durationMinutes = d.object(forKey: K.m) as? Int ?? 5
        durationSeconds = d.object(forKey: K.s) as? Int ?? 0
    }

    private func persist() {
        d.set(durationHours, forKey: K.h)
        d.set(durationMinutes, forKey: K.m)
        d.set(durationSeconds, forKey: K.s)
    }

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

    func pause() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        cancelNotification()
        LiveActivityManager.shared.timerPaused(remaining: remaining)
    }

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

    private func cancelNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["timer.fire"])
    }
}

/// Stopwatch with laps.
@Observable
final class StopwatchModel {
    init() {
        // Live Activities retry on first-launch races with the true
        // elapsed base, provided here.
        LiveActivityManager.stopwatchElapsedProvider = { [weak self] in self?.elapsed ?? 0 }
    }

    private(set) var elapsed: TimeInterval = 0
    private(set) var isRunning = false
    private(set) var laps: [TimeInterval] = []

    private var timer: Timer?
    private var startDate: Date?
    private var base: TimeInterval = 0

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

    func stop() {
        guard isRunning else { return }
        if let start = startDate { base += Date().timeIntervalSince(start) }
        startDate = nil
        isRunning = false
        timer?.invalidate()
        timer = nil
        LiveActivityManager.shared.stopwatchPaused(elapsed: base)
    }

    func reset() {
        stop()
        elapsed = 0
        base = 0
        laps = []
        LiveActivityManager.shared.stopwatchEnded()
    }

    func lap() {
        laps.append(elapsed)
        LiveActivityManager.shared.stopwatchLap(count: laps.count)
    }
}

/// Shows the in-app ringer overlay via AppModel. The alarm SOUND is the
/// system notification (Ringer & Alerts volume — immune to media mute);
/// the AVAudioPlayer loop here is only a fallback for the
/// notifications-denied case, because app-owned audio ALWAYS plays at
/// media volume (no session category changes that on iOS).
@Observable
final class RingerManager {
    static let shared = RingerManager()

    private var audioPlayer: AVAudioPlayer?

    func startTimerRinger() {
        startRinger(.init(kind: .timer, title: "Timer"))
    }

    private func startRinger(_ context: RingerContext) {
        DispatchQueue.main.async {
            guard AppModelRouter.shared.model?.ringer == nil else { return }
            AppModelRouter.shared.model?.startRinger(context)
            self.startSound()
        }
    }

    /// Media-volume loop, ONLY when notifications are denied (no system
    /// sound would exist at all). With notifications working, this is a
    /// no-op — the notification already rang at ringer volume.
    func startSound() {
        guard AlarmStore.shared.permissionDenied else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)
        guard let url = Bundle.main.url(forResource: "AlarmTone", withExtension: "caf") else { return }
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.numberOfLoops = -1
        audioPlayer?.volume = 1.0
        audioPlayer?.play()
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        DispatchQueue.main.async {
            AppModelRouter.shared.model?.ringer = nil
        }
        // The ringer no longer reconfigures the audio session (no ducking
        // to undo); the session stays active for music/background audio.
        // Re-arm tomorrow's request after the ringer is dismissed.
        AlarmStore.shared.schedule()
    }
}
