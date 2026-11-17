# On-device ML — CoreML, the Neural Engine, and FluidAudio

Speech-to-text and text-to-speech in this app run **entirely on the
device**: no audio ever leaves the phone, nothing needs network after
the model downloads. That privacy/latency trade is why the machinery
below exists.

## CoreML and the ANE

`CoreML` is Apple's runtime for trained models; it compiles `.mlmodel`
artifacts into an optimized form and dispatches them to the fastest
available engine:

- **ANE** (Apple Neural Engine) — the dedicated NPU; fastest and most
  efficient for transformers like Parakeet; *compilation for ANE happens
  on first load and can take ~10 minutes on device* (cached after —
  don't mistake it for a hang; the QA hook writes stage files for
  exactly this reason).
- GPU (Metal) / CPU — fallbacks; some models only run on them
  (Supertonic on the *simulator* needs `.cpuOnly` because its ANE-bucketed
  variants stall loading there).

Compute-unit choice is explicit (`MLComputeUnits.allCPU/allGPU/.cpuOnly/
andNeuralEngine`), and picking wrong is a real failure mode, not a
detail — MLX-based engines die in Metal command buffers on this device
(see below).

## FluidAudio — the SDK doing the plumbing

[FluidAudio](https://github.com/FluidInference/FluidAudio) (SPM package,
v0.18.3 here) wraps model download + CoreML/MLX execution for a family
of models. What it handles for us:

- **HuggingFace download** (~600 MB ASR, ~400 MB TTS) with progress
  callbacks → `ensureModels()` surfaces state to the download panel and
  the Live Activity. A disk-cache probe (`modelsExist`) answers "already
  downloaded" instantly, so cached loads never show a fake
  "Downloading…" state.
- **Streaming/transcribing** — `transcribe(url:)` with automatic
  **disk-backed chunking**: audio is streamed in pieces at ~1.2 MB
  constant memory, so hour-long memos don't explode RAM.
- TTS counterpart: `Supertonic3Manager.downloadAndCreate` (CoreML) and
  MLX loaders for Qwen/Breeze.

The case-insensitivity trap: FluidAudio's cache default
(`Application Support/fluidaudio`) collides with the ASR dir
(`…/FluidAudio`) on case-insensitive APFS → EIO; every call passes an
explicit `cacheDirectory`. One HF repo ships both `Config.json` and
`config.json`, which aborts ModelHub mid-download — the store
pre-fetches the tree skipping `Config.json`, and purges half-written
dirs on failure.

## The model graveyard (why these choices)

Choosing models here was empirical; the docstrings reference history so
nobody re-litigates it blind:

| Model | Fate |
|---|---|
| sherpa-onnx parakeet 0.6b int8 | dequantizes ~2.4 GB resident → jetsammed |
| sherpa parakeet 110m | fits but English-only |
| FluidAudio parakeet v3-coreml | mangles Dutch on iOS (fine on macOS) |
| **Parakeet ULTRA CoreML** | ✅ ASR — 25 languages, ANE, exact Dutch test transcript |
| Kokoro TTS | libBNNS/MPS SIGTRAP crashes on iOS 27.3 — macOS only |
| **Supertonic3 CoreML** | ✅ TTS default, RTF ~0.30, device-verified |
| Qwen3-TTS / Breeze (MLX) | model loads, process SIGKILLed at synthesis start (Metal abort class, size-independent) |

## Runtime discipline

- Synthesis/transcription windows keep the process alive with
  `SilentKeepAlive` (audio session =
  [avfoundation-audio-session.md](avfoundation-audio-session.md)).
- Progress flows through async streams into Live Activities
  ([activitykit-live-activities.md](activitykit-live-activities.md)).
- Memory headroom is watched (jetsam killed earlier experiments) — the
  QA hooks log `rtf=` and `headroomMB=` per run.

## Where to look

- `Sources/Features/Recorder/Transcription.swift` — ASR (Parakeet
  Ultra) + sidecar + App Intents.
- `Sources/Features/Reader/ReadAloudTTS.swift` — the TTS engine seam,
  three engines, per-engine download/delete.

## Related

[filemanager-and-sandbox.md](filemanager-and-sandbox.md) — where the
multi-GB caches live; [swift-protocols-and-generics.md](swift-protocols-and-generics.md)
— the engine seam that makes swapping models a one-line change.
