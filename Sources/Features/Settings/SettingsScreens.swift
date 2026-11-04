import SwiftUI
import MusicKit

/// Settings root: Apple Music status, Clickwheel, Display, Playback, About.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0

    private var appleMusicDetail: String {
        switch model.music.status {
        case .authorized: return "(Connected)"
        case .notDetermined: return "(Not Set)"
        default: return "(Denied)"
        }
    }

    private var items: [MenuItem] {
        [
            MenuItem(id: "music", title: "Apple Music", detail: appleMusicDetail, showsChevron: false),
            MenuItem(id: "clickwheel", title: "Clickwheel"),
            MenuItem(id: "display", title: "Display"),
            MenuItem(id: "playback", title: "Playback"),
            MenuItem(id: "about", title: "About"),
        ]
    }

    var body: some View {
        MenuList(items: items, selection: selection)
            .onWheel { handle($0) }
            .onAppear { model.music.refreshStatus() }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: items.count, delta: d, settings: settings)
        case .select:
            activateCurrent()
        case .menu:
            model.pop()
        default:
            break
        }
    }

    private func activateCurrent() {
        switch items[min(selection, items.count - 1)].id {
        case "music":
            if model.music.status != .authorized {
                Task {
                    await model.music.requestAccess()
                    if model.music.isAuthorized {
                        await model.music.loadLibrary()
                    }
                }
            }
        case "clickwheel": model.push(.settingsClickwheel)
        case "display": model.push(.settingsDisplay)
        case "playback": model.push(.settingsPlayback)
        case "about": model.push(.settingsAbout)
        default: break
        }
    }
}

/// Generic settings page with value-cycling rows: wheel changes the selected
/// row's value; rows with `route` push on center instead.
struct ValueSettingsScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0

    struct Row {
        let id: String
        let title: String
        let value: () -> String
        let cycle: (() -> Void)?
        let route: Route?

        init(id: String, title: String, value: @escaping () -> String, cycle: (() -> Void)? = nil, route: Route? = nil) {
            self.id = id
            self.title = title
            self.value = value
            self.cycle = cycle
            self.route = route
        }
    }

    let title: String
    let rows: [Row]

    var body: some View {
        MenuList(
            items: rows.map { MenuItem(id: $0.id, title: $0.title, detail: $0.value()) },
            selection: selection
        )
        .onWheel { handle($0) }
    }

    private func handle(_ event: ControlEvent) {
        let row = rows[min(selection, rows.count - 1)]
        switch event {
        case .tick(let d):
            if row.cycle != nil {
                row.cycle?()
                WheelFeedback.tick(dir: d)
            } else {
                moveListSelection(&selection, count: rows.count, delta: d, settings: settings)
            }
        case .select:
            if let route = row.route {
                model.push(route)
            } else if let cycle = row.cycle {
                cycle()
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}

/// Clickwheel settings page.
struct ClickwheelSettingsScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    private static let scrollLabels = ["Off", "Light", "Medium", "Strong"]
    private static let buttonLabels = ["Light", "Medium", "Heavy"]

    var body: some View {
        ValueSettingsScreen(
            title: "Clickwheel",
            rows: [
                .init(id: "haptics", title: "Haptics", value: { settings.hapticsEnabled ? "On" : "Off" }) {
                    settings.hapticsEnabled.toggle()
                },
                .init(id: "scroll", title: "Scrolling Haptics", value: { Self.scrollLabels[min(settings.scrollingHaptics, 3)] }) {
                    settings.scrollingHaptics = (settings.scrollingHaptics + 1) % 4
                },
                .init(id: "button", title: "Button Haptics", value: { Self.buttonLabels[min(settings.buttonHaptics, 2)] }) {
                    settings.buttonHaptics = (settings.buttonHaptics + 1) % 3
                },
                .init(id: "ticks", title: "Tick Sounds", value: { settings.tickSounds ? "On" : "Off" }) {
                    settings.tickSounds.toggle()
                },
                .init(id: "infinite", title: "Infinite Tick", value: { settings.infiniteTick ? "On" : "Off" }) {
                    settings.infiniteTick.toggle()
                },
                .init(id: "rubber", title: "Rubber Band Tick", value: { settings.rubberBandTick ? "On" : "Off" }) {
                    settings.rubberBandTick.toggle()
                },
                .init(id: "type", title: "Tick Type", value: { settings.softTick ? "Soft Tick" : "Classic Tick" }) {
                    settings.softTick.toggle()
                },
            ]
        )
    }
}

/// Display settings page.
struct DisplaySettingsScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    private static let scanLabels = ["Off", "Subtle", "Medium", "Strong"]
    private static let dimLabels: [(String, Int)] = [("Off", 0), ("15 sec", 15), ("30 sec", 30), ("1 min", 60), ("5 min", 300)]
    private static let fontLabels = AppSettings.fontLabels

    var body: some View {
        ValueSettingsScreen(
            title: "Display",
            rows: [
                .init(id: "crt", title: "CRT Effect", value: { settings.crtEnabled ? "On" : "Off" }) {
                    settings.crtEnabled.toggle()
                },
                .init(id: "scan", title: "Scanlines", value: { Self.scanLabels[min(settings.scanlineIntensity, 3)] }) {
                    settings.scanlineIntensity = (settings.scanlineIntensity + 1) % 4
                },
                .init(id: "illusion", title: "Backlight Illusion", value: { settings.backlightIllusion ? "On" : "Off" }) {
                    settings.backlightIllusion.toggle()
                },
                .init(id: "dim", title: "Dim After", value: { Self.dimLabels.first(where: { $0.1 == settings.dimAfterSeconds })?.0 ?? "Off" }) {
                    let idx = Self.dimLabels.firstIndex(where: { $0.1 == settings.dimAfterSeconds }) ?? 0
                    settings.dimAfterSeconds = Self.dimLabels[(idx + 1) % Self.dimLabels.count].1
                },
                .init(id: "fontsize", title: "Font Size", value: { Self.fontLabels[min(settings.fontScale, 2)] }) {
                    settings.fontScale = (settings.fontScale + 1) % 3
                },
            ]
        )
    }
}

/// Playback settings page.
struct PlaybackSettingsScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    private static let repeatLabels = ["Off", "All", "One"]

    var body: some View {
        ValueSettingsScreen(
            title: "Playback",
            rows: [
                .init(id: "shuffle", title: "Shuffle", value: { settings.shuffle ? "On" : "Off" }) {
                    settings.shuffle.toggle()
                },
                .init(id: "repeat", title: "Repeat", value: { Self.repeatLabels[min(settings.repeatMode, 2)] }) {
                    settings.repeatMode = (settings.repeatMode + 1) % 3
                },
                .init(id: "volstep", title: "Volume Step", value: { "\(Int(settings.volumeStep * 100))%" }) {
                    settings.volumeStep = min(0.15, settings.volumeStep + 0.01)
                    if settings.volumeStep >= 0.15 { settings.volumeStep = 0.02 }
                },
            ]
        )
    }
}

/// About page.
struct AboutScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "circle.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.inkDim)
            Text("iPodClassic")
                .font(Theme.barTitle(19))
            Text("Version \(Self.version)")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.inkDim)
            Text("Music, photos, camera, memos,\nnotes and clocks — with a real\nclick wheel and haptics.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .onWheel { handle($0) }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .menu:
            model.pop()
        default:
            break
        }
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}
