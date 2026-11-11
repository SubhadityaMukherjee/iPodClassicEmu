import Foundation
import AVFoundation
import UIKit

/// One saved voice memo.
struct RecordingFile: Identifiable, Equatable {
    let url: URL
    let name: String
    let duration: TimeInterval
    let date: Date

    var id: String { url.lastPathComponent }
    var shareURL: URL { url }
}

/// Voice memos: long-running background recording with pause/resume, local
/// playback, and file sharing. Files live in Documents/Recordings (.m4a).
@Observable
final class RecorderModel {
    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var elapsed: TimeInterval = 0

    private(set) var recordings: [RecordingFile] = []

    // Playback
    private(set) var playingID: String?
    private(set) var isPlaying = false
    private(set) var playTime: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var pausedTotal: TimeInterval = 0
    private var segmentStart: Date = Date()
    private var observingInterruptions = false

    var currentFileURL: URL? {
        recorder?.url
    }

    var recordingsURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Recording

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

    func pause() {
        guard isRecording, !isPaused else { return }
        recorder?.pause()
        pausedTotal += Date().timeIntervalSince(segmentStart)
        isPaused = true
        LiveActivityManager.shared.recorderPaused(elapsed: pausedTotal)
    }

    func resume() {
        guard isRecording, isPaused else { return }
        recorder?.record()
        segmentStart = Date()
        isPaused = false
        LiveActivityManager.shared.recorderResumed(base: pausedTotal)
    }

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
        deactivateSessionIfNeeded()
        loadRecordings()
    }

    private func deactivateSessionIfNeeded() {
        if player == nil {
            try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Playback

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

    func seekCurrent(_ delta: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = min(max(0, p.currentTime + delta), p.duration)
        playTime = p.currentTime
    }

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

    func delete(_ file: RecordingFile) {
        if playingID == file.id { stopPlayback() }
        try? FileManager.default.removeItem(at: file.url)
        TranscriptStore.remove(for: file.id)
        loadRecordings()
    }

    private static func date(fromName name: String) -> Date? {
        // "Recording 2026-11-04 14-05-37" (seconds optional for old files)
        let pattern = #"(\d{4})-(\d{2})-(\d{2}) (\d{2})-(\d{2})(?:-(\d{2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              match.numberOfRanges >= 6,
              let range = Range(match.range(at: 1), in: name) else { return nil }
        let ns = name as NSString
        func group(_ i: Int) -> Int? { match.range(at: i).location != NSNotFound ? Int(ns.substring(with: match.range(at: i))) : nil }
        let comps = DateComponents(
            year: group(1), month: group(2), day: group(3),
            hour: group(4), minute: group(5)
        )
        return Calendar.current.date(from: comps)
    }

    private static func duration(of url: URL) -> TimeInterval {
        // Sync duration via AVAudioPlayer (AVURLAsset.load is async-only).
        (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
    }

    // MARK: Timer

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
    static let shared = PlaybackBridge()
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
