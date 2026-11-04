import Foundation
import UserNotifications

/// The single classic alarm (hour/minute/AM-PM/enabled), persisted and
/// delivered via repeating local notifications.
final class AlarmStore: ObservableObject {
    static let shared = AlarmStore()

    @Published var enabled: Bool { didSet { persist(); if enabled { schedule() } else { cancel() } } }
    @Published var hour: Int { didSet { persist(); if enabled { schedule() } } }       // 1…12
    @Published var minute: Int { didSet { persist(); if enabled { schedule() } } }     // 0…59
    @Published var isPM: Bool { didSet { persist(); if enabled { schedule() } } }

    private let d = UserDefaults.standard
    private enum K { static let enabled = "alarm.enabled"; static let hour = "alarm.hour"; static let minute = "alarm.minute"; static let pm = "alarm.pm" }

    private init() {
        enabled = d.bool(forKey: K.enabled)
        hour = d.object(forKey: K.hour) as? Int ?? 7
        minute = d.object(forKey: K.minute) as? Int ?? 0
        isPM = d.bool(forKey: K.pm)
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

    private func persist() {
        d.set(enabled, forKey: K.enabled)
        d.set(hour, forKey: K.hour)
        d.set(minute, forKey: K.minute)
        d.set(isPM, forKey: K.pm)
    }

    /// Requests notification permission if needed, then (re)schedules.
    func schedule() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted else { return }
            self?.installRequest()
        }
    }

    private func installRequest() {
        let content = UNMutableNotificationContent()
        content.title = "Alarm"
        content.body = "iPodClassic Alarm Clock"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("AlarmBeep.caf"))
        content.categoryIdentifier = "ALARM"

        var comps = DateComponents()
        comps.hour = hour24
        comps.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)

        let request = UNNotificationRequest(identifier: "alarm.daily", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["alarm.daily"])
    }

    /// Snooze: schedule one shot in 9 minutes.
    func snooze() {
        let content = UNMutableNotificationContent()
        content.title = "Snoozed Alarm"
        content.body = "iPodClassic Alarm Clock"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("AlarmBeep.caf"))
        content.categoryIdentifier = "ALARM"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 9 * 60, repeats: false)
        let request = UNNotificationRequest(identifier: "alarm.snooze", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
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
