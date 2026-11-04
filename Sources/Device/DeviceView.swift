import SwiftUI
import MediaPlayer

/// The whole device: black body, LCD screen block, hold switch, click wheel.
struct DeviceView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var heartbeat = Date()

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Theme.bodyColor.ignoresSafeArea()

                VStack(spacing: 0) {
                    HoldSwitchView()
                        .frame(width: w * 0.915, height: 24)
                        .padding(.top, h * 0.018)

                    ScreenView()
                        .frame(width: w * 0.915, height: w * 0.915 * 0.75)
                        .padding(.top, 3)

                    Spacer(minLength: 0)

                    ClickWheelView()
                        .frame(width: w * 0.66, height: w * 0.66)

                    Spacer(minLength: 0)
                        .frame(height: h * 0.045)
                }
            }
        }
        .overlay(alignment: .top) {
            if isDimmed { dimOverlay }
        }
        .overlay {
            if model.screenAsleep { sleepOverlay }
        }
        .overlay {
            if let ringer = model.ringer {
                AlarmRingerOverlay(context: ringer)
            }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            heartbeat = Date()
        }
    }

    private var isDimmed: Bool {
        let after = TimeInterval(settings.dimAfterSeconds)
        guard after > 0 else { return false }
        return model.idleSeconds > after && model.ringer == nil
    }

    private var dimOverlay: some View {
        Color.black.opacity(0.62)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { model.markActivity() }
            .transition(.opacity)
            .animation(.easeIn(duration: 0.3), value: isDimmed)
    }

    private var sleepOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeIn(duration: 0.15)) { model.screenAsleep = false }
            }
    }
}

/// Small padlock switch at the top of the body (the Hold switch).
struct HoldSwitchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Spacer()
            Button {
                model.holdActive.toggle()
                WheelHaptics.shared.ensureRunning()
                WheelHaptics.shared.buttonPress(strength: 0.6)
            } label: {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.30, green: 0.30, blue: 0.31),
                                    Color(red: 0.16, green: 0.16, blue: 0.17),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.8))
                    if model.holdActive {
                        Capsule()
                            .fill(Color(red: 1.0, green: 0.55, blue: 0.10).opacity(0.85))
                            .frame(width: 26, height: 14)
                            .offset(x: 3)
                            .animation(.easeOut(duration: 0.12), value: model.holdActive)
                    }
                    Image(systemName: model.holdActive ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(white: 0.72))
                        .frame(maxWidth: .infinity, alignment: model.holdActive ? .trailing : .leading)
                        .padding(.horizontal, 4)
                }
                .frame(width: 44, height: 18)
            }
            .buttonStyle(.plain)
        }
    }
}
