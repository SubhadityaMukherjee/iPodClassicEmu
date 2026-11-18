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

The app originally used `repeats: true` triggers (one daily, or one per
weekday). Two structural traps forced a rewrite (2026-11-18) onto the
pattern production alarm apps use — the **occurrence window**:

- **Removing a repeating request kills EVERY future occurrence** — there
  is no per-occurrence cancellation. Every fire/edit/disable path had to
  dance around never removing what it still wanted; one miss = "alarm
  says on but never rings again."
- **Cancel-then-add of the same identifier races in the notification
  daemon** — the remove can land AFTER the add and silently delete the
  fresh request, and `removePendingNotificationRequests` has no
  completion callback to sequence against.
- **Focus can mute the banner** ("notification comes, nothing rings"):
  Sleep Focus suppresses standard notifications, and `.timeSensitive`
  only breaks through if the user allows it per-app. The banner arriving
  in the morning ≠ it ever having sounded.

### The window model (`AlarmStore`, current)

1. Schedule the **next seven occurrences** as one-shot,
   fully-specified triggers with deterministic per-date ids
   (`alarm.occ.<epoch>`). No repeating requests exist, so the first two
  traps are structurally impossible; iOS replaces same-id requests, so
   re-adding is idempotent; 7 slots stays far under the 64-pending cap.
2. **The OS's pending list is the source of truth** — reconciliation
   reads what is actually pending, sweeps `alarm.`-prefixed ids that are
   no longer wanted (edited times, old-era weekday triggers, snoozes,
   ghosts), adds what's missing, then **verifies by re-reading** and
   repairs once. Runs at launch, every foreground, and after any edit.
3. **One serialized maintenance slot**: every schedule/cancel/reconcile
   pass runs as a single cancellable Task — a straggler install that
   started while armed can't interleave past a disable's sweep and arm
   a ghost.
4. **Delivery diagnostics**: the verify pass also reads
   `soundSetting`/`timeSensitiveSetting` and the alarm screen warns
   (amber, tap-to-Settings) when iOS will deliver the banner silently —
   the environmental failure the app cannot fix, it can only name it.
5. **Notification sounds** must be ≤ 30 s and are referenced by name
   from the bundle root; and note the in-app ringer is MEDIA audio —
   audible under Focus and even the mute switch — which is why the
   background keep-alive (process stays alive via silent audio) is the
   primary overnight path, with the notification as the killed-app
   fallback.

## Where to look

- `Sources/Features/Clocks/AlarmStore.swift` — scheduling, reconcile,
  checkFire, the 0.5 s re-schedule hop.
- `Sources/Features/Clocks/AlarmRingerOverlay.swift` + `ClocksScreens`
  — the ringing UI and its QA readouts.

## Related

[activitykit-live-activities.md](activitykit-live-activities.md) — the
other background-visible surface (timers/stopwatch/recording);
[foundation.md](foundation.md) — Calendar math behind triggers.
