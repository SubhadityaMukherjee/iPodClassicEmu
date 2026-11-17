# MPRemoteCommandCenter & Now Playing Info — lock screen transport

When audio plays, iOS shows transport controls on the lock screen,
Control Center, and AirPods double-taps. Two MediaPlayer APIs connect
your app to that system UI:

## 1. `MPNowPlayingInfoCenter` — what the screen shows

```swift
var info: [String: Any] = [
    MPMediaItemPropertyTitle: "Schumann 7.83",
    MPMediaItemPropertyArtist: "Binaural",
    MPMediaItemPropertyPlaybackDuration: 0,
    MPNowPlayingInfoPropertyPlaybackRate: 1.0,
]
MPNowPlayingInfoCenter.default().nowPlayingInfo = info
```

A plain dictionary posted to a singleton; the system renders it on the
lock screen. (For MusicKit playback this is automatic —
`ApplicationMusicPlayer` maintains it. The binaural synthesizer plays
raw audio, so it posts its own "now playing" card so the lock screen
explains what's playing.)

## 2. `MPRemoteCommandCenter` — what the buttons do

```swift
let center = MPRemoteCommandCenter.shared()
center.playCommand.addTarget { [weak self] _ in
    self?.toggle(); return .success
}
center.nextTrackCommand.isEnabled = false   // hide what you can't do
```

Each command (play, pause, toggle, next/previous track) gets target
closures. The binaural screen enables only play/pause toggle — there
are no tracks to skip — and **reuses the system commands instead of
fighting them**: the app's global play/pause rule (global transport)
and the lock screen's play/pause both funnel into the same
`toggle()`.

## Why this matters in this app

- The click wheel's play/pause always controls "whatever is making
  sound" — music player or binaural synth. Remote commands extend that
  contract to headphones and the lock screen, keeping one source of
  truth for transport.
- Enabling only the commands you support keeps the lock screen honest
  (a disabled next-track button instead of a dead one).

## Where to look

- `Sources/Features/Binaural/BinauralModel.swift` —
  `installRemoteCommands` + `publishNowPlaying`.

## Related

[musickit.md](musickit.md) — MusicKit maintains these automatically for
library playback; [avfoundation-playback.md](avfoundation-playback.md)
— the synth side.
