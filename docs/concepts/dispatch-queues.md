# Dispatch queues — GCD, serial queues, and the main queue

Grand Central Dispatch (GCD) is iOS's kernel-level job scheduler. A
**dispatch queue** is a line of work blocks executed one after another;
`queue.async { … }` means "add this block to the line and return
immediately." Three flavors matter here:

| Queue | Behavior | Used for |
|---|---|---|
| `DispatchQueue.main` | The **UI thread**. All SwiftUI/UIKit state lives here. | every UI update |
| serial queue (`let q = DispatchQueue(label: "cam")`) | one block at a time, in order, off the main thread | session-serialized hardware access |
| concurrent (`label:…, attributes: .concurrent`) | many blocks at once | background work pools |

## Why "sessionQueue" exists — the serial-queue pattern

AVFoundation's camera (and older audio APIs) have a hard rule: **all calls
into the session must be serialized** — configure, start, capture, lens
flip. Two threads calling simultaneously = undefined behavior. Apple's
pattern, used by `CameraModel`, is one private serial queue:

```swift
private let sessionQueue = DispatchQueue(label: "com.ipodclassic.camera")

func configure() {
    sessionQueue.async {
        self.session.beginConfiguration()   // every session touch is on the queue…
        …
        self.session.commitConfiguration()
    }
}
func capture() {
    sessionQueue.async { self.photoOutput.capturePhoto(…) }  // …so they can't overlap
}
```

Everything on one serial queue can never race each other, and being off
main keeps configuration (slow) from freezing the wheel/UI. Results hop
back: `DispatchQueue.main.async { self.latestFrame = … }`.

## The mental model: queues vs actors vs async/await

Three tools for the same fear (two threads, one piece of state):

- **Serial DispatchQueue** — Objective-C era; blocks, not async/await;
  required by AVFoundation-style APIs and their delegates. No compile-time
  checking; pure convention + queue discipline.
- **`actor`** ([swift-actors-and-isolation.md](swift-actors-and-isolation.md))
  — Swift-native equivalent: methods instead of blocks, `await` at the
  boundary, compiler-enforced. Preferred for *new* pure-Swift state.
- **`@MainActor`** — the special case "serialize on the UI thread."

Rule of thumb in this codebase: hardware/framework objects keep their
`sessionQueue`; Swift-level caches and loaders are actors; everything UI
is main-actor. Don't mix two protections on one piece of state (a queue
guarding state an actor also guards just confuses).

## Deadlock rule

Never `queue.sync` onto a queue you might already be running on (or into
the main thread from main) — instant deadlock. Hops are one-directional:
background → main to publish; main → background via `async` only.

## DispatchSourceTimer — cancelable one-shot/repeating timers on a queue

`Timer.scheduledTimer` is bound to a run loop (usually main) and pauses
when the run loop is busy or the app backgrounds. For wheel hold-repeat
and similar interaction timers the project uses GCD's timer source:

```swift
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 0.5, repeating: 0.16)
timer.setEventHandler { … }     // fires on the chosen queue
timer.resume()                  // armed only after resume
timer.cancel()                  // one-shot cancellation, no retain issues
```

Why it wins over `Timer` here: cheap create/cancel per gesture (every
press schedules, every release cancels), precise deadlines, and no run
-loop mode surprises. The lifecycle rule: a `DispatchSource` starts
*suspended* — `resume()` exactly once or the handler never fires; cancel
before dropping the reference to avoid late fires (`WheelCoordinator`'s
hold timers follow exactly this pattern).

## Where to look

- `Sources/Features/Camera/CameraModel.swift` — the canonical
  `sessionQueue` (zoom, lens flip, capture all serialized).
- Photo callbacks (`PhotoLibraryModel`) — image requests return on
  arbitrary queues; every cache mutation hops to main first.

## Related

[swift-actors-and-isolation.md](swift-actors-and-isolation.md) —
[swift-async-await.md](swift-async-await.md) — the modern face of the
same scheduling machinery.
