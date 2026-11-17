# SwiftUI views, observation, and view identity

SwiftUI is a *declarative* UI framework: instead of imperatively mutating
views ("set this label's text"), you declare what the UI should look like
**as a function of state**, and the framework diffes and updates the screen
whenever that state changes.

## Views are cheap value descriptions

```swift
struct NowPlayingScreen: View {
    let song: Song                      // inputs are plain values
    var body: some View {               // body = "give me the UI for NOW"
        VStack { Text(song.title) … }
    }
}
```

A `View` struct is not the pixels — it's a lightweight *description* of the
UI. SwiftUI calls `body` whenever inputs change, diffs the new description
against the old, and applies the minimal real updates. Consequences this
codebase lives by:

- `body` must be a pure function of its inputs (no side effects on the
  render path).
- Views are recreated constantly; only `@State`/observable storage
  persists. See [swift-property-wrappers.md](swift-property-wrappers.md).
- Heavy work (image decode, transcription) never happens in `body`;
  models own it and publish results.

## Observation: the two eras

**`ObservableObject` (Combine-based, older):**
```swift
final class AppSettings: ObservableObject {
    @Published var hapticsOn: Bool
}
```
Views subscribe via `@StateObject`/`@ObservedObject`; writes fire
`objectWillChange`, and every view holding the object re-renders. Gotcha
hit here: `@Published` is the only auto-announcer — computed properties
backed by UserDefaults need explicit `objectWillChange.send()`
(`AppSettings` does this in every setter).

**`@Observable` (Observation framework, newer):**
```swift
@Observable final class AppModel { var stack: [Route] = [] }
```
The macro rewrites stored properties into tracked access; only views that
actually *read* `stack` re-render when it changes. `AppModel` uses this.
The older heartbeat bug (a written-but-never-read `@State` never
re-rendering anything) is the same law from the other side: **no read, no
dependency, no update**.

## View identity — why `id` matters

SwiftUI matches old and new view descriptions by *identity*. Same position
+ same type = same identity = keep subview state. `ForEach(items)` uses
`Identifiable` (stable `id`) — rows keep their `@State` across reorders.
This project's sharp edge: `ScreenRouter` keeps deep screens alive by
identity (`ForEach(stack) { route in … }` keyed by route value), so state
survives pops; and `PhotoDetailScreen` seeds `State(initialValue:)` in a
custom `init` because a re-created view with an equal route value is the
"same" view but a *fresh* struct with *fresh* `@State`.

## Navigation = a value array

The whole app's navigation is `stack: [Route]` (an enum) inside `AppModel`.
Push = append, pop = remove, deep-link = replace. Every screen is a pure
function of its `Route` value; see `Sources/Device/ScreenRouter.swift`.

## Lifecycle hooks used here

- `.onAppear` — record recents, kick loads, start observing.
- `.onReceive(model.controlBus)` — screens subscribe to wheel events
  ([combine.md](combine.md)).
- `.task` — async work cancelled automatically when the view goes away
  ([swift-async-await.md](swift-async-await.md)).
- `scenePhase` (environment) — foreground/background transitions drive
  alarm reconciliation and position autosave.

## Related

[combine.md](combine.md) — the event bus wiring screens to the wheel.
