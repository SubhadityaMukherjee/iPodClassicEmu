import SwiftUI
import MediaPlayer

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
        .task {
            // QA hooks: BINAURAL_START=<preset|1> opens with that session
            // playing; BINAURAL_AUTOSTOP=<seconds> stops it again (lock-
            // screen card reproduction).
            if let name = ProcessInfo.processInfo.environment["BINAURAL_START"] {
                let preset = BinauralModel.presets.first { $0.name == name }
                    ?? (name == "1" ? BinauralModel.presets.first : nil)
                if let preset { model.binaural.resume(preset) }
            }
            if let secs = Double(ProcessInfo.processInfo.environment["BINAURAL_AUTOSTOP"] ?? "") {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                    model.binaural.stop()
                    // QA: dump the Now Playing state after the stop (the
                    // ghost-card probe — state must read 3 = .stopped).
                    if ProcessInfo.processInfo.environment["BINAURAL_NP_DUMP"] == "1" {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        let center = MPNowPlayingInfoCenter.default()
                        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        let line = "state=\(center.playbackState.rawValue) info=\(center.nowPlayingInfo as NSDictionary??)"
                        try? line.write(to: docs.appendingPathComponent("binaural_np.txt"), atomically: true, encoding: .utf8)
                    }
                }
            }
        }
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
