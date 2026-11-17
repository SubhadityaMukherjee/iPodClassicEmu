# App Intents — Shortcuts, Siri, and app-integration

App Intents (`AppIntent`, `AppShortcut`) is the modern framework for
exposing app functionality to the **system**: the Shortcuts app, Siri,
Spotlight suggestions, and (via the Share Sheet) other apps. You declare
an intent as a struct with a run method; the system discovers it and can
invoke it — including while the app isn't running.

```swift
struct TranscribeRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Transcribe Recording"
    @Parameter(title: "Recording") var recording: RecordingEntity

    static var parameterSummary: some ParameterSummary { Summary(...) }

    func perform() async throws -> some IntentResult {
        let transcript = try await transcribe(recording)
        return .result(dialog: "Done")          // or .result(value:)
    }
}
```

The pieces this app registers:

- **`TranscribeRecordingIntent` / `GetTranscriptionIntent`** — transcribe
  a voice memo / fetch an existing transcript. The recording *entity*
  is resolvable over `Documents/Recordings`, so Shortcuts' pickers list
  real memos with names.
- **`AddArticleIntent`** — files a URL into the reader's Read Later
  list. Paired in Shortcuts with "Receive URLs from Share Sheet", any
  app's share button can save an article.
- **Camera shortcut** — a one-tap App Shortcut that opens the app
  straight to the camera.

## Why an *entity provider* matters

`@Parameter` types backed by an `EntityQuery` are what make Shortcuts
usable: the query enumerates live objects (recordings) by id + display
name, so users pick from real items instead of typing identifiers.
Deleting a recording invalidates its entity naturally.

## Constraints learned here

- Intents run in the **app process** (extension-less App Intents), so
  heavy work (transcription) must obey background rules — the audio
  session keep-alive applies here too
  ([avfoundation-audio-session.md](avfoundation-audio-session.md)).
- Output values that Shortcuts consumes downstream should be plain
  (`.result(value:)` with String/URL) — custom types need their own
  entity declarations.
- Shortcuts strings show up verbatim in the Shortcuts UI — keep
  `title`/`description` user-grade.

## Where to look

- `Sources/App/ShortcutsIntegration.swift` — transcription intents.
- `Sources/App/CameraShortcut.swift` — the open-camera shortcut.

## Related

[swift-protocols-and-generics.md](swift-protocols-and-generics.md) —
intents are protocol-conforming structs the system reflects over.
