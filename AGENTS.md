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

- `project.yml` is the source of truth for the Xcode project; the `.xcodeproj` is generated and committed. Bundle: `com.ipodclassic.app`, team `46655DQD2X`.
- `Sources/App/` — `iPodClassicApp` (@main), `AppModel` (`@Observable`; nav `stack: [Route]`, input router `handle(ControlEvent)`, service singletons), `AppSettings` (`ObservableObject`, UserDefaults-backed). `ControlEvent`/`Route` live in AppModel.swift.
- `Sources/Device/` — `DeviceView` (body layout, Hold switch, dim/sleep overlays, alarm ringer host), `ScreenView` (LCD + title bar), `CRTOverlay`, `ScreenRouter` (renders the nav stack; deep routes stay alive so state survives pops; top route owns wheel input; `title(for:)` maps routes to title-bar strings).
- `Sources/Wheel/` — `ClickWheelView` + `WheelCoordinator` (angle-delta ticks at 15°/detent, button quadrants vs diagonal scroll sectors, press→scroll conversion, hold timers with repeat), `WheelHaptics` (CoreHaptics transients + UIImpact), `TickSounds` (AudioServices; never touches AVAudioSession), `WheelFeedback` (applies haptics/sound settings).
- `Sources/UI/` — `Theme` (colors/fonts: LCD paper, brushed-metal bar, blue selection gradient, dimmed wheel), `MenuComponents` (`MenuItem`, `MenuList`/`MenuRow` incl. thumbnails + subtitles, `SplitMenuLayout`, `ModalPanel`, `moveListSelection` honoring Infinite Tick / Rubber Band Tick).
- `Sources/Features/` one folder per feature, each self-contained (model + screens):
  - `Music/` — MusicKit library fetch (cached in `MusicService`), `PlayerModel` (ApplicationMusicPlayer, transport, volume, 0.5s state polling), list screens, `AlbumDetailScreen` (View in Cover Flow / Shuffle / tracks), `CoverFlowScreen` (3D covers + numbered track overlay), `NowPlayingScreen` (wheel = volume).
  - `Photos/` — `PhotoLibraryModel` (PHFetchResult + thumbnail cache), grid/detail screens.
  - `Camera/` — `CameraModel` (AVCaptureSession on serial queue, zoom, lens switch, capture delegate), `CameraScreen` (wheel zoom, prev/next = aspect ratio, hold = flip lens, center = capture, MENU = options panel; claims transport buttons via `model.transportClaimedByScreen`).
  - `Recorder/` — `RecorderModel` (.m4a in Documents/Recordings, pause/resume, background-safe, interruption handling, playback), recorder/list/detail screens with share sheet.
  - `Notes/` — `NotesStore` (.txt in Documents/Notes, visible in Files app), list + editor (touch keyboard, debounced autosave, MENU writes).
  - `Clocks/` — `AlarmStore` (single classic alarm → repeating `UNCalendarNotificationTrigger`), `AlarmNotifications` (delegate → in-app ringer), `TimerModel`/`StopwatchModel`, `RingerManager` (in-app loop + overlay), `AlarmScreen` (wheel edits hour/minute/AM-PM, center advances), `TimerScreen`, `StopwatchScreen`.
  - `Settings/` — value-cycling rows via `ValueSettingsScreen`; Apple Music connect, Clickwheel, Display (CRT/scanlines/backlight illusion/dim), Playback, About.
- Input flow: `ClickWheelView` → `AppModel.handle` → (hold switch / sleep / global transport interception) → `controlBus` (Combine) → only the top screen reacts via `.onReceive`.
- Global transport: prev/next/play/pause always control music (like a real iPod) except when a screen claims them (camera). MENU-hold goes home; PLAY-hold sleeps.

## Sounds & resources

- `Resources/Sounds/*.caf` — Tick/TickSoft/RubberBand/AlarmBeep; regenerate via python wave + `afconvert -f caff -d LEI16@44100 -c 1`. Alarm notification sound must stay < 30 s.
- `scripts/make_icon.swift` — regenerates the AppIcon PNG.
- Info.plist keys (Music, Camera, Mic, Photos, background audio) are generated from `project.yml`.

## Conventions & gotchas

- Screens consume `ControlEvent` in `.onReceive(model.controlBus)` and call `moveListSelection` for lists — never reach into other screens' state.
- New screens need: a `Route` case, a `ScreenRouter` entry, and a `title(for:)` branch.
- Music playback requires a real device (ApplicationMusicPlayer is a simulator no-op) and MusicKit working via Xcode automatic signing; camera needs a physical device too.
- `AppSettings` is `ObservableObject` (not `@Observable`) with explicit `objectWillChange.send()` in setters — UserDefaults-backed computed properties don't auto-notify otherwise.
- Battery icon reads `UIDevice.current.batteryLevel` (enabled at app init; -1 in sim → 100%).
- Git flow: feature branches → commit → push → merge to `main`. Short imperative subjects.

## TestFlight

Bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml`, `xcodegen generate`, archive the `iPodClassic` scheme with Xcode, upload. MusicKit + notifications work on device with the personal team for development; TestFlight needs the paid team selected in Signing & Capabilities.
