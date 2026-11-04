import SwiftUI

/// The LCD screen: title bar on top, routed content below, CRT effect over
/// everything, all inside a thin dark bezel.
struct ScreenView: View {
    var body: some View {
        VStack(spacing: 0) {
            TitleBarView()
            ScreenRouter()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PaperBackground())
        // The LCD is always light — force it so system text (TextEditor,
        // .primary labels in panels) can never render white-on-white.
        .environment(\.colorScheme, .light)
        .overlay(CRTOverlay())
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.black.opacity(0.85), lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

/// Title bar: screen title, clock, battery (and a tiny play glyph while
/// music is playing) — brushed metal like the original.
struct TitleBarView: View {
    @Environment(AppModel.self) private var model
    @State private var now = Date()

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(Theme.barTitle(16.5))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.holdActive {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color(red: 0.55, green: 0.30, blue: 0.10))
                    .padding(.trailing, 6)
            }

            Text(TimeFormat.clock(now))
                .font(Theme.barClock(14))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()

            Spacer(minLength: 10)

            playGlyph

            BatteryIcon(level: model.batteryLevel)
        }
        .padding(.horizontal, 7)
        .frame(height: 23)
        .background(BrushedMetal())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.barBorder).frame(height: 0.7)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    /// Classic status glyphs: ▶ while playing, ❙❙ when paused mid-song.
    @ViewBuilder
    private var playGlyph: some View {
        if model.player.isPlaying {
            PlayTriangle()
                .foregroundStyle(Color(red: 0.18, green: 0.38, blue: 0.80))
                .padding(.trailing, 5)
        } else if model.player.currentSong != nil {
            HStack(spacing: 1.5) {
                Capsule().frame(width: 2.5, height: 9)
                Capsule().frame(width: 2.5, height: 9)
            }
            .foregroundStyle(Color(red: 0.18, green: 0.38, blue: 0.80))
            .padding(.trailing, 5)
        }
    }

    private var title: String { ScreenRouter.title(for: model) }
}

/// Equilateral play triangle for the title bar.
struct PlayTriangle: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
            ctx.fill(path, with: .color(Theme.ink))
        }
        .frame(width: 9, height: 10)
    }
}

/// Blue-fill battery, classic style.
struct BatteryIcon: View {
    let level: Double  // 0…1; < 0 = unknown

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .stroke(Color(white: 0.25), lineWidth: 1)
                .frame(width: 22, height: 10)
            Capsule()
                .fill(Color(white: 0.35))
                .frame(width: 2.5, height: 5)
                .offset(x: 22)
            Group {
                if level >= 0 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(level <= 0.2 ? Color(red: 0.9, green: 0.25, blue: 0.2) : Color(red: 0.30, green: 0.62, blue: 0.24))
                        .frame(width: max(1.5, 20 * level), height: 8)
                }
            }
            .padding(.leading, 1)
        }
    }
}
