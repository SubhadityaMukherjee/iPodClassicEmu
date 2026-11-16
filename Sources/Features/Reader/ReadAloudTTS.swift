import AVFoundation
import HuggingFace
import MLXAudioCore
import MLXAudioTTS
import Observation
import os

/// Read Aloud voice engines, all via the mlx-audio-swift package (MLX).
///
/// - **qwen** (default): Qwen3-TTS 0.6B Base 8-bit — ~700 MB, predefined
///   voices (Ryan/Aiden for English), multilingual via the `language`
///   parameter (Dutch/French/German/… chapters read natively).
/// - **breeze** (experimental, WIP): Breeze TTS 2 3B 4-bit — ~3 GB,
///   voice-design instructions, en/zh. JETSAMS the iPhone 16e (8 GB)
///   when synthesis starts — kept selectable for future devices only.
///
/// Only ONE engine's model is ever downloaded by the normal flows (the
/// selected one); both cache under `Application Support/MLXAudio` in
/// separate hub repo dirs, and Settings offers per-engine deletion.
@Observable
@MainActor
final class ReadAloudVoiceStore {
    static let shared = ReadAloudVoiceStore()

    enum Engine: String, CaseIterable {
        case qwen
        case breeze

        var title: String {
            switch self {
            case .qwen: return "Qwen3"
            case .breeze: return "Breeze (WIP)"
            }
        }

        var repo: String {
            switch self {
            case .qwen: return "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
            case .breeze: return "mlx-community/Breeze-TTS-2-mlx-4bit"
            }
        }

        /// Approximate checkpoint size — download-progress denominator.
        var expectedBytes: Int64 {
            switch self {
            case .qwen: return 700_000_000
            case .breeze: return 3_010_000_000
            }
        }

        var downloadLabel: String {
            switch self {
            case .qwen: return "Download Now (~700 MB)"
            case .breeze: return "Download Now (~3 GB)"
            }
        }

        /// Voice presets. Qwen: speaker names (Base checkpoint's preset
        /// speakers). Breeze: natural-language design instructions.
        var voices: [String] {
            switch self {
            case .qwen: return ["Ryan", "Aiden"]
            case .breeze: return ["Narrator", "Warm", "British", "Crisp"]
            }
        }

        func instruction(named name: String) -> String {
            switch self {
            case .qwen:
                return voices.contains(name) ? name : voices[0]
            case .breeze:
                let table = [
                    "Narrator": "A clear and calm English narrator with an even, steady pace.",
                    "Warm": "A warm, friendly storyteller with a relaxed English accent and unhurried pace.",
                    "British": "A composed British narrator with a measured, articulate delivery.",
                    "Crisp": "A crisp, energetic presenter with brisk pacing and a bright tone.",
                ]
                return table[name] ?? table["Narrator"]!
            }
        }

        /// Qwen takes the chapter language; Breeze ignores it (style rides
        /// the voice instruction).
        func languageParameter(code: String) -> String? {
            switch self {
            case .qwen:
                return Self.languageNames[code] ?? "English"
            case .breeze:
                return nil
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

    /// Selected engine (persisted). Switching unloads the in-memory
    /// model — the new engine downloads/loads on next use.
    var engine: Engine {
        get { Engine(rawValue: AppSettings.shared.readAloudEngine) ?? .qwen }
        set {
            guard newValue != engine else { return }
            AppSettings.shared.readAloudEngine = newValue.rawValue
            model = nil
            readyTask = nil
            stopProgressPolling()
            state = Self.hasCachedModel(newValue) ? .ready : .notStarted
        }
    }

    private(set) var state: DownloadState =
        ReadAloudVoiceStore.hasCachedModel(Engine(rawValue: AppSettings.shared.readAloudEngine) ?? .qwen) ? .ready : .notStarted

    nonisolated static var cacheRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MLXAudio", isDirectory: true)
    }

    /// The hub cache nests `models--<org>--<repo>/blobs`; cached = enough
    /// blob mass that the weights are certainly there.
    nonisolated static func hasCachedModel(_ engine: Engine) -> Bool {
        let threshold: Int64 = engine == .qwen ? 400_000_000 : 1_000_000_000
        return cacheBytes(repo: engine.repo) > threshold
    }

    /// Removes one engine's downloaded weights (frees disk).
    nonisolated static func deleteModel(_ engine: Engine) {
        let dir = cacheRoot.appendingPathComponent("models--" + engine.repo.replacingOccurrences(of: "/", with: "--"))
        try? FileManager.default.removeItem(at: dir)
    }

    private var model: (any SpeechGenerationModel)?
    private var readyTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    private init() {}

    var voices: [String] { engine.voices }

    /// Download + load the selected engine once (idempotent,
    /// single-flight). Returns the loaded model for synthesis.
    @discardableResult
    func loadModelIfNeeded() async throws -> any SpeechGenerationModel {
        if let model { return model }
        #if targetEnvironment(simulator)
        let message = "Read Aloud needs a real device (no MLX Metal in the simulator)"
        state = .failed(message)
        throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: message])
        #endif
        if let readyTask {
            await readyTask.value
            if let model { return model }
            // The in-flight load failed; surface whatever state it set.
            throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: statusMessage])
        }

        let repo = engine.repo
        let wasCached = Self.hasCachedModel(engine)
        let log = Logger(subsystem: "com.ipodclassic.app", category: "tts")
        if wasCached {
            state = .loading
        } else {
            state = .downloading(progress: 0)
            LiveActivityManager.shared.downloadStarted()
            startProgressPolling(repo: repo, expected: engine.expectedBytes)
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            do {
                // Explicit cache root: Application Support never gets
                // evicted by the system (unlike the Library/Caches
                // default, which would force a re-download).
                let loaded = try await TTS.loadModel(
                    modelRepo: repo,
                    cache: HubCache(location: .fixed(directory: Self.cacheRoot)))
                self.model = loaded
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
        if let model { return model }
        throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: statusMessage])
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

    /// The SDK exposes no download-progress callback; the hub downloader
    /// stages blobs into the cache as they land, so poll the directory
    /// size against the known checkpoint size. Only runs for real
    /// (non-cached) downloads; a cached load is silent.
    private func startProgressPolling(repo: String, expected: Int64) {
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                let bytes = Self.cacheBytes(repo: repo)
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
        let fm = FileManager.default
        let dir = cacheRoot.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Synthesizes one page of text with the selected engine. Chunks
    /// arrive as [Float] from the SDK's sample stream and are
    /// concatenated into a single page buffer.
    func synthesize(text: String, language: String, voiceName: String) async throws -> (samples: [Float], sampleRate: Int) {
        let model = try await loadModelIfNeeded()
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

/// Adapter to the audiobook seam so tests keep their mock.
extension ReadAloudVoiceStore: AudiobookSynthesizerType {
    func ensureReady() async throws {
        _ = try await loadModelIfNeeded()
    }

    func synthesize(_ text: String, language: String, voiceName: String) async throws -> (samples: [Float], sampleRate: Int) {
        try await synthesize(text: text, language: language, voiceName: voiceName)
    }
}
