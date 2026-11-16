# iPodClassic — contributor documentation

Start here, then follow the links below. `AGENTS.md` (repo root) is the
dense, always-current contributor cheat-sheet; these docs are the
expanded, human-readable versions of the same material plus the reasoning
behind the choices.

| Doc | What's in it |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the app is put together: layers, input flow, navigation, state, audio, on-device models |
| [DESIGN-DECISIONS.md](DESIGN-DECISIONS.md) | The "why" behind the non-obvious choices (polled engines, queue sync by title, ghost-alarm invariant, …) |
| [ADDING-FEATURES.md](ADDING-FEATURES.md) | Step-by-step recipe for adding a screen/feature, with the gotchas checklist |
| [TESTING.md](TESTING.md) | Test suites, QA launch-environment hooks, and the device verification workflow |

## Orientation in one paragraph

Native iOS app (SwiftUI, iOS 18) that emulates the *experience* of an
iPod Classic: a black device body with a real click wheel (CoreHaptics +
tick sounds), an LCD with subtle CRT scanlines, and the classic
blue-selection-bar menus. Everything runs on-device — music via
MusicKit/ApplicationMusicPlayer, photos via PhotoKit, camera via
AVFoundation, voice-memo transcription via a local CoreML Parakeet model,
and Read Aloud via Breeze TTS 2 on MLX. There is no server.

## The golden rules

1. **`project.yml` is the source of truth** for the Xcode project. Run
   `xcodegen generate` after adding/removing files or targets; the
   `.xcodeproj` is generated and committed.
2. **Verify on a running app** — the simulator for UI/logic, the real
   iPhone for anything touching MusicKit, the camera, Metal/MLX, or
   background audio. A build that compiles is not a fix that works.
3. **Add a regression test for every bug you fix.** The E2E suite exists
   because features regress after multi-item change batches.
4. **One feature = one branch** (`feature/<name>` or `fix/<name>`),
   merged back to `main` with a merge commit.
