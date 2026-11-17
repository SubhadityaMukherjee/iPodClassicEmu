# Concept docs

One page per concept. Each page explains a framework, OS service, or Swift
language mechanism that the iPod Classic emulator relies on — starting from
zero (the reader knows general programming but is new to Swift and iOS),
then why this project chose it, where it lives in the code, and the gotchas
we actually hit.

Source docstrings reference these pages with lines like:

```swift
/// Concept: AVAudioSession → docs/concepts/avfoundation-audio-session.md
```

so a concept is explained **once**, here, instead of being re-explained at
every call site.

## Swift language

| Page | Concept |
|---|---|
| [swift-optionals.md](swift-optionals.md) | Optionals, `nil`, `guard`/`if let`, force-unwrap vs safe unwrap |
| [swift-closures.md](swift-closures.md) | Closures, trailing closures, escaping closures, function types |
| [swift-value-and-reference-types.md](swift-value-and-reference-types.md) | `struct` vs `class`, copy semantics, when each is used |
| [swift-error-handling.md](swift-error-handling.md) | `throws`/`try`/`catch`, `try?`, `Result` |
| [swift-async-await.md](swift-async-await.md) | `async` functions, `Task`, structured concurrency |
| [swift-actors-and-isolation.md](swift-actors-and-isolation.md) | Actors, `@MainActor`, data races, isolation |
| [swift-property-wrappers.md](swift-property-wrappers.md) | `@State`, `@Environment`, `@Published`, property wrappers generally |
| [swift-protocols-and-generics.md](swift-protocols-and-generics.md) | Protocols, conformance, generics, `some`/`any` |
| [dispatch-queues.md](dispatch-queues.md) | GCD queues, serial queues (`sessionQueue`), the main queue |

## UI & reactive

| Page | Concept |
|---|---|
| [swiftui-views-and-state.md](swiftui-views-and-state.md) | SwiftUI views, `body`, `@Observable`/`ObservableObject`, view identity & lifecycle |
| [uiviewrepresentable.md](uiviewrepresentable.md) | Embedding UIKit views (AirPlay picker, MPVolumeView) in SwiftUI |
| [combine.md](combine.md) | Combine publishers/subscribers (`PassthroughSubject`, `onReceive`) |

## System services & persistence

| Page | Concept |
|---|---|
| [foundation.md](foundation.md) | Foundation essentials: `Date`, `Calendar`, `String`, `Data`, `FileManager` |
| [userdefaults.md](userdefaults.md) | UserDefaults key-value persistence |
| [nscache.md](nscache.md) | `NSCache` — memory cache with eviction |
| [activitykit-live-activities.md](activitykit-live-activities.md) | Live Activities / Dynamic Island |

## Device input & feedback

| Page | Concept |
|---|---|
| [corehaptics.md](corehaptics.md) | CoreHaptics vibration transients |

## Audio

| Page | Concept |
|---|---|
| [avfoundation-audio-session.md](avfoundation-audio-session.md) | `AVAudioSession` — the iOS audio-policy singleton |
| [avfoundation-playback.md](avfoundation-playback.md) | `AVAudioPlayer` (play-a-sound) vs `AVAudioSourceNode` (real-time synthesis) |
| [audiotoolbox.md](audiotoolbox.md) | AudioServices system sounds |
| [mpvolumeview.md](mpvolumeview.md) | The hidden-slider system-volume trick |

## Media libraries

| Page | Concept |
|---|---|
| [musickit.md](musickit.md) | MusicKit, `ApplicationMusicPlayer`, queue semantics |
| [photokit.md](photokit.md) | PHPhotoLibrary image loading & caching |
| [avfoundation-camera.md](avfoundation-camera.md) | AVCaptureSession pipeline, session queue, delegates, torch |
| [eventkit.md](eventkit.md) | EventKit calendar access & queries |
| [remote-commands.md](remote-commands.md) | MPRemoteCommandCenter / Now Playing info |

> Pages are added batch-by-batch as documented code reaches them; the list
> above grows over time. When you add a page, add it to this index.
