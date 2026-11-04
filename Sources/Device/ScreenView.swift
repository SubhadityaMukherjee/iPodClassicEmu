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
                .font(Theme.barTitle(15.5))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(TimeFormat.clock(now))
                .font(Theme.barClock(13.5))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()

            Spacer(minLength: 10)

            if model.player.isPlaying {
                HStack(spacing: 1.5) {
                    Capsule().frame(width: 2, height: 8)
                    Capsule().frame(width: 2, height: 5)
                }
                .foregroundStyle(Color(red: 0.18, green: 0.38, blue: 0.80))
                .padding(.trailing, 5)
            }

            BatteryIcon(level: model.batteryLevel)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(BrushedMetal())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.barBorder).frame(height: 0.7)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private var title: String { ScreenRouter.title(for: model) }
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
