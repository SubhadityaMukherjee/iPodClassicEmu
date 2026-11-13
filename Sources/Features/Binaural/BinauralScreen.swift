import SwiftUI

/// Binaural beats: preset list with live synthesis; playback keeps
/// running when you leave the screen (like music), so you can browse
/// with it on. MENU goes back; the session ends via Stop or the global
/// play/pause transport.
struct BinauralScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0

    private var items: [MenuItem] {
        var rows = [
            MenuItem(id: "stop", title: model.binaural.isPlaying ? "Stop" : "Off",
                     symbol: "stop.fill", showsChevron: false, isActionRow: true)
        ]
        for preset in BinauralModel.presets {
            let isActive = model.binaural.isPlaying && model.binaural.active == preset
            rows.append(MenuItem(
                id: preset.id,
                title: preset.name,
                detail: isActive ? TimeFormat.hms(model.binaural.elapsed) : preset.detail,
                symbol: isActive ? "waveform" : nil,
                showsChevron: false))
        }
        rows.append(MenuItem(id: "volume", title: "Volume",
                             detail: "\(Int(model.binaural.volume * 100))%",
                             showsChevron: false, isActionRow: true))
        return rows
    }

    var body: some View {
        ZStack {
            MenuList(items: items, selection: selection, style: .twoLine)
        }
        .onWheel { handle($0) }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: items.count, delta: d, settings: settings)
        case .select:
            let item = items[min(selection, items.count - 1)]
            switch item.id {
            case "stop":
                model.binaural.stop()
            case "volume":
                model.binaural.cycleVolume()
            default:
                guard let preset = BinauralModel.presets.first(where: { $0.id == item.id }) else { return }
                // Starting a session pauses music — two beat sources don't mix.
                if model.player.isPlaying { model.player.togglePlayPause() }
                model.binaural.toggle(preset)
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}
