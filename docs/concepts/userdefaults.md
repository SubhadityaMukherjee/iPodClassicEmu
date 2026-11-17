# UserDefaults — tiny key-value persistence

UserDefaults is iOS's built-in property-list database: a per-app dictionary
that survives launches, backed by a plist on disk. It is for *small,
scalar-ish* settings — a volume level, a selected tab, a bool. Not for
files, blobs, or anything big.

```swift
let d = UserDefaults.standard
d.set(true, forKey: "haptics.on")           // write (eventually flushed)
let on = d.bool(forKey: "haptics.on")       // read; false if absent
d.set(try JSONEncoder().encode(recents), forKey: "recents.activity")  // blobs via Data
d.removeObject(forKey: "haptics.on")
if d.object(forKey: "x") == nil { … }       // distinguish "absent" from "false"
```

## Why the project uses it

Settings (`AppSettings`), playback session restore
(`PlaybackSessionStore`), reader per-book positions, recents, tour/setup
"done" flags — all tiny, all read at launch synchronously. UserDefaults is
the right size: async databases (Core Data/SwiftData) would be machinery
with no payoff at this scale.

**Codable values** (recents, session queues) are `JSONEncoder`-encoded to
`Data` and stored as one key — the standard pattern for a small struct
graph. Decode failures fall back to defaults rather than crashing
(defensive `try?` + default value), because a corrupt plist must never
brick launch.

## The house rules you'll see in code

- **One owner per domain.** Each store owns its keys as private constants
  (`private enum Keys { static let done = "setup.done" }`) — no stringly
  typed access scattered across files.
- **Explicit change notification.** Reads are computed properties over
  `UserDefaults`; those don't auto-notify observers, so `AppSettings`
  fires `objectWillChange.send()` in setters — views re-render.
- **QA reset.** Launch-argument `RESET_DEFAULTS=1` wipes the domain before
  `AppModel` exists, because tests need a pristine first run.
- **Migrations are one-shot flags** (`reader.newBookStepMigrated`) — read
  the flag, transform old data, set the flag, never touch it again.

## Gotchas learned here

- Writes are eventually persisted, not instant; for "must survive a kill
  this second" data the code calls `synchronize()` or saves on
  background/terminate hooks (reader position: every 6s + on background).
- The simulator has per-app default domains that can go stale/haunted;
  tests prefer launch-argument hooks over `defaults write` (see
  AGENTS.md testing notes).
- A key's absence is indistinguishable from `false` via `bool(forKey:)` —
  "was setup ever done" checks `object(forKey:) == nil`, not a stored bool.

## Related

[foundation.md](foundation.md) — the framework this lives in;
[swiftui-views-and-state.md](swiftui-views-and-state.md) — why stores
re-send `objectWillChange` manually.
