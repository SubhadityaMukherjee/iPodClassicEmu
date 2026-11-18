import SwiftUI

/// Analog clock face: numerals, minute ticks, blue hands. Shows the live
/// time supplied by the parent (AppModel's clockTick heartbeat).
struct ClockFace: View {
    /// The instant to render (second hand included). The parent's
    /// re-render supplies fresh Dates — there is no internal clock.
    var date: Date = Date()
    /// Color of the second hand and center dot (matches the host page's
    /// accent so the clock blends into each screen).
    var accent: Color = Color(red: 0.22, green: 0.42, blue: 0.85)
    /// Whether the 1–12 numerals are drawn (the minute ticks always are).
    var showNumerals = true

    /// Draws the whole face in one Canvas pass: rim, 60 minute ticks,
    /// numerals, hands, center dot.
    ///
    /// Concept: SwiftUI views & state → docs/concepts/swiftui-views-and-state.md
    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 2

            // Face
            let face = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            ctx.stroke(face, with: .color(.black.opacity(0.55)), lineWidth: 1.2)

            let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
            let comps = (c.hour ?? 0, c.minute ?? 0, c.second ?? 0)

            // Minute ticks + numerals
            for i in 0..<60 {
                let angle = Double(i) / 60 * 2 * .pi
                let isMajor = i % 5 == 0
                let inner = radius * (isMajor ? 0.86 : 0.93)
                let outer = radius * 0.97
                var tick = Path()
                tick.move(to: CGPoint(
                    x: center.x + cos(angle) * inner,
                    y: center.y + sin(angle) * inner
                ))
                tick.addLine(to: CGPoint(
                    x: center.x + cos(angle) * outer,
                    y: center.y + sin(angle) * outer
                ))
                ctx.stroke(tick, with: .color(.black.opacity(isMajor ? 0.75 : 0.35)), lineWidth: isMajor ? 1.3 : 0.6)

                if showNumerals && isMajor {
                    let hourNum = i == 0 ? 12 : i / 5
                    let textPos = CGPoint(
                        x: center.x + cos(angle) * radius * 0.74,
                        y: center.y + sin(angle) * radius * 0.74
                    )
                    let label = Text("\(hourNum)")
                        .font(.system(size: radius * 0.16, weight: .medium))
                        .foregroundColor(.black.opacity(0.85))
                    ctx.draw(
                        ctx.resolve(label),
                        at: textPos
                    )
                }
            }

            /// Draws one hand: a rounded stroke from the center at
            /// `angleDegrees` (0 = 12 o'clock, clockwise).
            func hand(angleDegrees: Double, length: CGFloat, width: CGFloat, color: Color) {
                let rad = (angleDegrees - 90) / 180 * .pi
                var p = Path()
                p.move(to: center)
                p.addLine(to: CGPoint(
                    x: center.x + cos(rad) * length,
                    y: center.y + sin(rad) * length
                ))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }

            // Hour & minute (black), second hand (blue) when live.
            let hourAngle = Double(comps.0 % 12) / 12 * 360 + Double(comps.1) / 60 * 30
            let minuteAngle = Double(comps.1) / 60 * 360
            hand(angleDegrees: hourAngle, length: radius * 0.5, width: 2.6, color: .black)
            hand(angleDegrees: minuteAngle, length: radius * 0.74, width: 2.0, color: .black)

            let secondAngle = Double(comps.2) / 60 * 360
            hand(angleDegrees: secondAngle, length: radius * 0.82, width: 1.1, color: accent)

            // Center dot
            let dot = Path(ellipseIn: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
            ctx.fill(dot, with: .color(accent))
        }
    }
}
