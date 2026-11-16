import AVFoundation
import HuggingFace
import MLXAudioCore
import MLXAudioTTS
import Observation
import os

/// On-device neural TTS for Read Aloud: **Breeze TTS 2** (3B, 4-bit MLX)
/// via the mlx-audio-swift package. First use downloads ~3 GB from
/// HuggingFace into an EXPLICIT cache under Application Support — the
/// hub default lives in `Library/Caches`, which iOS may evict under
/// pressure, and a silent 3 GB re-download is not acceptable.
///
/// MLX needs a real Metal GPU family: the SIMULATOR cannot run it.
/// `ensureReady()` fails there with a friendly message instead of a
/// Metal error, so UI tests and sim QA stay usable (the state machine
/// itself is covered by AudiobookModelTests with a mock synthesizer).
///
/// Voices are natural-language design instructions (Breeze's voice-design
/// feature) — the short names here cycle in the Read Aloud panel and the
/// instruction string rides along. Breeze is English/Chinese bilingual;
/// the instruction carries accent/pace/tone, so language routing from
/// the reader is intentionally ignored for now.
@Observable
@MainActor
final class ReadAloudVoiceStore {
    static let shared = ReadAloudVoiceStore()

    enum DownloadState: Equatable {
        case notStarted
        case downloading(progress: Double?)  // nil = indeterminate
        case loading                          // weights into memory
        case ready
        case failed(String)
    }

    private(set) var state: DownloadState = ReadAloudVoiceStore.hasCachedModel() ? .ready : .notStarted

    static let modelRepo = "mlx-community/Breeze-TTS-2-mlx-4bit"
    /// Total download size of the 4-bit checkpoint (progress denominator).
    private static let expectedBytes: Int64 = 3_010_000_000

    static let voices: [(name: String, instruction: String)] = [
        ("Narrator", "A clear and calm English narrator with an even, steady pace."),
        ("Warm", "A warm, friendly storyteller with a relaxed English accent and unhurried pace."),
        ("British", "A composed British narrator with a measured, articulate delivery."),
        ("Crisp", "A crisp, energetic presenter with brisk pacing and a bright tone."),
    ]

    static func voiceInstruction(named name: String) -> String {
        voices.first { $0.name == name }?.instruction ?? voices[0].instruction
    }

    nonisolated static var cacheRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MLXAudio", isDirectory: true)
    }

    /// The hub cache nests `models--<org>--<repo>/blobs`; the checkpoint
    /// is sharded into a handful of large blobs. Cached = enough blob
    /// mass that the weights are certainly there (> 1 GB).
    nonisolated static func hasCachedModel() -> Bool {
        let fm = FileManager.default
        let blobs = cacheRoot.appendingPathComponent("models--mlx-community--Breeze-TTS-2-mlx-4bit/blobs")
        guard let files = try? fm.contentsOfDirectory(at: blobs, includingPropertiesForKeys: [.fileSizeKey]) else { return false }
        let total = files.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total > 1_000_000_000
    }

    private var model: (any SpeechGenerationModel)?
    private var readyTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    private init() {}

    /// Download + load once (idempotent, single-flight). Returns the
    /// loaded model for synthesis.
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

        let wasCached = Self.hasCachedModel()
        let log = Logger(subsystem: "com.ipodclassic.app", category: "tts")
        if wasCached {
            state = .loading
        } else {
            state = .downloading(progress: 0)
            LiveActivityManager.shared.downloadStarted()
            startProgressPolling()
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            do {
                // Explicit cache root: Application Support never gets
                // evicted by the system (unlike the Library/Caches
                // default, which would force a 3 GB re-download).
                let loaded = try await TTS.loadModel(
                    modelRepo: Self.modelRepo,
                    cache: HubCache(location: .fixed(directory: Self.cacheRoot)))
                self.model = loaded
                self.state = .ready
                if !wasCached { LiveActivityManager.shared.downloadFinished(success: true) }
                log.notice("breeze model ready (cached=\(wasCached, privacy: .public))")
            } catch {
                self.state = .failed(error.localizedDescription)
                if !wasCached { LiveActivityManager.shared.downloadFinished(success: false) }
                log.notice("breeze load failed: \(error.localizedDescription, privacy: .public)")
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
    /// size against the known checkpoint size (~3 GB). Only runs for
    /// real (non-cached) downloads; a cached load is silent.
    private func startProgressPolling() {
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                let bytes = Self.cacheBytes()
                let fraction = Double(bytes) / Double(Self.expectedBytes)
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

    nonisolated private static func cacheBytes() -> Int64 {
        let fm = FileManager.default
        let repo = cacheRoot.appendingPathComponent("models--mlx-community--Breeze-TTS-2-mlx-4bit")
        guard let enumerator = fm.enumerator(at: repo, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Synthesizes one page of text. Chunks arrive as [Float] from the
    /// SDK's sample stream and are concatenated into a single page buffer.
    func synthesize(text: String, voiceName: String) async throws -> (samples: [Float], sampleRate: Int) {
        let model = try await loadModelIfNeeded()
        var samples: [Float] = []
        for try await chunk in model.generateSamplesStream(
            text: text,
            voice: Self.voiceInstruction(named: voiceName),
            refAudio: nil,
            refText: nil,
            language: nil) {
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
        // Breeze is bilingual en/zh and takes style through the voice
        // instruction; the detected chapter language is unused for now.
        try await synthesize(text: text, voiceName: voiceName)
    }
}
