import Foundation
import AVFoundation
import UserNotifications

/// The single classic alarm (hour/minute/AM-PM/enabled), persisted and
/// delivered via local notifications.
///
/// SCHEDULING MODEL (reference-implementation rewrite, 2026-11-18): the
/// alarm schedules the NEXT SEVEN OCCURRENCES as individual
/// NON-repeating, fully-specified `UNCalendarNotificationTrigger`s —
/// a sliding window, refreshed idempotently on every launch/foreground.
/// This is the pattern used by production alarm apps ("Local
/// notifications: the 100% delivery myth", "Building Wake Me Smarter",
/// adaptive-alarms guides) because repeating triggers carry two traps
/// this codebase lived through:
///
/// - Removing a repeating pending request kills EVERY future occurrence
///   (no per-occurrence removal) — the original "alarm says on but never
///   rings again" bug. One-shot occurrences make that invariant moot.
/// - Cancel-then-add of the same identifier races inside the
///   notification daemon: the remove can land AFTER the add and silently
///   delete the fresh request. Occurrences use deterministic per-date
///   ids, and reconciliation only removes ids that are NOT wanted, so
///   remove and add never target the same identifier in one pass.
///
/// Reconciliation treats the OS's pending list as the source of truth
/// ("your model only says what should be" — Wake Me Smarter): read what
/// is pending, remove stale `alarm.`-prefixed entries, add missing
/// occurrences, then VERIFY by re-reading and repair once if the system
/// dropped one.
///
/// DELIVERY DIAGNOSTICS: a banner that arrives silently is a real
/// failure mode this app has shipped (Sleep Focus, per-app Sounds off,
/// Time Sensitive denied). The verify pass also reads
/// `soundSetting`/`timeSensitiveSetting` and publishes
/// `deliveryWarning` so the alarm screen can say WHY the phone may stay
/// quiet even though everything is scheduled.
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
    /// re-schedules the occurrence window while the alarm is armed.
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
    /// Non-nil when iOS settings will deliver the alarm SILENTLY (Sounds
    /// toggle off, or Time Sensitive denied so Focus modes win). Read in
    /// the verify pass and surfaced on the alarm screen — "the banner
    /// comes but nothing rings" must be diagnosable in-app.
    @Published private(set) var deliveryWarning: String?
    /// Next scheduled occurrence for the QA readout / diagnostics.
    @Published private(set) var nextFireText: String?

    /// How many upcoming occurrences the window schedules. Seven: one per
    /// possible weekday, so even a week without launching the app leaves
    /// later days armed, while staying far under iOS's 64-pending cap.
    static let windowSize = 7

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
    /// notifications. Rebuilds them on every launch and foreground pass:
    /// sweeps stale `alarm.`-prefixed requests, then re-installs the
    /// occurrence window when armed. This heals ghosts (RESET_DEFAULTS
    /// QA launches clear the persisted state but NOT the notification
    /// center) and repairs windows the system dropped.
    ///
    /// Fire-and-forget wrapper for existing sync call sites; tests and
    /// anything needing completion use `reconcileAsync()`.
    func reconcile() {
        _ = scheduleMaintenance { await self.reconcileBody() }
    }

    /// Async reconciliation body: cancel-everything when disabled, else
    /// install the occurrence window. Internal so unit tests can await
    /// it. Serialized: awaits its turn in the maintenance slot, so a
    /// straggler install from a just-flipped toggle cannot interleave.
    func reconcileAsync() async {
        await scheduleMaintenance { await self.reconcileBody() }.value
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

    // MARK: - Occurrence window (the reference scheduling model)

    /// Next `limit` fire Dates for the alarm rule, strictly after `now`.
    /// Pure and calendar-injectable so unit tests pin timezones/DST.
    ///
    /// Day matching walks forward day by day (an empty or full repeat
    /// selection means every day); each match resolves wall-clock
    /// hour:minute on that day via the calendar, so DST gaps resolve to
    /// the next valid time (Calendar's .nextTime policy) instead of a
    /// nonexistent instant.
    ///
    /// - Parameters:
    ///   - hour24: hour 0…23.
    ///   - minute: minute 0…59.
    ///   - repeatDays: seven booleans, Sunday first; none/fall = daily.
    ///   - now: instant the window opens after.
    ///   - calendar: calendar/timezone to resolve in.
    ///   - limit: how many occurrences to return.
    /// - Returns: ascending fire dates; fewer than `limit` only when the
    ///   day search horizon (35 days) runs out, which no real rule hits.
    static func upcomingFireDates(hour24: Int, minute: Int, repeatDays: [Bool],
                                  from now: Date = Date(), calendar: Calendar = Calendar.current,
                                  limit: Int = windowSize) -> [Date] {
        let everyDay = repeatDays.allSatisfy { !$0 } || repeatDays.allSatisfy { $0 }
        var out: [Date] = []
        for offset in 0..<35 where out.count < limit {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let weekdayIdx = calendar.component(.weekday, from: day) - 1  // 0 = Sunday
            guard everyDay || repeatDays.indices.contains(weekdayIdx) && repeatDays[weekdayIdx] else { continue }
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = hour24
            comps.minute = minute
            guard let fire = calendar.date(from: comps), fire > now else { continue }
            out.append(fire)
        }
        return out
    }

    /// Deterministic request id for one occurrence. Idempotent by
    /// construction: the same fire instant always maps to the same id,
    /// so re-adding (iOS replaces same-id requests) can never duplicate.
    static func occurrenceID(for date: Date) -> String {
        "alarm.occ.\(Int(date.timeIntervalSince1970))"
    }

    /// Alarm-family prefix shared by occurrences and snooze — the sweep
    /// and the QA count both key off it.
    private static let idPrefix = "alarm."

    /// The notification content for alarm occurrences (and snooze).
    private func makeContent(title: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "\(displayText) · \(repeatLabel)"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("AlarmTone.caf"))
        content.categoryIdentifier = "ALARM"
        // Break through Focus / Do Not Disturb (user can still opt out —
        // when they do, `deliveryWarning` says so on the alarm screen).
        content.interruptionLevel = .timeSensitive
        content.userInfo["kind"] = "alarm"
        return content
    }

    /// The single maintenance slot: every schedule/cancel/reconcile pass
    /// runs here, one at a time, each new pass cancelling the straggler
    /// it replaces. Without this, the fire-and-forget `didSet` tasks
    /// interleave — an install that started while armed could still be
    /// ADDING occurrences after a disable's sweep finished, leaving a
    /// ghost armed with the toggle off (the interleaving was caught by
    /// `testInstallWindowInstallsNothingWhileDisabled`).
    private var maintenanceTask: Task<Void, Never>?

    @discardableResult
    private func scheduleMaintenance(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        maintenanceTask?.cancel()
        let task = Task { @MainActor in await body() }
        maintenanceTask = task
        return task
    }

    private func reconcileBody() async {
        if enabled {
            await installBody()
        } else {
            await cancelBody()
        }
    }

    /// Verifies notification permission, then installs the occurrence
    /// window. Never silently gives up: the outcome is published so the
    /// alarm screen can warn. The settings check runs INSIDE the
    /// serialized maintenance slot — a pass superseded while awaiting
    /// settings dies right there, so no late callback can cancel a
    /// newer install mid-loop (the straggler-callback race this shape
    /// closed).
    func schedule() {
        _ = scheduleMaintenance { await self.scheduleBody() }
    }

    private func scheduleBody() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard !Task.isCancelled else { return }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            permissionDenied = false
            await installBody()
        case .notDetermined:
            // First-run setup owns the notification prompt (it asks
            // for all permissions in one pass); once setup is done,
            // arming an alarm prompts here as usual. ALARM_GRANT=1
            // (UI tests) lets the prompt fire regardless of setup.
            guard UserDefaults.standard.bool(forKey: "setup.done")
                    || ProcessInfo.processInfo.environment["ALARM_GRANT"] == "1" else {
                permissionDenied = false
                return
            }
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard !Task.isCancelled else { return }
            permissionDenied = !granted
            if granted { await installBody() }
        default:
            permissionDenied = true
        }
    }

    /// Installs the occurrence window for the currently armed alarm.
    /// Awaitable + serialized (see `scheduleMaintenance`); internal so
    /// AlarmReconcileTests exercise the disabled gate directly — the
    /// full schedule() path needs notification authorization the
    /// unit-test runner can't grant.
    ///
    /// The pass is diff-based against the OS's pending list (the source
    /// of truth): remove stale `alarm.` requests we no longer want, add
    /// missing occurrences, then verify by re-reading and repair once.
    func installWindow() async {
        await scheduleMaintenance { await self.installBody() }.value
    }

    private func installBody() async {
        // Nothing installs while the alarm is off. schedule() also runs
        // for its side effects (permission prompt, post-ringer re-arm,
        // setup completion, ALARM_ENABLE QA hooks) — installing with the
        // toggle off was the ghost-ring bug.
        guard enabled else {
            await cancelBody()
            return
        }
        let dates = Self.upcomingFireDates(hour24: hour24, minute: minute, repeatDays: repeatDays)
        let wanted = Set(dates.map { Self.occurrenceID(for: $0) })
        await sweep(keeping: wanted)
        guard !Task.isCancelled else { return }
        await addOccurrences(dates: dates)
        guard !Task.isCancelled else { return }
        // Verify + repair: re-read pending; anything still missing gets
        // one retry (a first add can fail transiently — daemon busy).
        let missing = await missingOccurrenceIDs(wanted: wanted)
        if !missing.isEmpty, !Task.isCancelled {
            WheelEventLog.log("alarm verify: re-adding \(missing.count) dropped request(s)")
            await addOccurrences(dates: dates)
        }
        guard !Task.isCancelled else { return }
        await publishState(expected: wanted)
    }

    /// Removes every pending `alarm.`-prefixed request that is not in
    /// `keeping` — occurrences from an edited time/day set, weekday
    /// variants from the pre-window era, snoozes, ghosts. Ids come from
    /// the OS's pending list, never re-derived from model state (the
    /// "stale identifier" bug: an edit Mon→Fri would otherwise leave
    /// Monday ringing forever).
    private func sweep(keeping wanted: Set<String>) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let stale = pending
            .map { $0.identifier }
            .filter { $0.hasPrefix(Self.idPrefix) && !wanted.contains($0) }
        guard !stale.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: stale)
    }

    /// Adds one-shot, fully-specified trigger per occurrence (iOS
    /// replaces same-id requests, so re-adding is safe and idempotent).
    /// Checks cancellation between adds so a superseded pass stops
    /// mid-loop instead of arming ghosts a later sweep must chase.
    private func addOccurrences(dates: [Date]) async {
        let center = UNUserNotificationCenter.current()
        let content = makeContent(title: "Alarm")
        for date in dates {
            guard !Task.isCancelled else { return }
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(identifier: Self.occurrenceID(for: date),
                                                content: content, trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                WheelEventLog.log("alarm schedule failed: \(error.localizedDescription)")
            }
        }
    }

    /// Pending occurrence ids the system does not have (verify pass).
    private func missingOccurrenceIDs(wanted: Set<String>) async -> Set<String> {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let have = Set(pending.map { $0.identifier })
        return wanted.subtracting(have)
    }

    /// Cancels every alarm-family request: the occurrence window AND a
    /// pending snooze (a snoozed alarm left pending after disable would
    /// ring 9 minutes later as a ghost). Fire-and-forget wrapper for
    /// sync call sites; awaits completion via `cancelAsync()`.
    func cancel() {
        _ = scheduleMaintenance { await self.cancelBody() }
    }

    /// Async cancel body — same sweep with nothing kept; serialized and
    /// awaitable so tests can assert a deterministic end state.
    func cancelAsync() async {
        await scheduleMaintenance { await self.cancelBody() }.value
    }

    private func cancelBody() async {
        await sweep(keeping: [])
        guard !Task.isCancelled else { return }
        await publishState(expected: [])
    }

    /// Reads back ground truth (pending count, next fire) plus the
    /// delivery-diagnostics settings, and publishes it all. This is the
    /// "schedule, verify, and reconcile" loop's verify step.
    private func publishState(expected: Set<String>) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let alarmPending = pending.filter { $0.identifier.hasPrefix(Self.idPrefix) }
        let settings = await center.notificationSettings()

        var warning: String?
        if enabled, settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral {
            if settings.soundSetting != .enabled {
                warning = "Sounds are off for iPodClassic in Settings —\nthe alarm banner will arrive silently."
            } else if settings.timeSensitiveSetting != .enabled {
                warning = "Time Sensitive notifications are off —\nFocus modes (e.g. Sleep) can silence the alarm.\nAllow Time Sensitive in Settings → Notifications."
            }
        }

        let next = alarmPending
            .compactMap { $0.trigger as? UNCalendarNotificationTrigger }
            .compactMap { $0.nextTriggerDate() }
            .min()

        pendingAlarmCount = alarmPending.count
        deliveryWarning = warning
        nextFireText = next.map {
            TimeFormat.clock($0) + " · " + TimeFormat.duration($0.timeIntervalSinceNow)
        }
        if enabled, alarmPending.isEmpty {
            WheelEventLog.log("alarm WARNING: enabled but 0 pending (expected \(expected.count))")
        }
    }

    // MARK: - In-app firing (the Snooze/Stop overlay; the sound itself
    // comes from the system notification at Ringer & Alerts volume)

    /// Near-silent looping player: background audio keeps iOS from
    /// suspending the process so the fire monitor can keep running.
    /// The in-app ringer this enables plays MEDIA audio — audible even
    /// with the mute switch on and under Focus, unlike the notification.
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
    ///
    /// PlayerModel re-invokes this when music stops while backgrounded —
    /// the old gap: music playing skipped the silent player, the album
    /// then ended at 2am, the session went idle, iOS suspended the
    /// process, and the (Focus-silenceable) notification became the only
    /// sound.
    func startKeepAlive() {
        guard enabled, monitor == nil else { return }
        // Heal before the night matters: if a previous fire/dismiss cycle
        // died mid-way (force-quit, crash, reboot), the pending window
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
    /// The fired occurrence's one-shot request consumed itself; the rest
    /// of the window (and tomorrow's occurrences, replenished on the
    /// next foreground) stay armed — no remove/re-add at fire time, the
    /// invariant that broke the repeating-trigger era.
    ///
    /// Concept: UNUserNotifications → docs/concepts/usernotifications.md
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
        // volume — immune to media mute); it fired on its own. Show the
        // in-app Snooze/Stop overlay on top.
        stopKeepAlive()
        DispatchQueue.main.async {
            AppModelRouter.shared.model?.startRinger(RingerContext(kind: .alarm(id: UUID()), title: "Alarm"))
        }
    }

    /// Snooze: notification in 9 minutes (killed-app fallback) plus an
    /// in-app timer that rings without needing the notification.
    func snooze() {
        let request = UNNotificationRequest(identifier: "alarm.snooze",
                                            content: makeContent(title: "Snoozed Alarm"),
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 9 * 60, repeats: false))
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
