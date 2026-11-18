import XCTest
import UserNotifications
@testable import iPodClassic

/// Alarm scheduling: the occurrence-window math (pure) and notification
/// reconciliation (needs the center; the enabled path additionally needs
/// authorization, which the alarm E2E covers on the simulator).
///
/// The window model replaced repeating triggers in 2026-11: the alarm
/// schedules the next seven occurrences as one-shot fully-specified
/// triggers, and reconciliation sweeps `alarm.`-prefixed requests that
/// are no longer wanted — including ghosts from RESET_DEFAULTS QA
/// launches, which clear the persisted store but NOT the notification
/// center.
@MainActor
final class AlarmReconcileTests: XCTestCase {
    private var savedEnabled = false
    private var savedHour = 7
    private var savedMinute = 0
    private var savedPM = false
    private var savedDays: [Bool] = []

    override func setUp() {
        super.setUp()
        let store = AlarmStore.shared
        savedEnabled = store.enabled
        savedHour = store.hour
        savedMinute = store.minute
        savedPM = store.isPM
        savedDays = store.repeatDays
    }

    override func tearDown() {
        // Restore the saved rule; disabling also sweeps anything the
        // test scheduled. didSet side effects fire per field; the final
        // state is restored before the next test reads the store.
        let store = AlarmStore.shared
        store.enabled = false
        store.hour = savedHour
        store.minute = savedMinute
        store.isPM = savedPM
        store.repeatDays = savedDays
        store.enabled = savedEnabled
        super.tearDown()
    }

    // MARK: - Occurrence window math (pure)

    private var nyCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    /// A fixed instant: 2026-11-18 14:03 New York (a Wednesday).
    private var fixedNow: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 11; comps.day = 18
        comps.hour = 14; comps.minute = 3
        return nyCalendar.date(from: comps)!
    }

    func testDailyWindowReturnsSevenAscendingOccurrences() {
        let dates = AlarmStore.upcomingFireDates(hour24: 7, minute: 30,
                                                 repeatDays: Array(repeating: false, count: 7),
                                                 from: fixedNow, calendar: nyCalendar)
        XCTAssertEqual(dates.count, 7)
        XCTAssertEqual(dates, dates.sorted(), "occurrences must be ascending")
        // First occurrence is TOMORROW 07:30 (today's 07:30 already passed).
        let first = nyCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: dates[0])
        XCTAssertEqual([first.year, first.month, first.day, first.hour, first.minute],
                       [2026, 11, 19, 7, 30])
        // One per consecutive day.
        for pair in zip(dates, dates.dropFirst()) {
            XCTAssertEqual(nyCalendar.dateComponents([.day], from: pair.0, to: pair.1).day, 1)
        }
    }

    func testEmptySelectionMeansEveryDay() {
        let none = AlarmStore.upcomingFireDates(hour24: 7, minute: 30,
                                                repeatDays: Array(repeating: false, count: 7),
                                                from: fixedNow, calendar: nyCalendar)
        let all = AlarmStore.upcomingFireDates(hour24: 7, minute: 30,
                                               repeatDays: Array(repeating: true, count: 7),
                                               from: fixedNow, calendar: nyCalendar)
        XCTAssertEqual(none, all, "no selection and full selection must both mean daily")
    }

    func testWeekdaySelectionYieldsOnlyThoseWeekdays() {
        // Monday (index 1) and Friday (index 5), Sunday-first.
        var days = Array(repeating: false, count: 7)
        days[1] = true
        days[5] = true
        let dates = AlarmStore.upcomingFireDates(hour24: 6, minute: 0,
                                                 repeatDays: days, from: fixedNow, calendar: nyCalendar)
        XCTAssertEqual(dates.count, 7, "35-day horizon covers 7 Mon/Fri occurrences")
        for date in dates {
            let weekday = nyCalendar.component(.weekday, from: date)  // 1=Sun…7=Sat
            XCTAssertTrue(weekday == 2 || weekday == 6, "got a \(weekday), want Mon or Fri")
        }
    }

    func testOccurrencesAreStrictlyAfterNow() {
        // 14:03:00 now, alarm 14:03 — the current minute must NOT match;
        // the first occurrence is tomorrow (the classic edge that made
        // same-minute QA alarms silently wait a day).
        var comps = nyCalendar.dateComponents([.year, .month, .day], from: fixedNow)
        comps.hour = 14
        comps.minute = 3
        let now = nyCalendar.date(from: comps)!
        let dates = AlarmStore.upcomingFireDates(hour24: 14, minute: 3,
                                                 repeatDays: [], from: now, calendar: nyCalendar)
        XCTAssertTrue(dates.allSatisfy { $0 > now })
        let firstDay = nyCalendar.dateComponents([.day], from: now, to: dates[0]).day
        XCTAssertEqual(firstDay, 1)
    }

    func testOccurrenceIDsAreDeterministicAndPrefixed() {
        let d = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AlarmStore.occurrenceID(for: d), AlarmStore.occurrenceID(for: d))
        XCTAssertTrue(AlarmStore.occurrenceID(for: d).hasPrefix("alarm.occ."))
    }

    // MARK: - Notification reconciliation (needs the center)

    private func pendingAlarmIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
            .map { $0.identifier }
            .filter { $0.hasPrefix("alarm.") }
    }

    private func addStaleTrigger(identifier: String, minute: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "Alarm"
        var comps = DateComponents()
        comps.hour = 11
        comps.minute = minute
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        )
        _ = try? await UNUserNotificationCenter.current().add(request)
    }

    func testReconcileRemovesStaleTriggersWhenDisabled() async throws {
        let store = AlarmStore.shared
        store.enabled = false  // disable: nothing may remain pending
        await addStaleTrigger(identifier: "alarm.occ.999", minute: 53)
        await addStaleTrigger(identifier: "alarm.snooze", minute: 2)
        await addStaleTrigger(identifier: "alarm.daily", minute: 15)

        await store.reconcileAsync()

        let remaining = await pendingAlarmIdentifiers()
        XCTAssertTrue(remaining.isEmpty,
                      "reconcile with the alarm disabled must clear every stale trigger (got \(remaining))")
    }

    func testDisablingCancelsAPendingSnooze() async throws {
        let store = AlarmStore.shared
        store.enabled = true
        await addStaleTrigger(identifier: "alarm.snooze", minute: 2)

        store.enabled = false  // didSet fires cancel(); await the async body
        await store.cancelAsync()

        let remaining = await pendingAlarmIdentifiers()
        XCTAssertFalse(remaining.contains("alarm.snooze"),
                       "a snoozed alarm left pending after disable would ring 9 minutes later as a ghost")
    }

    /// installWindow must be a no-op (beyond the sweep) while the alarm
    /// is disabled. It runs from several unconditional call sites — the
    /// alarm screen's permission prompt, RingerManager.stop() after a
    /// TIMER ringer, setup completion, the ALARM_ENABLE=0 QA hook — and
    /// used to install requests anyway: a ghost ring at the set time
    /// with the toggle reading Off (until the next launch healed it).
    func testInstallWindowInstallsNothingWhileDisabled() async throws {
        let store = AlarmStore.shared
        store.enabled = true
        await addStaleTrigger(identifier: "alarm.occ.999", minute: 41)

        store.enabled = false
        await store.installWindow()

        let remaining = await pendingAlarmIdentifiers()
        XCTAssertTrue(remaining.isEmpty,
                      "installWindow with the alarm disabled must not leave requests pending (got \(remaining))")
    }

    /// And the enabled path still schedules — the gate must not have
    /// broken the normal arm flow. Needs notification authorization
    /// (a fresh/rebooted sim resets it for the app host — the alarm
    /// E2E covers this path with the prompt granted).
    func testInstallWindowSchedulesWhileEnabled() async throws {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else {
            throw XCTSkip("needs notification authorization (re-grant after a sim reboot: xcrun simctl privacy booted grant notifications com.ipodclassic.app)")
        }
        let store = AlarmStore.shared
        store.enabled = true
        store.repeatDays = Array(repeating: false, count: 7)  // daily: full window
        await store.installWindow()

        let remaining = await pendingAlarmIdentifiers()
        XCTAssertTrue(remaining.contains { $0.hasPrefix("alarm.occ.") },
                      "installWindow with the alarm enabled must schedule the occurrence window (got \(remaining))")

        store.enabled = false  // tearDown restores; this also cleans up
        await store.cancelAsync()
    }
}
