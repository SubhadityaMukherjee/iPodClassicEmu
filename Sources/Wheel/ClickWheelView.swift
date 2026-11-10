import SwiftUI

/// The click wheel: touch ring divided into button quadrants (MENU, prev,
/// next, play/pause) and diagonal scroll sectors, with the center button
/// inside. Angle deltas drive scroll ticks; haptics + tick sounds fire per
/// detent. Matches the classic wheel's gesture feel, including converting a
/// button-press into a scroll when the finger rotates away.
struct ClickWheelView: View {
    @Environment(AppModel.self) private var model

    @State private var pressedZone: WheelZone?
    @State private var coordinator = WheelCoordinator()

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

private struct WheelFace: View {
    @EnvironmentObject private var settings: AppSettings

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

    @ViewBuilder
    private func zoneLabel<Content: View>(_ zone: WheelZone, @ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(Theme.wheelLabel(settings.theme))
            .offset(zoneOffset(zone))
    }

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

enum WheelZone: Equatable {
    case menu, prev, next, play, center, scroll
}

/// State machine for one touch on the wheel. Reference type so its timers can
/// fire directly; the view mirrors `pressedZone` for the press highlight.
final class WheelCoordinator {
    var send: ((ControlEvent) -> Void)?
    var onZoneChange: ((WheelZone?) -> Void)?
    private(set) var pressedZone: WheelZone? { didSet { onZoneChange?(pressedZone) } }

    /// Degrees of rotation per detent.
    private let tickDegrees = 15.0
    /// Adaptive scroll: smoothed angular speed (°/s) of the current spin,
    /// and the time of the last move event feeding it.
    private var degreesPerSecond = 0.0
    private var lastMoveAt = Date()

    /// Rows advanced per detent at a given spin speed — the real wheel's
    /// adaptive scrolling: a slow roll steps one row, a fast flick flies.
    /// Kept conservative so a single quick detent-flick stays 1 row.
    /// Direction-agnostic: the sign of `speed` is ignored.
    static func rowsPerDetent(speed: Double) -> Int {
        switch abs(speed) {
        case ..<300: return 1
        case ..<700: return 2
        case ..<1200: return 3
        case ..<2000: return 4
        default: return 6
        }
    }

    private enum Mode {
        case scroll
        case button(WheelZone)
        case center
    }

    private var mode: Mode?
    private var startAngle = 0.0
    private var lastAngle = 0.0
    private var accumulated = 0.0
    private var touchStart = Date()
    private var holdFired = false
    private var convertedToScroll = false
    private var holdTimer: DispatchSourceTimer?
    private var repeatTimer: DispatchSourceTimer?

    // MARK: Touch lifecycle

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

    private func scrolled(to angle: Double, send: (ControlEvent) -> Void) {
        let now = Date()
        let d = angleDelta(from: lastAngle, to: angle)
        lastAngle = angle
        // Smoothed angular speed: instantaneous °/s over the event gap,
        // EMA-weighted so one fast event doesn't jump the multiplier. A
        // long pause (> 0.5 s) means the spin stopped — start fresh.
        let dt = now.timeIntervalSince(lastMoveAt)
        lastMoveAt = now
        if dt >= 0.5 {
            degreesPerSecond = 0
        } else if dt > 0.004 {
            let instant = abs(d) / dt
            degreesPerSecond = degreesPerSecond == 0
                ? instant
                : degreesPerSecond * 0.65 + instant * 0.35
        }
        accumulated += d
        let rows = Self.rowsPerDetent(speed: degreesPerSecond)
        while abs(accumulated) >= tickDegrees {
            let dir: Int = accumulated > 0 ? 1 : -1
            accumulated -= Double(dir) * tickDegrees
            for _ in 0..<rows { send(.tick(dir)) }
        }
    }

    private func angleDelta(from a: Double, to b: Double) -> Double {
        var d = b - a
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    private static func normalize(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return a
    }

    // MARK: Holds

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

    private func cancelHold() {
        holdTimer?.cancel()
        holdTimer = nil
        repeatTimer?.cancel()
        repeatTimer = nil
    }

    private func reset() {
        mode = nil
        holdFired = false
        convertedToScroll = false
        accumulated = 0
        degreesPerSecond = 0
        pressedZone = nil
        cancelHold()
    }

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

    static func rubberBand() {
        let s = AppSettings.shared
        if s.rubberBandTick {
            TickSounds.shared.rubberBand()
            if s.hapticsEnabled { WheelHaptics.shared.rubberBand() }
        }
    }
}
