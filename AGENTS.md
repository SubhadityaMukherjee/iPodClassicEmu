# AGENTS.md — iPodClassic contributor/agent guide

Native iOS (SwiftUI + AVFoundation/MusicKit/PhotoKit) iPod Classic emulator: full-device UI on a black body with a real click wheel (CoreHaptics + tick sounds), LCD screen with subtle CRT scanlines, and classic iPod menus.

## Commands

```sh
xcodegen generate                      # regenerate iPodClassic.xcodeproj from project.yml (after adding files)
xcodebuild -project iPodClassic.xcodeproj -scheme iPodClassic \
  -destination 'platform=iOS Simulator,name=iPhone 17' build   # verification build
xcodebuild -project iPodClassic.xcodeproj -scheme iPodClassic \
  -destination 'platform=iOS Simulator,name=iPhone 17' test     # unit tests
```

There is no linter; keep style consistent with surrounding code. Swift 5, iOS 18 deployment target, `SWIFT_STRICT_CONCURRENCY: minimal`.

## Architecture

- `project.yml` is the source of truth for the Xcode project; the `.xcodeproj` is generated and committed. Bundle: `com.ipodclassic.app`; the signing team is configured once via `DEVELOPMENT_TEAM` in `project.yml` (never hardcode team IDs in docs).
- `Sources/App/` — `iPodClassicApp` (@main), `AppModel` (`@Observable`; nav `stack: [Route]`, input router `handle(ControlEvent)`, service singletons), `AppSettings` (`ObservableObject`, UserDefaults-backed). `ControlEvent`/`Route` live in AppModel.swift.
- `Sources/Device/` — `DeviceView` (body layout, Hold switch, dim/sleep overlays, alarm ringer host), `ScreenView` (LCD + title bar), `CRTOverlay`, `ScreenRouter` (renders the nav stack; deep routes stay alive so state survives pops; top route owns wheel input; `title(for:)` maps routes to title-bar strings).
- `Sources/Wheel/` — `ClickWheelView` + `WheelCoordinator` (angle-delta ticks at 15°/detent, button quadrants vs diagonal scroll sectors, press→scroll conversion, hold timers with repeat), `WheelHaptics` (CoreHaptics transients + UIImpact), `TickSounds` (AudioServices; never touches AVAudioSession), `WheelFeedback` (applies haptics/sound settings).
- `Sources/UI/` — `Theme` (colors/fonts: LCD paper, brushed-metal bar, blue selection gradient, dimmed wheel), `MenuComponents` (`MenuItem`, `MenuList`/`MenuRow` incl. thumbnails + subtitles, `SplitMenuLayout`, `ModalPanel`, `moveListSelection` honoring Infinite Tick / Rubber Band Tick).
- `Sources/Features/` one folder per feature, each self-contained (model + screens):
  - `Music/` — MusicKit library fetch (cached in `MusicService`), `PlayerModel` (ApplicationMusicPlayer, transport, queue bookkeeping synced from `player.queue.currentEntry`, volume, 0.5s state polling), list screens (hold center on a song row = add to queue), `AlbumDetailScreen` (View in Cover Flow / Shuffle / tracks), `CoverFlowScreen` (3D covers + numbered track overlay), `NowPlayingScreen` (wheel = volume; hold center = song options incl. Up Next queue list with jump-to-entry).
  - `Extras/` (in `Features/Extras/ExtrasScreens.swift`) — Extras menu, Flashlight (torch), Calendar, `MusicSearchScreen` (ranked song search; hold center → Go to Artist / Go to Album).
  - `Photos/` — `PhotoLibraryModel` (PHFetchResult + thumbnail cache), grid/detail screens.
  - `Camera/` — `CameraModel` (AVCaptureSession on serial queue, zoom, lens switch, capture delegate), `CameraScreen` (wheel zoom, prev/next = aspect ratio, hold = flip lens, center = capture, MENU = options panel; claims transport buttons via `model.transportClaimedByScreen`).
  - `Recorder/` — `RecorderModel` (.m4a in Documents/Recordings, pause/resume, background-safe, interruption handling, playback), recorder/list/detail screens with share sheet.
  - `Notes/` — `NotesStore` (.txt in Documents/Notes, visible in Files app), list + editor (touch keyboard, debounced autosave, MENU writes).
  - `Clocks/` — `AlarmStore` (single classic alarm with weekday repeats; nothing selected = daily → one repeating `UNCalendarNotificationTrigger` per selected day), `AlarmNotifications` (delegate → in-app ringer), `TimerModel`/`StopwatchModel`, `RingerManager` (in-app loop + overlay), `AlarmScreen` (wheel edits hour/minute/AM-PM, day cursor; center advances/toggles — wheel past the day-row edges changes segment), `TimerScreen`, `StopwatchScreen`.
  - `Reader/` — PDF/EPUB reader. `ReaderStore` (registry in Documents/Books + per-book settings/position persisted in UserDefaults), `EpubContainer` (custom ZIP extractor over Apple `Compression` + OPF/spine/TOC parsing — chapter titles from toc.ncx/EPUB3 nav, then `<title>`/`<h1>`), `ReaderHighlights` (selection capture + persistent text-anchored marks + `- "text"` notes mirror), `ReaderScreens` (`ReaderScreen` list w/ Files-app import + hold-to-delete, `BookScreen`: wheel = page-step scroll, center = chapters, hold center = book settings (font size/family/line spacing/margins/scroll step/screen dim/PDF view mode), prev/next = chapter or page; thin whole-book progress bar; PDF highlights are native `PDFAnnotation`s written into the PDF file).
  - `Settings/` — value-cycling rows via `ValueSettingsScreen`; Apple Music connect, Clickwheel, Display (CRT/scanlines/backlight illusion/dim), Playback, About.
- Input flow: `ClickWheelView` → `AppModel.handle` → (hold switch / sleep / global transport interception) → `controlBus` (Combine) → only the top screen reacts via `.onReceive`.
- Global transport: prev/next/play/pause always control music (like a real iPod) except when a screen claims them (camera). MENU-hold goes home; PLAY-hold sleeps.
- Live Activities: `iPodClassicWidgets` extension target (bundle `com.ipodclassic.app.widgets`) shows one activity per kind (timer/stopwatch/recorder) on lock screen + Dynamic Island. `Shared/TrackActivityAttributes.swift` is compiled into BOTH the app and the widget; `LiveActivityManager` (Sources/App) is driven by the timer/stopwatch/recorder models. All on-screen motion is auto-ticking `Text(timerInterval:)` — the app only posts updates on start/pause/resume/lap/end, no push token. Requires `NSSupportsLiveActivities` (set in project.yml); Dynamic Island needs a real device.

## Sounds & resources

- `Resources/Sounds/*.caf` — Tick/TickSoft/RubberBand/AlarmBeep; regenerate via python wave + `afconvert -f caff -d LEI16@44100 -c 1`. Alarm notification sound must stay < 30 s.
- `scripts/make_icon.swift` — regenerates the AppIcon PNG.
- Info.plist keys (Music, Camera, Mic, Photos, background audio) are generated from `project.yml`.

## Tests

- `Tests/iPodClassicTests/` — unit tests (no host app): `TimeFormat`, `WheelCoordinator` geometry, alarm hour24 + repeat labels/bitmask, `PlayerModel` volume, `ReaderStore` import/remove/old-format decode, ZIP extraction (stored + deflate + traversal guard), EPUB spine/TOC/title parsing, `HighlightStore`.
- `Tests/UITests/` — real-gesture E2E over XCUI (`WheelTapTests`, `E2ETests`): wheel drag → tick, center tap, hold timers, navigation depth, alarm ringer fire/dismiss, reader render, songs hold. Launch hooks via `launchEnvironment`: `RESET_DEFAULTS=1`, `START_ROUTE=<route>`, `FAKE_LIBRARY=1` (QA seed songs — MusicKit items can't be constructed in tests), `ALARM_FIRE_SECONDS=N`.

## Conventions & gotchas

- Screens consume `ControlEvent` in `.onReceive(model.controlBus)` and call `moveListSelection` for lists — never reach into other screens' state.
- New screens need: a `Route` case, a `ScreenRouter` entry, and a `title(for:)` branch.
- Music playback requires a real device (ApplicationMusicPlayer is a simulator no-op) and MusicKit working via Xcode automatic signing; camera needs a physical device too.
- `AppSettings` is `ObservableObject` (not `@Observable`) with explicit `objectWillChange.send()` in setters — UserDefaults-backed computed properties don't auto-notify otherwise.
- Battery icon reads `UIDevice.current.batteryLevel` (enabled at app init; -1 in sim → 100%).
- Git flow: feature branches → commit → push → merge to `main`. Short imperative subjects.
- MusicKit queue sync: queue entries are transient on insertion — entry IDs are temporary, entries get replaced when the playback engine resolves them, and `Entry.item` can be nil mid-resolution. NEVER map bookkeeping by entry ID/item snapshot; match `player.queue.currentEntry.title` (+ `subtitle` = artist) against your own song array in the poll tick. Transport uses `skipToNextEntry`/`skipToPreviousEntry` (throws harmlessly at queue end). The queue is an `ObservableObject` but its events are not settled at event time — poll, don't trust the event.
- `ApplicationMusicPlayer` plays in-process: background audio requires an active `AVAudioSession` `.playback` category, activated once at app launch. The alarm ringer must never deactivate the session, and the keep-alive timer must not reconfigure it while music plays — that was the music-dies-in-background bug.
- PDFKit (this SDK): `PDFDocument` has no `.pages` — use `pageCount`/`page(at:)`/`index(for:)`; `PDFOutline` iterates via `numberOfChildren` + `child(at:)`.
- Swift/JS escaping: `\\(x)` inside a Swift string emits the literal text `\(x)` — interpolation does NOT happen. In JS source strings passed to `evaluateJavaScript`, interpolate with single-backslash `\(x)` and verify with a standalone `swift` script before shipping (this silently shipped invalid reader CSS once).

## TestFlight

Bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml`, `xcodegen generate`, archive the `iPodClassic` scheme with Xcode, upload. MusicKit + notifications work on device with the personal team for development; TestFlight needs the paid team selected in Signing & Capabilities.
