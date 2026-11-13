import Foundation
import ActivityKit
import os

/// Mirrors the timer, stopwatch, or voice-memo recording as a Live Activity
/// on the lock screen / Dynamic Island. One activity per kind, so a timer
/// and a stopwatch can be up at the same time.
///
/// All motion on screen comes from auto-updating `Text(timerInterval:)` in
/// the widget; the app only posts an update on start/pause/resume/lap/end.
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activities: [TrackActivityAttributes.Kind: Activity<TrackActivityAttributes>] = [:]
    private var lastStates: [TrackActivityAttributes.Kind: TrackActivityAttributes.ContentState] = [:]
    private var laps: [TrackActivityAttributes.Kind: Int] = [:]

    private init() {
        // Adopt activities still showing from a previous process (relaunch).
        for activity in Activity<TrackActivityAttributes>.activities {
            activities[activity.attributes.kind] = activity
        }
    }

    // MARK: Timer

    func timerStarted(endDate: Date, total: TimeInterval) {
        start(.timer, total: total, staleDate: endDate, state: .init(
            endDate: endDate, segmentStart: Date(), pausedValue: nil, laps: 0, done: false))
    }

    func timerPaused(remaining: TimeInterval) {
        update(.timer, state: .init(
            endDate: Date().addingTimeInterval(remaining), segmentStart: Date(),
            pausedValue: remaining, laps: 0, done: false))
    }

    func timerResumed(endDate: Date) {
        update(.timer, state: .init(
            endDate: endDate, segmentStart: Date(), pausedValue: nil, laps: 0, done: false))
    }

    /// Timer hit zero with the app alive: leave a "Done" card up until the
    /// user dismisses it (standard iOS timer behavior).
    func timerFinished() {
        finish(.timer, finalState: .init(
            endDate: Date(), segmentStart: Date(), pausedValue: 0, laps: 0, done: true),
            dismissalPolicy: .default)
    }

    func timerEnded() { finish(.timer) }

    // MARK: Stopwatch

    func stopwatchStarted() {
        start(.stopwatch, total: 0, staleDate: nil, state: countUp(base: 0),
              retryState: { self.countUp(base: Self.stopwatchElapsedProvider()) })
    }

    func stopwatchPaused(elapsed: TimeInterval) {
        update(.stopwatch, state: pausedUp(elapsed: elapsed))
    }

    func stopwatchResumed(base: TimeInterval) {
        update(.stopwatch, state: countUp(base: base))
    }

    func stopwatchLap(count: Int) {
        laps[.stopwatch] = count
        // Mutate only the lap count on the last known running state so the
        // ticking segment interval (and thus the displayed time) is untouched.
        if var s = lastStates[.stopwatch] {
            s.laps = count
            update(.stopwatch, state: s)
        }
    }

    func stopwatchEnded() { finish(.stopwatch) }

    // MARK: Recorder

    func recorderStarted() {
        // Live Activities can fail to start right after an install; the
        // retry re-derives the elapsed base from the recorder.
        start(.recorder, total: 0, staleDate: nil, state: countUp(base: 0),
              retryState: { self.countUp(base: Self.recorderElapsedProvider()) })
    }

    func recorderPaused(elapsed: TimeInterval) {
        update(.recorder, state: pausedUp(elapsed: elapsed))
    }

    func recorderResumed(base: TimeInterval) {
        update(.recorder, state: countUp(base: base))
    }

    func recorderEnded() { finish(.recorder) }

    // MARK: Transcription

    /// Segments decoded so far + start time, to project the finish date
    /// from the observed rate (the readout ticks down to it live).
    private var transcriptionStart: Date?
    private var transcriptionLastFraction: Double = 0

    func transcriptionStarted(file: String) {
        transcriptionStart = Date()
        transcriptionLastFraction = 0
        start(.transcription, total: 0, staleDate: nil, state: .init(
            endDate: .distantFuture, segmentStart: Date(),
            pausedValue: nil, laps: 0, done: false, progress: 0, label: file))
    }

    func transcriptionProgress(file: String, fraction: Double) {
        guard activities[.transcription] != nil else { return }
        var remaining: TimeInterval = 0
        if let started = transcriptionStart, fraction > transcriptionLastFraction + 0.001 {
            let elapsed = Date().timeIntervalSince(started)
            remaining = elapsed * (1 - fraction) / max(fraction, 0.01)
        }
        transcriptionLastFraction = fraction
        update(.transcription, state: .init(
            endDate: Date().addingTimeInterval(remaining), segmentStart: Date(),
            pausedValue: nil, laps: 0, done: false, progress: fraction, label: file),
            staleDate: Date().addingTimeInterval(remaining + 10))
    }

    func transcriptionFinished(file: String, state: String) {
        transcriptionStart = nil
        let label: String
        switch state {
        case "failed": label = "Transcription failed"
        case "partial": label = "Transcription paused"
        default: label = "Transcribed"
        }
        finish(.transcription, finalState: .init(
            endDate: Date(), segmentStart: Date(), pausedValue: nil, laps: 0, done: true,
            progress: state == "failed" ? nil : 1, label: label),
            dismissalPolicy: state == "done" ? .default : .immediate)
    }

    // MARK: Model download

    func downloadStarted() {
        start(.modelDownload, total: 0, staleDate: nil, state: .init(
            endDate: .distantFuture, segmentStart: Date(),
            pausedValue: nil, laps: 0, done: false, progress: 0, label: "Downloading…"))
    }

    func downloadProgress(_ fraction: Double) {
        guard activities[.modelDownload] != nil else { return }
        update(.modelDownload, state: .init(
            endDate: .distantFuture, segmentStart: Date(),
            pausedValue: nil, laps: 0, done: false, progress: min(0.999, fraction),
            label: "Downloading…"))
    }

    func downloadFinished(success: Bool) {
        guard activities[.modelDownload] != nil else { return }
        finish(.modelDownload, finalState: .init(
            endDate: Date(), segmentStart: Date(), pausedValue: nil, laps: 0, done: true,
            progress: success ? 1 : nil, label: success ? "Model ready" : "Download failed"),
            dismissalPolicy: success ? .default : .immediate)
    }

    // MARK: Internals

    /// Running count-up state: displays base + (now - real segment start) by
    /// shifting the segment start back by `base`.
    private func countUp(base: TimeInterval) -> TrackActivityAttributes.ContentState {
        .init(endDate: .distantFuture,
              segmentStart: Date().addingTimeInterval(-base),
              pausedValue: nil,
              laps: laps[.stopwatch] ?? 0,
              done: false)
    }

    private func pausedUp(elapsed: TimeInterval) -> TrackActivityAttributes.ContentState {
        .init(endDate: Date(),
              segmentStart: Date().addingTimeInterval(-elapsed),
              pausedValue: elapsed,
              laps: laps[.stopwatch] ?? 0,
              done: false)
    }

    private func start(_ kind: TrackActivityAttributes.Kind, total: TimeInterval,
                       staleDate: Date?, state: TrackActivityAttributes.ContentState,
                       retryState: (() -> TrackActivityAttributes.ContentState)? = nil) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            scheduleRetry(kind, total: total, staleDate: staleDate, retryState: retryState)
            return
        }
        finish(kind)  // restart cleanly if one is already up
        let attributes = TrackActivityAttributes(kind: kind, total: total)
        let requested = try? Activity.request(
            attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate))
        if requested == nil {
            // Fresh installs race the system's widget-extension registration:
            // the first request can fail while iOS is still setting the
            // extension up. Retry shortly (with fresh state) instead of
            // silently losing the activity.
            Logger(subsystem: "com.ipodclassic.app", category: "liveactivity")
                .notice("request failed for \(String(describing: kind), privacy: .public); retrying")
            scheduleRetry(kind, total: total, staleDate: staleDate, retryState: retryState)
            return
        }
        retryAttempts[kind] = 0
        wanted.insert(kind)
        activities[kind] = requested
        lastStates[kind] = state
    }

    /// Live Activities occasionally fail to start on the first launch after
    /// an install; keep trying briefly. Cleared when the kind is finished
    /// or after a few attempts.
    private var retryAttempts: [TrackActivityAttributes.Kind: Int] = [:]
    private var retryWork: [TrackActivityAttributes.Kind: DispatchWorkItem] = [:]
    private var wanted: Set<TrackActivityAttributes.Kind> = []
    /// Count-up kinds re-derive their elapsed base on retry so a
    /// late-starting activity still shows the true elapsed time.
    static var recorderElapsedProvider: () -> TimeInterval = { 0 }
    static var stopwatchElapsedProvider: () -> TimeInterval = { 0 }

    private func scheduleRetry(_ kind: TrackActivityAttributes.Kind, total: TimeInterval,
                               staleDate: Date?,
                               retryState: (() -> TrackActivityAttributes.ContentState)?) {
        let attempts = (retryAttempts[kind] ?? 0) + 1
        guard attempts <= 4 else { return }
        retryAttempts[kind] = attempts
        wanted.insert(kind)
        retryWork[kind]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wanted.contains(kind) else { return }
            let fresh = retryState?() ?? self.lastStates[kind]
            guard let fresh else { return }
            self.start(kind, total: total, staleDate: staleDate, state: fresh, retryState: retryState)
        }
        retryWork[kind] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func update(_ kind: TrackActivityAttributes.Kind,
                        state: TrackActivityAttributes.ContentState, staleDate: Date? = nil) {
        lastStates[kind] = state
        guard let activity = activities[kind] else { return }
        let content = ActivityContent(state: state, staleDate: staleDate)
        Task { try? await activity.update(content) }
    }

    private func finish(_ kind: TrackActivityAttributes.Kind,
                        finalState: TrackActivityAttributes.ContentState? = nil,
                        dismissalPolicy: ActivityUIDismissalPolicy = .immediate) {
        wanted.remove(kind)
        retryWork[kind]?.cancel()
        retryWork[kind] = nil
        retryAttempts[kind] = 0
        guard let activity = activities.removeValue(forKey: kind) else { return }
        lastStates[kind] = nil
        laps[kind] = nil
        let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
        Task { try? await activity.end(content, dismissalPolicy: dismissalPolicy) }
    }
}
