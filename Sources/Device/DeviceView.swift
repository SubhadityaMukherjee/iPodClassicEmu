import SwiftUI
import MediaPlayer

/// The whole device: black body, LCD screen block, hold switch, click wheel.
struct DeviceView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var heartbeat = Date()
    @State private var booted = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Theme.bodyColor.ignoresSafeArea()

                VStack(spacing: 0) {
                    HoldSwitchView()
                        .frame(width: w * 0.955, height: 24)
                        .padding(.top, h * 0.016)

                    ScreenView()
                        .frame(width: w * 0.955, height: w * 0.955 * 0.75)
                        .overlay {
                            // Boot splash: the white screen with the iPod
                            // wordmark, like turning on the real thing.
                            if !booted {
                                BootSplash()
                                    .transition(.opacity)
                            }
                        }
                        .padding(.top, 2)

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
        .task {
            // Brief authentic boot, skippable by any wheel input.
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeIn(duration: 0.35)) { booted = true }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            heartbeat = Date()
        }
        .onReceive(model.controlBus.map { _ in () }) { _ in
            if !booted {
                withAnimation(.easeIn(duration: 0.25)) { booted = true }
            }
            // Input ends the dim immediately rather than waiting for the heartbeat.
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

/// Startup screen: white backlight, black "iPod" wordmark — like powering
/// on the original.
struct BootSplash: View {
    var body: some View {
        ZStack {
            Color(white: 0.96)
            Text("iPod")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.12))
        }
        .contentShape(Rectangle())
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
