# MPVolumeView — setting system volume when no API exists

`ApplicationMusicPlayer` has no `volume` property (that's MusicKit's
design — volume belongs to the *system*, not the app). The wheel needs to
adjust volume anyway, so `MediaVolumeController` uses the one sanctioned
trick.

## The trick

`MPVolumeView` (MediaPlayer framework) is the system volume HUD/slider
control. It contains exactly one `UISlider` subview, and setting that
slider's value sets the **actual system volume**, with the OS behaving
exactly as if the user pressed hardware volume buttons.

```swift
let view = MPVolumeView(frame: .zero)     // never shown — offscreen
parent.addSubview(view)                    // must be in a window's hierarchy
if let slider = view.subviews.first as? UISlider {
    slider.value = 0.6                    // changes system volume
}
```

## Why this ugliness is the *right* tool

- The public alternatives are worse: `AVSystemController` is private API
  (App Store rejection), `MPMusicPlayerController.systemMusicPlayer`
  volume is deprecated, and the only legit public path is… this slider.
- It's the standard, shipped-in-thousands-of-apps approach; Apple's own
  sample code uses it.
- No permission prompts, works on device; the sim's volume is a no-op
  (fine — tests assert the model's bookkeeping, not the OS mixer).

## The details that make it work

- The view must exist in a live window hierarchy (some iOS versions
  ignore the slider otherwise) — hence hidden/offscreen embedding.
- The slider appears asynchronously; code that needs it polls/retries
  briefly rather than assuming it exists at init.
- Volume changes also arrive from hardware buttons — the model reads the
  current value back (or listens for change) so the on-screen bar matches
  reality even when the user used the side buttons.
- The system volume HUD is suppressed by *showing* an MPVolumeView
  nearby… the project hides the HUD where possible so the LCD's own
  volume UI is the feedback.

## Where to look

- `Sources/Features/MediaVolumeController.swift` — hidden-view setup,
  slider discovery, set/read volume.

## Related

[musickit.md](musickit.md) — the player this volume controls.
