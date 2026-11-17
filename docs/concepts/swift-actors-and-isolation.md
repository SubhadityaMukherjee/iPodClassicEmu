# Actors and isolation (`actor`, `@MainActor`)

Modern CPUs run code on many threads at once. If two threads mutate the
same property simultaneously you get data races — undefined behavior,
crashes that reproduce "sometimes". Swift's answer is *isolation*: types
that guarantee their mutable state is touched by one execution context at a
time.

## The two tools in this codebase

### 1. `@MainActor` — the UI thread contract

The main thread is the only thread allowed to touch UIKit/SwiftUI state.
`@MainActor` marks a declaration as "must run on the main actor"; the
compiler *forces* callers from other contexts to hop over (`await`):
calling a main-actor method from a background Task suspends, hops, runs,
hops back.

- `AppModel` and every screen model is `@MainActor` (or main-actor by
  default via `@Observable` usage in a SwiftUI context).
- System callbacks arrive on arbitrary queues; the code hops home before
  touching state — e.g. `DispatchQueue.main.async` in photo callbacks, or
  `Task { @MainActor in … }`.

### 2. `actor` — a self-serializing object

An `actor` is a reference type whose every method runs exclusively: callers
from anywhere `await` their turn. It's a built-in lock with no deadlock
risk. Used for caches and loaders that background threads hammer:

```swift
actor ArtworkLoader {
    private var cache: [String: UIImage] = [:]     // safe: actor-isolated
    func image(for key: String) async -> UIImage? { … }
}
```

Outside, `await loader.image(for: key)` serializes automatically.

## Actors vs serial `DispatchQueue` — why both exist here

Older APIs (AVFoundation camera, audio sessions) predate Swift concurrency
and expose serial queues (`sessionQueue`); Apple's own sample code drives
them with `queue.async { … }`. The project uses the queue where the
framework requires it and actors for pure-Swift state. Concept page:
[dispatch-queues.md](dispatch-queues.md).

## Reentrancy trap (the subtle one)

An actor is serial *between* suspension points, not across them: while an
actor method is suspended at an `await`, another call can enter and run.
So "check cache, await load, write cache" can double-load unless the
in-flight request is tracked (the photo pipeline's `inflight` set exists
precisely for this).

## Where to look

- `Sources/UI/ArtworkView.swift` — `ArtworkLoader` actor.
- `Sources/App/AppModel.swift` — `@MainActor final class AppModel`.
- `Sources/Features/Photos/PhotoLibraryModel.swift` — main-queue hops from
  PHImageManager callbacks.

## Related

[swift-async-await.md](swift-async-await.md) — actors are used through
async/await; read that page first if `await` is unfamiliar.
