# CoreHaptics — programmatic vibration

Haptics = touch feedback, the buzz you feel. iOS offers it at two levels,
and the click wheel uses **both**:

## Level 1: `UIImpactFeedbackGenerator` (UIKit) — the easy preset

```swift
let gen = UIImpactFeedbackGenerator(style: .rigid)
gen.prepare()          // warms the Taptic Engine so fire is instant
gen.impactOccurred(intensity: 0.8)
```

One line, a few preset styles (`.light`, `.rigid`, `.heavy`…). Latency is
low but you can't customize the *shape* — just intensity.

## Level 2: `CHHapticEngine` (CoreHaptics) — the full synthesizer

The Taptic Engine is literally an audio-to-vibration device: you schedule
**events** with frequency/amplitude envelopes, like a synth.

```swift
let engine = try CHHapticEngine()
let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
], relativeTime: 0)
try engine.start()
try engine.play(events: [event])
```

- `.hapticTransient` = a click/tick (short, percussive) — what each wheel
  detent fires.
- `.hapticContinuous` = a sustained buzz (used elsewhere for alerts).

## How `WheelHaptics` combines them

- **Transients (CoreHaptics)** for the scroll detent ticks — the crisp
  iPod wheel feel needs the low-latency custom engine.
- **UIImpact** for button presses — presets are plenty there.
- `prepare()`/keeping the engine alive so the first tick after idle isn't
  late.
- Failure is always tolerated: haptics are denied on some devices/simulators;
  every call is wrapped so a missing engine degrades to silence, never a
  crash.

## The throttling rule (why `WheelFeedback` exists)

Fast spins fire detents far faster than the engine can usefully render —
saturation makes haptics feel like one long blur and burns CPU. The
feedback layer caps pulses (~50/s) and merges extras, and applies the
user's haptics settings (on/off, strong scroll, heavy button). The wheel
*coordinator* computes *when* a tick happened; `WheelFeedback` decides
*whether it becomes a pulse + sound*. Separation of concerns, and the
same seam lets tick sounds be disabled without touching haptics.

## Gotchas

- `CHHapticEngine` `start()` can throw (engine lost, e.g. backgrounding) —
  always `try?` + reset, and re-`prepare` after interruptions.
- CoreHaptics does nothing on the simulator — real device only for feel.
- Battery: transient events are cheap; the throttle keeps them cheap.

## Where to look

- `Sources/Wheel/WheelHaptics.swift` — engine setup, both generator types.
- `Sources/Wheel/ClickWheelView.swift` / `WheelCoordinator` — when ticks
  fire; `WheelFeedback` — rate limiting.

## Related

[audiotoolbox.md](audiotoolbox.md) — the audible half of a wheel tick.
