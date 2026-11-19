import AVFoundation
import CoreML
import FluidAudio
import Foundation
import Observation
import os
import UIKit

/// Read Aloud voice engines, selected in Settings → Read Aloud. All three
/// are English-only (user decision 2026-11-19) and all three chunk text at
/// SENTENCE level internally, so `AudiobookModel.render` feeds them whole
/// pages (`feedsWholePages`).
///
/// - **paradee** (default — device-verified on the 16e 2026-11-19):
///   Paradee-8M v1.2 (Kokoro-82M distilled) — 12 MB models + the Kokoro
///   English G2P frontend (~50 MB total), CPU-only by design, four voices
///   (af_heart default, bf_isabella, am_puck, bm_fable).
/// - **pocketSmall**: Kyutai Pocket TTS 18m (Oct 2026) — ~145 MB,
///   FlowLM on the Neural Engine via one MLState package, 21 English
///   "literary" voices, 24 kHz. Sentence chunks of ≤50 tokens.
/// - **pocket**: Kyutai Pocket TTS 100M, `english_2026-10` pack, int8 —
///   ~550 MB, richer prosody than the small models, same 26 voices.
/// - **paradee**: Paradee-8M v1.2 (Kokoro-82M distilled) — 12 MB models +
///   the Kokoro English G2P frontend (~50 MB total), CPU-only by design,
///   four voices (af_heart, bf_isabella, am_puck, bm_fable).
///
/// History — engines that are GONE and why (do not re-add without new
/// evidence):
/// - **Supertonic3** (removed 2026-11-19): its CoreML text window caps
///   every synthesis chunk at 70 Latin characters
///   (`Supertonic3Constants.maxChunkLengthLatin` — WER degrades near the
///   128-token window), and each chunk is an independent inference with
///   ~0.4–0.7 s of baked leading/trailing silence. Any sentence longer
///   than ~70 chars is cut mid-sentence with ~1 s of dead air — it can
///   never read books smoothly.
/// - **Kokoro (FluidAudio KokoroAne)**: on iOS 27 both CoreML routes
///   terminate the process (libBNNS/MPSGraph, FluidAudio #889); "there is
///   currently no OS version or routing on iOS that is demonstrated safe
///   for long sessions".
/// - **MLX engines (qwen/breeze)**: SIGKILL at synthesis start on the
///   16e/iOS 27.3 (removed 2026-11-19).
///
/// The store's `init` sweeps the caches of all three dead engines.
@Observable
@MainActor
final class ReadAloudVoiceStore {
    static let shared = ReadAloudVoiceStore()

    /// The selectable TTS engines (see the class doc for sizes/status).
    enum Engine: String, CaseIterable {
        case pocketSmall = "pocket18"
        case pocket = "pocket100"
        case paradee = "paradee"

        /// Settings-row label.
        var title: String {
            switch self {
            case .pocketSmall: return "Pocket 18m"
            case .pocket: return "Pocket 100M"
            case .paradee: return "Paradee 8M"
            }
        }

        /// Approximate download size — progress denominator and labels.
        var expectedBytes: Int64 {
            switch self {
            case .pocketSmall: return 145_000_000
            case .pocket: return 550_000_000
            case .paradee: return 30_000_000  // 12 MB models + Kokoro G2P
            }
        }

        /// Download button label with the engine's approximate size.
        var downloadLabel: String {
            let mb = expectedBytes / 1_000_000
            return "Download Now (~\(mb) MB)"
        }

        /// Voice presets of the engine (the store validates on use).
        var voices: [String] {
            switch self {
            case .pocketSmall, .pocket:
                // The 21 English "literary" voices shared by every Kyutai
                // pack (default "alba").
                return [
                    "alba", "anna", "azelma", "bill_boerst", "caro_davy",
                    "charles", "cosette", "eponine", "eve", "fantine",
                    "george", "jane", "javert", "jean", "marius", "mary",
                    "michael", "paul", "peter_yearsley", "stuart_bell", "vera",
                ]
            case .paradee:
                return ["af_heart", "bf_isabella", "am_puck", "bm_fable"]
            }
        }

        /// All three engines chunk at sentence level internally and keep
        /// prosody/audio state across their own chunks — `render` feeds
        /// them whole pages instead of our sentence units. (Supertonic
        /// needed units because of its 70-char cap.)
        var feedsWholePages: Bool { true }
    }

    /// Download/load lifecycle, mirrored into the Settings screen and
    /// the download Live Activity.
    enum DownloadState: Equatable {
        /// Nothing on disk and no attempt made.
        case notStarted
        /// Weights arriving; the optional fraction (0…1) is nil when the
        /// engine gives no measurable progress yet.
        case downloading(progress: Double?)  // nil = indeterminate
        /// Files complete; weights being loaded/compiled into memory.
        case loading                          // weights into memory
        /// Ready to synthesize.
        case ready
        /// Download or load failed; the message is user-facing.
        case failed(String)
    }

    /// Selected engine (persisted; defaults to paradee — device-verified
    /// 2026-11-19). Switching drops whatever is in memory — the new
    /// engine downloads/loads on next use.
    var engine: Engine {
        get { Engine(rawValue: AppSettings.shared.readAloudEngine) ?? .paradee }
        set {
            guard newValue != engine else { return }
            AppSettings.shared.readAloudEngine = newValue.rawValue
            pocketSmallBackend = nil
            pocketBackend = nil
            paradeeBackend = nil
            readyTask = nil
            stopProgressPolling()
            state = Self.hasCachedModel(newValue) ? .ready : .notStarted
        }
    }

    /// Current engine's state. Initialized from a DISK PROBE at store
    /// creation (not "notStarted") so an already-downloaded model never
    /// shows a bogus "Downloading…" — the fix for warm starts being
    /// mislabeled as downloads.
    private(set) var state: DownloadState =
        ReadAloudVoiceStore.hasCachedModel(
            Engine(rawValue: AppSettings.shared.readAloudEngine) ?? .paradee) ? .ready : .notStarted

    /// Shared cache root for every engine's downloads (the capital-case
    /// `FluidAudio` path the ASR models already use — the SDK's lowercase
    /// default collides on case-insensitive APFS).
    nonisolated static var ttsRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("FluidAudio/TTS", isDirectory: true)
    }

    /// Engine weights on disk, keyed by the directories each downloader
    /// creates under `ttsRoot`. Pocket downloads land under
    /// `Models/pocket-tts-coreml/<pack>/`; Paradee splits across
    /// `paradee-8m-coreml/` (models, ~12 MB) and the shared Kokoro G2P
    /// in `kokoro/` (roughly the same again) — probing only the repo
    /// dir made a fully-downloaded Paradee read "Not downloaded"
    /// (2026-11-19).
    nonisolated private static func cacheDirs(_ engine: Engine) -> [URL] {
        switch engine {
        case .pocketSmall:
            return [ttsRoot.appendingPathComponent("Models/pocket-tts-coreml/v4/english_18m_2026-10")]
        case .pocket:
            return [ttsRoot.appendingPathComponent("Models/pocket-tts-coreml/v2.1/english_2026-10")]
        case .paradee:
            return [
                ttsRoot.appendingPathComponent("paradee-8m-coreml"),
                ttsRoot.appendingPathComponent("kokoro"),
            ]
        }
    }

    /// Cached = the engine's weights are mostly on disk (>50% of the
    /// expected pack size; the SDK resumes partial downloads, so a
    /// half-written pack legitimately re-enters `.downloading` later).
    nonisolated static func hasCachedModel(_ engine: Engine = selectedEngine()) -> Bool {
        cacheDirs(engine).reduce(Int64(0)) { $0 + dirBytes($1) } > engine.expectedBytes / 2
    }

    /// The persisted engine without touching actor-isolated state.
    nonisolated private static func selectedEngine() -> Engine {
        Engine(rawValue: AppSettings.shared.readAloudEngine) ?? .paradee
    }

    /// Voice presets of the currently selected engine (panel cycling).
    nonisolated static var voices: [String] { selectedEngine().voices }

    /// Download button label for the currently selected engine (wizard).
    nonisolated static var downloadLabel: String { selectedEngine().downloadLabel }

    /// Removes the selected engine's downloaded weights (frees disk) and
    /// resets state so Settings rows re-render as "Not downloaded".
    /// Paradee's delete also drops the shared Kokoro G2P (its only
    /// consumer — the Pocket engines tokenize raw text).
    func deleteDownloadedModel() {
        for dir in Self.cacheDirs(engine) {
            try? FileManager.default.removeItem(at: dir)
        }
        pocketSmallBackend = nil
        pocketBackend = nil
        paradeeBackend = nil
        state = .notStarted
    }

    /// The loaded PocketTTS small backend (18m), nil until `prepare()`.
    private var pocketSmallBackend: PocketTtsSmallManager?
    /// The loaded PocketTTS 100M backend, nil until `prepare()`.
    private var pocketBackend: PocketTtsManager?
    /// The loaded Paradee backend, nil until `prepare()`.
    private var paradeeBackend: ParadeeManager?
    /// In-flight prepare task — awaited by concurrent `prepare()` calls so
    /// the download happens once (single-flight).
    private var readyTask: Task<Void, Never>?
    /// Directory-size poller driving download progress.
    private var progressTask: Task<Void, Never>?

    /// Private: process-wide singleton (`ReadAloudVoiceStore.shared`).
    /// Sweeps the caches of the REMOVED engines — supertonic (~400 MB),
    /// the MLX engines (up to ~3.7 GB) and their `MLXAudio` root — their
    /// dirs are never written again, so deleting unconditionally hands the
    /// disk straight back to the user. QA hook: `TTS_ENGINE=pocket18|
    /// pocket100|paradee` overrides the persisted engine at launch so
    /// each one can be exercised end-to-end from env (sim + devicectl).
    private init() {
        if let raw = ProcessInfo.processInfo.environment["TTS_ENGINE"],
           let forced = Engine(rawValue: raw) {
            AppSettings.shared.readAloudEngine = forced.rawValue
        }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: Self.ttsRoot.appendingPathComponent("supertonic-3"))
        try? fm.removeItem(at: support.appendingPathComponent("MLXAudio"))
    }

    /// Download + load the selected engine once (idempotent,
    /// single-flight). Manages state/Live Activity for all callers
    /// (reader, setup wizard, settings, QA hook). Compute routing:
    /// Pocket 18m is cpuOnly on the simulator (its ANE-MLState package
    /// can't run there — same lesson as supertonic's ANE buckets) and
    /// ANE on device; Pocket 100M keeps FluidAudio's measured defaults
    /// on device and avoids the ANE on the simulator; Paradee is
    /// cpuOnly everywhere (its LSTMs abort on the GPU).
    ///
    /// A REAL download (not cached) brackets itself with the idle timer
    /// disabled and a silent keep-alive player: a screen lock or app
    /// switch suspends the process and kills an unprotected multi-minute
    /// HuggingFace fetch (why the pocket models "didn't download" from
    /// Settings while paradee's 60 MB made it — 2026-11-19).
    func prepare() async throws {
        if isLoaded { return }
        if let readyTask {
            await readyTask.value
            if isLoaded { return }
            throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: statusMessage])
        }
        let current = engine
        let wasCached = Self.hasCachedModel(current)
        if wasCached {
            state = .loading
        } else {
            state = .downloading(progress: 0)
            LiveActivityManager.shared.downloadStarted()
            startProgressPolling(dirs: Self.cacheDirs(current))
        }
        // Suspension guards for real downloads only — cached loads take
        // seconds and don't need the screen held on.
        var downloadGuards: SilentKeepAlive?
        if !wasCached {
            await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
            let keepAlive = SilentKeepAlive()
            keepAlive.start()
            downloadGuards = keepAlive
        }
        defer {
            if let downloadGuards {
                downloadGuards.stop()
                Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false }
            }
        }
        let log = Logger(subsystem: "com.ipodclassic.app", category: "tts")
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            do {
                try await self.loadBackend(current)
                self.state = .ready
                if !wasCached { LiveActivityManager.shared.downloadFinished(success: true) }
                log.notice("tts \(current.rawValue, privacy: .public) ready cached=\(wasCached, privacy: .public)")
            } catch {
                self.state = .failed(error.localizedDescription)
                if !wasCached { LiveActivityManager.shared.downloadFinished(success: false) }
                log.notice("tts \(current.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            self.stopProgressPolling()
        }
        readyTask = task
        await task.value
        readyTask = nil
        if !isLoaded {
            throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: statusMessage])
        }
    }

    /// True when the selected engine's backend is resident in memory.
    private var isLoaded: Bool {
        switch engine {
        case .pocketSmall: return pocketSmallBackend != nil
        case .pocket: return pocketBackend != nil
        case .paradee: return paradeeBackend != nil
        }
    }

    /// Downloads (if needed) and loads the engine's backend. All engines
    /// cache under the shared `ttsRoot`.
    private func loadBackend(_ engine: Engine) async throws {
        switch engine {
        case .pocketSmall:
            guard pocketSmallBackend == nil else { return }
            #if targetEnvironment(simulator)
            let units: MLComputeUnits = .cpuOnly // no ANE in the simulator
            #else
            let units: MLComputeUnits = .cpuAndNeuralEngine
            #endif
            let manager = PocketTtsSmallManager(model: .english18m, computeUnits: units)
            try await manager.initialize(directory: Self.ttsRoot)
            pocketSmallBackend = manager
        case .pocket:
            guard pocketBackend == nil else { return }
            #if targetEnvironment(simulator)
            let units = PocketTtsComputeUnits.avoidNeuralEngine
            #else
            let units = PocketTtsComputeUnits.default
            #endif
            let manager = PocketTtsManager(
                defaultVoice: "alba", language: .english, directory: Self.ttsRoot,
                precision: .int8, placement: .gpu, computeUnits: units)
            try await manager.initialize()
            pocketBackend = manager
        case .paradee:
            guard paradeeBackend == nil else { return }
            let manager = ParadeeManager(
                version: .v12, variant: .int8, directory: Self.ttsRoot,
                computeUnits: .cpuOnly)
            try await manager.initialize()
            paradeeBackend = manager
        }
    }

    /// Human-readable one-liner for settings/QA surfaces.
    var statusMessage: String {
        switch state {
        case .notStarted: return "Voice model not downloaded"
        case .downloading(let progress):
            return progress.map { String(format: "Downloading… %d%%", Int($0 * 100)) } ?? "Downloading…"
        case .loading: return "Loading voice model…"
        case .ready: return "Voice model ready ✓"
        case .failed(let message): return message
        }
    }

    /// The SDKs expose no download-progress callback; files stage into
    /// the cache dirs as they land, so poll their combined size against
    /// the pack's expected size. Only runs for real (non-cached)
    /// downloads.
    private func startProgressPolling(dirs: [URL]) {
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                let bytes = dirs.reduce(Int64(0)) { $0 + Self.dirBytes($1) }
                let expected = Self.selectedEngine().expectedBytes
                let fraction = Double(bytes) / Double(max(expected, 1))
                await MainActor.run {
                    guard case .downloading = self?.state else { return }
                    self?.state = .downloading(progress: min(0.999, fraction))
                    LiveActivityManager.shared.downloadProgress(min(0.999, fraction))
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Cancels and clears the progress poller (success, failure, or
    /// engine switch).
    private func stopProgressPolling() {
        progressTask?.cancel()
        progressTask = nil
    }

    /// Recursively sums file sizes under `dir` via a FileManager
    /// enumerator (cheap metadata walk, no file reads).
    nonisolated private static func dirBytes(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Synthesizes one page (or speech unit) of text with the selected
    /// engine. All engines are English — `language` is accepted for the
    /// seam and applied as the pack's own English frontend.
    func synthesize(text: String, language: String, voiceName: String) async throws -> (samples: [Float], sampleRate: Int) {
        try await prepare()
        switch engine {
        case .pocketSmall:
            guard let backend = pocketSmallBackend else {
                throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "engine not ready"])
            }
            let samples = try await backend.synthesizeSamples(text: text, voice: voiceName)
            return (samples, 24_000)
        case .pocket:
            guard let backend = pocketBackend else {
                throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "engine not ready"])
            }
            let result = try await backend.synthesizeDetailed(text: text, voice: voiceName)
            return (result.samples, 24_000)
        case .paradee:
            guard let backend = paradeeBackend else {
                throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "engine not ready"])
            }
            let voice = ParadeeVoice(rawValue: voiceName) ?? .afHeart
            let samples = try await backend.synthesize(text: text, voice: voice)
            return (samples, 24_000)
        }
    }
}

/// Adapter to the audiobook seam so tests keep their mock.
///
/// `isReady` is answered from the store's state (disk-probe-initialized),
/// which is exactly the contract AudiobookModel needs to distinguish a
/// warm start from a download.
extension ReadAloudVoiceStore: AudiobookSynthesizerType {
    /// True when the engine's weights are loaded and cached — from the
    /// init-time disk probe, so warm starts never read false.
    var isReady: Bool { state == .ready }

    /// These engines chunk at sentence level themselves — the model feeds
    /// whole pages (see `Engine.feedsWholePages`).
    var feedsWholePages: Bool { engine.feedsWholePages }

    /// Seam counterpart of `prepare()` (download + load, idempotent).
    func ensureReady() async throws {
        try await prepare()
    }

    /// Seam counterpart of `synthesize(text:language:voiceName:)`.
    func synthesize(_ text: String, language: String, voiceName: String) async throws -> (samples: [Float], sampleRate: Int) {
        try await synthesize(text: text, language: language, voiceName: voiceName)
    }
}
