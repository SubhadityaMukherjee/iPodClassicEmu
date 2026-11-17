# Error handling: `throws`, `try`, `catch`, `try?`, `Result`

Swift errors are values thrown out of a function and handled by the caller.
A function that can fail must say so in its signature (`throws`), and every
call site must say how it wants to deal with failure — there is no invisible
exception path like Java/C++.

```swift
enum ReaderError: Error { case corruptZip, missingFile(String) }

func open(book: URL) throws -> Book { … }        // can throw

do {
    let book = try open(book: url)
} catch ReaderError.corruptZip {
    // specific case
} catch {
    // anything else; `error` is bound automatically
}
```

## The three call-site forms

```swift
let x = try f()        // propagate: caller must handle (or also throw)
let x = try? f()       // swallow: nil on ANY error — use only when
                       // failure means "skip this"
let x = try! f()       // crash on error. Effectively banned here.
```

## Where this project draws the lines

- **Propagate (`try`) inside feature models** — e.g. `EpubContainer` throws
  typed errors (`missingFile`) so reader import code can show a precise
  message.
- **`try?` for opportunistic work** — thumbnail loads, optional metadata
  enrichment: failure degrades gracefully.
- **`try!`/force-unwrap: never.**
- **Non-throwing by convention:** top-level UI handlers catch and log (or
  surface a status string) instead of throwing into SwiftUI, which has no
  catch.

## `throws` + async + closures

These compose: `func fetch() async throws -> [Song]` is the standard shape
of MusicKit's catalog/library calls — `await try` in a `do/catch`, with the
catch usually setting an "empty library" state rather than crashing.

## Gotchas learned here

- Some system APIs signal failure without throwing: `AVAudioPlayer.play()`
  **returns false** instead of throwing. During the audiobook work a
  zero-frame temp WAV made `play()` return false silently — the fix was to
  check the return value and build WAV data in memory instead
  (`AVAudioPlayer(data:)`). Lesson: read the return type, not just the
  `throws` marker.
- `removePendingNotificationRequests` has no completion or error callback
  at all — fire-and-forget. Where iOS gives no feedback, this codebase adds
  its own verification (e.g. `pendingAlarmCount` readouts).
