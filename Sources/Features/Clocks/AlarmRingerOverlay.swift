import SwiftUI

/// Full-screen ringer when the alarm or timer fires in-app: big time, title,
/// Snooze / Stop rows driven by the wheel.
struct AlarmRingerOverlay: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    let context: RingerContext

    @State private var selection = 0

    private var rows: [String] {
        switch context.kind {
        case .alarm: return ["Snooze", "Stop"]
        case .timer: return ["Stop"]
        }
    }

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
