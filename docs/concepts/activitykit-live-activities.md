# ActivityKit — Live Activities & Dynamic Island

A **Live Activity** is a card your app pins to the Lock Screen (and, on
supported devices, the Dynamic Island) that updates in real time while your
app is backgrounded — Apple's own Clock timer, food delivery, flight
boards. This app mirrors the timer, stopwatch, and voice-memo recording
there.

## The three moving parts

### 1. Shared attributes (`Shared/TrackActivityAttributes.swift`)

```swift
struct TrackActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable { … }   // the CHANGING values
    var kind: Kind                                   // fixed at start
}
```

`ActivityAttributes` defines the activity's data contract: fixed fields
(timer kind) plus a `ContentState` of values that update over time
(elapsed base, title, % done). The **same file compiles into BOTH the app
and the widget extension** — both sides must decode identical types, hence
the shared target membership.

### 2. The widget extension (`iPodClassicWidgets`)

A separate process (`com.ipodclassic.app.widgets`) renders the actual
card. Its SwiftUI code reads the attributes/content state and draws lock
screen + island layouts. The extension is declared in `project.yml` and
`NSSupportsLiveActivities` must be true.

### 3. The app side (`LiveActivityManager`)

```swift
activity = try Activity.request(
    attributes: attrs, content: .init(state: initial, staleDate: nil))
// later:
await activity.update(ActivityContent(state: newState, staleDate: nil))
await activity.end(nil, dismissalPolicy: .immediate)
```

## Why the project's usage looks the way it does

- **`Text(timerInterval:)` does the ticking.** The lock-screen timer
  counts up/down by itself — the system re-renders that text every second
  without waking the app. The app only posts updates on *state changes*
  (start/pause/resume/lap/end): no push tokens, no per-second updates, no
  battery cost. Look for `Text(timerInterval: now...endDate)` in the
  widget code.
- **Count-up re-derivation.** After a process restart the elapsed value is
  re-derived from a stored base via registered providers
  (`recorderElapsedProvider` / `stopwatchElapsedProvider`) so a resumed
  activity shows the correct running total, not zero.
- **First-launch retry.** A fresh install races the widget extension's
  registration: `Activity.request` fails once, and
  `LiveActivityManager` retries (wanted set, ≤4 attempts, 1.2s apart)
  instead of silently dropping the activity. Failures log on category
  `liveactivity`.
- **One activity per kind** — starting a second timer replaces the first
  (matching Apple's Clock behavior).

## Constraints worth knowing

- Requires a real device for Dynamic Island; the simulator shows lock
  screen cards only.
- Activities expire (8h hard cap, 12h stale limit system-wide); long
  recordings update states at coarse milestones.
- `Activity.request` throws — the manager catches and queues rather than
  crashing launch.

## Where to look

- `Sources/App/LiveActivityManager.swift` — request/update/end + retry.
- `Shared/TrackActivityAttributes.swift` — the shared contract.
- Widget UI lives in the `iPodClassicWidgets` target.

## Related

[swiftui-views-and-state.md](swiftui-views-and-state.md) — the widget side
is SwiftUI too; [usernotifications.md](usernotifications.md) — alarms use
notifications instead because they must fire when no activity is running.
