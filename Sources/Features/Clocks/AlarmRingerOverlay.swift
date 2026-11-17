import SwiftUI

/// Full-screen ringer when the alarm or timer fires in-app: big time, title,
/// Snooze / Stop rows driven by the wheel.
///
/// Hosted as an overlay on the LCD ONLY (see DeviceView) — it never covers
/// the click wheel, so Snooze/Stop stay wheel-reachable while it rings.
/// While it is up, AppModel.handle diverts every ControlEvent to
/// `ringerBus`, so the screen underneath cannot react to input.
struct AlarmRingerOverlay: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    /// What is ringing (alarm or timer) — drives the title and the rows.
    let context: RingerContext

    /// Index of the highlighted action row.
    @State private var selection = 0

    /// Actions offered: alarms get Snooze + Stop, timers only Stop.
    private var rows: [String] {
        switch context.kind {
        case .alarm: return ["Snooze", "Stop"]
        case .timer: return ["Stop"]
        }
    }

    /// The LCD page: title, live clock, wheel-driven action rows.
    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 8) {
                Text(context.title)
                    .font(Theme.barTitle(20))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 12)
                Text(TimeFormat.clock())
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                MenuList(
                    items: rows.map { MenuItem(id: $0, title: $0, showsChevron: false) },
                    selection: selection
                )
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            }
        }
        .zIndex(10)
        .onReceive(model.ringerBus) { handle($0) }
    }

    /// Wheel input, received from `ringerBus`: ticks move the row
    /// selection; center, MENU and play/pause all activate the
    /// highlighted row (any main button answers a ringing alarm).
    ///
    /// Concept: Combine → docs/concepts/combine.md
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: rows.count, delta: d, settings: settings)
        case .select:
            activateCurrent()
        case .menu, .playPause:
            activateCurrent()
        default:
            break
        }
    }

    /// Runs the highlighted row: Snooze schedules the 9-minute re-ring and
    /// dismisses; Stop dismisses (which also re-arms the alarm schedule —
    /// see RingerManager.stop).
    private func activateCurrent() {
        let row = rows[min(selection, rows.count - 1)]
        switch row {
        case "Snooze":
            model.alarms.snooze()
            RingerManager.shared.stop()
        case "Stop":
            RingerManager.shared.stop()
        default:
            break
        }
    }
}
