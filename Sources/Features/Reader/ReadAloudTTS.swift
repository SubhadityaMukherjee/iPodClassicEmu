import AVFoundation
import CoreML
import FluidAudio
import Foundation
import HuggingFace
import MLXAudioCore
import MLXAudioTTS
import Observation
import os

/// Read Aloud voice engines, selected in Settings → Read Aloud.
///
/// - **supertonic** (default): Supertonic3 CoreML via FluidAudio —
///   ~400 MB, 44.1 kHz output, RTF ~0.30, **device-verified on the
///   iPhone 16e**; voices M1–M5/F1–F5; multilingual (en/nl/de/fr/es/it).
/// - **qwen** (WIP): Qwen3-TTS 0.6B Base 8-bit via MLX — ~700 MB,
///   voices Ryan/Aiden. JETSAMMED the 16e at synthesis start (SIGKILL,
///   model loads fine) — kept as an experiment for future devices/OSes.
/// - **breeze** (WIP): Breeze TTS 2 3B 4-bit via MLX — ~3 GB. Crashed
///   the 16e the same way.
///
/// Only the SELECTED engine downloads. Supertonic caches under
/// `Application Support/FluidAudio/TTS`; MLX engines under
/// `Application Support/MLXAudio` (explicit HubCache — the default
/// lives in evictable Library/Caches).
@Observable
@MainActor
final class ReadAloudVoiceStore {
    static let shared = ReadAloudVoiceStore()

    enum Engine: String, CaseIterable {
        case supertonic
        case qwen
        case breeze

        var title: String {
            switch self {
            case .supertonic: return "Supertonic"
            case .qwen: return "Qwen3 (WIP)"
            case .breeze: return "Breeze (WIP)"
            }
        }

        var isExperimental: Bool { self != .supertonic }

        /// MLX repo, or nil for the CoreML engine (FluidAudio manages
        /// its own cache).
        var repo: String? {
            switch self {
            case .supertonic: return nil
            case .qwen: return "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
            case .breeze: return "mlx-community/Breeze-TTS-2-mlx-4bit"
            }
        }

        /// Approximate checkpoint size — download-progress denominator.
        var expectedBytes: Int64 {
            switch self {
            case .supertonic: return 400_000_000
            case .qwen: return 700_000_000
            case .breeze: return 3_010_000_000
            }
        }

        var downloadLabel: String {
            switch self {
            case .supertonic: return "Download Now (~400 MB)"
            case .qwen: return "Download Now (~700 MB)"
            case .breeze: return "Download Now (~3 GB)"
            }
        }

        /// Voice presets per engine.
        var voices: [String] {
            switch self {
            case .supertonic: return Supertonic3Voice.allCases.map(\.rawValue)
            case .qwen: return ["Ryan", "Aiden"]
            case .breeze: return ["Narrator", "Warm", "British", "Crisp"]
            }
        }

        /// The `voice:` parameter for the engine's generate call.
        func instruction(named name: String) -> String? {
            switch self {
            case .supertonic:
                return nil // voice travels as a Supertonic3Voice style
            case .qwen:
                return voices.contains(name) ? name : voices[0]
            case .breeze:
                let table = [
                    "Narrator": "A clear and calm English narrator with an even, steady pace.",
                    "Warm": "A warm, friendly storyteller with a relaxed English accent and unhurried pace.",
                    "British": "A composed British narrator with a measured, articulate delivery.",
                    "Crisp": "A crisp, energetic presenter with brisk pacing and a bright tone.",
                ]
                return table[voices.contains(name) ? name : "Narrator"]!
            }
        }

        /// The `language:` parameter: Supertonic takes an ISO code,
        /// Qwen a language name, Breeze nothing.
        func languageParameter(code: String) -> String? {
            switch self {
            case .supertonic: return code
            case .qwen: return Self.languageNames[code] ?? "English"
            case .breeze: return nil
            }
        }

        static let languageNames = [
            "en": "English", "nl": "Dutch", "de": "German", "fr": "French",
            "es": "Spanish", "it": "Italian",
        ]
    }

    enum DownloadState: Equatable {
        case notStarted
        case downloading(progress: Double?)  // nil = indeterminate
        case loading                          // weights into memory
        case ready
        case failed(String)
    }

    /// Selected engine (persisted). Switching unloads whatever is in
    /// memory — the new engine downloads/loads on next use.
    var engine: Engine {
        get { Engine(rawValue: AppSettings.shared.readAloudEngine) ?? .supertonic }
        set {
            guard newValue != engine else { return }
            AppSettings.shared.readAloudEngine = newValue.rawValue
            mlxModel = nil
            readyTask = nil
            stopProgressPolling()
            state = Self.hasCachedModel(newValue) ? .ready : .notStarted
        }
    }

    private(set) var state: DownloadState =
        ReadAloudVoiceStore.hasCachedModel(Engine(rawValue: AppSettings.shared.readAloudEngine) ?? .supertonic) ? .ready : .notStarted

    nonisolated static var mlxCacheRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MLXAudio", isDirectory: true)
    }

    /// FluidAudio's TTS cache (the capital-case path the ASR models
    /// already use — the SDK's lowercase default collides on
    /// case-insensitive APFS).
    nonisolated static var fluidTTSRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("FluidAudio/TTS", isDirectory: true)
    }

    /// Cached = the engine's weights are certainly on disk.
    nonisolated static func hasCachedModel(_ engine: Engine) -> Bool {
        switch engine {
        case .supertonic:
            // The loader reads these two once the tree fetch completes.
            let repo = fluidTTSRoot.appendingPathComponent("supertonic-3")
            let fm = FileManager.default
            return fm.fileExists(atPath: repo.appendingPathComponent("tts.json").path)
                && fm.fileExists(atPath: repo.appendingPathComponent("unicode_indexer.json").path)
        case .qwen, .breeze:
            let threshold: Int64 = engine == .qwen ? 400_000_000 : 1_000_000_000
            return cacheBytes(repo: engine.repo!) > threshold
        }
    }

    /// Removes one engine's downloaded weights (frees disk).
    nonisolated static func deleteModel(_ engine: Engine) {
        switch engine {
        case .supertonic:
            try? FileManager.default.removeItem(
                at: fluidTTSRoot.appendingPathComponent("supertonic-3", isDirectory: true))
        case .qwen, .breeze:
            let dir = mlxCacheRoot.appendingPathComponent("models--" + engine.repo!.replacingOccurrences(of: "/", with: "--"))
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private var mlxModel: (any SpeechGenerationModel)?
    private var supertonicBackend: SupertonicSynthesis?
    private var readyTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    private init() {}

    var voices: [String] { engine.voices }

    /// Download + load the selected engine once (idempotent,
    /// single-flight). Manages state/Live-activity for all callers
    /// (reader, setup wizard, settings, QA hook).
    func prepare() async throws {
        switch engine {
        case .supertonic:
            if supertonicBackend != nil { return }
            // NOTE: Supertonic RUNS on the simulator (cpuOnly) — keeps
            // sim QA and the Read Aloud panel testable, unlike MLX.
            let wasCached = Self.hasCachedModel(.supertonic)
            if wasCached {
                state = .loading
            } else {
                state = .downloading(progress: 0)
                LiveActivityManager.shared.downloadStarted()
                startProgressPolling(repo: nil, expected: Engine.supertonic.expectedBytes,
                                     dir: Self.fluidTTSRoot.appendingPathComponent("supertonic-3"))
            }
            do {
                let backend = supertonicBackend ?? SupertonicSynthesis()
                try await backend.ensureReady()
                supertonicBackend = backend
                state = .ready
                if !wasCached { LiveActivityManager.shared.downloadFinished(success: true) }
            } catch {
                state = .failed(error.localizedDescription)
                if !wasCached { LiveActivityManager.shared.downloadFinished(success: false) }
                throw error
            }
            stopProgressPolling()

        case .qwen, .breeze:
            if mlxModel != nil { return }
            #if targetEnvironment(simulator)
            let message = "This voice engine needs a real device (no MLX Metal in the simulator)"
            state = .failed(message)
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: message])
            #endif
            if let readyTask {
                await readyTask.value
                if mlxModel != nil { return }
                throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: statusMessage])
            }
            let repo = engine.repo!
            let wasCached = Self.hasCachedModel(engine)
            let log = Logger(subsystem: "com.ipodclassic.app", category: "tts")
            if wasCached {
                state = .loading
            } else {
                state = .downloading(progress: 0)
                LiveActivityManager.shared.downloadStarted()
                startProgressPolling(repo: repo, expected: engine.expectedBytes,
                                     dir: nil)
            }
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                do {
                    let loaded = try await TTS.loadModel(
                        modelRepo: repo,
                        cache: HubCache(location: .fixed(directory: Self.mlxCacheRoot)))
                    self.mlxModel = loaded
                    self.state = .ready
                    if !wasCached { LiveActivityManager.shared.downloadFinished(success: true) }
                    log.notice("tts model ready repo=\(repo, privacy: .public) cached=\(wasCached, privacy: .public)")
                } catch {
                    self.state = .failed(error.localizedDescription)
                    if !wasCached { LiveActivityManager.shared.downloadFinished(success: false) }
                    log.notice("tts load failed repo=\(repo, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                self.stopProgressPolling()
            }
            readyTask = task
            await task.value
            readyTask = nil
            if mlxModel == nil {
                throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: statusMessage])
            }
        }
    }

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

    /// The SDKs expose no download-progress callback; both stage files
    /// into their cache dirs as they land, so poll directory size
    /// against the known checkpoint size. Only runs for real
    /// (non-cached) downloads.
    private func startProgressPolling(repo: String?, expected: Int64, dir: URL?) {
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                let bytes: Int64
                if let dir {
                    bytes = Self.dirBytes(dir)
                } else if let repo {
                    bytes = Self.cacheBytes(repo: repo)
                } else {
                    bytes = 0
                }
                let fraction = Double(bytes) / Double(expected)
                await MainActor.run {
                    guard case .downloading = self?.state else { return }
                    self?.state = .downloading(progress: min(0.999, fraction))
                    LiveActivityManager.shared.downloadProgress(min(0.999, fraction))
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopProgressPolling() {
        progressTask?.cancel()
        progressTask = nil
    }

    nonisolated private static func cacheBytes(repo: String) -> Int64 {
        let dir = mlxCacheRoot.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
        return dirBytes(dir)
    }

    nonisolated private static func dirBytes(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Synthesizes one page of text with the selected engine.
    func synthesize(text: String, language: String, voiceName: String) async throws -> (samples: [Float], sampleRate: Int) {
        try await prepare()
        switch engine {
        case .supertonic:
            guard let backend = supertonicBackend else {
                throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "engine not ready"])
            }
            return try await backend.synthesize(text, language: language, voiceName: voiceName)
        case .qwen, .breeze:
            guard let model = mlxModel else {
                throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "engine not ready"])
            }
            var samples: [Float] = []
            for try await chunk in model.generateSamplesStream(
                text: text,
                voice: engine.instruction(named: voiceName),
                refAudio: nil,
                refText: nil,
                language: engine.languageParameter(code: language)) {
                samples.append(contentsOf: chunk)
            }
            guard !samples.isEmpty else {
                throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "no audio generated"])
            }
            return (samples, model.sampleRate)
        }
    }
}

/// Supertonic-3 backend (FluidAudio CoreML): the engine that is
/// DEVICE-VERIFIED on the iPhone 16e (~400 MB, RTF ~0.30, 44.1 kHz).
/// Single-flight download with the case-collision workaround for the
/// HF repo's duplicate `Config.json`/`config.json` pair.
@MainActor
final class SupertonicSynthesis {
    private var manager: Supertonic3Manager?
    private var styles: [String: Supertonic3VoiceStyle] = [:]
    private var readyTask: Task<Void, Error>?

    private func downloadOnce() async throws {
        let cache = ReadAloudVoiceStore.fluidTTSRoot
        let repoDir = cache.appendingPathComponent("supertonic-3", isDirectory: true)
        try? FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        // The supertonic-3-coreml HF repo ships BOTH `Config.json` (a
        // 2-byte stub) and `config.json` — a fatal collision on Apple's
        // case-insensitive filesystem (downloader aborts, code 516).
        // Fetch the tree with the stub + unneeded sources skipped; the
        // loader then finds every required file present.
        Logger(subsystem: "com.ipodclassic.app", category: "tts").notice("supertonic tree fetch start")
        _ = try await ModelHub.download(
            .supertonic3, subdirectory: "", to: repoDir,
            shouldSkip: { path in
                if path == "Config.json" { return true }
                if path.hasSuffix(".mlpackage") { return true }
                return false
            })
        Logger(subsystem: "com.ipodclassic.app", category: "tts").notice("supertonic tree fetch done")
        // The simulator has no ANE; asking for one can stall CoreML's
        // compile. CPU-only there, CPU+ANE on device.
        #if targetEnvironment(simulator)
        let units: MLComputeUnits = .cpuOnly
        #else
        let units: MLComputeUnits = .cpuAndNeuralEngine
        #endif
        manager = try await Supertonic3Manager.downloadAndCreate(cacheDirectory: cache, computeUnits: units)
        Logger(subsystem: "com.ipodclassic.app", category: "tts").notice("supertonic pipeline ready")
    }

    private func purgeRepo() {
        try? FileManager.default.removeItem(
            at: ReadAloudVoiceStore.fluidTTSRoot.appendingPathComponent("supertonic-3", isDirectory: true))
    }

    /// Downloads the pipeline once (idempotent, single-flight). A
    /// failed attempt purges the half-written repo dir — interrupted
    /// downloads leave `*.partial` staging files the next pass cannot
    /// move over — and retries clean before surfacing the error.
    func ensureReady() async throws {
        if manager != nil { return }
        if let readyTask { try await readyTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.downloadOnce()
            } catch {
                self.purgeRepo()
                try await self.downloadOnce()
            }
        }
        readyTask = task
        defer { readyTask = nil }
        try await task.value
    }

    func synthesize(_ text: String, language: String, voiceName: String) async throws -> (samples: [Float], sampleRate: Int) {
        guard let manager else {
            throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "engine not ready"])
        }
        let style: Supertonic3VoiceStyle
        if let cached = styles[voiceName] {
            style = cached
        } else {
            let voice = Supertonic3Voice(name: voiceName) ?? .m1
            style = try await Supertonic3ResourceDownloader.loadVoiceStyle(
                voice, directory: ReadAloudVoiceStore.fluidTTSRoot)
            styles[voiceName] = style
        }
        let (samples, _) = try await manager.synthesize(text: text, language: language, style: style)
        // Vocoder output rate (Supertonic3Constants.sampleRate).
        return (samples, 44_100)
    }
}

/// Adapter to the audiobook seam so tests keep their mock.
extension ReadAloudVoiceStore: AudiobookSynthesizerType {
    func ensureReady() async throws {
        try await prepare()
    }

    func synthesize(_ text: String, language: String, voiceName: String) async throws -> (samples: [Float], sampleRate: Int) {
        try await synthesize(text: text, language: language, voiceName: voiceName)
    }
}
