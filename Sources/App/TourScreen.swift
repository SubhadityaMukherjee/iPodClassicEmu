import SwiftUI

/// First-open feature tour: a few modern, icon-led pages listing the app's
/// major features, shown before the setup wizard. Center (or swipe left)
/// advances, MENU skips, wheel ticks page back/forward.
struct TourScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    private struct Page {
        let symbol: String
        let headline: String
        let body: String
    }

    private let pages: [Page] = [
        Page(symbol: "music.note",
             headline: "The classic, rebuilt",
             body: "Your music with the full click-wheel experience — Cover Flow, playlists, and a glowing Now Playing screen."),
        Page(symbol: "book",
             headline: "Read anything",
             body: "EPUBs and PDFs paginated like paper, articles saved from any app via the share sheet, highlights that stick."),
        Page(symbol: "mic",
             headline: "Memos that transcribe",
             body: "Voice memos turn into text entirely on-device. Private by design — nothing leaves your phone."),
        Page(symbol: "photo.on.rectangle.angled",
             headline: "Photos, camera, notes",
             body: "A gallery in your pocket, a camera with wheel zoom, and notes that sync to the Files app."),
        Page(symbol: "alarm",
             headline: "Clocks that ring",
             body: "Alarms fire even when the app is closed, with timers, a stopwatch, and a sleep dimmer."),
        Page(symbol: "hand.point.up.left.fill",
             headline: "Wheel tips",
             body: "Spin to scroll — flick for speed. Hold center for row options, MENU goes back, hold MENU for home."),
    ]

    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Swipe between pages like a modern onboarding deck.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 24)
                            .onEnded { value in
                                if value.translation.width < -30 { next() }
                                else if value.translation.width > 30 { back() }
                            }
                    )
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: pages[page].symbol)
                        .font(.system(size: 52, weight: .ultraLight))
                        .foregroundStyle(Theme.ink)
                        .frame(height: 64)
                    Text(pages[page].headline)
                        .font(Theme.font(20, .semibold))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                    Text(pages[page].body)
                        .font(Theme.font(13, .regular))
                        .foregroundStyle(Theme.inkDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 26)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
            .frame(maxHeight: .infinity)

            // Page dots
            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Theme.ink : Theme.inkDim.opacity(0.35))
                        .frame(width: i == page ? 18 : 7, height: 7)
                        .animation(.easeOut(duration: 0.18), value: page)
                }
            }
            .padding(.bottom, 10)

            Text(page == pages.count - 1 ? "Center: get started · MENU: skip" : "Center: next · MENU: skip tour")
                .font(Theme.font(11, .regular))
                .foregroundStyle(Theme.inkDim)
                .padding(.bottom, 10)
        }
        .padding(.top, 12)
        .onWheel { handle($0) }
    }

    // MARK: Navigation

    private func next() {
        if page < pages.count - 1 {
            withAnimation(.easeOut(duration: 0.2)) { page += 1 }
            WheelFeedback.tick(dir: 1)
        } else {
            finish()
        }
    }

    private func back() {
        guard page > 0 else { return }
        withAnimation(.easeOut(duration: 0.2)) { page -= 1 }
        WheelFeedback.tick(dir: -1)
    }

    private func finish() {
        WheelHaptics.shared.ensureRunning()
        WheelHaptics.shared.buttonPress(strength: 0.8)
        model.completeTour()
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            d > 0 ? next() : back()
        case .select:
            next() // advances page by page; on the last page this finishes
        case .menu:
            model.completeTour() // skip the whole tour
        default:
            break
        }
    }
}
