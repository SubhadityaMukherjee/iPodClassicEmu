# Protocols, extensions, and generics

## Protocols — a contract, not a base class

A protocol lists requirements (methods/properties); any type can *conform*.
Unlike inheritance, conformance is retroactive and orthogonal — a struct, a
class, and an enum can all conform to the same protocol. This is how Swift
does interfaces/mix-ins:

```swift
protocol AudiobookSynthesizerType {           // the seam in ReadAloudTTS
    var isReady: Bool { get }
    func synthesize(text: String, language: String?, voiceName: String?)
        throws -> (samples: [Float], sampleRate: Int)
}
```

The three TTS engines (supertonic, qwen, breeze) each conform; `AudiobookModel`
depends only on the protocol. Swapping engines — or faking one in tests —
is then a one-line change. The project's *type-seam* pattern.

Protocols you'll meet constantly from the SDK:

- `View` — every SwiftUI screen's `body`.
- `ObservableObject` — classes that announce changes.
- `Hashable`/`Identifiable`/`Equatable` — required to put values in
  `Set`/`Dictionary`, drive SwiftUI `ForEach`, compare routes.
- `AVCapturePhotoCaptureDelegate`, `UNUserNotificationCenterDelegate`,
  `AVAudioPlayer`'s delegate — callback contracts from Objective-C APIs.

## Extensions — add members to any type, anywhere

```swift
extension Date {
    var ipodTimeString: String { … }   // now every Date has this
}
```

Used for helper groupings (`Date`, `String`, `TimeInterval` formatters in
`Sources/Support/TimeFormat.swift`) and protocol conformance
(`extension CameraModel: AVCapturePhotoCaptureDelegate`).

## Generics — code that works for many types

```swift
func moveSelection<T: Equatable>(…)          // list-cursor helper
struct MenuRow<Item> where Item: Identifiable
```

`MusicLibraryRequest<Song>` — the same MusicKit request type fetches songs,
albums, artists; the generic parameter picks both the request shape and the
response type. `some View` in a `body` means "one specific view type the
compiler fills in, caller doesn't care which" (an *opaque* return type);
`any View` would mean "any type that conforms" (type-erased box).

## Where to look

- `Sources/Features/Reader/ReadAloudTTS.swift` — the
  `AudiobookSynthesizerType` seam: protocol + three conformers + a store
  choosing between them.
- `Sources/UI/MenuComponents.swift` — generic menu-row views constrained
  to `Identifiable` items.

## Gotchas learned here

- Objective-C-world delegates (camera, notifications, audio player) require
  a class (often `NSObject`) conforming — structs can't hold the required
  identity across the callback. Hence `CameraModel: NSObject`.
- `some` vs `any`: a `body` returns `some View` (one concrete type); storing
  heterogeneous views in an array needs `AnyView` or a grouping container —
  the route screens avoid that by switching over `Route` in one builder.
