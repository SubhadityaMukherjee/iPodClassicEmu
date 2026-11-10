import SwiftUI
import WidgetKit

// iPod-flavored palette: black LCD body, green phosphor text, red REC dot.
private let lcdGreen = Color(red: 0.73, green: 0.85, blue: 0.64)
private let recRed = Color(red: 1.0, green: 0.27, blue: 0.23)

private extension TrackActivityAttributes.Kind {
    var icon: String {
        switch self {
        case .timer: return "timer"
        case .stopwatch: return "stopwatch"
        case .recorder: return "mic.fill"
        case .transcription: return "waveform"
        case .modelDownload: return "arrow.down.circle"
        }
    }
}

/// Tapping a Live Activity opens the app; the time itself ticks via
/// Text(timerInterval:) with no updates from the app.
struct TrackLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrackActivityAttributes.self) { context in
            LockScreenTrackView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.kind.title, systemImage: context.attributes.kind.icon)
                        .font(.headline)
                        .foregroundStyle(accent(context))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    islandExtra(context)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    timeText(context)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent(context))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.attributes.kind.icon)
                    .foregroundStyle(accent(context))
            } compactTrailing: {
                timeText(context)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent(context))
            } minimal: {
                Image(systemName: context.attributes.kind.icon)
                    .foregroundStyle(accent(context))
            }
        }
    }
}

// MARK: - Shared pieces

/// Timer that fired while the app was suspended: the system marks the
/// activity stale at its fire date, which we render as "Done".
private func showDone(_ context: ActivityViewContext<TrackActivityAttributes>) -> Bool {
    context.state.done || (context.isStale && context.attributes.kind == .timer)
}

@ViewBuilder
private func timeText(_ context: ActivityViewContext<TrackActivityAttributes>) -> some View {
    let s = context.state
    if showDone(context) {
        Text("Done")
    } else if context.attributes.kind == .transcription || context.attributes.kind == .modelDownload {
        Text(s.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "…")
    } else if let paused = s.pausedValue {
        Text(paused.liveClock)
    } else if context.attributes.kind == .timer {
        // Ticks down to zero and freezes there at the range end.
        Text(timerInterval: s.segmentStart...s.endDate, countsDown: true)
    } else {
        // Ticks up forever (endDate is .distantFuture).
        Text(timerInterval: s.segmentStart...s.endDate, countsDown: false)
    }
}

@ViewBuilder
private func islandExtra(_ context: ActivityViewContext<TrackActivityAttributes>) -> some View {
    let s = context.state
    if showDone(context) {
        Image(systemName: "checkmark.circle.fill")
    } else if let paused = s.pausedValue {
        Text("Paused")
    } else if context.attributes.kind == .timer {
        HStack(spacing: 2) {
            Text("ends")
            Text(context.state.endDate, style: .time)
        }
    } else if context.attributes.kind == .stopwatch {
        Text("Lap \(s.laps)")
    } else if context.attributes.kind == .transcription {
        Text("till done")
    } else if context.attributes.kind == .modelDownload {
        Text("one time")
    } else {
        Text("REC")
    }
}

private func accent(_ context: ActivityViewContext<TrackActivityAttributes>) -> Color {
    if showDone(context) { return lcdGreen }
    if context.state.pausedValue != nil { return Color.white.opacity(0.55) }
    return context.attributes.kind == .recorder ? recRed : lcdGreen
}

// MARK: - Lock screen

private struct LockScreenTrackView: View {
    let context: ActivityViewContext<TrackActivityAttributes>

    private var accentColor: Color { accent(context) }

    private var bigIcon: String {
        if showDone(context) { return "checkmark.circle.fill" }
        if context.attributes.kind == .recorder, context.state.pausedValue == nil {
            return "record.circle"
        }
        return context.attributes.kind.icon
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label(context.attributes.kind.title, systemImage: context.attributes.kind.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                timeText(context)
                    .font(.system(size: 36, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accentColor)
                statusLine
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                if (context.attributes.kind == .transcription || context.attributes.kind == .modelDownload),
                   let progress = context.state.progress, !showDone(context) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.18))
                            Capsule().fill(lcdGreen)
                                .frame(width: max(4, geo.size.width * progress))
                        }
                    }
                    .frame(height: 4)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: bigIcon)
                .font(.system(size: 30))
                .foregroundStyle(accentColor.opacity(0.9))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .activityBackgroundTint(.black)
    }

    @ViewBuilder
    private var statusLine: some View {
        let s = context.state
        if showDone(context) {
            Text("Completed")
        } else if s.pausedValue != nil {
            Text("Paused")
        } else if context.attributes.kind == .timer {
            HStack(spacing: 2) {
                Text("ends")
                Text(s.endDate, style: .time)
            }
        } else if context.attributes.kind == .stopwatch {
            Text("Laps \(s.laps)")
        } else if context.attributes.kind == .transcription {
            Text(s.label ?? "Transcribing…")
        } else if context.attributes.kind == .modelDownload {
            Text(s.label ?? "Downloading…")
        } else {
            Text("Recording")
        }
    }
}
