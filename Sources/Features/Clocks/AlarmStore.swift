import Foundation
import AVFoundation
import UserNotifications

/// The single classic alarm (hour/minute/AM-PM/enabled), persisted and
/// delivered via repeating local notifications.
final class AlarmStore: ObservableObject {
    /// Process-wide singleton: the app, the notification delegate and the
    /// ringer all mutate ONE alarm, so exactly one instance owns the
    /// system schedule.
    static let shared = AlarmStore()

    /// Master arm toggle. Flipping it persists and immediately installs or
    /// removes the system requests — the toggle must never disagree with
    /// what is actually scheduled to ring.
    @Published var enabled: Bool { didSet { persist(); if enabled { schedule() } else { cancel() } } }
    /// Alarm hour in 1–12 form (classic clock face). Persisted; any edit
    /// re-schedules the repeating requests while the alarm is armed.
    @Published var hour: Int { didSet { persist(); if enabled { schedule() } } }       // 1…12
    /// Alarm minute, 0–59. Persisted; any edit re-schedules while armed.
    @Published var minute: Int { didSet { persist(); if enabled { schedule() } } }     // 0…59
    /// Afternoon flag; `hour24` combines it with `hour`. Persisted; any
    /// edit re-schedules while armed.
    @Published var isPM: Bool { didSet { persist(); if enabled { schedule() } } }
    /// Repeats on these weekdays (Sunday-first, like the iPhone alarm).
    /// Nothing selected = every day.
    @Published var repeatDays: [Bool] { didSet { persist(); if enabled { schedule() } } }
    /// True when notifications are denied — the alarm cannot ring.
    @Published private(set) var permissionDenied = false
    /// Pending alarm-family notification requests (nil = not yet known).
    /// Published so the alarm screen can warn when the alarm is "on" but
    /// nothing is actually scheduled to ring — the silent-death state.
    @Published private(set) var pendingAlarmCount: Int?

    private let d = UserDefaults.standard
    /// UserDefaults keys for the five persisted alarm fields.
    private enum K { static let enabled = "alarm.enabled"; static let hour = "alarm.hour"; static let minute = "alarm.minute"; static let pm = "alarm.pm"; static let repeatDays = "alarm.repeatDays" }

    /// Loads the persisted alarm, then immediately reconciles the system
    /// schedule with it. Private: all access goes through `shared`.
    private init() {
        enabled = d.bool(forKey: K.enabled)
        hour = d.object(forKey: K.hour) as? Int ?? 7
        minute = d.object(forKey: K.minute) as? Int ?? 0
        isPM = d.bool(forKey: K.pm)
        repeatDays = Self.days(fromBitmask: d.integer(forKey: K.repeatDays))
        reconcile()
    }

    /// The persisted store is the single source of truth for system
    /// notifications. Rebuilds them on every launch: cancels ALL alarm
    /// identifiers first, then reschedules only when armed. This heals
    /// ghosts — RESET_DEFAULTS (QA launches) clears the persisted state
    /// but NOT the notification center, so a stale repeating trigger
    /// would otherwise ring daily forever with nothing armed.
    func reconcile() {
        cancel()
        if enabled { schedule() }
    }

    /// 24-hour hour for display/scheduling.
    var hour24: Int {
        var h = hour % 12
        if isPM { h += 12 }
        return h
    }

    /// "07 : 30 AM" — used for the alarm row and the notification body.
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

    /// Writes all five fields; called from every `didSet` so a kill can
    /// never lose an edit.
    ///
    /// Concept: UserDefaults → docs/concepts/userdefaults.md
    private func persist() {
        d.set(enabled, forKey: K.enabled)
        d.set(hour, forKey: K.hour)
        d.set(minute, forKey: K.minute)
        d.set(isPM, forKey: K.pm)
        d.set(Self.bitmask(fromDays: repeatDays), forKey: K.repeatDays)
    }

    /// Packs the day flags into a storable integer.
    ///
    /// - Parameter days: seven booleans, Sunday first.
    /// - Returns: a bitmask where bit i is set iff day i is selected.
    private static func bitmask(fromDays days: [Bool]) -> Int {
        days.enumerated().reduce(0) { $0 + ($1.element ? 1 << $1.offset : 0) }
    }

    /// Inverse of `bitmask(fromDays:)`.
    ///
    /// - Parameter mask: persisted weekday bitmask (bit 0 = Sunday).
    /// - Returns: seven booleans, Sunday first.
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
                // First-run setup owns the notification prompt (it asks
                // for all permissions in one pass); once setup is done,
                // arming an alarm prompts here as usual.
                // First-run setup owns the notification prompt (it asks
                // for all permissions in one pass); once setup is done,
                // arming an alarm prompts here as usual. ALARM_GRANT=1
                // (UI tests) lets the prompt fire regardless of setup.
                guard UserDefaults.standard.bool(forKey: "setup.done")
                        || ProcessInfo.processInfo.environment["ALARM_GRANT"] == "1" else {
                    DispatchQueue.main.async { self.permissionDenied = false }
                    return
                }
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    DispatchQueue.main.async { self.permissionDenied = !granted }
                    if granted { self.installRequest() }
                }
            default:
                DispatchQueue.main.async { self.permissionDenied = true }
            }
        }
    }

    /// Installs the repeating requests for the currently armed alarm.
    /// Internal (not private) so AlarmReconcileTests can exercise the
    /// disabled gate directly — the full schedule() path needs
    /// notification authorization the unit-test runner can't grant.
    func installRequest() {
        // Clean slate first: stale requests from earlier repeat-mode
        // toggles would otherwise ring alongside the current set (the
        // alarm "rings twice" and resurrects after Stop).
        cancel()
        // Nothing installs while the alarm is off. schedule() is also
        // called for its side effects (permission prompt on the alarm
        // screen, post-ringer re-arm, setup completion) — those used to
        // land here with the alarm disabled and install repeating
        // requests anyway: a ghost that rings at the set time with the
        // toggle reading Off until the next relaunch healed it.
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Alarm"
        content.body = "\(displayText) · \(repeatLabel)"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("AlarmTone.caf"))
        content.categoryIdentifier = "ALARM"
        // Break through Focus / Do Not Disturb (user can still opt out).
        content.interruptionLevel = .timeSensitive
        content.userInfo["kind"] = "alarm"

        let center = UNUserNotificationCenter.current()
        let group = DispatchGroup()
        let add: (UNNotificationRequest) -> Void = { request in
            group.enter()
            center.add(request) { error in
                if let error {
                    WheelEventLog.log("alarm schedule failed: \(error.localizedDescription)")
                }
                group.leave()
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
        group.notify(queue: .main) { [weak self] in self?.refreshPendingCount() }
    }

    /// Removes every alarm-family request: the repeating triggers, all
    /// weekday variants, AND a pending snooze (a snoozed alarm left
    /// pending after disable would ring 9 minutes later as a ghost).
    func cancel() {
        let ids = ["alarm.daily", "alarm.snooze"] + (1...7).map { "alarm.day.\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        // The removal lands on the notification daemon in milliseconds;
        // hop the main queue so the refresh reads the post-cancel state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPendingCount()
        }
    }

    /// Publishes how many alarm requests are actually pending — the
    /// ground truth for "the alarm says ON but will not ring".
    private func refreshPendingCount() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let count = requests.filter { $0.identifier.hasPrefix("alarm.") }.count
            DispatchQueue.main.async { self.pendingAlarmCount = count }
        }
    }

    // MARK: - In-app firing (the Snooze/Stop overlay; the sound itself
    // comes from the system notification at Ringer & Alerts volume)

    /// Near-silent looping player: background audio keeps iOS from
    /// suspending the process so the fire monitor can keep running.
    private var keepAlivePlayer: AVAudioPlayer?
    /// 1-second fire-check timer while the keep-alive is active.
    private var monitor: Timer?
    /// In-app 9-minute snooze re-ring (pairs with the `alarm.snooze`
    /// notification of the same name).
    private var snoozeTimer: Timer?
    /// Start-of-day key of the last in-app fire, so the matching minute
    /// rings exactly once instead of once per monitor tick.
    private var lastFireDay: String?

    /// While backgrounded with an armed alarm, plays near-silent audio so
    /// iOS keeps the process alive; a monitor then shows the ringer
    /// overlay in-app at the alarm time (the sound comes from the system
    /// notification, which rings at Ringer & Alerts volume regardless of
    /// media volume).
    func startKeepAlive() {
        guard enabled, monitor == nil else { return }
        // Heal before the night matters: if a previous fire/dismiss cycle
        // died mid-way (force-quit, crash, reboot), the pending requests
        // may be gone while enabled is still true — without this the
        // alarm silently never rings again.
        reconcile()
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

    /// Tears down the fire monitor and the silent keep-alive player (on
    /// fire, or when the app returns to the foreground).
    func stopKeepAlive() {
        monitor?.invalidate()
        monitor = nil
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
    }

    /// Monitor tick: rings the in-app ringer once when the clock reaches
    /// the armed minute and today is a selected day (no day selected =
    /// every day). `lastFireDay` makes it once per day.
    ///
    /// Deliberately does NOT touch the pending repeating requests:
    /// removing a repeating UNCalendarNotificationTrigger kills ALL its
    /// future occurrences (UserNotifications has no per-occurrence
    /// removal), so a remove/re-add at fire time was exactly how the
    /// "alarm says on but never rings again" bug happened. Tomorrow's
    /// rings stay armed; the re-arm/heal paths are RingerManager.stop()
    /// → schedule() after dismissal and reconcile() on every foreground.
    ///
    /// Concept: UNUserNotificationCenter → docs/concepts/usernotifications.md
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
        // The system notification IS the alarm sound (Ringer & Alerts
        // volume — immune to media mute); leave it alone and show the
        // in-app Snooze/Stop overlay on top. Leaving the repeating
        // requests untouched also means no remove/re-schedule dance (the
        // old path had to heal the "removed every future occurrence"
        // invariant itself).
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
        content.body = "\(displayText) · \(repeatLabel)"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("AlarmTone.caf"))
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
    /// Set by `AlarmNotifications.configureDelegate`; forwards ringer
    /// requests to the live AppModel.
    var onStartRinger: ((RingerContext) -> Void)?

    /// Decides presentation while the app is open. Alarm/timer
    /// notifications become the in-app ringer; returning `.sound`
    /// WITHOUT `.banner` plays the system sound (Ringer & Alerts volume
    /// — the only domain that rings when media is muted) without
    /// stacking a banner on top of the overlay that already offers
    /// Snooze/Stop.
    ///
    /// Concept: UNUserNotificationCenter → docs/concepts/usernotifications.md
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let category = notification.request.content.categoryIdentifier
        if category == "ALARM" || category == "TIMER" {
            startRinger(for: notification)
            // The SYSTEM notification sound is the alarm: it plays at the
            // Ringer & Alerts volume — the only iOS audio domain that
            // still rings when media volume is muted. `.sound` without
            // `.banner` avoids a duplicate banner over the in-app overlay
            // (which provides Snooze/Stop).
            completionHandler([.sound])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    /// Handles taps and banner actions: "Snooze 9 min" re-arms without
    /// opening the app, Stop just dismisses, any other tap opens the
    /// in-app ringer.
    ///
    /// Concept: UNUserNotificationCenter → docs/concepts/usernotifications.md
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.content.categoryIdentifier == "ALARM" {
            switch response.actionIdentifier {
            case "SNOOZE_ALARM":
                // Re-arm in 9 minutes without opening the app.
                AlarmStore.shared.snooze()
            case "STOP_ALARM":
                break  // banner dismissed; nothing further
            default:
                startRinger(for: response.notification)
            }
        }
        completionHandler()
    }

    /// Maps a delivered notification back to a ringer context.
    ///
    /// - Parameter notification: the delivered alarm/snooze/timer
    ///   notification; its identifier picks the ringer kind.
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

/// Namespace for the one-time notification wiring done at app start.
enum AlarmNotifications {
    /// Shared delegate instance, retained here for the process lifetime —
    /// UNUserNotificationCenter keeps its delegate only weakly.
    static let delegate = AlarmNotificationsDelegate()

    /// Registers the ALARM notification category (Stop / Snooze actions
    /// right on the banner — critical when the app is closed and the
    /// notification IS the alarm), installs the delegate, and wires
    /// delegate callbacks to the live AppModel. Call once at launch.
    ///
    /// Concept: UNUserNotificationCenter → docs/concepts/usernotifications.md
    static func configureDelegate() {
        let center = UNUserNotificationCenter.current()
        // Actionable alarm notifications: Stop / Snooze right on the
        // banner — critical for the app-closed case, where the notification
        // IS the alarm.
        let stop = UNNotificationAction(identifier: "STOP_ALARM", title: "Stop",
                                        options: [.destructive])
        let snooze = UNNotificationAction(identifier: "SNOOZE_ALARM", title: "Snooze 9 min",
                                          options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "ALARM", actions: [stop, snooze],
                                   intentIdentifiers: [], options: [])
        ])
        center.delegate = delegate
        delegate.onStartRinger = { context in
            // Routed to the live AppModel through the shared hook; the
            // delegate callback arrives off-main, the ringer is UI.
            DispatchQueue.main.async {
                AppModelRouter.shared.model?.startRinger(context)
            }
        }
    }
}

/// Indirection so the notification delegate can reach the live AppModel.
final class AppModelRouter {
    static let shared = AppModelRouter()
    /// The live AppModel, set at launch; weak so the router can reference
    /// it without owning or keeping it alive.
    weak var model: AppModel?
}
