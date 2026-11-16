# Architecture

## Source layout

```
Sources/
  App/        application shell: AppModel, settings, setup/tour, Live Activities,
              recents, Shortcuts intents
  Device/     the physical device: DeviceView (body + hold switch + dim/sleep +
              alarm ringer host), ScreenView (LCD + title bar), CRTOverlay,
              ScreenRouter (nav stack rendering)
  Wheel/      the click wheel: gesture → detents, haptics, tick sounds,
              adaptive scrolling
  UI/         shared LCD components: Theme (colors/fonts), MenuComponents
              (MenuList/MenuRow/ModalPanel), ArtworkView
  Features/   one folder per feature, each self-contained (model + screens):
    Music/    MusicKit library, PlayerModel, list/album/artist/Cover Flow/
              Now Playing screens
    Reader/   Books: PDF/EPUB/articles, pagination, highlights, Read Aloud
              (AudiobookModel + BreezeTTS engine store)
    Recorder/ voice memos + on-device transcription (Parakeet Ultra CoreML
              via FluidAudio)
    Notes/    plaintext notes + trash
    Clocks/   alarm (system notifications), timer, stopwatch, in-app ringer
    Photos/   PhotoKit grid/detail
    Camera/   AVCaptureSession photo/video
    Extras/   flashlight, calendar, binaural beats, music search
    Settings/ value-cycling settings screens
    Home/     home screen + recents
    Calendar/ month grid
Shared/       code compiled into BOTH the app and the widget extension
              (TrackActivityAttributes)
Widgets/      WidgetKit extension: timer/stopwatch/recorder/download Live
              Activities (lock screen + Dynamic Island)
```

The rule of thumb: a feature folder never reaches into another feature's
screens; cross-feature communication goes through `AppModel` (services,
singletons, the control bus) or `RecentActivity`.

## The input pipeline (the heart of the app)

Every user interaction funnels through one chain:

```
ClickWheelView (UIKit gesture: angle-delta detents, button quadrants)
   │  ControlEvent (.tick(+/-n), .select, .centerHold, .menu, .menuHold,
   │                .playPause, .prev/.next, .prevHold/.nextHold, …)
   ▼
AppModel.handle(_:)            ← the single input router
   │  1. hold switch active?  → swallow everything
   │  2. alarm/timer ringer up? → redirect to ringerBus
   │  3. global transport?     → prev/next/playPause control MUSIC
   │                            (like a real iPod) unless the top screen
   │                            claims them (camera, book reader)
   │  4. MENU-hold → popToRoot; PLAY-hold → sleep
   ▼
controlBus (Combine PassthroughSubject<ControlEvent>)
   ▼
only the TOP screen, via .onReceive(model.controlBus) { handle($0) }
```

Screens never read the wheel directly and never touch each other's
state. This is what keeps "the wheel does the right thing" true across
~25 screens.

### The wheel itself

- Scroll = angular movement quantized to **15°/tick** (a detent), one
  haptic pulse + tick sound per detent (throttled to 50/s so fast spins
  don't saturate CoreHaptics).
- **Adaptive scrolling**: smoothed angular speed maps to rows-per-detent
  1→6 (tiers at 300/900/1800/3000 °/s — deliberately strict so
  mid-speed flicks don't overshoot). Decelerating spins shed speed fast;
  spins stop resetting after 0.35 s.
- Buttons = quadrants (top/right/bottom/left = MENU/next/play/prev);
  diagonals are scroll sectors. Press→scroll conversion and hold-timers
  with repeat live in `WheelCoordinator`.

## Navigation

`AppModel.stack: [Route]` is the whole navigation state; `Route` is a
`Hashable` enum (`home`, `music`, `.songs`, `.nowPlaying`,
`.readerBook(id)`, …). `ScreenRouter` renders the stack with a
`ForEach`/`navigationDestination`-free ZStack approach:

- **Deep routes stay alive** — popping keeps the view in the hierarchy,
  so state (scroll position, playback, form text) survives a push/pop
  cycle.
- **The top route owns wheel input**; deeper routes ignore the bus.
- The title bar (`ScreenView`) maps routes to strings via
  `AppModel.title(for:)`.

Adding a screen = a `Route` case + a `ScreenRouter` entry + a
`title(for:)` branch (see [ADDING-FEATURES.md](ADDING-FEATURES.md)).

## State management

- `AppModel` is `@Observable` (Observation framework) and `@MainActor`.
  It owns the nav stack, the service singletons (`music`, `player`,
  `photos`, `camera`, `notes`, `recorder`, `reader`, `alarms`, `timer`,
  `stopwatch`, `audiobook`, `transcription`), `controlBus`, the idle
  clock (`clockTick`, bumped by `tickIdle()`), and the ringer overlay
  state.
- `AppSettings` is deliberately **`ObservableObject`** (not `@Observable`)
  because it is UserDefaults-backed computed properties — auto-synthesis
  can't see writes, so setters call `objectWillChange.send()` manually.
- The SwiftUI gotcha this codebase keeps re-learning: **writing to a
  `@State` that `body` never reads does not invalidate the view.**
  Periodic re-renders (idle dim, hold switch) read
  `model.clockTick` in `body` to register the dependency.

## Audio strategy (one session, many owners)

A single `AVAudioSession` with category `.playback` is activated once at
launch and **never deactivated** — music's background audio depends on
it. Owners cooperate instead of swapping the session:

| Owner | Configuration |
| --- | --- |
| Music | `ApplicationMusicPlayer` (plays in-process; poll `queue.currentEntry`, see below) |
| Alarm sound | the **system notification** (rings at Ringer & Alerts volume, immune to media mute); the in-app AVAudioPlayer loop is only a fallback when notifications are denied |
| Voice memos | `.playAndRecord` + `[.defaultToSpeaker, .allowBluetoothHFP]` (the BT option is REQUIRED or AirPods churn A2DP↔HFP and disconnect) |
| Read Aloud | AVAudioPlayer over in-memory WAV data |
| Background survival | near-silent looping AVAudioPlayer keep-alives (alarm monitor, transcription, recorder) |

Read Aloud and music yield to each other: starting Read Aloud pauses
music; the camera screen claims the transport buttons while open.

## On-device models

| Model | Purpose | Runtime | Size | Cache |
| --- | --- | --- | --- | --- |
| Parakeet Ultra (multilingual) | voice-memo transcription | CoreML (FluidAudio SPM) | ~600 MB | `Application Support/FluidAudio/Models/` |
| Breeze TTS 2 (4-bit) | Read Aloud | MLX (mlx-audio-swift SPM) | ~3 GB | `Application Support/MLXAudio/` |

Both caches are **explicit and under Application Support** — SDK defaults
that point into `Library/Caches` (evictable) would silently force
multi-GB re-downloads. Downloads mirror progress into the download Live
Activity. First device loads are slow (CoreML ANE compile; MLX warmup) —
QA status files exist so you can tell "compiling" from "hung".

The ML stack runs **only on real devices**: MLX needs a Metal GPU family
the simulator doesn't provide (Read Aloud fails with a friendly message
there), and CoreML ANE buckets stall in the simulator (ASR uses
`.cpuOnly` there).

## Live Activities

The widget extension shows one activity per kind (timer, stopwatch,
recorder, download) on the lock screen + Dynamic Island. All on-screen
motion is auto-ticking `Text(timerInterval:)`; the app only posts
start/pause/resume/lap/end updates — no push tokens.
`LiveActivityManager` retries failed first-launch requests (fresh
installs race widget-extension registration).

## Persistence

- UserDefaults: app settings, playback session (`PlaybackSessionStore`
  restores the queue PAUSED — never auto-play), reader per-book
  settings/positions, recents, alarm state.
- Files under `Documents/` (visible in the Files app): `Books/`
  (EPUB/PDF/article registry), `Notes/` (+ hidden `.trash/`),
  `Recordings/` (+ `.transcripts.json` sidecar).
- Everything model-cache lives under `Application Support/`.

## What runs where (device matrix)

| Capability | Simulator | Real device |
| --- | --- | --- |
| UI, wheel, menus, notes, reader, clocks | ✅ | ✅ |
| Music playback | ❌ (ApplicationMusicPlayer is a no-op) | ✅ |
| Camera | ❌ | ✅ |
| Transcription (CoreML) | ✅ cpuOnly, slow | ✅ ANE |
| Read Aloud (MLX/Breeze) | ❌ (no Metal) — friendly error | ✅ |
| Alarm firing | partial | ✅ (system notifications) |
