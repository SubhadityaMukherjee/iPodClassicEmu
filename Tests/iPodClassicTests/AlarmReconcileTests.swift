import XCTest
import UserNotifications
@testable import iPodClassic

/// Alarm notification reconciliation: the persisted store is the source
/// of truth for system notifications. This is the ghost-alarm fix —
/// RESET_DEFAULTS (every UI-test launch) clears the persisted state but
/// NOT the notification center, so a stale repeating trigger would ring
/// daily forever with nothing armed.
///
/// (The reschedule side of reconcile() needs notification authorization,
/// which the unit-test runner cannot grant — it's exercised by the alarm
/// E2E tests on the simulator instead.)
@MainActor
final class AlarmReconcileTests: XCTestCase {
    private var savedEnabled: Bool = false

    override func setUp() {
        super.setUp()
        savedEnabled = AlarmStore.shared.enabled
    }

    override func tearDown() {
        AlarmStore.shared.enabled = savedEnabled
        super.tearDown()
    }

    private func pendingAlarmIdentifiers() async -> [String] {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                cont.resume(returning: requests.map { $0.identifier }.filter { $0.contains("alarm") })
            }
        }
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
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            UNUserNotificationCenter.current().add(request) { _ in cont.resume() }
        }
    }

    func testReconcileRemovesStaleTriggersWhenDisabled() async throws {
        let store = AlarmStore.shared
        store.enabled = false  // disable: nothing may remain pending
        await addStaleTrigger(identifier: "alarm.daily", minute: 53)
        await addStaleTrigger(identifier: "alarm.snooze", minute: 2)
        await addStaleTrigger(identifier: "alarm.day.4", minute: 15)

        store.reconcile()

        let remaining = await pendingAlarmIdentifiers()
        XCTAssertTrue(remaining.isEmpty,
                      "reconcile with the alarm disabled must clear every stale trigger (got \(remaining))")
    }

    func testDisablingCancelsAPendingSnooze() async throws {
        let store = AlarmStore.shared
        store.enabled = true
        await addStaleTrigger(identifier: "alarm.snooze", minute: 2)

        store.enabled = false  // disable must also cancel the snooze

        let remaining = await pendingAlarmIdentifiers()
        XCTAssertFalse(remaining.contains("alarm.snooze"),
                       "a snoozed alarm left pending after disable would ring 9 minutes later as a ghost")
    }
}
