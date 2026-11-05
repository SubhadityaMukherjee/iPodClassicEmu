import Foundation
import ActivityKit

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
        start(.stopwatch, total: 0, staleDate: nil, state: countUp(base: 0))
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
        start(.recorder, total: 0, staleDate: nil, state: countUp(base: 0))
    }

    func recorderPaused(elapsed: TimeInterval) {
        update(.recorder, state: pausedUp(elapsed: elapsed))
    }

    func recorderResumed(base: TimeInterval) {
        update(.recorder, state: countUp(base: base))
    }

    func recorderEnded() { finish(.recorder) }

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
                       staleDate: Date?, state: TrackActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        finish(kind)  // restart cleanly if one is already up
        let attributes = TrackActivityAttributes(kind: kind, total: total)
        activities[kind] = try? Activity.request(
            attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate))
        lastStates[kind] = state
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
        guard let activity = activities.removeValue(forKey: kind) else { return }
        lastStates[kind] = nil
        laps[kind] = nil
        let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
        Task { try? await activity.end(content, dismissalPolicy: dismissalPolicy) }
    }
}
