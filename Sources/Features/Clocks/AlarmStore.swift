import Foundation
import AVFoundation
import UserNotifications

/// The single classic alarm (hour/minute/AM-PM/enabled), persisted and
/// delivered via repeating local notifications.
final class AlarmStore: ObservableObject {
    static let shared = AlarmStore()

    @Published var enabled: Bool { didSet { persist(); if enabled { schedule() } else { cancel() } } }
    @Published var hour: Int { didSet { persist(); if enabled { schedule() } } }       // 1…12
    @Published var minute: Int { didSet { persist(); if enabled { schedule() } } }     // 0…59
    @Published var isPM: Bool { didSet { persist(); if enabled { schedule() } } }
    /// Repeats on these weekdays (Sunday-first, like the iPhone alarm).
    /// Nothing selected = every day.
    @Published var repeatDays: [Bool] { didSet { persist(); if enabled { schedule() } } }
    /// True when notifications are denied — the alarm cannot ring.
    @Published private(set) var permissionDenied = false

    private let d = UserDefaults.standard
    private enum K { static let enabled = "alarm.enabled"; static let hour = "alarm.hour"; static let minute = "alarm.minute"; static let pm = "alarm.pm"; static let repeatDays = "alarm.repeatDays" }

    private init() {
        enabled = d.bool(forKey: K.enabled)
        hour = d.object(forKey: K.hour) as? Int ?? 7
        minute = d.object(forKey: K.minute) as? Int ?? 0
        isPM = d.bool(forKey: K.pm)
        repeatDays = Self.days(fromBitmask: d.integer(forKey: K.repeatDays))
        // Insurance: make sure a pending request exists on every launch —
        // reinstalling the request is free and heals any dropped state.
        if enabled { schedule() }
    }

    /// 24-hour hour for display/scheduling.
    var hour24: Int {
        var h = hour % 12
        if isPM { h += 12 }
        return h
    }

    var displayText: String {
        String(format: "%02d : %02d %@", hour, minute, isPM ? "PM" : "AM")
    }

    /// iPhone-style repeat summary: "Every Day", "Weekdays", "Weekends",
    /// or a comma list ("Mon, Wed, Fri").
    var repeatLabel: String {
        let all = repeatDays.allSatisfy { $0 }
        let none = repeatDays.allSatisfy { !$0 }
        if all || none { return "Every Day" }
        if repeatDays == [false, true, true, true, true, true, false] { return "Weekdays" }
        if repeatDays == [true, false, false, false, false, false, true] { return "Weekends" }
        let names = Calendar.current.shortWeekdaySymbols  // Sun…Sat
        return repeatDays.enumerated().filter { $0.element }.map { names[$0.offset] }.joined(separator: ", ")
    }

    private func persist() {
        d.set(enabled, forKey: K.enabled)
        d.set(hour, forKey: K.hour)
        d.set(minute, forKey: K.minute)
        d.set(isPM, forKey: K.pm)
        d.set(Self.bitmask(fromDays: repeatDays), forKey: K.repeatDays)
    }

    private static func bitmask(fromDays days: [Bool]) -> Int {
        days.enumerated().reduce(0) { $0 + ($1.element ? 1 << $1.offset : 0) }
    }

    private static func days(fromBitmask mask: Int) -> [Bool] {
        (0..<7).map { mask & (1 << $0) != 0 }
    }

    /// Verifies notification permission, then (re)schedules. Never silently
    /// gives up: the outcome is published so the alarm screen can warn.
    func schedule() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { self.permissionDenied = false }
                self.installRequest()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    DispatchQueue.main.async { self.permissionDenied = !granted }
                    if granted { self.installRequest() }
                }
            default:
                DispatchQueue.main.async { self.permissionDenied = true }
            }
        }
    }

    private func installRequest() {
        let content = UNMutableNotificationContent()
        content.title = "Alarm"
        content.body = "iPodClassic Alarm Clock"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("AlarmBeep.caf"))
        content.categoryIdentifier = "ALARM"
        // Break through Focus / Do Not Disturb (user can still opt out).
        content.interruptionLevel = .timeSensitive

        let center = UNUserNotificationCenter.current()
        let add: (UNNotificationRequest) -> Void = { request in
            center.add(request) { error in
                if let error {
                    WheelEventLog.log("alarm schedule failed: \(error.localizedDescription)")
                }
            }
        }

        let everyDay = repeatDays.allSatisfy { $0 } || repeatDays.allSatisfy { !$0 }
        if everyDay {
            // One daily repeating request (the classic iPod behavior).
            var comps = DateComponents()
            comps.hour = hour24
            comps.minute = minute
            add(UNNotificationRequest(identifier: "alarm.daily", content: content,
                                      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
        } else {
            // One repeating request per weekday (1 = Sunday … 7 = Saturday).
            for (i, on) in repeatDays.enumerated() where on {
                var comps = DateComponents()
                comps.hour = hour24
                comps.minute = minute
                comps.weekday = i + 1
                add(UNNotificationRequest(identifier: "alarm.day.\(i + 1)", content: content,
                                          trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
            }
        }
    }

    func cancel() {
        let ids = ["alarm.daily"] + (1...7).map { "alarm.day.\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - In-app firing (keeps ringing even when locked or muted)

    private var keepAlivePlayer: AVAudioPlayer?
    private var monitor: Timer?
    private var snoozeTimer: Timer?
    private var lastFireDay: String?

    /// While backgrounded with an armed alarm, plays near-silent audio so
    /// iOS keeps the process alive; a monitor then fires the ringer in-app
    /// at the alarm time — full volume, even on the silent switch.
    func startKeepAlive() {
        guard enabled, monitor == nil else { return }
        // The monitor must always run; the silent audio below is only
        // needed when nothing else keeps the process alive. While music
        // plays, leave the session alone — reconfiguring it can interrupt
        // playback, and the active audio session keeps us alive anyway.
        let musicPlaying = AppModelRouter.shared.model?.player.isPlaying == true
        if !musicPlaying {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [])
            try? session.setActive(true)
            if let url = Bundle.main.url(forResource: "Tick", withExtension: "caf") {
                keepAlivePlayer = try? AVAudioPlayer(contentsOf: url)
                keepAlivePlayer?.numberOfLoops = -1
                keepAlivePlayer?.volume = 0.01   // effectively inaudible
                keepAlivePlayer?.play()
            }
        }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkFire() }
        RunLoop.main.add(t, forMode: .common)
        monitor = t
    }

    func stopKeepAlive() {
        monitor?.invalidate()
        monitor = nil
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
    }

    private func checkFire() {
        let cal = Calendar.current
        let now = cal.dateComponents([.hour, .minute], from: Date())
        guard let h = now.hour, let m = now.minute, h == hour24, m == minute else { return }
        // Honor the repeat selection (nothing selected = every day).
        let today = cal.component(.weekday, from: Date()) - 1  // 0 = Sunday
        guard repeatDays.allSatisfy({ !$0 }) || repeatDays[today] else { return }
        let key = cal.startOfDay(for: Date()).timeIntervalSince1970.description
        guard lastFireDay != key else { return }
        lastFireDay = key
        // The app handles today's ring; drop today's (duplicate) system
        // notification and let schedule() re-arm tomorrow's.
        cancel()
        stopKeepAlive()
        DispatchQueue.main.async {
            AppModelRouter.shared.model?.startRinger(RingerContext(kind: .alarm(id: UUID()), title: "Alarm"))
        }
    }

    /// Snooze: notification in 9 minutes (killed-app fallback) plus an
    /// in-app timer that rings without needing the notification.
    func snooze() {
        let content = UNMutableNotificationContent()
        content.title = "Snoozed Alarm"
        content.body = "iPodClassic Alarm Clock"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("AlarmBeep.caf"))
        content.categoryIdentifier = "ALARM"
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 9 * 60, repeats: false)
        let request = UNNotificationRequest(identifier: "alarm.snooze", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)

        snoozeTimer?.invalidate()
        snoozeTimer = Timer(timeInterval: 9 * 60, repeats: false) { [weak self] _ in
            self?.lastFireDay = nil
            DispatchQueue.main.async {
                AppModelRouter.shared.model?.startRinger(RingerContext(kind: .alarm(id: UUID()), title: "Alarm"))
            }
        }
        RunLoop.main.add(snoozeTimer!, forMode: .common)
    }
}

import UIKit

/// Notification delegate: presents the in-app ringer when a notification
/// arrives while the app is open, and opens the ringer when the user taps.
final class AlarmNotificationsDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onStartRinger: ((RingerContext) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.content.categoryIdentifier == "ALARM" {
            startRinger(for: notification)
            completionHandler([])  // in-app overlay handles presentation
        } else {
            completionHandler([.banner, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.content.categoryIdentifier == "ALARM" {
            startRinger(for: response.notification)
        }
        completionHandler()
    }

    private func startRinger(for notification: UNNotification) {
        let id = notification.request.identifier
        let context: RingerContext
        if id.contains("snooze") || id.contains("alarm") {
            context = RingerContext(kind: .alarm(id: UUID()), title: "Alarm")
        } else {
            context = RingerContext(kind: .timer, title: "Timer")
        }
        DispatchQueue.main.async {
            self.onStartRinger?(context)
        }
    }
}

enum AlarmNotifications {
    static let delegate = AlarmNotificationsDelegate()

    static func configureDelegate() {
        UNUserNotificationCenter.current().delegate = delegate
        delegate.onStartRinger = { context in
            // Routed to the live AppModel through the shared hook.
            AppModelRouter.shared.model?.startRinger(context)
        }
    }
}

/// Indirection so the notification delegate can reach the live AppModel.
final class AppModelRouter {
    static let shared = AppModelRouter()
    weak var model: AppModel?
}
