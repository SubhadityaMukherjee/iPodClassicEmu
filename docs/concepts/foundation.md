# Foundation essentials (`Date`, `Calendar`, `String`, `Data`, `FileManager`)

Foundation is Swift's standard library of *non-language* essentials: dates
and calendars, strings and formatting, raw bytes, file paths, timers,
notification posting. Every file imports it (often implicitly via
SwiftUI/UIKit). This page covers the pieces the project leans on; pages
that exist for a single dedicated concept (persistence, caching) live on
their own.

## `Date` + `DateComponents` + `Calendar`

A `Date` is just an instant (seconds since a reference date) — it has *no*
timezone, hour, or weekday by itself. To ask human questions ("what weekday
is this? 9am tomorrow?") you convert through a `Calendar`:

```swift
var comps = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
comps.hour = 7
let nextFire = Calendar.current.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
```

This is exactly how `AlarmStore` turns a user-chosen 07:30 + weekday set
into the next concrete fire `Date` for a notification trigger. The alarm's
hour24 math, timer formatters, and stopwatch lap displays all go through
`Sources/Support/TimeFormat.swift` rather than hand-rolled `%02d` strings.

Why not compare/format dates by hand? Calendar handles DST shifts, user
locale, and 12/24-hour clocks — `DateFormatter`/`Duration` produce the
right string for the user's settings automatically.

## `String`, `AttributedString`, and `Data`

- `Data` — raw bytes (ZIP streams in `EpubContainer`, WAV building in the
  audiobook engine, transcript sidecars).
- Swift `String` is Unicode-correct; the reader's text extraction does
  entity decoding (incl. numeric refs like `&#8212;`) where naive byte
  handling would corrupt text.
- `String(format:)` appears for `%02d:%02d` time padding; ICU-level text
  processing (sentence splitting in transcripts) goes through Foundation's
  text machinery.

## `FileManager` + URLs

Sandboxed apps get a container per user data area; you never use absolute
paths — you ask for the well-known directory and append:

```swift
let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
```

The Documents folder is user-visible in the Files app (Notes `.txt` files,
recordings, imported books all live there on purpose); caches and
application support (multi-GB ML models) go to their own areas so iOS can
evict/persist them appropriately. Files are addressed by `URL`
throughout, not paths-as-strings, because Apple file APIs take URLs.

## `Timer` and `DispatchSourceTimer`

`Timer.scheduledTimer` runs a closure on a run loop (main by default) —
fine for UI ticks (the 1s clock, autosave debounce). It pauses with the app;
background-accurate timing uses notification triggers or the audio
session's clock instead (alarm invariant lives in
[usernotifications.md](usernotifications.md)).

## Where to look

- `Sources/Support/TimeFormat.swift` — all shared time formatting.
- `Sources/Features/Clocks/AlarmStore.swift` — Calendar-driven trigger math.
- `Sources/Features/Reader/EpubContainer.swift` — `Data`/`FileManager` in
  anger (ZIP extraction, sandbox paths).

## Related

[userdefaults.md](userdefaults.md) — small preferences;
[filemanager-and-sandbox.md](filemanager-and-sandbox.md) — deeper file-system
coverage (added with the Reader batch).
