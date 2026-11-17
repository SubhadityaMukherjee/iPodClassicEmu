# AVAudioPlayer & AVAudioSourceNode — two ways to make sound

Once the audio *session* (see
[avfoundation-audio-session.md](avfoundation-audio-session.md)) allows
sound, you need something that actually produces samples. This project
uses the two workhorses, chosen per job:

| | `AVAudioPlayer` | `AVAudioSourceNode` |
|---|---|---|
| Input | a complete sound (file URL / `Data`) | a render callback you write |
| Timing | start/stop/pause, loop, duration | real-time, sample by sample |
| Best for | recordings, alarm ringer, TTS pages | *synthesizing* audio live |
| Used by | Recorder playback, RingerManager, AudiobookModel | BinauralModel |

## AVAudioPlayer — the "play this sound" object

```swift
let player = try AVAudioPlayer(data: wavData)   // decodes up front
player.numberOfLoops = -1                       // loop forever (alarm)
player.play()                                   // returns Bool, not throws!
```

- **`play()` returns `false` on failure** — it does not throw. Check it:
  the audiobook bug where temp-file WAVs had zero frames was invisible
  until the return value was logged. (That's also why pages synthesize to
  *in-memory* `Data` — temp files on some devices wrote zero frames.)
- The whole sound is decoded at init — ideal for ringtones/ringers where
  you need `duration` and instant looping, less ideal for giant streams.
- One player per sound; keep a reference or it deallocates and stops.

## AVAudioSourceNode — real-time synthesis in a callback

For generated sound (the binaural-beat generator) there is no file: you
compute every sample yourself inside a render callback the engine calls
on a high-priority audio thread:

```swift
let node = AVAudioSourceNode { _, _, frameCount, audioBufferList in
    let buf = UnsafeMutableAudioBufferListPointer(audioBufferList)[0]
    let out = buf.mData!.assumingMemoryBound(to: Float.self)
    for i in 0..<Int(frameCount) {
        out[i] = sin(carrierPhase) * 0.5          // left: carrier - beat/2
        carrierPhase += twoPi * (carrier - beat/2) / sampleRate
        // (right channel: carrier + beat/2 — the binaural effect)
    }
    return noErr
}
```

Rules the binaural model follows:

- **The callback runs on the render thread** — no allocations, no locks,
  no Swift overhead you can avoid; parameters (frequency changes) cross
  in via atomics/simple vars, not method calls into the callback.
- Phase is accumulated (not computed from wall time) so frequency changes
  don't click.
- The node is attached to an `AVAudioEngine` (`attach`, `connect` to
  mainMixer, `engine.start()`) — the engine owns the pulling.
- Binaural beats need **headphones**: each ear gets a slightly different
  pure tone and the brain perceives the difference as a beat (presets:
  Delta/Theta/Schumann/Alpha/Beta/Gamma).

## Where to look

- `Sources/Features/Binaural/BinauralModel.swift` — source-node render
  loop, both channels, keep-playing-after-screen-exit semantics.
- `Sources/Features/Reader/AudiobookModel.swift` — in-memory WAV →
  `AVAudioPlayer(data:)`.
- `Sources/Features/Clocks/` — RingerManager's looping beep.

## Related

[avfoundation-audio-session.md](avfoundation-audio-session.md) — policy
first, playback second; [swift-closures.md](swift-closures.md) — the
render callback is a plain (non-escaping) C function pointer closure.
