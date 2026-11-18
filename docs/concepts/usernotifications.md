# UserNotifications — scheduling when the app isn't running

Local notifications are how iOS lets an app schedule something to happen
at a future time *without the app running*. `UNUserNotificationCenter`
(the singleton) manages permission, registration, and delivery. This app
uses them for the countdown **timer**.

## Why in-app timers are insufficient

A `Timer` dies with the process: force-quit, crash, memory pressure —
any of them silently kills it. For the timer's "finished" moment the app
registers a *request* with the system and renders UI when the system
hands the notification back.

## The moving parts

### Permission (prompt once)
```swift
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
```
Denied permission is a normal state; the setup wizard batches this
prompt with the others.

### A request = trigger + content
```swift
let content = UNMutableNotificationContent()
content.title = "Timer"
content.sound = UNNotificationSound(named: "AlarmBeep.caf")   // ≤ 30 s

let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
let req = UNNotificationRequest(identifier: "timer.fire", content: content, trigger: trigger)
try await center.add(req)
```
One-shot interval trigger — simple, cancelable by identifier.

### Delivery back into the app
The `UNUserNotificationCenterDelegate` (`TimerNotificationsDelegate`)
receives notifications while the app is foregrounded and forwards them
to `RingerManager` — the in-app overlay plus the **media-audio tone
loop** (which plays through the hardware mute switch; the notification's
own sound does not).

## The hard lesson: why there is no alarm feature (removed 2026-11-18)

This project shipped a weekday alarm for months and went through every
scheduling design (repeating `UNCalendarNotificationTrigger`s → an
occurrence-window of one-shot triggers with verify-and-repair). The
scheduling was eventually bulletproof — and irrelevant, because of two
platform facts no third-party app can escape:

1. **The notification sound obeys the hardware mute switch and Focus
   modes.** A muted phone delivers the banner in total silence.
2. **A force-quit kills every app path.** No process → no in-app media
   audio; the muted notification is all that remains.

Apple's Clock app is special-cased by the OS (mute-switch-immune,
DND-breaking); no public API grants those powers. A wake-up alarm that
can silently fail is worse than none, so the feature was removed by user
decision — "cannot afford missing alarms" — and a launch-time sweep
deletes any legacy `alarm.`-pending requests.

Rules that survive that lesson:

- Notification **sounds** must be ≤ 30 s, bundled, referenced by name —
  and they obey the mute switch; never treat them as alarm-grade.
- App-owned media audio (AVAudioPlayer on an active session) punches
  through the mute switch — but only while the process lives.
- `Time Sensitive` interruption level lets a notification through Focus
  *only if* the user allows it per-app — check
  `notificationSettings()`, warn in UI when it's off.

## Where to look

- `Sources/Features/Clocks/TimerStopwatchModels.swift` —
  `TimerModel.scheduleNotification`, `RingerManager`,
  `TimerNotificationsDelegate`.

## Related

[avfoundation-audio-session.md](avfoundation-audio-session.md) — the
session the tone loop plays on; [activitykit-live-activities.md](activitykit-live-activities.md)
— the timer's lock-screen countdown.
