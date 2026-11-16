# Testing & verification

## Commands

```sh
xcodegen generate
xcodebuild -project iPodClassic.xcodeproj -scheme iPodClassic \
  -destination 'platform=iOS Simulator,name=iPhone 17' build   # verification build
xcodebuild ... test -only-testing:iPodClassicTests              # unit tests
xcodebuild ... test                                            # everything incl. UI
scripts/ship.sh            # Release build → install on the connected iPhone
scripts/ship.sh --tf       # + archive and upload to TestFlight
```

## Suites

- `Tests/iPodClassicTests/` — unit tests, no host app: wheel geometry +
  adaptive tiers, alarm scheduling/reconcile, timer/stopwatch state
  machines, player volume, notes ordering + wheel clamp, route/title
  coverage, `moveListSelection`, reader CSS/settings/imports, ZIP/EPUB
  parsing, transcript store, audiobook state machine (mocked engine +
  synthesizer).
- `Tests/UITests/` — real-gesture E2E over XCUI: wheel drags → ticks,
  center taps, hold timers, nav depth, alarm fire/dismiss + schedule
  survival, notes editor (probe scroll + keyboard cycle), photos grid →
  framed detail, recording capture.

## QA launch-environment hooks

Env vars beat `defaults write` (unreliable on current sims — a stale
value once broke the whole wheel suite). Sim:

```sh
xcrun simctl terminate booted com.ipodclassic.app; sleep 2   # warm relaunches DROP env
SIMCTL_CHILD_START_ROUTE=songs SIMCTL_CHILD_FAKE_LIBRARY=1 xcrun simctl launch booted com.ipodclassic.app
```

Device: `xcrun devicectl device process launch --terminate-existing
--device <UDID> --environment-variables '{"KEY":"val"}' com.ipodclassic.app`

| Hook | Effect |
| --- | --- |
| `RESET_DEFAULTS=1` | clear defaults before startup (skips tour/setup) |
| `SHOW_TOUR=1` / `SHOW_SETUP=1` | force the tour / setup wizard |
| `SETUP_PAGE=voiceModel\|readingVoice` | jump to a setup wizard page |
| `START_ROUTE=<route>` | open a specific screen (replaces the stack — home is NOT in it; at depth 1 `pop()` is a no-op) |
| `START_ROUTE=readerLast` | reopen the first book |
| `FAKE_LIBRARY=1` | QA seed songs + fake Now Playing + fake cover (MusicKit items can't be constructed in tests) |
| `AUTOPLAY=1` | shuffle-play the real library at launch (device only) |
| `DIM_AFTER=<seconds>` | force the idle-dim threshold |
| `ALARM_ENABLE=1\|0`, `ALARM_FIRE_SECONDS=<n>`, `ALARM_SET_NOW_PLUS=<n>`, `ALARM_GRANT=1`, `ALARM_DEBUG=1` | alarm arming/firing/permission/pending-readout |
| `TIMER_PRESETS=1` | open the timer presets panel |
| `NOTES_QA=1` + `START_ROUTE=noteEditor` | seed a 60-line note + `y=<offset>` scroll readout |
| `NOTES_PANEL=1` | open the Note Options hold menu |
| `READER_IMPORT=<file>`, `READER_CHAPTER=<n>`, `READER_FRACTION=<0…1>`, `READER_FONT=<idx>`, `READER_TICKS=<n>`, `READER_DEBUG=1` | reader seeding + per-page geometry logging |
| `READER_PDF_REFLOW=1` | force reflow view for a PDF |
| `READER_ADD_URL=<url>` | auto-add an article on launch |
| `BOOK_SETTINGS=1` | open the book settings panel for screenshots |
| `NOW_PLAYING_PANEL=1` | open the Now Playing hold panel |
| `READ_ALOUD_START=1` | start Read Aloud in the open book |
| `QA_TRANSCRIBE=<file>` | end-to-end transcription check → `Documents/qa_status.txt` (RESULT rtf= headroomMB= on category "transcribe") |
| `QA_TTS=<text>` | end-to-end TTS check → `Documents/qa_status.txt` + `qa_tts.wav` (RESULT on category "tts") |
| `START_ROUTE=transcript` | open the QA transcript screen |
| `BINAURAL_START=<preset>`, `BINAURAL_AUTOSTOP=<s>`, `BINAURAL_NP_DUMP=1` | binaural QA + Now-Playing card state dump |

Device-only pull (status files):

```sh
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.ipodclassic.app \
  --source Documents/qa_status.txt --destination /tmp/qa_status.txt
```

## UI-test gotchas (learned the hard way)

- Relaunching over a warm app (simctl OR XCUIApplication) silently drops
  the launch environment; terminate + sleep 2+ first. E2E helpers detect
  the tour marker and relaunch once more.
- A test that leaves an audio capture alive poisons the next launch —
  stop recordings before ending the test.
- Photo permission resets on every test-run reinstall; grant via the
  SpringBoard dialog monitor, and `simctl privacy booted reset photos
  com.ipodclassic.app` after a stale DENIED.
- Split menus render only rows near the selection — tick onto a row
  before asserting it exists.
- Timer digits tick every second — assert with a windowed predicate,
  never one exact string.
- Photos in the sim: `xcrun simctl addmedia booted <numbered PNGs>`.

## The device verification ritual

For anything touching MusicKit, the camera, MLX/CoreML, notifications,
or background audio — the simulator proves nothing:

1. `scripts/ship.sh` (Release → phone).
2. Launch with QA hooks via devicectl (syntax above), phone unlocked.
3. Pull status files from the app container; watch the os_log category
   (`tts`, `transcribe`) for the `RESULT rtf= headroomMB=` lines.
4. Exercise the flow by hand on the phone — the fix isn't done until the
   behavior is observed on the device.
