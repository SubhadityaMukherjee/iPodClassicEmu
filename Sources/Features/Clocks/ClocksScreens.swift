import SwiftUI

/// Clocks menu: Timer, Stopwatch.
struct ClocksMenuScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0

    private let rows: [MenuItem] = [
        MenuItem(id: "timer", title: "Timer"),
        MenuItem(id: "stopwatch", title: "Stopwatch"),
    ]

    /// The two-row Clocks menu list.
    var body: some View {
        MenuList(items: rows, selection: selection)
            .onWheel { handle($0) }
    }

    /// Wheel routing: ticks move the selection, center pushes the matching
    /// clock screen, MENU pops back to the parent menu.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: rows.count, delta: d, settings: settings)
        case .select:
            switch rows[min(selection, rows.count - 1)].id {
            case "timer": model.push(.timer)
            case "stopwatch": model.push(.stopwatch)
            default: break
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}

/// Blue-dial countdown timer with Start/Reset/Set Duration rows.
struct TimerScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    /// Focus rows for the timer: Start/Pause, Reset, Set Duration.
    enum Segment: Int, CaseIterable { case startStop, reset, setDuration }
    /// Which h/m/s field the wheel edits in duration-editing mode.
    enum DurationSegment: Int, CaseIterable { case hour, minute, second }

    /// Highlighted action row (Start/Pause, Reset, Set Duration).
    @State private var segment: Segment = .startStop
    /// Active h/m/s field while editing the duration.
    @State private var durationSegment: DurationSegment = .minute
    /// True while the h/m/s fields are being edited (center-press mode).
    @State private var editingDuration = false
    /// Whether the quick-presets hold panel is up.
    @State private var presetsOpen = false
    /// Highlighted row in the presets panel.
    @State private var presetSelection = 0

    /// Quick-start durations (minutes) — hold center on the timer screen.
    private let presets = [5, 10, 15, 30, 60]

    /// Blue countdown dial, digital readout and action rows; the presets
    /// panel overlays everything while open. Records the Recents
    /// "last clock" entry on appear.
    var body: some View {
        ZStack {
            VStack(spacing: 6) {
                dial
                    .frame(maxHeight: 108)
                    .padding(.top, 4)

                Text(TimeFormat.hms(model.timer.remaining))
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)

                controls
                    .padding(.horizontal, 22)
            }
            .onWheel { handle($0) }
            if presetsOpen {
                ModalHost { presetsPanel }
                    .zIndex(2)
            }
        }
        .task {
            // Recents: the last clock screen opened.
            model.recents.record(clock: "timer")
            // QA hook: open the presets panel without a gesture (screenshots).
            if ProcessInfo.processInfo.environment["TIMER_PRESETS"] == "1" {
                presetsOpen = true
            }
        }
    }

    /// The hold-center quick-start panel: preset minute counts + Cancel.
    private var presetsPanel: some View {
        ModalPanel(title: "Presets", onClose: { closePresets() }) {
            MenuList(
                items: presets.map { m in
                    MenuItem(id: "p.\(m)", title: "\(m) min",
                             symbol: "timer", showsChevron: false, isActionRow: true)
                } + [MenuItem(id: "cancel", title: "Cancel", showsChevron: false)],
                selection: presetSelection, compact: true
            )
            .padding(.top, 2)
        }
    }

    /// Dismisses the presets panel with the standard panel fade.
    private func closePresets() {
        withAnimation(.easeIn(duration: 0.15)) { presetsOpen = false }
    }

    /// Wheel ticks are raw here (the panel is small); selection moves
    /// one row per detent with the standard feedback.
    private func handlePresets(_ event: ControlEvent) -> Bool {
        guard presetsOpen else { return false }
        switch event {
        case .tick(let d):
            moveListSelection(&presetSelection, count: presets.count + 1, delta: d, settings: settings)
            WheelFeedback.tick(dir: d)
        case .select:
            let idx = min(presetSelection, presets.count)
            if idx < presets.count {
                let minutes = presets[idx]
                closePresets()
                model.timer.start(duration: Double(minutes) * 60)
                WheelHaptics.shared.ensureRunning()
                WheelHaptics.shared.buttonPress(strength: 0.8)
            } else {
                closePresets()
            }
        case .menu:
            closePresets()
        default:
            break
        }
        return true
    }

    /// Solid blue dial carrying the tick/hand overlay.
    private var dial: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.243, green: 0.408, blue: 0.71))
                .aspectRatio(1, contentMode: .fit)
                .frame(maxHeight: 108)
            TimerDialOverlay(fraction: dialFraction)
        }
    }

    /// Remaining/total for the sweep hand; 0 when no total is set.
    private var dialFraction: Double {
        guard model.timer.total > 0 else { return 0 }
        return model.timer.remaining / model.timer.total
    }

    /// Two modes: duration-editing shows the h/m/s segments; otherwise
    /// the duration readout sits above the Start/Pause + Reset pair,
    /// with Set Duration as its own row.
    private var controls: some View {
        VStack(spacing: 4) {
            // Duration sits above the buttons so it's always in view.
            if editingDuration {
                HStack(spacing: 4) {
                    durSegment(label: "h", value: model.timer.durationHours, selected: durationSegment == .hour)
                    Text(":").font(Theme.font(17, .semibold))
                    durSegment(label: "m", value: model.timer.durationMinutes, selected: durationSegment == .minute)
                    Text(":").font(Theme.font(17, .semibold))
                    durSegment(label: "s", value: model.timer.durationSeconds, selected: durationSegment == .second)
                }
                Text("Wheel: adjust · Center: next · MENU: done")
                    .font(Theme.font(10, .medium))
                    .foregroundStyle(Theme.inkDim)
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                        .font(Theme.font(12, .semibold))
                    Text("\(model.timer.durationHours > 0 ? String(format: "%d:", model.timer.durationHours) : "")\(String(format: "%02d:%02d", model.timer.durationMinutes, model.timer.durationSeconds))")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.inkDim)
                HStack(spacing: 0) {
                    controlRow(text: running ? "Pause" : (model.timer.remaining < model.timer.total && model.timer.remaining > 0 ? "Resume" : "Start"), selected: segment == .startStop, leading: true)
                    controlRow(text: "Reset", selected: segment == .reset, leading: false)
                }
                HStack {
                    Text("Set Duration")
                        .font(Theme.font(16, .semibold))
                        .foregroundStyle(segment == .setDuration ? Color.white : Theme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(segment == .setDuration ? AnyShapeStyle(SelectionGradient()) : AnyShapeStyle(Color.clear)))
                }
            }
        }
    }

    private var running: Bool { model.timer.isRunning }

    /// One half of the paired Start/Reset row; the selection gradient is
    /// masked to round only the OUTER corners so the pair reads as a
    /// single split bar.
    private func controlRow(text: String, selected: Bool, leading: Bool) -> some View {
        Text(text)
            .font(Theme.font(16, .semibold))
            .foregroundStyle(selected ? Color.white : Theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                Group {
                    if selected {
                        SelectionGradient()
                            .mask(
                                UnevenRoundedRectangle(topLeadingRadius: leading ? 4 : 0, bottomLeadingRadius: leading ? 4 : 0, bottomTrailingRadius: leading ? 0 : 4, topTrailingRadius: leading ? 0 : 4)
                            )
                    }
                }
            )
    }

    /// One boxed h/m/s value, highlighted when its field is active.
    private func durSegment(label: String, value: Int, selected: Bool) -> some View {
        HStack(spacing: 2) {
            Text(String(format: "%02d", value))
                .font(Theme.font(17, .semibold))
                .monospacedDigit()
            Text(label)
                .font(Theme.font(10, .medium))
                .foregroundStyle(Theme.inkDim)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? AnyShapeStyle(SelectionGradient()) : AnyShapeStyle(Color.clear)))
    }

    // MARK: Input

    /// Wheel routing. The presets panel consumes events first when open;
    /// otherwise ticks move the segment, center activates, hold center
    /// opens the presets (idle only), and MENU leaves duration-editing
    /// before it ever pops the screen.
    private func handle(_ event: ControlEvent) {
        if handlePresets(event) { return }
        switch event {
        case .tick(let d):
            tickAdjust(by: d)
        case .select:
            selectCurrent()
        case .centerHold:
            // Hold center: quick presets (only when idle at the buttons).
            guard !editingDuration else { break }
            presetSelection = 0
            WheelHaptics.shared.ensureRunning()
            WheelHaptics.shared.buttonPress(strength: 0.85)
            withAnimation(.easeOut(duration: 0.18)) { presetsOpen = true }
        case .menu:
            if editingDuration {
                editingDuration = false
            } else {
                model.pop()
            }
        default:
            break
        }
    }

    /// Wheel ticks. In edit mode they adjust the active h/m/s field
    /// (wrapping); otherwise ticks ALWAYS navigate rows — hijacking
    /// ticks as minute-adjustments made it impossible to scroll back
    /// out of the Set Duration row, which is exactly what the
    /// center-press editing mode exists for.
    private func tickAdjust(by d: Int) {
        if editingDuration {
            switch durationSegment {
            case .hour: model.timer.durationHours = wrap(model.timer.durationHours + d, 0, 23)
            case .minute: model.timer.durationMinutes = wrap(model.timer.durationMinutes + d, 0, 59)
            case .second: model.timer.durationSeconds = wrap(model.timer.durationSeconds + d, 0, 59)
            }
            WheelFeedback.tick(dir: d)
        } else {
            // Scroll always navigates — even on Set Duration. (Hijacking
            // ticks here as minute-adjustments made it impossible to
            // scroll back out of the row; adjusting duration is what
            // center-press editing mode is for.)
            _ = moveListSelectionInt(&rawSegmentIndex, count: Segment.allCases.count, delta: d)
        }
    }

    /// Bridges `segment` to a plain inout Int so the wrap-around list
    /// helper can drive it. The setter is `nonmutating` because an
    /// @State setter mutates SwiftUI-owned storage, not the struct view
    /// that declares it — Swift requires `nonmutating` for exactly that.
    ///
    /// Concept: Swift value & reference types → docs/concepts/swift-value-and-reference-types.md
    private var rawSegmentIndex: Int {
        get { segment.rawValue }
        nonmutating set { segment = Segment(rawValue: newValue) ?? .startStop }
    }

    /// Center press. In edit mode it walks h → m → s and exits editing on
    /// the last field; otherwise Start/Pause/Resume (tri-state on the
    /// model), Reset, or entering duration editing.
    private func selectCurrent() {
        WheelHaptics.shared.ensureRunning()
        WheelHaptics.shared.buttonPress(strength: 0.8)
        if editingDuration {
            // Last segment: finish editing and return to the buttons.
            if durationSegment == .second {
                editingDuration = false
                segment = .startStop
            } else {
                durationSegment = DurationSegment(rawValue: durationSegment.rawValue + 1) ?? .hour
            }
            return
        }
        switch segment {
        case .startStop:
            if model.timer.isRunning {
                model.timer.pause()
            } else if model.timer.remaining > 0 {
                model.timer.resume()
            } else {
                model.timer.start(duration: Double(model.timer.durationHours) * 3600 + Double(model.timer.durationMinutes) * 60 + Double(model.timer.durationSeconds))
            }
        case .reset:
            model.timer.reset()
        case .setDuration:
            editingDuration = true
        }
    }

    /// Wraps `v` into lo…hi (inclusive) so wheel spins cycle.
    private func wrap(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        let range = hi - lo + 1
        return lo + ((v - lo + range * 4) % range)
    }
}

/// Tick marks overlay for the timer dial.
private struct TimerDialOverlay: View {
    /// Remaining fraction of the countdown (1 = full, 0 = done).
    let fraction: Double

    /// Twelve tick marks plus a sweep hand that empties clockwise as the
    /// remaining fraction shrinks.
    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 6
            for i in 0..<12 {
                let angle = Double(i) / 12 * 2 * .pi
                var tick = Path()
                let inner = radius * 0.86
                let outer = radius * 0.98
                tick.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                tick.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                ctx.stroke(tick, with: .color(.white.opacity(0.8)), lineWidth: 1.2)
            }
            // Sweep hand showing remaining fraction
            let handAngle = (1 - fraction) * 2 * .pi
            var hand = Path()
            hand.move(to: center)
            hand.addLine(to: CGPoint(
                x: center.x + cos(handAngle - .pi / 2) * radius * 0.9,
                y: center.y + sin(handAngle - .pi / 2) * radius * 0.9
            ))
            ctx.stroke(hand, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            let dot = Path(ellipseIn: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
            ctx.fill(dot, with: .color(.white))
        }
    }
}

/// Stopwatch with lap list.
struct StopwatchScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0

    /// State-dependent actions: Stop/Lap/Reset while running;
    /// Resume/Reset when paused with time on the clock; Start when fresh.
    private var rows: [String] {
        model.stopwatch.isRunning ? ["Stop", "Lap", "Reset"] : (model.stopwatch.elapsed > 0 ? ["Resume", "Reset"] : ["Start"])
    }

    /// Big monospaced readout, newest-first lap list, action rows.
    var body: some View {
        VStack(spacing: 4) {
            Text(TimeFormat.stopwatch(model.stopwatch.elapsed))
                .font(.system(size: 32, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .padding(.top, 8)
            .onAppear {
                // Recents: the last clock screen opened.
                model.recents.record(clock: "stopwatch")
            }

            if !model.stopwatch.laps.isEmpty {
                lapList
                    .padding(.horizontal, 16)
            } else {
                Spacer(minLength: 0)
            }

            MenuList(
                items: rows.map { MenuItem(id: $0, title: $0, showsChevron: false) },
                selection: selection
            )
            .padding(.horizontal, 22)
            .padding(.bottom, 8)
        }
        .onWheel { handle($0) }
    }

    /// Lap rows, newest first, height-capped so the readout and actions
    /// stay on screen. Values are cumulative splits (see
    /// StopwatchModel.lap).
    private var lapList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(model.stopwatch.laps.enumerated().reversed()), id: \.offset) { i, lap in
                    HStack {
                        Text("Lap \(i + 1)")
                            .font(Theme.font(12.5, .semibold))
                            .foregroundStyle(Theme.inkDim)
                        Spacer()
                        Text(TimeFormat.stopwatch(lap))
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 1.5)
                }
            }
        }
        .frame(maxHeight: 60)
    }

    /// Wheel routing: ticks move the selection, center activates, MENU pops.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: rows.count, delta: d, settings: settings)
        case .select:
            activateCurrent()
        case .menu:
            model.pop()
        default:
            break
        }
    }

    /// Runs the highlighted action and re-homes the selection.
    private func activateCurrent() {
        let row = rows[min(selection, rows.count - 1)]
        switch row {
        case "Start", "Resume":
            model.stopwatch.start()
        case "Stop":
            model.stopwatch.stop()
        case "Lap":
            model.stopwatch.lap()
        case "Reset":
            model.stopwatch.reset()
        default:
            break
        }
        selection = 0
    }
}

/// Shared move helper without the settings dependency (timer segments wrap).
private func moveListSelectionInt(_ selection: inout Int, count: Int, delta: Int) -> Bool {
    guard count > 0 else { return false }
    let next = selection + delta
    if next >= 0 && next < count {
        selection = next
        WheelFeedback.tick(dir: delta)
        return true
    }
    selection = (next + count) % count
    WheelFeedback.tick(dir: delta)
    return true
}
