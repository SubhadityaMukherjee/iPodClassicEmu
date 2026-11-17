# Optionals (`?`, `nil`, `if let`, `guard`, `??`)

Swift refuses to let you use a value that might be absent. A variable whose
type is `String` can never be "no string"; a variable whose type is `String?`
(optional String) is either a `String` or `nil`. The compiler forces you to
acknowledge the absent case before using the value — a whole class of bugs
(null-pointer crashes) becomes unrepresentable.

## The mechanics

```swift
var title: String?          // may be nil
let upper = title.uppercased()          // ❌ compile error — might be nil
```

Unwrapping tools, all used constantly in this codebase:

```swift
// 1. nil-coalescing: provide a default
let name = song.artist ?? "Unknown Artist"

// 2. if-let: bind to a new non-optional constant inside the block
if let entry = player.queue.currentEntry {
    print(entry.title)
}

// 3. guard-let: early-exit when absent, keep the value after the guard
guard let url = URL(string: raw) else { return }
// url is non-optional from here on — the guard branch already returned

// 4. optional chaining: call through, get nil if any link is nil
let minutes = item.duration.map { $0 / 60 }   // nil if duration is nil

// 5. force unwrap (!) — CRASHES the app if nil. Avoid.
let bad = title!
```

## Why you'll see `guard` so much in this project

`guard let … else { return }` keeps the happy path at the top indentation
level. Long SwiftUI and audio functions would otherwise nest five `if let`
levels deep. House style: guard out the invalid cases first, then write the
real logic flat.

## Where to look

- `Sources/Features/Music/PlayerModel.swift` — playback math always
  coalesces `Song.duration` (`TimeInterval?`) with `?? 0`; the MusicKit SDK
  declares it optional and lying about it crashes.
- `Sources/App/AppModel.swift` — `handle(_:)` guards on the top screen
  before routing wheel events.

## Gotchas learned here

- MusicKit's `Song.duration` and `ApplicationMusicPlayer.Queue.Entry.item`
  are optional even when they "shouldn't" be. Every consumer coalesces or
  guards; a force-unwrap would be a crash waiting on a network hiccup.
- `try?` (see [swift-error-handling.md](swift-error-handling.md)) converts a
  throwing call into an optional — convenient, but it silently swallows the
  error, so we use it only when failure genuinely means "ignore this".
