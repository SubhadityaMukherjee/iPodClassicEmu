# iPodClassic

A native iOS app that puts a full iPod Classic in your pocket: a real click wheel with haptics and tick sounds, a scanlined LCD, and the classic menus — wired to **Apple Music**, plus a camera, voice recorder, alarms, and a book reader.

<p align="center">
  <img src="docs/screenshots/home.png" width="280" alt="Home menu" />
  <img src="docs/screenshots/songs.png" width="280" alt="Songs list" />
  <img src="docs/screenshots/nowplaying.png" width="280" alt="Now Playing" />
</p>

> This project started as a personal design brief ([`agent.md`](agent.md)) and was built iteratively with AI coding agents. See [Origin](#origin) for how it came together.

## Features

**The device feel**
- Full-device UI: black (or silver) body, working Hold switch, LCD with subtle CRT scanlines and backlight illusion
- Real click wheel: angle-based scroll ticks (15°/detent), press-and-turn, hold timers with repeat, CoreHaptics tick feedback and click sounds, dimmed wheel like real hardware
- Wheel-only navigation with the classic quirks: MENU pops one level, MENU-hold goes home, PLAY-hold sleeps

**Music (Apple Music via MusicKit)**
- Artists, albums, songs, genres, playlists, recently added — synced from your Apple Music library
- Cover Flow with 3D flipping covers and numbered track overlay
- Now Playing with marquee text, volume on the wheel, scrubbing, shuffle and repeat
- Playback keeps working in the background; Now Playing follows auto-advance and manual skips even while backgrounded
- **Queue**: hold the center button on any song row to "play next"; Now Playing → hold center → Up Next shows the whole queue and can jump to any entry
- **Search**: ranked results (title > artist > album); hold center on a result to jump to the artist or album

**Clocks**
- Classic alarm clock with iPhone-style weekday repeats (S M T W T F S; none selected = daily), in-app ringer with Snooze/Stop, notification-backed so it fires even when the app is closed
- Timer and Stopwatch — each with a **Live Activity**: live countdown/elapsed time on the lock screen and Dynamic Island, timer flips to "Done" when it fires in the background

**Reader**
- Import PDFs and EPUBs from the Files app; everything stays on-device
- EPUBs reflow with adjustable font size, serif/sans font, line spacing, margins, and page-step scrolling (wheel = exact page steps)
- PDFs render via PDFKit with continuous or one-page mode
- Chapter navigation (titles come from the book's own table of contents), per-book position memory, thin whole-book progress line, screen dimming for night reading
- **Highlights**: select text, tap Highlight — marks persist across sessions (text-anchored, reflow-proof) and are mirrored into a Notes file you can open in the Files app

**Everything else**
- Camera with wheel zoom, aspect-ratio switching (prev/next), lens flip (hold), wheel-driven capture — just like the real thing
- Photos grid + full-screen detail
- Voice recorder: background-safe long recordings, pause/resume, playback, share sheet
- Notes editor with autosave; files visible in the Files app
- Calendar, flashlight, and an About screen
- Settings for haptics, wheel behavior, display (CRT/scanlines/dim), playback, and themes

## Requirements

- Xcode 26+ with the iOS 18 SDK (project uses `xcodegen`)
- An Apple ID for signing (the free Personal Team works for on-device runs; MusicKit needs automatic signing enabled)
- A **physical iPhone** for music playback, camera, haptics, and Live Activities (ApplicationMusicPlayer is a no-op in the simulator)
- An Apple Music subscription or a synced music library for the Music features

## Building

```sh
brew install xcodegen           # if you don't have it
xcodegen generate               # regenerate iPodClassic.xcodeproj from project.yml
open iPodClassic.xcodeproj      # set your signing team, then Run
```

Or from the command line:

```sh
xcodebuild -project iPodClassic.xcodeproj -scheme iPodClassic \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Install on your device:

```sh
xcodebuild -project iPodClassic.xcodeproj -scheme iPodClassic \
  -destination 'id=<YOUR-UDID>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <YOUR-UDID> \
  ~/Library/Developer/Xcode/DerivedData/iPodClassic-*/Build/Products/Debug-iphoneos/iPodClassic.app
```

## Tests

```sh
xcodebuild -project iPodClassic.xcodeproj -scheme iPodClassic \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

- **Unit tests** (`Tests/iPodClassicTests/`) cover time formatting, wheel geometry, alarm math and weekday repeats, the player model, the reader store, ZIP/EPUB extraction and parsing, and the highlight store.
- **UI tests** (`Tests/UITests/`) drive the click wheel with real touch events and verify navigation, the alarm ringer, search, and the reader end to end.

The app exposes launch-environment hooks for testing: `RESET_DEFAULTS=1`, `START_ROUTE=<route>`, `FAKE_LIBRARY=1` (seed songs, since MusicKit items can't be constructed in tests), and `ALARM_FIRE_SECONDS=N` (fires the ringer after N seconds).

## Project structure

```
project.yml                 xcodegen spec (source of truth for the .xcodeproj)
Sources/
  App/                      @main, AppModel (nav stack + input router), Live Activities
  Device/                   device body, LCD, CRT overlay, screen router
  Wheel/                    click wheel gestures, haptics, tick sounds
  UI/                       theme, menus, modal panels, artwork
  Features/                 one self-contained folder per feature
    Music/  Photos/  Camera/  Recorder/  Notes/  Clocks/  Extras/  Reader/  Settings/
Shared/                     activity attributes shared with the widget target
Widgets/                    Live Activity widget extension
Tests/                      unit + UI tests
scripts/                    icon generator
docs/screenshots/           app screenshots
```

Input flows one way: `ClickWheelView` → `AppModel.handle(ControlEvent)` → a Combine `controlBus` → only the top screen reacts. Every screen is a `Route` on the navigation stack; deep screens stay alive so state survives pops, exactly like drilling into menus on the real device.

## Origin

The app began as a one-page brief ([`agent.md`](agent.md)) describing the device, the features, and a folder of reference screenshots — then grew feature by feature (branch → build → test → merge) with AI coding agents doing the implementation. The original reference images are not included in this repository.

## Notes & legal

- This is a personal hobby project and is **not affiliated with or endorsed by Apple**. iPod classic is a trademark of Apple Inc.
- Music features require MusicKit entitlements and an Apple Music-associated Apple ID; your library data stays within Apple's standard MusicKit access on your own device.
- No license is granted yet — all rights reserved by the author until a license file is added.
