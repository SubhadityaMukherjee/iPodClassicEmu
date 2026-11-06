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
                Theme.body(settings.theme).ignoresSafeArea()

                VStack(spacing: 0) {
                    HoldSwitchView()
                        .frame(width: w * 0.955, height: 24)
                        .padding(.top, h * 0.016)

                    ScreenView()
                        .frame(width: w * 0.955, height: w * 0.955 * 0.75)
                        .overlay {
                            // Hold: LCD fades out, playing art centered.
                            if model.holdActive {
                                HoldScreenOverlay()
                                    .transition(.opacity)
                            }
                            // Ringer confined to the LCD — the click wheel
                            // stays visible and drives Snooze/Stop.
                            if let ringer = model.ringer {
                                AlarmRingerOverlay(context: ringer)
                                    .transition(.opacity)
                            }
                        }
                        // Subtle inset: soft shadow + dark bevel so the LCD
                        // reads as recessed into the body.
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.black.opacity(0.55), lineWidth: 1.2)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .shadow(color: .black.opacity(0.35), radius: 5, x: 0, y: 1)
                        .padding(.top, 2)

                    Spacer(minLength: 0)

                    ClickWheelView()
                        .frame(width: w * 0.66, height: w * 0.66)
                        // Faint ambient shadow so the wheel reads as seated
                        // inside the body.
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.45))
                                .blur(radius: 9)
                                .offset(y: 2)
                                .padding(-4)
                        )

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
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            heartbeat = Date()
        }
        .onReceive(model.controlBus.map { _ in () }) { _ in
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

/// Hold screen: display fades to near-black with the playing album art as a
/// big centered square (or a lock when nothing is playing).
struct HoldScreenOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.88)
                if let aw = model.player.currentSong?.artwork {
                    ArtworkView(artwork: aw, width: 500, height: 500)
                        .frame(width: geo.size.height * 0.66, height: geo.size.height * 0.66)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        // Keep the art as dim as the rest of the hold screen.
                        .overlay(Color.black.opacity(0.72))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.6), lineWidth: 1))
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 58))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Small padlock switch at the top of the body (the Hold switch).
struct HoldSwitchView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let silver = settings.theme == 1
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
                                colors: silver
                                    ? [Color(white: 0.66), Color(white: 0.52)]
                                    : [Color(red: 0.30, green: 0.30, blue: 0.31),
                                       Color(red: 0.16, green: 0.16, blue: 0.17)],
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
                        .foregroundStyle(silver ? Color(white: 0.15) : Color(white: 0.72))
                        .frame(maxWidth: .infinity, alignment: model.holdActive ? .trailing : .leading)
                        .padding(.horizontal, 4)
                }
                .frame(width: 44, height: 18)
            }
            .buttonStyle(.plain)
        }
    }
}
