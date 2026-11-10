import Foundation
import AVFoundation
import UIKit
import FluidAudio
import os

/// One recording's transcription, persisted in a hidden JSON sidecar next
/// to the recordings. `partial` transcripts save as they go, so a killed
/// app never loses what was already transcribed; `failed` entries can be
/// retried from the hold menu.
struct TranscriptEntry: Codable, Equatable {
    var file: String          // recording file name (….m4a)
    var text: String
    var state: String         // "done" | "partial" | "failed"
    var date: Date
    var secondsDone: Double   // audio seconds transcribed so far

    var isDone: Bool { state == "done" }
}

enum TranscriptStore {
    /// Hidden from the Files app by the leading dot.
    static var url: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(".transcripts.json")
    }

    static func loadAll() -> [TranscriptEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([TranscriptEntry].self, from: data) else { return [] }
        return entries
    }

    static func entry(for file: String) -> TranscriptEntry? {
        loadAll().first { $0.file == file }
    }

    /// Title-bar text for the transcript screen ("Recording 2026-11-10 …").
    static func displayTitle(for file: String) -> String {
        let base = file.replacingOccurrences(of: ".m4a", with: "")
        return base.count > 26 ? "Transcript" : base
    }

    /// Upserts one entry (thread-safe enough: called from the main actor).
    static func save(_ entry: TranscriptEntry) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.file == entry.file }) {
            all[idx] = entry
        } else {
            all.append(entry)
        }
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func remove(for file: String) {
        var all = loadAll()
        all.removeAll { $0.file == file }
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Parakeet speech-to-text for voice memos via the FluidAudio CoreML
/// runtime (parakeet-tdt-0.6b-v3, 25 European languages, runs on the
/// Apple Neural Engine). The SDK downloads the model from HuggingFace on
/// first use; transcription is batch but the SDK chunks long audio
/// internally, and the transcript sidecar saves as it goes so a killed
/// app never loses everything.
@Observable
final class TranscriptionManager {
    static let shared = TranscriptionManager()
    private init() {}

    enum DownloadState: Equatable {
        case notStarted
        case downloading(file: String, progress: Double?) // nil = indeterminate
        case ready
        case failed(String)
    }

    @MainActor private(set) var downloadState: DownloadState = .notStarted

    /// One-time sweep of sherpa-era model caches (superseded by
    /// FluidAudio's own cache) and QA test artifacts.
    nonisolated private static func sweepLegacyCaches() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        for name in ["ParakeetTDT-v2", "Parakeet110m-v1"] {
            try? fm.removeItem(at: appSupport.appendingPathComponent(name, isDirectory: true))
        }
        try? fm.removeItem(at: appSupport.appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3", isDirectory: true))
        // QA artifact from the sherpa-era device test.
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        if let docs {
            try? fm.removeItem(at: docs.appendingPathComponent("Recordings/Recording 2026-11-10 22-30-00.m4a"))
        }
    }
    /// Recording file names currently transcribing.
    @MainActor private(set) var transcribing: Set<String> = []

    private var asrManager: AsrManager?

    /// Loads (downloading first if needed) the Parakeet Ultra CoreML
    /// models. FluidAudio caches the download; subsequent calls are
    /// instant (the first device load compiles for ANE, ~10 min once).
    /// The download mirrors to a Live Activity with a progress bar.
    @MainActor
    func ensureModels() async throws -> AsrManager {
        if let asrManager { return asrManager }
        TranscriptionManager.sweepLegacyCaches()
        downloadState = .downloading(file: "asr-models", progress: nil)
        LiveActivityManager.shared.downloadStarted()
        do {
            let models = try await AsrModels.downloadAndLoad(version: .ultra, progressHandler: { p in
                let fraction = p.fractionCompleted
                let phase: String
                if case .compiling(let modelName) = p.phase {
                    phase = "Compiling \(modelName)…"
                } else {
                    phase = "Downloading…"
                }
                Task { @MainActor in
                    self.downloadState = .downloading(file: phase, progress: fraction)
                    LiveActivityManager.shared.downloadProgress(fraction)
                }
            })
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(models)
            asrManager = mgr
            downloadState = .ready
            LiveActivityManager.shared.downloadFinished(success: true)
            return mgr
        } catch {
            downloadState = .failed(error.localizedDescription)
            LiveActivityManager.shared.downloadFinished(success: false)
            throw error
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private var cancelFlags: [String: CancelFlag] = [:]

    /// Transcribes one recording (async, off main). One transcription at
    /// a time — recognition saturates the ANE and the manager is shared.
    @MainActor
    func transcribe(file: String, sourceURL: URL) {
        guard transcribing.isEmpty, FileManager.default.fileExists(atPath: sourceURL.path) else { return }
        let flag = CancelFlag()
        cancelFlags[file] = flag
        transcribing.insert(file)
        TranscriptStore.save(TranscriptEntry(file: file, text: "", state: "partial",
                                             date: Date(), secondsDone: 0))
        LiveActivityManager.shared.transcriptionStarted(file: file)
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runTranscription(file: file, url: sourceURL, cancel: flag)
        }
    }

    /// Transcribes and awaits completion — for App Intents/Shortcuts,
    /// which return the transcript text to the caller.
    @MainActor
    func transcribeAndWait(file: String, sourceURL: URL) async -> String {
        transcribe(file: file, sourceURL: sourceURL)
        while transcribing.contains(file) {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return TranscriptStore.entry(for: file)?.text ?? ""
    }

    @MainActor
    func cancel(file: String) {
        cancelFlags[file]?.cancel()
    }

    nonisolated private func runTranscription(file: String, url: URL, cancel: CancelFlag) async {
        let keepAlive = SilentKeepAlive()
        keepAlive.start()
        defer { keepAlive.stop() }
        let startedAt = Date()
        let logger = Logger(subsystem: "com.ipodclassic.app", category: "transcribe")
        logger.notice("start \(file, privacy: .public)")

        func finish(state: String, text: String, seconds: Double) {
            TranscriptStore.save(TranscriptEntry(file: file, text: text, state: state,
                                                 date: Date(), secondsDone: seconds))
            let headroom = os_proc_available_memory() / 1_048_576
            let elapsed = max(1, Date().timeIntervalSince(startedAt))
            let line = "RESULT \(file) state=\(state) chars=\(text.count) sec=\(Int(seconds)) rtf=\(String(format: "%.2f", elapsed / max(1, seconds))) headroomMB=\(Int(headroom))"
            logger.notice("\(line, privacy: .public)")
            Task { @MainActor in
                self.transcribing.remove(file)
                self.cancelFlags[file] = nil
                LiveActivityManager.shared.transcriptionFinished(file: file, state: state)
            }
        }

        do {
            let mgr = try await self.ensureModels()
            if cancel.isCancelled {
                finish(state: "partial", text: TranscriptStore.entry(for: file)?.text ?? "", seconds: 0)
                return
            }
            // Observe the SDK's chunked-decode progress (0…1) for the
            // Live Activity percentage.
            let stream = await mgr.transcriptionProgressStream
            let progressTask = Task {
                for try await fraction in stream {
                    let f = fraction
                    await MainActor.run {
                        LiveActivityManager.shared.transcriptionProgress(file: file, fraction: f)
                    }
                }
            }
            defer { progressTask.cancel() }
            // URL-based transcription: large files decode disk-backed with
            // ~1.2 MB constant memory, so hour-long memos are safe.
            var decoderState = TdtDecoderState.make()
            let result = try await mgr.transcribe(url, decoderState: &decoderState)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let seconds = TranscriptStore.entry(for: file).map { entry in
                max(entry.secondsDone, 0)
            } ?? 0
            let duration = (try? AVAudioFile(forReading: url)).map {
                Double($0.length) / $0.processingFormat.sampleRate
            } ?? seconds
            finish(state: "done", text: text, seconds: duration)
        } catch {
            let msg = String(describing: error)
            logger.notice("ERROR \(file, privacy: .public): \(msg, privacy: .public)")
            finish(state: "failed", text: "", seconds: 0)
        }
    }
}

/// Keeps the process alive during long transcriptions: plays a silent
/// loop under the app's active .playback audio session (the app already
/// activates one at launch), so iOS's `audio` background mode never
/// suspends us mid-transcription.
final class SilentKeepAlive {
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.caf")
        if !FileManager.default.fileExists(atPath: url.path) {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000,
                                       channels: 1, interleaved: false)!
            guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else { return }
            if let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000) {
                buf.frameLength = 8_000
                try? file.write(from: buf)
            }
        }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.volume = 0.01
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
