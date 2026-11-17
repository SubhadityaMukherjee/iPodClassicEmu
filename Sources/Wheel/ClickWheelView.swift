import SwiftUI

/// The click wheel: touch ring divided into button quadrants (MENU, prev,
/// next, play/pause) and diagonal scroll sectors, with the center button
/// inside. Angle deltas drive scroll ticks; haptics + tick sounds fire per
/// detent. Matches the classic wheel's gesture feel, including converting a
/// button-press into a scroll when the finger rotates away.
///
/// Concept: SwiftUI views and state → docs/concepts/swiftui-views-and-state.md
struct ClickWheelView: View {
    @Environment(AppModel.self) private var model

    /// Mirror of the coordinator's active zone, updated via
    /// `onZoneChange`. Currently write-only — the shipped face draws
    /// no press highlight — but kept as the hookup for one.
    @State private var pressedZone: WheelZone?
    /// One long-lived coordinator per view identity. `@State` on a
    /// reference type keeps the same instance across re-renders
    /// (SwiftUI recreates the struct, not its stored objects), so
    /// touch state and timers survive.
    @State private var coordinator = WheelCoordinator()

    /// Renders the square wheel face fitted to the available space,
    /// attaches a zero-distance drag gesture (every touch, not just
    /// movement), and on first appearance wires the coordinator's
    /// outputs to `AppModel` and `pressedZone`.
    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            WheelFace()
                .frame(width: d, height: d)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            coordinator.touchChanged(value, center: center, radius: d / 2)
                        }
                        .onEnded { value in
                            coordinator.touchEnded(value, center: center, radius: d / 2)
                        }
                )
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            coordinator.send = { model.handle($0) }
            coordinator.onZoneChange = { pressedZone = $0 }
        }
        .accessibilityElement()
        .accessibilityIdentifier("clickwheel")
    }
}

// MARK: - Wheel face drawing

/// Pure drawing of the wheel — no gesture handling. Layers the face
/// gradient, a recessed inset rim, the center button, the diagonal
/// seams that mark the four button sectors, and the four button
/// labels, all recolored for the user's theme (silver or black iPod).
private struct WheelFace: View {
    @EnvironmentObject private var settings: AppSettings

    /// Composes the face circle with its rim gradients, then the
    /// center button, sector seams, and zone labels on top.
    var body: some View {
        let t = settings.theme
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.wheelEdge(t), Theme.wheelFace(t), Theme.wheelFace(t), Theme.wheelEdge(t).opacity(0.9)],
                        center: .center, startRadius: 0, endRadius: 500
                    )
                )
                .overlay(Circle().stroke(Color.white.opacity(0.05), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 3)
                // Subtle inset rim, echoing the recessed LCD: a dark edge
                // ring, strongest at the top, seated just inside the rim.
                .overlay(
                    ZStack {
                        LinearGradient(colors: [.black.opacity(0.28), .clear],
                                       startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.32))
                        LinearGradient(colors: [.black.opacity(0.16), .clear],
                                       startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.9))
                        LinearGradient(colors: [.black.opacity(0.11), .clear],
                                       startPoint: .leading, endPoint: UnitPoint(x: 0.08, y: 0.5))
                        LinearGradient(colors: [.black.opacity(0.11), .clear],
                                       startPoint: .trailing, endPoint: UnitPoint(x: 0.92, y: 0.5))
                    }
                    .mask(Circle().strokeBorder(lineWidth: 9))
                    .allowsHitTesting(false)
                )

            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                Circle()
                    .fill(RadialGradient(colors: [Theme.wheelCenter(t), t == 1 ? Color(white: 0.72) : .black], center: .center, startRadius: 0, endRadius: d / 3))
                    .frame(width: d * 0.365, height: d * 0.365)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.06), lineWidth: 0.6)
                            .frame(width: d * 0.365, height: d * 0.365)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    )
                // Button seams: thin dark-grey radial lines along the
                // diagonals marking the four button sectors — a touch
                // darker than the wheel face, not black.
                Path { p in
                    for angle in [45.0, 135.0, 225.0, 315.0] {
                        let rad = angle * .pi / 180
                        let r0 = d * 0.205, r1 = d * 0.462
                        p.move(to: CGPoint(x: c.x + r0 * sin(rad), y: c.y - r0 * cos(rad)))
                        p.addLine(to: CGPoint(x: c.x + r1 * sin(rad), y: c.y - r1 * cos(rad)))
                    }
                }
                .stroke(Color.black.opacity(0.30), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }

            zoneLabel(.menu) {
                Text("MENU")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .tracking(2)
            }
            zoneLabel(.prev) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 19, weight: .bold))
            }
            zoneLabel(.next) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 19, weight: .bold))
            }
            zoneLabel(.play) {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                    Image(systemName: "pause.fill")
                        .font(.system(size: 15, weight: .bold))
                }
            }
        }
    }

    /// Styles a label with the theme's label color and offsets it to
    /// its zone's compass position.
    ///
    /// - Parameters:
    ///   - zone: the button whose label this is; selects the offset.
    ///   - content: the label content (text or SF Symbol images).
    ///
    /// Concept: Swift protocols and generics → docs/concepts/swift-protocols-and-generics.md
    @ViewBuilder
    private func zoneLabel<Content: View>(_ zone: WheelZone, @ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(Theme.wheelLabel(settings.theme))
            .offset(zoneOffset(zone))
    }

    /// Fixed point-offsets placing each label at its compass spot
    /// (MENU top, prev left, next right, play bottom); center/scroll
    /// have no label.
    private func zoneOffset(_ zone: WheelZone) -> CGSize {
        switch zone {
        case .menu: return CGSize(width: 0, height: -96)
        case .play: return CGSize(width: 0, height: 96)
        case .prev: return CGSize(width: -96, height: 0)
        case .next: return CGSize(width: 96, height: 0)
        case .center, .scroll: return .zero
        }
    }
}

// MARK: - Zones

/// The regions of the wheel face: four compass-point button
/// quadrants, the center button, and the diagonal scroll sectors
/// between the buttons.
enum WheelZone: Equatable {
    case menu, prev, next, play, center, scroll
}

/// State machine for one touch on the wheel. Reference type so its timers can
/// fire directly; the view mirrors `pressedZone` for the press highlight.
///
/// Concept: Swift value and reference types → docs/concepts/swift-value-and-reference-types.md
final class WheelCoordinator {
    /// Forwards control events to `AppModel.handle`. Wired in the
    /// view's `onAppear`; nil until then, and every touch handler
    /// guards on it.
    var send: ((ControlEvent) -> Void)?
    /// Notifies the view of zone changes so it can mirror
    /// `pressedZone`.
    var onZoneChange: ((WheelZone?) -> Void)?
    /// Zone under the current touch (nil between touches); changes
    /// fan out through `onZoneChange`.
    private(set) var pressedZone: WheelZone? { didSet { onZoneChange?(pressedZone) } }

    /// Degrees of rotation per detent.
    private let tickDegrees = 15.0
    /// Adaptive scroll: smoothed angular speed (°/s) of the current spin,
    /// and the time of the last move event feeding it.
    private var degreesPerSecond = 0.0
    /// Timestamp of the last move event; feeds the speed estimate
    /// and the 0.35 s spin-stopped reset.
    private var lastMoveAt = Date()

    /// Rows advanced per detent at a given spin speed — the real wheel's
    /// adaptive scrolling: a slow roll steps one row, a fast flick flies.
    /// Kept conservative so a single quick detent-flick stays 1 row.
    /// Direction-agnostic: the sign of `speed` is ignored.
    static func rowsPerDetent(speed: Double) -> Int {
        switch abs(speed) {
        case ..<300: return 1
        case ..<900: return 2
        case ..<1800: return 3
        case ..<3000: return 4
        default: return 6
        }
    }

    /// What the touch is currently doing — chosen on the first move,
    /// it decides how later moves and the lift are interpreted.
    private enum Mode {
        case scroll
        case button(WheelZone)
        case center
    }

    /// Current mode; nil while no touch is active.
    private var mode: Mode?
    /// Angle where the touch began; rotating > 28° away from a
    /// button zone converts the press into a scroll.
    private var startAngle = 0.0
    /// Angle of the previous move; scroll rotation is measured from
    /// it.
    private var lastAngle = 0.0
    /// Degrees rotated since the last emitted detent; each 15°
    /// crossing fires ticks.
    private var accumulated = 0.0
    /// When the touch began, for the < 0.45 s tap-vs-hold test.
    /// Always a wall-clock `Date()` — see the NOTE in
    /// `touchChanged(_:center:radius:)`.
    private var touchStart = Date()
    /// Whether the 0.55 s hold already fired (its lift sends
    /// `.holdEnded` instead of a tap).
    private var holdFired = false
    /// A button press turned into a scroll mid-gesture, so the lift
    /// must not emit a tap.
    private var convertedToScroll = false
    /// One-shot 0.55 s timer that fires a hold event.
    private var holdTimer: DispatchSourceTimer?
    /// 0.18 s repeating timer for hold-repeat events (prev/next
    /// skipping).
    private var repeatTimer: DispatchSourceTimer?

    // MARK: Touch lifecycle

    /// Feeds one drag-move event into the state machine.
    ///
    /// The touch point is converted to polar coordinates around the
    /// wheel center: `atan2(dy, dx)` in degrees, where 0° is east
    /// and angles grow clockwise (screen Y points down, so
    /// increasing atan2 is clockwise on screen). The first move
    /// classifies the touch; afterwards a scroll accumulates
    /// rotation, and a finger rotating > 28° off a button converts
    /// that press into a scroll — the real wheel's thumb-slide.
    ///
    /// - Parameters:
    ///   - value: drag update; only `value.location` is used (never
    ///     `value.time` — see the NOTE inline).
    ///   - center: wheel center in view coordinates.
    ///   - radius: wheel radius in points.
    func touchChanged(_ value: DragGesture.Value, center: CGPoint, radius: CGFloat) {
        guard let send else { return }
        let point = value.location
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        let r = sqrt(dx * dx + dy * dy)
        let angle = atan2(dy, dx) * 180 / .pi  // 0° = east, positive clockwise

        guard mode != nil else {
            // NOTE: never use value.time here — it is not a wall-clock Date on
            // all platforms (huge offsets), which broke every tap. Date() only.
            beginTouch(angle: angle, r: r, radius: radius, at: Date())
            return
        }

        switch mode {
        case nil:
            break
        case .scroll:
            scrolled(to: angle, send: send)
        case .button:
            if abs(angleDelta(from: startAngle, to: angle)) > 28 {
                // Finger rotated away from the button: becomes a scroll.
                convertedToScroll = true
                cancelHold()
                mode = .scroll
                pressedZone = .scroll
                startAngle = angle
                lastAngle = angle
                accumulated = 0
                degreesPerSecond = 0
                lastMoveAt = Date()
            }
        case .center:
            break
        }
    }

    /// Classifies the lift and emits the matching event. A tap —
    /// under 0.45 s, hold never fired, no press-to-scroll conversion
    /// — fires the zone's button event; lifting after a hold sends
    /// `.holdEnded`; a scroll lift sends nothing (ticks already fired
    /// per detent).
    ///
    /// - Parameters:
    ///   - value: unused — the signature mirrors `touchChanged` for
    ///     uniform call sites.
    ///   - center: unused (see `value`).
    ///   - radius: unused (see `value`).
    func touchEnded(_ value: DragGesture.Value, center: CGPoint, radius: CGFloat) {
        guard let send else { return }
        let duration = Date().timeIntervalSince(touchStart)
        cancelHold()

        let tap = !holdFired && !convertedToScroll && duration < 0.45
        switch mode {
        case .center where tap:
            buttonHaptic()
            send(.select)
        case .button(.menu) where tap:
            buttonHaptic()
            send(.menu)
        case .button(.play) where tap:
            buttonHaptic()
            send(.playPause)
        case .button(.prev) where tap:
            buttonHaptic()
            send(.prev)
        case .button(.next) where tap:
            buttonHaptic()
            send(.next)
        case .button where holdFired:
            send(.holdEnded)
        default:
            break
        }

        reset()
    }

    // MARK: Begin

    /// Classifies where the touch landed and arms hold timers for
    /// buttons: inside the center circle (36.5% of the wheel radius)
    /// → center mode; on a button arc → that button (prev/next holds
    /// repeat, menu/play don't); otherwise a diagonal scroll sector.
    /// Speed starts at zero — every touch begins as a slow roll and
    /// speeds up as it spins.
    ///
    /// - Parameters:
    ///   - angle: touch angle in degrees (0° = east, clockwise
    ///     positive).
    ///   - r: touch distance from the wheel center.
    ///   - radius: wheel radius in points.
    ///   - time: wall-clock `Date()` of the touch start.
    private func beginTouch(angle: Double, r: Double, radius: CGFloat, at time: Date) {
        touchStart = time
        accumulated = 0
        startAngle = angle
        lastAngle = angle
        // Every new touch starts a slow roll; speed builds as it spins.
        degreesPerSecond = 0
        lastMoveAt = time
        holdFired = false
        convertedToScroll = false

        let centerR = Double(radius) * 0.365
        if r <= centerR {
            mode = .center
            pressedZone = .center
            scheduleHold(fires: .centerHold, repeating: nil)
            return
        }

        if let zone = Self.quadrantZone(angle) {
            mode = .button(zone)
            pressedZone = zone
            switch zone {
            case .prev:
                scheduleHold(fires: .prevHold, repeating: .prevHold)
            case .next:
                scheduleHold(fires: .nextHold, repeating: .nextHold)
            case .menu:
                scheduleHold(fires: .menuHold, repeating: nil)
            case .play:
                scheduleHold(fires: .playHold, repeating: nil)
            case .center, .scroll:
                break
            }
        } else {
            mode = .scroll
            pressedZone = .scroll
        }
    }

    /// Button arcs: ±32° around each label (N/E/S/W), like the real wheel's
    /// narrow button zones. The diagonal sectors between them are scroll
    /// areas. Angle: 0° = east, positive clockwise.
    static func quadrantZone(_ angle: Double) -> WheelZone? {
        let a = normalize(angle)
        switch a {
        case 328..<360, 0..<32: return .next
        case 58..<122: return .play
        case 148..<212: return .prev
        case 238..<302: return .menu
        default: return nil  // diagonal scroll sector
        }
    }

    // MARK: Scroll

    /// Accumulates rotation since the last move and emits detent
    /// ticks.
    ///
    /// Angular speed is smoothed with an EMA so a single fast event
    /// can't jump the row multiplier, but deceleration sheds speed
    /// quickly (the down-side averages toward the lower instantaneous
    /// value) — a slow ramp-down made every flick overshoot its
    /// target. A gap > 0.35 s means the spin stopped, so speed
    /// resets. Every 15° of accumulated rotation emits
    /// `rowsPerDetent(speed:)` ticks in the rotated direction: fast
    /// spins advance several rows per detent.
    ///
    /// - Parameters:
    ///   - angle: current touch angle in degrees.
    ///   - send: event sink, already unwrapped by the caller.
    private func scrolled(to angle: Double, send: (ControlEvent) -> Void) {
        let now = Date()
        let d = angleDelta(from: lastAngle, to: angle)
        lastAngle = angle
        // Smoothed angular speed: instantaneous °/s over the event gap,
        // EMA-weighted so one fast event doesn't jump the multiplier. A
        // short pause (> 0.35 s) means the spin stopped — start fresh.
        // While decelerating, shed speed quickly toward the instantaneous
        // value: a slow ramp-down made every flick overshoot its target.
        let dt = now.timeIntervalSince(lastMoveAt)
        lastMoveAt = now
        if dt >= 0.35 {
            degreesPerSecond = 0
        } else if dt > 0.004 {
            let instant = abs(d) / dt
            if instant < degreesPerSecond {
                degreesPerSecond = (degreesPerSecond + instant) / 2
            } else {
                degreesPerSecond = degreesPerSecond == 0
                    ? instant
                    : degreesPerSecond * 0.65 + instant * 0.35
            }
        }
        accumulated += d
        let rows = Self.rowsPerDetent(speed: degreesPerSecond)
        while abs(accumulated) >= tickDegrees {
            let dir: Int = accumulated > 0 ? 1 : -1
            accumulated -= Double(dir) * tickDegrees
            for _ in 0..<rows { send(.tick(dir)) }
        }
    }

    /// Shortest signed rotation from `a` to `b`, wrapped into
    /// (-180, 180] so dragging across the atan2 seam at ±180° reads
    /// as a small step, not a full-circle jump.
    ///
    /// - Parameters:
    ///   - a: starting angle in degrees.
    ///   - b: ending angle in degrees.
    /// - Returns: signed degrees to rotate from `a` to `b`.
    private func angleDelta(from a: Double, to b: Double) -> Double {
        var d = b - a
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    /// Wraps any angle — possibly negative or over 360 — into 0..<360
    /// for button-sector classification.
    ///
    /// - Parameter angle: angle in degrees.
    /// - Returns: the equivalent angle in [0, 360).
    private static func normalize(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return a
    }

    // MARK: Holds

    /// Arms the 0.55 s one-shot hold timer. When it fires, the hold
    /// event is sent once and, if `repeated` is set, a 0.18 s
    /// repeating timer re-sends it — how held prev/next keep
    /// skipping. DispatchSourceTimers on the main queue are cheap
    /// one-shots whose handlers can mutate this reference-type
    /// coordinator directly.
    ///
    /// - Parameters:
    ///   - fires: event sent when the hold threshold passes.
    ///   - repeated: event re-sent every 0.18 s afterwards, or nil
    ///     for a single-shot hold.
    ///
    /// Concept: GCD Dispatch Sources → docs/concepts/dispatch-queues.md
    private func scheduleHold(fires: ControlEvent, repeating repeated: ControlEvent?) {
        cancelHold()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.55)
        timer.setEventHandler { [weak self] in
            guard let self, let send = self.send else { return }
            self.holdFired = true
            buttonHaptic()
            send(fires)
            if let repeated {
                let rep = DispatchSource.makeTimerSource(queue: .main)
                rep.schedule(deadline: .now() + 0.18, repeating: 0.18)
                rep.setEventHandler { [weak self] in
                    guard let self, let send = self.send else { return }
                    send(repeated)
                }
                rep.resume()
                self.repeatTimer?.cancel()
                self.repeatTimer = rep
            }
        }
        timer.resume()
        holdTimer = timer
    }

    /// Cancels the hold and repeat timers (on lift, conversion, or
    /// reset).
    private func cancelHold() {
        holdTimer?.cancel()
        holdTimer = nil
        repeatTimer?.cancel()
        repeatTimer = nil
    }

    /// Clears all per-touch state so the next touch starts clean.
    private func reset() {
        mode = nil
        holdFired = false
        convertedToScroll = false
        accumulated = 0
        degreesPerSecond = 0
        pressedZone = nil
        cancelHold()
    }

    /// Button-press haptic scaled by the Button Haptics setting
    /// (0…2 mapped to 0…1). `ensureRunning` first — the system may
    /// have stopped the engine since the last interaction.
    private func buttonHaptic() {
        WheelHaptics.shared.ensureRunning()
        WheelHaptics.shared.buttonPress(strength: Double(AppSettings.shared.buttonHaptics) / 2.0)
    }
}

/// Shared feed for scroll ticks so any screen can react, and so the wheel
/// itself can trigger per-detent haptics/sounds honoring the settings.
enum WheelFeedback {
    /// Minimum gap between haptic/sound pulses. Adaptive scrolling emits
    /// several ticks per detent on a fast spin (up to hundreds/s); without
    /// a ceiling the haptic engine saturates and the purr becomes mush.
    /// Slow rolls (~13 ticks/s) never reach this.
    private static var lastPulseAt = Date.distantPast
    private static let minPulseGap = 0.02

    /// Emits the per-detent haptic + tick sound, honoring the
    /// haptics/tick-sound settings. Every scroll consumer (list
    /// movement, text scrolling) calls this so feedback stays
    /// consistent app-wide. Pulses denser than `minPulseGap` —
    /// adaptive spins emit several ticks per detent — are suppressed
    /// so the haptic engine isn't saturated.
    ///
    /// - Parameter dir: scroll direction (+1 or -1); the pulse itself
    ///   is direction-independent — both directions tick alike.
    static func tick(dir: Int) {
        let s = AppSettings.shared
        let now = Date()
        let dense = now.timeIntervalSince(lastPulseAt) < minPulseGap
        lastPulseAt = now
        let intensities = [0.0, 0.4, 0.7, 1.0]
        let level = s.hapticsEnabled && !dense ? intensities[min(s.scrollingHaptics, 3)] : 0
        WheelHaptics.shared.ensureRunning()
        WheelHaptics.shared.tick(intensity: level)
        if s.tickSounds && !dense {
            TickSounds.shared.tick(soft: s.softTick)
        }
    }

    /// Edge-bounce feedback: rubber-band sound + warning haptic,
    /// only when the Rubber Band Tick setting is on. Never dense, so
    /// it isn't throttled.
    static func rubberBand() {
        let s = AppSettings.shared
        if s.rubberBandTick {
            TickSounds.shared.rubberBand()
            if s.hapticsEnabled { WheelHaptics.shared.rubberBand() }
        }
    }
}
