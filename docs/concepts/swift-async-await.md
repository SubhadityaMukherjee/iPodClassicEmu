# Async/await and `Task`

`async`/`await` is Swift's built-in way to write asynchronous (slow,
non-blocking) code that *reads* like normal sequential code. Instead of
nesting callbacks, you write:

```swift
func loadLibrary() async throws -> [Song] {
    let songs = try await MusicLibraryRequest<Song>().response()  // suspends here
    return songs                       // resumes when the response lands
}
```

`await` marks a suspension point: the thread is freed to do other work
(keep the UI at 60fps) while the operation runs. When it completes,
execution resumes on the function's executor.

## Where the code comes from: `Task { }`

`await` can only live inside an async context. SwiftUI button actions and
`onAppear` are synchronous, so you open a context with `Task { … }` — an
unstructured, immediately-starting job:

```swift
.task { await model.loadLibrary() }        // SwiftUI: cancels with the view
Task { await transcribe(url) }             // manual: lives independently
Task.detached { … }                        // runs off the current actor
```

`.task { }` (the SwiftUI modifier) is preferred where possible: it is
cancelled automatically when the view disappears.

## Cancellation is cooperative

Swift tasks are not killed mid-statement; they check `Task.isCancelled` (or
`try Task.checkCancellation()`) at await points. Photo loading in this
project polls with cancellation awareness — one reason a cancelled load must
not write stale results back into state.

## Where to look

- `Sources/Features/Music/MusicService.swift` — `loadLibrary` awaits four
  MusicKit sections concurrently (`async let` / task groups) and publishes
  all four at once.
- `Sources/Features/Reader/AudiobookModel.swift` — a deliberate
  **poll-based** loop: `Task.sleep` + `engine.isPlaying` checks instead of
  callbacks. That file's docstrings explain why (lost callbacks stalled
  page advance).

## Gotchas learned here

- **The old completion-callback trap:** a callback that never fires leaves
  you hung forever. The audiobook engine moved to polling *because*
  continuation-based callbacks silently stalled.
- **Background lifetime:** iOS suspends the app (and its Tasks) when it
  backgrounds, unless an audio session is active. Long transcriptions /
  TTS runs hold the audio session alive with `SilentKeepAlive` for exactly
  this reason — see
  [avfoundation-audio-session.md](avfoundation-audio-session.md).
- Don't block: `Task { @MainActor in … }` when a background result must
  touch UI state — see [swift-actors-and-isolation.md](swift-actors-and-isolation.md).

## Related

[swift-closures.md](swift-closures.md) — completion closures are the older
style this replaces; both appear because system APIs span both eras.
