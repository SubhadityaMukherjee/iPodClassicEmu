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
            WheelFace(pressed: pressedZone)
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
    let pressed: WheelZone?
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
                Circle()
                    .fill(RadialGradient(colors: [Theme.wheelCenter(t), t == 1 ? Color(white: 0.72) : .black], center: .center, startRadius: 0, endRadius: d / 3))
                    .frame(width: d * 0.365, height: d * 0.365)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.06), lineWidth: 0.6)
                            .frame(width: d * 0.365, height: d * 0.365)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    )
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
            .foregroundStyle(pressed == zone ? Theme.wheelLabelLit(settings.theme) : Theme.wheelLabel(settings.theme))
            .animation(.easeOut(duration: 0.08), value: pressed)
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
        let d = angleDelta(from: lastAngle, to: angle)
        lastAngle = angle
        accumulated += d
        while abs(accumulated) >= tickDegrees {
            let dir: Int = accumulated > 0 ? 1 : -1
            accumulated -= Double(dir) * tickDegrees
            send(.tick(dir))
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
    static func tick(dir: Int) {
        let s = AppSettings.shared
        let intensities = [0.0, 0.4, 0.7, 1.0]
        let level = s.hapticsEnabled ? intensities[min(s.scrollingHaptics, 3)] : 0
        WheelHaptics.shared.ensureRunning()
        WheelHaptics.shared.tick(intensity: level)
        if s.tickSounds {
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
