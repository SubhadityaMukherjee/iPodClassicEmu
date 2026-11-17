# UIViewRepresentable — embedding UIKit inside SwiftUI

SwiftUI doesn't (yet) wrap every UIKit control. When you need a real
UIKit view — a system control with no SwiftUI equivalent, or one whose
behavior depends on UIKit internals — you bridge it in by making a small
SwiftUI wrapper conform to `UIViewRepresentable`:

```swift
struct AirPlayPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> some UIView {
        AVRoutePickerView()                    // create the UIKit view ONCE
    }
    func updateUIView(_ uiView: UIViewType, context: Context) {
        // sync SwiftUI state → the UIKit view whenever SwiftUI re-renders
    }
}
```

SwiftUI calls `makeUIView` once per view identity to create the embedded
view, hosts it in its hierarchy, and then calls `updateUIView` whenever
the surrounding SwiftUI state changes. (The mirror protocol
`UIViewControllerRepresentable` does the same for view controllers.)

## Why the app needs it

The Now Playing song panel offers an **AirPlay route picker**. The
control is `AVRoutePickerView` (AVKit) — a UIKit view. SwiftUI has no
native AirPlay picker, so `AirPlayPicker` wraps it via
`UIViewRepresentable` and drops it in a SwiftUI row like any other view.

Other classic uses (in the wild): `MPVolumeView` (see
[mpvolumeview.md](mpvolumeview.md) — this app hides one offscreen purely
for its system-volume side effect), `UITextView` inside wrappers where
precise text-control behavior matters, ad/payment SDK views.

## The contract you're signing up for

- **You own the bridge.** State doesn't flow automatically; anything that
  should change the UIKit view goes through `updateUIView`, and anything
  the UIKit view does back to SwiftUI goes through a `Coordinator` (an
  auxiliary class you provide for delegates/target-actions).
- **Identity rules still apply** — `makeUIView` runs once per identity;
  recycling the wrapper for a *different* value means diffing duty in
  `updateUIView`, not assuming recreation.
- Don't fight it: prefer the pure-SwiftUI approach when one exists; use
  the bridge only for what SwiftUI genuinely can't do (the Notes editor's
  `UITextView` probing and the AirPlay picker are the two live reasons
  here).

## Where to look

- `Sources/Features/Music/NowPlayingScreen.swift` — `AirPlayPicker`.
- `Sources/Features/Music/MediaVolumeController.swift` — hidden
  `MPVolumeView` embedding.

## Related

[swiftui-views-and-state.md](swiftui-views-and-state.md) — the SwiftUI
side of the bridge; [mpvolumeview.md](mpvolumeview.md) — the volume
trick that rides on this pattern.
