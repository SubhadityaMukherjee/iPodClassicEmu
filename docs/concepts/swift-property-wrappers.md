# Property wrappers (`@State`, `@Environment`, `@Published`, `@AppStorage`)

A property wrapper is a generic struct that "wraps" a stored property and
injects behavior into every read and write of it — declared with `@`. You
write `@State var x = 0` and reads/writes of `x` secretly call the
wrapper's code. They exist to remove boilerplate: instead of writing
get/set logic, observers, and persistence hooks at every property, you
attach one attribute.

## The wrappers this project actually uses

### `@State` — a view's private, persistent storage

```swift
struct PlayerScreen: View {
    @State private var showQueue = false
}
```

SwiftUI destroys and recreates view *structs* constantly; `@State` moves the
actual storage out of the struct into SwiftUI's care, so the value survives
re-creation and, when the view body *reads* it, invalidates that body on
change. Rules of thumb enforced all over this codebase:

- Always `private`.
- Writing a `@State` the body never **reads** does nothing (no
  re-render) — a real bug here once: a heartbeat counter updated every 2s
  but never read, so the dim overlay never appeared. Periodic re-renders
  now go through the observable `AppModel.clockTick`.
- `@State` lifetime is tied to the view's *identity* on screen, not to the
  Swift variable — same-route re-creation keeps state, see
  [swiftui-views-and-state.md](swiftui-views-and-state.md).

### `@StateObject` / `@ObservedObject` / `@EnvironmentObject` — borrowed observable objects

- `@StateObject var model` — SwiftUI creates **and owns** the object for
  the lifetime of the view identity (use at the "birthplace" of a model).
- `@ObservedObject var model` — the object lives elsewhere; this view just
  re-renders on its changes (passing a model down into a child screen).
- `@EnvironmentObject` / `@Environment(\.displayScale)` — dependency
  injection from ancestors: the environment carries system values
  (display scale, color scheme, scene phase) and shared objects so they
  don't have to be threaded through every init.

### `@Published` — the change announcer inside `ObservableObject`

```swift
final class AppSettings: ObservableObject {
    @Published var hapticsOn = true { didSet { save() } }
}
```

`@Published` fires `objectWillChange` on write, which is what makes every
`@ObservedObject`/`@StateObject` view re-render. Note the companion gotcha:
plain computed properties backed by `UserDefaults` do **not** notify —
`AppSettings` calls `objectWillChange.send()` explicitly in its setters.

### `@AppStorage` — not used here

SwiftUI's UserDefaults wrapper; this project centralizes defaults access in
`AppSettings`/feature stores instead, with explicit `objectWillChange` and
QA-resettable keys. See [userdefaults.md](userdefaults.md).

## Where to look

- `Sources/App/AppSettings.swift` — the explicit-notify pattern.
- `Sources/Device/DeviceView.swift` — `@State` + observable reads for the
  dim overlay (the heartbeat regression lives in git history).

## Related

[swiftui-views-and-state.md](swiftui-views-and-state.md) for how
observation drives re-rendering overall.
