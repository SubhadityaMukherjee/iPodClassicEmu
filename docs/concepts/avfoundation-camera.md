# AVCaptureSession — the camera pipeline

AVFoundation's capture stack is a pipeline of connected objects:

```
AVCaptureDevice (the lens)
   └─ AVCaptureDeviceInput
        └─ AVCaptureSession   ← the hub; everything connects through it
             └─ AVCapturePhotoOutput  (still photos → your delegate)
             └─ AVCaptureVideoPreviewLayer (what the user sees)
```

- **`AVCaptureSession`** — the central object. `beginConfiguration() /
  commitConfiguration()` bracket any change to inputs/outputs (atomic,
  batched). `session.startRunning()` is **blocking** — never call it on
  the main thread.
- **`AVCaptureDevice`** — one physical lens (wide/back, front). zoom,
  position, torch live here. `lockForConfiguration()` / unlock brackets
  setting properties (it throws).
- **`AVCapturePhotoOutput`** — `capturePhoto(with:delegate:)` hands the
  full-res shot to a delegate object.

## The serial-queue rule

All calls into the session must be serialized. `CameraModel` owns one
private serial `DispatchQueue` (`sessionQueue`); configure/start/capture/
zoom/lens-flip all go through it. See
[dispatch-queues.md](dispatch-queues.md) — this is the canonical
sessionQueue pattern, straight from Apple's sample code.

## Why delegates require a class (NSObject)

`AVCapturePhotoCaptureDelegate` methods arrive later, on a queue, and the
system holds a reference to the delegate through the callback — a
value-type struct can't fulfill that (identity + lifetime). Hence
`final class CameraModel: NSObject, AVCapturePhotoCaptureDelegate`. This
is an Objective-C-era contract; structs are simply not eligible.

## Device-only, permission-gated

- Camera needs the `NSCameraUsageDescription` Info.plist key and the
  runtime permission prompt (part of the setup wizard).
- **The camera does not exist on the simulator** — the screen is
  device-only (which is why README camera shots come from the sim's
  *photo* assets, never a live preview).
### The preview layer is a `CALayer`, not a SwiftUI view — camera screens
### bridge it in via `UIViewRepresentable`
([uiviewrepresentable.md](uiviewrepresentable.md)).

## The torch (flashlight)

The LED flash is a camera-device property, which is why the Flashlight
screen reaches for `AVCaptureDevice` despite never taking a picture:

```swift
let device = AVCaptureDevice.default(for: .video)!
try device.lockForConfiguration()   // exclusive change window; throws
device.setTorchModeOn(level: 0.5)   // 0.0…1.0 brightness
device.unlockConfiguration()
```

Rules: guard `hasFlash`/`isTorchModeSupported`, always lock/unlock
around changes, and torch level can only be set while the torch is
already on or being turned on (the screen's `setTorch` handles the
ordering). The Extras flashlight turns the torch **off when the screen
pops** — leaving it on after navigation was a real bug — so its MENU
handler fires a torch-off before the pop.

## Project-specific behaviors documented in the code

- Wheel = zoom (a ramped `videoZoomFactor` on the session queue).
- prev/next = aspect ratio; **hold = flip lens, rate-limited to one flip
  per hold** — hold events repeat every ~0.18s, and unrestrained handling
  toggled the lens back and forth.
- The camera screen *claims* the transport buttons
  (`model.transportClaimedByScreen`) so prev/next reach the camera, not
  the music player — the one screen that overrides the global transport
  rule.

## Where to look

- `Sources/Features/Camera/CameraModel.swift` — session pipeline.
- `Sources/Features/Camera/CameraScreen.swift` — UI + input handling.

## Related

[dispatch-queues.md](dispatch-queues.md) — the sessionQueue pattern;
[avfoundation-audio-session.md](avfoundation-audio-session.md) — the
audio sibling of "one object owns the hardware."
