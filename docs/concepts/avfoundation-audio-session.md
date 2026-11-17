# AVAudioSession — iOS's audio-policy singleton

On iOS, an app **cannot just play or record audio**. Every sound the app
makes flows through one process-wide object, `AVAudioSession.shared`, and
the *category/options* you set on it are a promise to the OS about how
your audio behaves. The OS uses that promise to decide: mix with other
apps' audio? keep playing in background? which microphone? honor the
silent switch?

This is policy configuration, not playback — and getting it wrong is the
root cause of most "audio mysteriously stops" bugs.

## Categories in one breath

| Category | Meaning |
|---|---|
| `.playback` | "I'm a music app." Plays in background, ignores silent switch, **deactivates other apps**' audio. |
| `.playAndRecord` | Record + play simultaneously (calls, voice memos with monitoring). |
| `.record` | Recording only. |
| `.ambient` | UI sounds; silenced by the ringer switch, mixes with others. |

## How this app configures it

- **`.playback`, activated once at launch.** `ApplicationMusicPlayer`
  plays *in-process*; without an active session iOS suspends the app in
  background and music dies. That was the original
  music-dies-in-background bug.
- **Recording switches to `.playAndRecord`** with options
  `[.defaultToSpeaker, .allowBluetoothHFP]`. The Bluetooth option is load
  -bearing: without it, iOS engages the AirPods mic, finds no declared BT
  support, and churns A2DP↔HFP until the AirPods disconnect. With it:
  one clean switch, mic + monitoring through the AirPods.
- **SilentKeepAlive** — a silent looping `AVAudioPlayer` whose only job
  is to keep the session (and thus the process) alive during background
  transcription/TTS synthesis.
- **Alarm ringer** loops via `AVAudioPlayer` on the same session — and it
  must **never deactivate the session**, and the keep-alive timer must
  not *reconfigure* the category while music plays.

## The two iron rules (both learned as bugs)

1. **One owner.** The session is a singleton; any code that sets a
   category stomps every other audio feature. Configure in as few places
   as possible; restore the previous category when a feature finishes.
2. **Deactivation is destructive.** `setActive(false)` while another
   feature plays kills it. Features here *never* deactivate on their way
   out.

## Interruptions & route changes

Calls, Siri, AirPods connects: iOS fires interruption/route notifications
through the session. `RecorderModel` listens and pauses/resumes
gracefully; the player treats interruption-end as a resume opportunity.
Interruptions are delivered as notifications with typed reasons, not
errors.

## Where to look

- `Sources/App/iPodClassicApp.swift` — launch-time `.playback` activation.
- `Sources/Features/Recorder/RecorderModel.swift` — `.playAndRecord` +
  options, interruption handling.
- `Sources/Features/Reader/AudiobookModel.swift` + `SilentKeepAlive` —
  keeping synthesis alive in background.

## Related

[audiotoolbox.md](audiotoolbox.md) — the one audio API that bypasses all
this; [musickit.md](musickit.md) — why the session must be active for
MusicKit background play.
