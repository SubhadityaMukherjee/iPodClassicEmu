# Closures

A closure is a self-contained block of code you can store in a variable,
pass as an argument, and run later — the same idea as a lambda/anonymous
function in other languages. Swift functions are just closures with names.

```swift
let double = { (x: Int) in x * 2 }
double(4)                       // 8
```

## Forms you'll see in this codebase

```swift
// Trailing-closure syntax: when the last parameter is a closure,
// it moves outside the parentheses — this is the shape of ALL SwiftUI.
Button("Play") { startPlayback() }
MenuScreen { row in handleTap(row) }

// Closures as callbacks / handlers:
session.activate { error in /* runs later, on some queue */ }

// Stored closures (a "provider"): the Reader hands the audiobook engine
// a closure that returns the current page's text whenever asked.
let pageText: () -> String

// @escaping: the closure is kept and called AFTER the function returns.
// Required whenever a stored/callback closure is a parameter.
func poll(every interval: TimeInterval, handler: @escaping () -> Void)

// Capture lists: [weak model] avoids a retain cycle — without it,
// a stored closure that captures `model` keeps it alive forever.
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
    self?.tick()
}
```

## Why closures matter here

- **SwiftUI is closures.** `body` composes views by nesting trailing
  closures; every `{ ... }` inside a view is building UI.
- **Deferred providers.** `AudiobookModel` receives closures from
  `BookScreen` ("give me the text of the page now showing") because the
  engine must re-fetch the text on every page turn, long after the call
  site has returned — an escaping closure is the mechanism for that.
- **Cross-thread boundaries.** Camera and audio callbacks arrive on
  arbitrary system queues; the closure body hops to the main queue before
  touching UI state.

## Gotchas learned here

- A closure captures the variables it uses **strongly by default**. Storing
  a closure inside an object that captures the object back = retain cycle =
  memory leak. `[weak self]` breaks it; see
  [swift-actors-and-isolation.md](swift-actors-and-isolation.md).
- FluidAudio's transcription API takes a `decoderState: inout` parameter —
  closures cannot capture `inout` args, which is one reason the
  transcription loop is a plain `for` loop rather than a callback chain.

## Related

[swift-async-await.md](swift-async-await.md) — `async`/`await` is the
modern alternative to passing completion closures; the project uses both,
choosing per API.
