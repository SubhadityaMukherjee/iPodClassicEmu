# FileManager & the app sandbox — where files are allowed to live

iOS apps run in a **sandbox**: a per-app container directory tree the app
owns and outside of which it (mostly) cannot touch files. There is no
current-directory, no arbitrary paths — you ask `FileManager` for
well-known directories and build from there.

## The directories that matter here

```swift
let fm = FileManager.default
let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
```

| Directory | Semantics | Used for |
|---|---|---|
| `Documents/` | User data, **visible in the Files app**, backed up | Notes `.txt`, Recordings `.m4a`, imported Books |
| `Library/Application Support/` | app-managed data, backed up, NOT user-visible | ML models (FluidAudio/MLX caches) |
| `Library/Caches/` | purgeable | temp caches |
| `tmp/` (or `temporaryDirectory`) | whenever | scratch |

Choosing right is user-facing: recordings *should* appear in Files so
users can drag them out; a 3 GB TTS model *should not* clutter their
Documents. Hidden-from-Files but inside Documents works too via
`.isHidden` — that's how `Notes/.trash` stays out of sight while deleted
notes remain restorable.

## Core operations (and their throwing nature)

```swift
try fm.createDirectory(at: dir, withIntermediateDirectories: true)  // mkdir -p
let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
try fm.removeItem(at: url)         // delete; throws if absent
try? fm.trashItem(at: url, resultingItemURL: nil)   // …on the MAC, not iOS
```

Note the trap: **`trashItem` doesn't exist on iOS** — the system Recycle
Bin is a macOS concept. iOS apps that want undo-able deletes implement
their own trash folder (`NotesStore`: move into `Documents/Notes/.trash`,
`restore()` back, `deleteForever()` for real removal). Atomic writes go
through `Data.write(to: .atomic)` — a half-written file after a kill is
otherwise a real corruption class (the transcript sidecar saves
before+after each run for exactly this reason).

## Why `URL` everywhere (not String paths)

Apple's file APIs are URL-based: `appendingPathComponent` handles
separators, percent-encoding, and directory-ness correctly, and
`URLResourceValues` reads metadata (file size, hidden flag) that string
paths can't. This codebase never builds paths by string concatenation.

## Bookkeeping that files can't do themselves

Files have no metadata store — "which recording is transcribed?"
needs either a sidecar index (the JSON `.transcripts.json` keyed by
filename) or expensive rescans. The pattern here: files are the source
of truth for *content*, a small index (sidecar or UserDefaults) is the
source of truth for *state*, and every delete path must update both.

## Where to look

- `Sources/Features/Notes/NotesStore.swift` — Documents layout + trash.
- `Sources/Features/Recorder/RecorderModel.swift` /
  `Transcription.swift` — recordings + sidecar discipline.
- `Sources/Features/Reader/ReaderStore.swift` — book registry in
  Documents/Books.

## Related

[foundation.md](foundation.md) — the parent tour;
[userdefaults.md](userdefaults.md) — the other half of persistence.
