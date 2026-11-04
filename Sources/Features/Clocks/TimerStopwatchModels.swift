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
    }

    func pause() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        cancelNotification()
    }

    func resume() {
        guard !isRunning, remaining > 0 else { return }
        isRunning = true
        fireDate = Date().addingTimeInterval(remaining)
        startTimer()
        scheduleNotification(after: remaining)
    }

    func reset() {
        isRunning = false
        remaining = 0
        total = 0
        fireDate = nil
        timer?.invalidate()
        timer = nil
        cancelNotification()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let fire = self.fireDate else { return }
            self.remaining = max(0, fire.timeIntervalSinceNow)
            if self.remaining <= 0 {
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
    }

    func reset() {
        stop()
        elapsed = 0
        base = 0
        laps = []
    }

    func lap() {
        laps.append(elapsed)
    }
}

/// Plays the ringer loop and shows the in-app overlay via AppModel.
@Observable
final class RingerManager {
    static let shared = RingerManager()

    private var audioPlayer: AVAudioPlayer?

    func startTimerRinger() {
        startRinger(.init(kind: .timer, title: "Timer"))
    }

    func startAlarmRinger() {
        startRinger(.init(kind: .alarm(id: UUID()), title: "Alarm"))
    }

    private func startRinger(_ context: RingerContext) {
        DispatchQueue.main.async {
            guard AppModelRouter.shared.model?.ringer == nil else { return }
            AppModelRouter.shared.model?.startRinger(context)
            self.playLoop()
        }
    }

    private func playLoop() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)
        guard let url = Bundle.main.url(forResource: "AlarmBeep", withExtension: "caf") else { return }
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.numberOfLoops = -1
        audioPlayer?.volume = 1.0
        audioPlayer?.play()
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        AppModelRouter.shared.model?.ringer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
