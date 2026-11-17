# Design decisions

The reasoning behind the non-obvious choices. Each entry: the decision,
why, and what breaks if you "simplify" it.

## Input & wheel

**One control bus, top screen only.** Every screen subscribes to
`controlBus` but only the top of the nav stack is mounted in a state
that reacts — this models the real iPod, where the foreground screen
owns the wheel. The alternative (each screen managing its own gesture
recognizers) is how you get two screens reacting to one tick.

**Adaptive scroll tiers are deliberately strict** (rows-per-detent jumps
at 300/900/1800/3000 °/s). Looser tiers made mid-speed flicks overshoot
targets. If lists feel like they "skip", tune here — not in the lists.

**Buttons claim transport globally.** prev/next/play/pause always
control music (authentic iPod) unless a screen sets
`transportClaimedByScreen` (camera, book reader while Read Aloud runs).

**MENU-hold = home, PLAY-hold = sleep, always.** Screens can't override
these; panels that list a `.menuHold` case are dead code by design.

## Navigation & state

**Deep routes stay alive across pops.** State survival beats view
lifecycle purity. Consequence: `ScreenRouter` identity is route *value* —
`photoDetail(N)` re-pushed with a different N is a NEW view, which is
why `PhotoDetailScreen` seeds selection from `index` in `init`
(`State(initialValue:)`).

**`AppSettings` stays `ObservableObject`.** UserDefaults-backed computed
properties don't trip Observation's access tracking. Manual
`objectWillChange.send()` in every setter is the price; @Observable
here silently means settings changes never re-render.

## Audio

**One `.playback` session, never deactivated.** Music-dies-in-background
was exactly this bug: something called `setActive(false)`. Owners
cooperate (see ARCHITECTURE.md's table) instead of reconfiguring.

**The alarm sound is the system notification**, not an in-app loop.
App-owned audio always plays at *media* volume on iOS — no category
changes that. The notification rings at *Ringer & Alerts* volume, which
is the only domain that survives a muted media slider. The in-app loop
(`RingerManager.startSound`) exists only for the notifications-denied
case.

**Ghost-alarm invariant: `installRequest()` gates on `enabled`.**
`schedule()` is called from several unconditional paths (alarm screen
appear, timer-ringer dismissal, setup completion, QA hooks). Before the
gate, any of those with the alarm toggle OFF installed repeating
requests — a ghost ring at the set time with the toggle reading Off.
Related: removing a repeating pending request kills every future
occurrence, so any remove→re-schedule dance must re-schedule
asynchronously (this SDK has no completion variant for removal).

**Music queue sync matches by title+artist, polled.** MusicKit queue
entries are transient: IDs are temporary, entries get replaced during
resolution, `Entry.item` can be nil mid-resolution. Any bookkeeping
keyed by entry ID silently breaks. `PlayerModel` polls
`queue.currentEntry` (title+subtitle are always populated) against its
own song array every 0.5 s. Trust the poll, not the event.

**Read Aloud plays in-memory WAVs (`AVAudioPlayer(data:)`).** Writing
the same PCM to `temporaryDirectory` produced zero-frame files on a real
iPhone (0-duration player, `play()` returns false). No filesystem in the
playback path.

**Read Aloud's engine loop polls, never awaits callbacks.** Lost
AVAudioPlayer/AVAudioEngine completions stalled the whole audiobook on
both sim and device; `Task.sleep` always resumes. The loop polls
`isPlaying` with a ~2 s "past the end" grace window and fails loudly if
a page renders no audio (dead backend) instead of racing through the
book.

**Bluetooth HFP option on the recorder session.** Without
`.allowBluetoothHFP`, iOS engages the AirPods mic, finds no declared BT
support, and churns A2DP↔HFP until the AirPods drop. With it: one clean
switch at record start.

## Reader

**True column pagination, one tick = one page, pages hold complete
lines only.** Estimated chapter page counts (0.44em glyph prior) get
recalibrated to exact counts as the user visits chapters
(`readerPosition` returns `{fraction, pageCount}`).

**Never re-add an offscreen WKWebView measurer.** iOS WebKit paginates
columns asynchronously; scrollWidth overshoots then tightens, and
about:blank races reported every chapter as 1 page. All geometry comes
from the live view.

**Read Aloud turns pages through the same paths as manual reading** —
so exiting mid-page leaves the reader exactly where listening stopped,
and position persistence comes for free. Pages advance via
`provider.showPage` *before* speaking each segment; wheel seeks flag
`engine.seekRequested` and re-sync to the shown page.

## On-device ML

**Transcription = Parakeet Ultra CoreML (FluidAudio).** sherpa-onnx
0.6b dequantized to ~2.4 GB and jetsammed; the 110m fit but is
English-only; the v3-coreml path mangles Dutch on iOS. Ultra decodes
Dutch+English perfectly on the ANE. Hour-long memos are safe thanks to
the SDK's disk-backed chunking (~1.2 MB constant memory).

**TTS = Supertonic3 CoreML (default); both MLX engines are WIP.** The
MLX path (Qwen3 0.6B and Breeze 3B alike) loads its model fine but the
process is SIGKILLed at synthesis start on the iPhone 16e / iOS 27.3 —
model size is irrelevant (0.6B died like 3B), pointing at the MLX
Metal compute path on this OS, not memory (mlx-swift issues #407/#458
document the abort class). Supertonic3 (~400 MB, RTF ~0.30, 44.1 kHz,
verified by listening on this exact phone) is the default again, and
it also runs in the simulator (cpuOnly). Kokoro remains
document-unsafe on iOS 26.4+/27 — do not ship.

**Explicit model caches under Application Support.** SDK defaults that
live in `Library/Caches` are evictable; a silently evicted 3 GB model
means a surprise re-download on cellular.

## UI & lists

**Every scroll surface owns a fixed-size clipped container.** Scrolling
regressions recur whenever layout code shifts a list's height — the
fixed container is the scope boundary. Long text scrolls by moving text
inside a fixed-width clipped frame, never by displacing neighbors.

**`MenuList` renders a window, not the whole list** (menus with hundreds
of rows stay smooth). The window clamps — not resets — when item counts
change mid-browse; a reset teleported the viewport while the selection
stayed deep.

**Idle dim covers ONLY the LCD** (0.62 black inside the screen clip);
the wheel and body never dim. Playback (music, Read Aloud) keeps the
backlight on, classic iPod style.

**Photos thumbnails: size in the cache key, only final bitmaps cached,
cells decode at `cellSize * displayScale`.** Shared keys made one screen
inherit another's blurry resolution; caching degraded opportunistic
deliveries froze cells blurry forever; hardcoded 2× was soft on 3×
screens.

**The Now Playing lock-screen card clears via
`MPNowPlayingPlaybackState.stopped`**, not by nil-ing `nowPlayingInfo` —
with the shared session still active, an `.unknown` state leaves a
ghost "playing" card on the lock screen.

## Process & conventions

**QA by launch environment, not by defaults writes.** `simctl spawn
defaults write` into an app domain is unreliable on current sims
(`RESET_DEFAULTS` may not even clear it) — a stale value once broke
every wheel UI test. All test hooks (`START_ROUTE`, `FAKE_LIBRARY`,
`READER_*`, `QA_TTS`, …) are env vars; see TESTING.md.

**Relaunching over a warm app silently drops the launch environment**
(sim and XCUI both). Terminate + wait + launch, and the E2E helpers
detect the first-run tour marker and relaunch once more if needed.

**TestFlight is opt-in.** Default delivery is a direct Release install
to the connected phone (`scripts/ship.sh`); `--tf` archives and uploads
when explicitly requested.
