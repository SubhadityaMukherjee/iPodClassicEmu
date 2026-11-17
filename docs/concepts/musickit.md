# MusicKit — the Apple Music library & `ApplicationMusicPlayer`

MusicKit is the framework for reading the user's Apple Music library
(songs, albums, artists, artwork) and playing it. Two very different
halves, both used here:

## 1. Reading the library — `MusicLibraryRequest`

```swift
var req = MusicLibraryRequest<Song>()
req.sort(by: \.title, ascending: true)
let resp = try await req.response()      // full library fetch
resp.items          // [Song]
```

The generic picks the entity type: `<Song>`, `<Album>`, `<Artist>` — same
request machinery. Key facts driving `MusicService`:

- **Permission**: first request triggers the Music access prompt;
  `MusicAuthorization.request()` is called during setup instead, so the
  app controls when the user sees it.
- **Cost**: a full-library fetch is not cheap. `MusicService` fetches its
  four sections concurrently (`async let`), caches all four arrays in
  memory, and publishes **once** when all are done — no mixed-state window
  where albums render but songs are still loading.
- `Song` has no `albumID` — albums are matched via `albumTitle`.
  `Song.duration` is `TimeInterval?` (optional — coalesce before math).
- The **simulator can't play** MusicKit content (`ApplicationMusicPlayer`
  is a no-op there); library UI renders, playback needs a real device.

## 2. Playing — `ApplicationMusicPlayer`

The app-scoped player: plays the user's matched library content,
integrates with system media controls / lock screen, no view needed.

```swift
let player = ApplicationMusicPlayer.shared
player.queue = ApplicationMusicPlayer.Queue(items: songs)  // or entries
try await player.play()
```

### The queue-sync trap (hard-won here)

Queue **entries are transient**: on insertion their IDs are temporary,
entries get *replaced* when the playback engine resolves them, and
`Entry.item` can be nil mid-resolution. Any code that maps state by
entry ID or item snapshot silently breaks. What's stable:
`currentEntry.title` (+ `.subtitle` = artist) at poll time.

So `PlayerModel` syncs by **matching title+artist against its own song
array**, every 0.5s poll tick:

- The queue is an `ObservableObject`, but its events fire mid-churn —
  "don't trust the event, poll."
- Transport uses `skipToNextEntry()`/`skipToPreviousEntry()` (proven to
  advance audio; they throw harmlessly at queue end).
- `player.state` is an *object* — check
  `player.state.playbackStatus == .playing`, and `state` is itself
  observable for UI.
- There is **no `volume`** on this player — see
  [mpvolumeview.md](mpvolumeview.md).

## Persistence

The playback session (queue of song IDs, index, position) is
`Codable`-encoded into UserDefaults (`PlaybackSessionStore`), saved on
background/terminate/track-change/every ~2s, and restored at launch
**paused** — never auto-play.

## Where to look

- `Sources/Features/Music/MusicService.swift` — fetch & cache.
- `Sources/Features/Music/PlayerModel.swift` — transport, poll sync,
  volume, restore.
- `Sources/Features/Music/PlaybackSession.swift` — session persistence.

## Related

[swift-async-await.md](swift-async-await.md) — the request API is async;
[avfoundation-audio-session.md](avfoundation-audio-session.md) — why
background play needs an active session even with MusicKit.
