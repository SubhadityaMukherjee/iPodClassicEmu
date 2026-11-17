# UserNotifications — scheduling alarms that fire when the app is dead

Local notifications are how iOS lets an app schedule something to happen
at a future time *without the app running*. `UNUserNotificationCenter`
(the singleton) manages permission, registration, and delivery.

## Why alarms must use this (project invariant)

An in-app `Timer` dies with the process: force-quit, crash, reboot,
memory pressure — any of them silently kills it. The "alarm says on but
never rings" bug class exists precisely because in-app scheduling feels
fine when it isn't. **Alarms fire from the OS**: the app only registers
a *request* and renders UI when the system hands the notification back.

## The moving parts

### Permission (prompt once)
```swift
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
```
Denied permission is a first-class state — the alarm screen warns in
red; the setup wizard batches this prompt with the others.

### A request = trigger + content
```swift
let content = UNMutableNotificationContent()
content.title  = "Alarm"
content.sound = UNNotificationSound(named: "AlarmBeep.caf")   // ≤ 30 s

var comps = DateComponents(); comps.hour = 7; comps.minute = 30
comps.weekday = 2                       // Monday
let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)

let req = UNNotificationRequest(identifier: "alarm-mon", content: content, trigger: trigger)
try await center.add(req)
```

`UNCalendarNotificationTrigger` matches date components — a request with
a weekday set and `repeats: true` fires weekly on that weekday.
Date-component math (hour24 wrap, weekday bitmask) is Foundation
Calendar work (see [foundation.md](foundation.md)).

### Delivery back into the app
The `UNUserNotificationCenterDelegate` receives notifications while the
app is foregrounded (default behavior would only banner it) —
`AlarmNotifications` forwards to `RingerManager`, which loops the alarm
sound via AVAudioPlayer ([avfoundation-playback.md](avfoundation-playback.md))
and shows the ringer overlay **without covering the click wheel**
(dismiss must always be reachable).

## The sharp edges (all bit this project)

- **Removing a repeating request kills EVERY future occurrence** — there
  is no per-occurrence cancellation. So the in-app fire path must
  *re-schedule*: remove → hop 0.5 s (this SDK has no completion callback
  on removal) → `schedule()` again. Any exit that skips the re-schedule
  leaves the alarm enabled-but-dead.
- **Heal on foreground**: because a mid-cycle death (force-quit during
  the ringer) can skip the re-schedule, `reconcile()` re-derives what
  should be pending and repairs it at every `scenePhase .active` and at
  keep-alive start.
- **Verify, don't trust**: `pendingAlarmCount` is fetched back from the
  center (async DispatchGroup) and published; the screen's red warning
  when enabled-but-zero-pending is the UI expression of "the system says
  nothing will fire."
- Notification sounds must be ≤ 30 s and are referenced by name from the
  bundle, not by URL.

## Where to look

- `Sources/Features/Clocks/AlarmStore.swift` — scheduling, reconcile,
  checkFire, the 0.5 s re-schedule hop.
- `Sources/Features/Clocks/AlarmRingerOverlay.swift` + `ClocksScreens`
  — the ringing UI and its QA readouts.

## Related

[activitykit-live-activities.md](activitykit-live-activities.md) — the
other background-visible surface (timers/stopwatch/recording);
[foundation.md](foundation.md) — Calendar math behind triggers.
