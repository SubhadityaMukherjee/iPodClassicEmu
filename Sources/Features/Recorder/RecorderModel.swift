import Foundation
import AVFoundation
import UIKit

/// One saved voice memo.
struct RecordingFile: Identifiable, Equatable {
    let url: URL
    let name: String
    let duration: TimeInterval
    let date: Date

    /// Identity used for list routing and lookup: the file name (unique
    /// inside Recordings/).
    var id: String { url.lastPathComponent }
    /// The URL handed to the share sheet (same file, named for intent).
    var shareURL: URL { url }
}

/// Voice memos: long-running background recording with pause/resume, local
/// playback, and file sharing. Files live in Documents/Recordings (.m4a).
@Observable
final class RecorderModel {
    /// Registers the recorder's elapsed-time provider with
    /// LiveActivityManager: when a first-launch activity request has to be
    /// retried (it races widget-extension registration on fresh installs),
    /// the retry re-derives its count-up base from the true elapsed value.
    /// Concept: Live Activities → docs/concepts/activitykit-live-activities.md
    init() {
        // Live Activities retry on first-launch races with the true
        // elapsed base, provided here.
        LiveActivityManager.recorderElapsedProvider = { [weak self] in self?.elapsed ?? 0 }
    }
    private(set) var isRecording = false
    private(set) var isPaused = false
    /// Recorded seconds so far, excluding paused intervals: the sum of
    /// finished segments (`pausedTotal`) plus the live segment's span.
    private(set) var elapsed: TimeInterval = 0

    private(set) var recordings: [RecordingFile] = []

    // Playback
    /// File id (`RecordingFile.id`) of the memo loaded in the player, if any.
    private(set) var playingID: String?
    private(set) var isPlaying = false
    /// Playhead of the current playback in seconds, ticked by the shared timer.
    private(set) var playTime: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    /// One 0.25 s timer drives BOTH clocks — recorded `elapsed` and playback
    /// `playTime` — so it deliberately outlives `stop()` while a memo plays.
    private var timer: Timer?
    /// Accumulated seconds of finished recording segments — the base that
    /// `elapsed` counts up from once a pause ends.
    private var pausedTotal: TimeInterval = 0
    /// When the current recording segment began (set by start/resume); its
    /// span is folded into `pausedTotal` when the segment ends.
    private var segmentStart: Date = Date()
    /// Guards `observeInterruptions()` so the observer registers exactly once.
    private var observingInterruptions = false

    /// The file being written by an active recording session, if any.
    var currentFileURL: URL? {
        recorder?.url
    }

    /// Documents/Recordings — where every memo lives; created on first
    /// access so callers never need to bootstrap the directory.
    /// Concept: FileManager & sandbox → docs/concepts/filemanager-and-sandbox.md
    var recordingsURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Recording

    /// Starts a new .m4a recording in Documents/Recordings and the elapsed timer.
    ///
    /// The audio session category here is a hard-won invariant:
    /// `.playAndRecord` with `[.defaultToSpeaker, .allowBluetoothHFP]`. The
    /// BluetoothHFP option is REQUIRED — without it iOS engages the AirPods
    /// microphone, finds the category declares no Bluetooth support, and
    /// churns A2DP↔HFP until the AirPods disconnect mid-recording; with it
    /// AirPods make ONE clean switch at record start. `.defaultToSpeaker`
    /// is the no-headphones fallback (loud speaker, not the earpiece). Any
    /// setup failure just returns — the screen stays in its idle state.
    /// Concept: AVAudioSession → docs/concepts/avfoundation-audio-session.md
    func start() {
        guard !isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // .allowBluetooth is required for the AirPods/HFP microphone:
            // without it iOS engages the BT mic route, finds the category
            // doesn't declare BT support, and falls back to the built-in
            // mic — the AirPods route churns A2DP<->HFP and often drops
            // entirely mid-recording. With it, AirPods make ONE clean
            // A2DP->HFP switch at record start (mic + monitor through the
            // AirPods); .defaultToSpeaker stays as the no-BT fallback
            // (speaker instead of the quiet earpiece).
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            return
        }

        let name = uniqueRecordingName()
        let url = recordingsURL.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return }
        r.record(forDuration: 0)  // unlimited
        recorder = r
        isRecording = true
        isPaused = false
        elapsed = 0
        pausedTotal = 0
        segmentStart = Date()
        startTimer()
        LiveActivityManager.shared.recorderStarted()
        loadRecordings()
    }

    /// Pauses the active recording: banks the finished segment into
    /// `pausedTotal` (so `elapsed` freezes instead of drifting) and mirrors
    /// the pause into the recorder Live Activity.
    func pause() {
        guard isRecording, !isPaused else { return }
        recorder?.pause()
        pausedTotal += Date().timeIntervalSince(segmentStart)
        isPaused = true
        LiveActivityManager.shared.recorderPaused(elapsed: pausedTotal)
    }

    /// Resumes a paused recording by opening a new segment, and re-bases the
    /// Live Activity count-up at `pausedTotal` so it continues seamlessly.
    func resume() {
        guard isRecording, isPaused else { return }
        recorder?.record()
        segmentStart = Date()
        isPaused = false
        LiveActivityManager.shared.recorderResumed(base: pausedTotal)
    }

    /// Stops the recorder and saves the file. `elapsed` resets to 0 — the
    /// duration now lives on the file itself — the Live Activity ends, and
    /// the shared audio session is deliberately left active (background
    /// music depends on it; see `leaveSessionActive()`).
    func stop() {
        guard isRecording else { return }
        if !isPaused { pausedTotal += Date().timeIntervalSince(segmentStart) }
        recorder?.stop()
        elapsed = 0  // the timer resets after a save; duration lives on the file
        recorder = nil
        isRecording = false
        isPaused = false
        stopTimer()
        LiveActivityManager.shared.recorderEnded()
        leaveSessionActive()
        loadRecordings()
    }

    /// Keeps the shared .playback session active after recording (music
    /// and background audio depend on it — never deactivate), and lets
    /// other audio (e.g. a paused music app) resume.
    private func leaveSessionActive() {
        if player == nil {
            try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Playback

    /// Plays a memo through AVAudioPlayer, switching the shared session to
    /// `.playback` first. Completion arrives via `PlaybackBridge` — the
    /// delegate protocol needs a class instance, and the bridge's closure
    /// hands control back into this model.
    /// - Parameter file: the recording to load and play.
    func play(_ file: RecordingFile) {
        stopPlayback()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        guard let p = try? AVAudioPlayer(contentsOf: file.url) else { return }
        p.delegate = PlaybackBridge.shared
        PlaybackBridge.shared.onFinish = { [weak self] in
            self?.isPlaying = false
            self?.playTime = 0
        }
        p.play()
        player = p
        playingID = file.id
        isPlaying = true
        startTimer()
    }

    /// Toggles play/pause of `file`; if it isn't the already-loaded memo,
    /// starts it from the top instead.
    /// - Parameter file: the recording acted on.
    func playPauseCurrent(_ file: RecordingFile) {
        guard let p = player, playingID == file.id else {
            play(file)
            return
        }
        if isPlaying {
            p.pause()
            isPlaying = false
        } else {
            p.play()
            isPlaying = true
        }
    }

    /// Moves the playhead of the loaded memo by `delta` seconds, clamped to
    /// the file's [0, duration] range.
    /// - Parameter delta: seconds to seek by (negative rewinds).
    func seekCurrent(_ delta: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = min(max(0, p.currentTime + delta), p.duration)
        playTime = p.currentTime
    }

    /// Stops the current playback and clears the playing state and playhead.
    func stopPlayback() {
        player?.stop()
        player = nil
        playingID = nil
        isPlaying = false
        playTime = 0
    }

    // MARK: Files

    /// "Recording 2026-11-04 14-05-37.m4a", with a numeric suffix if a file
    /// with that exact name already exists (never overwrite a recording).
    private func uniqueRecordingName() -> String {
        let base = "Recording \(TimeFormat.recordingStamp())"
        var candidate = recordingsURL.appendingPathComponent("\(base).m4a")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = recordingsURL.appendingPathComponent("\(base)-\(n).m4a")
            n += 1
        }
        return candidate.lastPathComponent
    }

    /// Rescans Documents/Recordings for .m4a files and republishes the list,
    /// newest first. Display dates prefer the timestamp parsed from the file
    /// NAME over the filesystem creation date — creation dates move when
    /// files are synced or restored, file names don't.
    func loadRecordings() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: recordingsURL, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]) else { return }
        let loaded = files.filter { $0.pathExtension == "m4a" }.map { url -> RecordingFile in
            var date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let name = url.deletingPathExtension().lastPathComponent
            // Prefer the timestamp parsed from the filename (stable across sync).
            let parsed = Self.date(fromName: name)
            if let parsed { date = parsed }
            return RecordingFile(url: url, name: name, duration: Self.duration(of: url), date: date)
        }
        recordings = loaded.sorted { $0.date > $1.date }
    }

    /// Deletes a memo: stops playback if it's the playing one, removes the
    /// file AND its transcript sidecar entry (no orphaned transcripts),
    /// then reloads the list.
    /// - Parameter file: the recording to delete.
    func delete(_ file: RecordingFile) {
        if playingID == file.id { stopPlayback() }
        try? FileManager.default.removeItem(at: file.url)
        TranscriptStore.remove(for: file.id)
        loadRecordings()
    }

    /// Parses the capture date out of a recording's file name.
    /// - Parameter name: file name without extension, e.g.
    ///   "Recording 2026-11-04 14-05-37" (seconds optional for old files).
    /// - Returns: the parsed date, or nil when the name doesn't match.
    private static func date(fromName name: String) -> Date? {
        // "Recording 2026-11-04 14-05-37" (seconds optional for old files)
        let pattern = #"(\d{4})-(\d{2})-(\d{2}) (\d{2})-(\d{2})(?:-(\d{2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              match.numberOfRanges >= 6,
              let range = Range(match.range(at: 1), in: name) else { return nil }
        let ns = name as NSString
        /// Captured group `i` as an Int, nil when the group didn't
        /// participate in the match (e.g. the optional seconds).
        func group(_ i: Int) -> Int? { match.range(at: i).location != NSNotFound ? Int(ns.substring(with: match.range(at: i))) : nil }
        let comps = DateComponents(
            year: group(1), month: group(2), day: group(3),
            hour: group(4), minute: group(5)
        )
        return Calendar.current.date(from: comps)
    }

    /// Reads a file's duration synchronously via AVAudioPlayer —
    /// AVURLAsset's duration load is async-only, and list reloads need the
    /// value right now.
    /// - Parameter url: the audio file to measure.
    /// - Returns: duration in seconds (0 if the file can't be read).
    private static func duration(of url: URL) -> TimeInterval {
        // Sync duration via AVAudioPlayer (AVURLAsset.load is async-only).
        (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
    }

    // MARK: Timer

    /// Runs the shared 0.25 s timer that ticks `elapsed` while recording
    /// and `playTime` while playing (one timer drives both clocks).
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isRecording && !self.isPaused {
                self.elapsed = self.pausedTotal + Date().timeIntervalSince(self.segmentStart)
            }
            if let p = self.player, self.isPlaying {
                self.playTime = p.currentTime
            }
        }
    }

    /// Invalidates the shared timer only when no player is left — a
    /// recording can stop while a memo is still playing, and `playTime`
    /// must keep ticking.
    private func stopTimer() {
        if player == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Audio session interruption (call, Siri): pause safely; resume
    /// recording when the interruption ends so long captures survive.
    func observeInterruptions() {
        guard !observingInterruptions else { return }
        observingInterruptions = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let info = note.userInfo,
                  let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            switch type {
            case .began:
                if self.isRecording && !self.isPaused { self.pause() }
                if self.isPlaying { self.player?.pause(); self.isPlaying = false }
            case .ended:
                if self.isRecording && self.isPaused { self.resume() }
            @unknown default:
                break
            }
        }
    }
}

/// AVAudioPlayerDelegate bridge (delegate pattern needs a class).
final class PlaybackBridge: NSObject, AVAudioPlayerDelegate {
    /// Process-wide delegate instance (AVAudioPlayer's delegate is a weak,
    /// class-constrained property).
    static let shared = PlaybackBridge()
    /// Set per playback by RecorderModel; fired when the file finishes.
    var onFinish: (() -> Void)?

    /// AVAudioPlayerDelegate callback: forwards playback completion into the
    /// current `onFinish` closure.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
