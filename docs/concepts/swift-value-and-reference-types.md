# Value types vs reference types (`struct` vs `class`)

Swift has two kinds of named types, and choosing between them is a real
design decision:

- **`struct`, `enum`** — *value types*. Assignment **copies**. Two variables
  never share a struct. `let`/`var` on the variable controls the whole thing.
- **`class`** — *reference type*. Assignment copies only the *reference*;
  two variables point at the same object. Has identity, inheritance,
  deinit, and — critically — **can be observed for changes**
  (`ObservableObject`) and can be shared across threads behind an actor.

## The default in this codebase: struct

Almost everything is a struct — `Route`, `ControlEvent`, `Song` rows, every
SwiftUI view. Benefits:

- Free thread-safety reasoning: handing a struct to another thread hands it
  a private copy; nobody can mutate it under you.
- SwiftUI *requires* view values to be cheap, disposable descriptions. Views
  are structs; the framework diffs them.
- Value semantics kill "who else holds this array?" bugs: filtering a
  `[Song]` can never mutate the caller's array.

## When the project uses `class` (and why)

| Need | Why a class | Example |
|---|---|---|
| Shared mutable state that views observe | Only classes can be `ObservableObject`/`@Observable` | `AppModel`, `AppSettings`, `PlayerModel` |
| API demands it | Delegate protocols require Objective-C classes | `CameraModel: NSObject, AVCapturePhotoCaptureDelegate` |
| Identity-based caching/registry | One shared instance everyone points at | `TranscriptionManager`, `MusicService` |
| Background-protected mutable state | An `actor` is a reference type with locking built in | `ArtworkLoader` |

You'll also see `final class` — `final` just forbids subclassing, a small
compiler optimization and a "this is a leaf" signal, nothing deeper.

## The mutation trap (why `struct` + method + `mutating`)

Structs can't be mutated through just any reference — you'll see
`mutating func` in value-type helpers (e.g. list-cursor math): it marks a
method that rewrites `self`, allowed only when the struct sits in a `var`.

## Where to look

- `Sources/App/AppModel.swift` — `Route`/`ControlEvent` are tiny structs
  (pure values, compared by `==`, hashed into sets); `AppModel` itself is a
  class because the whole app points at one instance.
- `Sources/Features/Camera/CameraModel.swift` — forced to be a class by the
  AVCapture delegate requirement.

## Gotchas learned here

- SwiftUI view identity: two structs with equal contents are the *same*
  value — `ScreenRouter` keys deep screens by route *value*, which is why
  `PhotoDetailScreen` needed an explicit `State(initialValue:)` seed: a
  re-created view with the same route value does **not** keep old `@State`.
  See [swiftui-views-and-state.md](swiftui-views-and-state.md).
