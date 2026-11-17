import Foundation
import ActivityKit
import os

/// Mirrors the timer, stopwatch, or voice-memo recording as a Live Activity
/// on the lock screen / Dynamic Island. One activity per kind, so a timer
/// and a stopwatch can be up at the same time.
///
/// All motion on screen comes from auto-updating `Text(timerInterval:)` in
/// the widget; the app only posts an update on start/pause/resume/lap/end.
/// Mirrors the timer, stopwatch, or voice-memo recording as a Live Activity
/// on the lock screen / Dynamic Island. One activity per kind, so a timer
/// and a stopwatch can be up at the same time.
///
/// All motion on screen comes from auto-updating `Text(timerInterval:)` in
/// the widget; the app only posts an update on start/pause/resume/lap/end.
///
/// Plain class with no locking: every caller is a UI model on the main
/// thread, and the retry work item hops back onto the main queue.
///
/// Concept: activitykit-live-activities → docs/concepts/activitykit-live-activities.md
final class LiveActivityManager {
    /// Process-wide singleton; the timer/stopwatch/recorder models drive it.
    static let shared = LiveActivityManager()

    /// Live activity handle per kind — at most one card of each kind is up.
    private var activities: [TrackActivityAttributes.Kind: Activity<TrackActivityAttributes>] = [:]
    /// Most recently posted content state per kind, so retries and lap
    /// updates can re-derive from the last known running state.
    private var lastStates: [TrackActivityAttributes.Kind: TrackActivityAttributes.ContentState] = [:]
    /// Current lap count per kind (stopwatch readout).
    private var laps: [TrackActivityAttributes.Kind: Int] = [:]

    /// Singleton; adopts activities still showing from a previous process
    /// so a relaunch doesn't strand them.
    private init() {
        // Adopt activities still showing from a previous process (relaunch).
        for activity in Activity<TrackActivityAttributes>.activities {
            activities[activity.attributes.kind] = activity
        }
    }

    // MARK: Timer

    /// Starts (or restarts) the countdown card counting down to `endDate`.
    ///
    /// - Parameters:
    ///   - endDate: when the timer fires.
    ///   - total: original duration, for the progress-ring fraction.
    func timerStarted(endDate: Date, total: TimeInterval) {
        start(.timer, total: total, staleDate: endDate, state: .init(
            endDate: endDate, segmentStart: Date(), pausedValue: nil, laps: 0, done: false))
    }

    /// Freezes the countdown card showing `remaining` as a static value.
    ///
    /// - Parameter remaining: seconds left at the moment of the pause.
    func timerPaused(remaining: TimeInterval) {
        update(.timer, state: .init(
            endDate: Date().addingTimeInterval(remaining), segmentStart: Date(),
            pausedValue: remaining, laps: 0, done: false))
    }

    /// Continues the countdown card toward `endDate`.
    ///
    /// - Parameter endDate: new fire date (now + remaining).
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

    /// Cancels the timer card outright (user reset) — no "Done" card.
    func timerEnded() { finish(.timer) }

    // MARK: Stopwatch

    /// Starts the count-up from zero; if the start is retried, the elapsed
    /// base is re-derived from `stopwatchElapsedProvider` so a late
    /// activity still shows the true elapsed time.
    func stopwatchStarted() {
        start(.stopwatch, total: 0, staleDate: nil, state: countUp(base: 0),
              retryState: { self.countUp(base: Self.stopwatchElapsedProvider()) })
    }

    /// Freezes the readout at `elapsed`.
    func stopwatchPaused(elapsed: TimeInterval) {
        update(.stopwatch, state: pausedUp(elapsed: elapsed))
    }

    /// Continues counting up from `base` seconds already elapsed.
    func stopwatchResumed(base: TimeInterval) {
        update(.stopwatch, state: countUp(base: base))
    }

    /// Posts the lap count without touching the running interval, so the
    /// displayed time keeps ticking unchanged.
    ///
    /// - Parameter count: laps completed so far.
    func stopwatchLap(count: Int) {
        laps[.stopwatch] = count
        // Mutate only the lap count on the last known running state so the
        // ticking segment interval (and thus the displayed time) is untouched.
        if var s = lastStates[.stopwatch] {
            s.laps = count
            update(.stopwatch, state: s)
        }
    }

    /// Ends and immediately dismisses the stopwatch card.
    func stopwatchEnded() { finish(.stopwatch) }

    // MARK: Recorder

    /// Starts the recording count-up; retries re-derive the elapsed base
    /// from `recorderElapsedProvider`.
    func recorderStarted() {
        // Live Activities can fail to start right after an install; the
        // retry re-derives the elapsed base from the recorder.
        start(.recorder, total: 0, staleDate: nil, state: countUp(base: 0),
              retryState: { self.countUp(base: Self.recorderElapsedProvider()) })
    }

    /// Freezes the recording readout at `elapsed`.
    func recorderPaused(elapsed: TimeInterval) {
        update(.recorder, state: pausedUp(elapsed: elapsed))
    }

    /// Continues the recording count-up from `base` seconds.
    func recorderResumed(base: TimeInterval) {
        update(.recorder, state: countUp(base: base))
    }

    /// Ends and immediately dismisses the recording card.
    func recorderEnded() { finish(.recorder) }

    // MARK: Transcription

    /// Segments decoded so far + start time, to project the finish date
    /// from the observed rate (the readout ticks down to it live).
    private var transcriptionStart: Date?
    /// Last reported progress fraction, to ignore negligible jitter when
    /// measuring the observed rate.
    private var transcriptionLastFraction: Double = 0

    /// Opens the transcription progress card for `file`.
    func transcriptionStarted(file: String) {
        transcriptionStart = Date()
        transcriptionLastFraction = 0
        start(.transcription, total: 0, staleDate: nil, state: .init(
            endDate: .distantFuture, segmentStart: Date(),
            pausedValue: nil, laps: 0, done: false, progress: 0, label: file))
    }

    /// Projects the finish time from the rate observed since the start and
    /// re-posts the card; the widget's timer then ticks down to that date.
    ///
    /// - Parameters:
    ///   - file: name being transcribed (card label).
    ///   - fraction: overall progress 0…1.
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

    /// Ends the card with a result label; success stays for the user to
    /// dismiss, failed/paused dismiss immediately.
    ///
    /// - Parameters:
    ///   - file: name that was transcribed.
    ///   - state: "done", "partial", or "failed".
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

    /// Opens an indeterminate "Downloading…" card for a voice-model fetch.
    func downloadStarted() {
        start(.modelDownload, total: 0, staleDate: nil, state: .init(
            endDate: .distantFuture, segmentStart: Date(),
            pausedValue: nil, laps: 0, done: false, progress: 0, label: "Downloading…"))
    }

    /// Advances the download bar; capped below 1 so the card can never
    /// read "complete" before the download actually finished.
    ///
    /// - Parameter fraction: bytes downloaded / total, 0…1.
    func downloadProgress(_ fraction: Double) {
        guard activities[.modelDownload] != nil else { return }
        update(.modelDownload, state: .init(
            endDate: .distantFuture, segmentStart: Date(),
            pausedValue: nil, laps: 0, done: false, progress: min(0.999, fraction),
            label: "Downloading…"))
    }

    /// Ends the download card; success lingers as "Model ready", failure
    /// dismisses immediately.
    ///
    /// - Parameter success: whether the download completed.
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

    /// Frozen count-up state showing exactly `elapsed`.
    private func pausedUp(elapsed: TimeInterval) -> TrackActivityAttributes.ContentState {
        .init(endDate: Date(),
              segmentStart: Date().addingTimeInterval(-elapsed),
              pausedValue: elapsed,
              laps: laps[.stopwatch] ?? 0,
              done: false)
    }

    /// Requests an activity of `kind`, first ending any previous one; when
    /// activities are disabled or the request fails, schedules a retry
    /// rather than silently dropping the card.
    ///
    /// - Parameters:
    ///   - kind: which card to show.
    ///   - total: total duration, for progress fractions.
    ///   - staleDate: when the system may regard the card as stale.
    ///   - state: initial content state.
    ///   - retryState: closure re-deriving fresh state for a retry
    ///     (count-ups re-read their elapsed base so a late-starting card
    ///     shows the true elapsed time).
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
    /// Pending retry timer per kind, cancelled on success or finish.
    private var retryWork: [TrackActivityAttributes.Kind: DispatchWorkItem] = [:]
    /// Kinds a caller asked for that aren't up yet — what drives retries.
    private var wanted: Set<TrackActivityAttributes.Kind> = []
    /// Count-up kinds re-derive their elapsed base on retry so a
    /// late-starting activity still shows the true elapsed time.
    /// Registered by RecorderModel's init.
    static var recorderElapsedProvider: () -> TimeInterval = { 0 }
    /// Stopwatch counterpart of `recorderElapsedProvider`; registered by
    /// StopwatchModel's init.
    static var stopwatchElapsedProvider: () -> TimeInterval = { 0 }

    /// Retries a failed start after 1.2 s, up to 4 attempts, using state
    /// freshly derived from `retryState` when provided.
    ///
    /// Concept: swift-closures → docs/concepts/swift-closures.md
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

    /// Posts a new content state to the running activity. Fire-and-forget
    /// `Task` — ActivityKit updates are async and a failed update is
    /// harmless (the next event re-posts).
    private func update(_ kind: TrackActivityAttributes.Kind,
                        state: TrackActivityAttributes.ContentState, staleDate: Date? = nil) {
        lastStates[kind] = state
        guard let activity = activities[kind] else { return }
        let content = ActivityContent(state: state, staleDate: staleDate)
        Task { try? await activity.update(content) }
    }

    /// Ends the kind's activity and clears its retry/bookkeeping state.
    ///
    /// - Parameters:
    ///   - kind: which activity to end.
    ///   - finalState: optional last content (e.g. the "Done" card).
    ///   - dismissalPolicy: `.default` leaves the card for the user to
    ///     swipe away; `.immediate` removes it now.
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
