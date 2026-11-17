# Combine (`PassthroughSubject`, `onReceive`)

Combine is Apple's reactive-events framework: values flow from
**publishers** to **subscribers** over time. This project uses exactly one
slice of it — a typed, broadcast event bus — because the problem is "many
screens want wheel events, only the top one should react," which is a
subscription problem, not a state problem.

## The one pattern used

```swift
// AppModel (the hub):
let controlBus = PassthroughSubject<ControlEvent, Never>()

// Every screen (subscribers):
.onReceive(model.controlBus) { event in
    switch event { … }        // only the top screen's handler acts
}
```

- `PassthroughSubject<Element, Never>` — a publisher you feed by hand.
  `send(event)` pushes to all current subscribers; nothing is stored or
  replayed (no subscriber = the event evaporates).
- `Never` — the failure type: this channel can't error out.
- `.onReceive(…)` — a SwiftUI modifier that subscribes for the view's
  lifetime on the main run loop and calls the closure per event. The view
  body re-derives nothing; it's plain imperative handling inside the
  closure.

## Why a bus instead of direct calls?

The wheel (`ClickWheelView`) is a global input device; which screen should
react changes with navigation. Direct wiring would make the wheel know
every screen. Instead: wheel → `AppModel.handle(_:)` (hold switch, sleep,
global transport interception) → `controlBus.send(event)` → whichever
screens are mounted filter for what's theirs. Screens never reach into
each other's state — the project's stated rule.

## Why Combine and not async sequences?

Both exist (`AsyncStream` would also work). Combine is chosen here because
`.onReceive` binds a subscription to a SwiftUI view's *lifetime*
automatically (subscribe on appear, tear down on disappear) — with
AsyncStream we'd manage that by hand. There's no backpressure, combine
operators, or error-channel complexity in play; the bus stays a
one-liner.

## Where to look

- `Sources/App/AppModel.swift` — `controlBus`, `handle(_:)` interception
  order (hold switch → sleep → global transport → screen).
- Any screen file — `.onReceive(model.controlBus)` blocks are the input
  contract of that screen.

## Related

[swiftui-views-and-state.md](swiftui-views-and-state.md) — the other half
of the input story (state changes re-render; events drive logic).
