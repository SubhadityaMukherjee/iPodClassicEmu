import SwiftUI
import AVFoundation
import MusicKit

/// Extras menu: Clocks, Calendar, Flashlight — like the classic Extras menu.
struct ExtrasScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0

    private var items: [MenuItem] {
        [
            MenuItem(id: "clocks", title: "Clocks"),
            MenuItem(id: "calendar", title: "Calendar"),
            MenuItem(id: "flashlight", title: "Flashlight", symbol: "flashlight.on.fill", showsChevron: false),
        ]
    }

    var body: some View {
        MenuList(items: items, selection: selection)
            .onWheel { handle($0) }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: items.count, delta: d, settings: settings)
        case .select:
            switch items[min(selection, items.count - 1)].id {
            case "clocks": model.push(.clocks)
            case "calendar": model.push(.calendar)
            case "flashlight": model.push(.flashlight)
            default: break
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}

/// Torch screen: center toggles the flashlight, wheel sets the level.
struct FlashlightScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    @State private var on = false
    @State private var level: Double = 1.0

    var body: some View {
        VStack(spacing: 10) {
            Button {
                setTorch(!on)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(on ? AnyShapeStyle(SelectionGradient()) : AnyShapeStyle(Color(white: 0.82)))
                        .frame(width: 120, height: 120)
                    Image(systemName: on ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(on ? Color.white : Theme.inkDim)
                }
            }
            .buttonStyle(.plain)

            VStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.18)).frame(height: 9)
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.selMid, Theme.selTop], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6.0, 150 * level), height: 9)
                }
                .frame(width: 150)
                Text(on ? "Level \(Int(level * 100))%" : "Center: on · Wheel: level")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.inkDim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onWheel { handle($0) }
        .onDisappear { setTorch(false) }
    }

    private func setTorch(_ wantOn: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            on = false
            return
        }
        do {
            try device.lockForConfiguration()
            if wantOn {
                device.torchMode = .on
                try device.setTorchModeOn(level: Float(max(0.1, level)))
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
            on = wantOn
            WheelHaptics.shared.ensureRunning()
            WheelHaptics.shared.buttonPress(strength: 0.9)
        } catch {
            on = false
        }
    }

    private func updateLevel() {
        guard on, let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            try device.setTorchModeOn(level: Float(max(0.1, level)))
            device.unlockForConfiguration()
        } catch {}
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            level = min(1, max(0.1, level + Double(d) * 0.05))
            WheelFeedback.tick(dir: d)
            updateLevel()
        case .select:
            setTorch(!on)
        case .menu:
            setTorch(false)
            model.pop()
        default:
            break
        }
    }
}

/// Library search: type with the keyboard, results live-update.
struct MusicSearchScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: [Song] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        return model.music.songs
            .filter {
                $0.title.localizedCaseInsensitiveContains(q)
                    || $0.artistName.localizedCaseInsensitiveContains(q)
                    || ($0.albumTitle ?? "").localizedCaseInsensitiveContains(q)
            }
            .sorted { $0.title.lowercased() != $1.title.lowercased() ? $0.title.lowercased() < $1.title.lowercased() : $0.id.rawValue < $1.id.rawValue }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.inkDim)
                TextField("Search songs, artists, albums", text: $query)
                    .focused($focused)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .submitLabel(.search)
                    .padding(.vertical, 4)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.inkDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(white: 0.92))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.18), lineWidth: 0.8))
            )
            .padding(.horizontal, 6)
            .onTapGesture { focused = true }

            MenuList(
                items: results.map { s in
                    MenuItem(id: s.id.rawValue, title: s.title, subtitle: s.artistName, showsChevron: false)
                },
                selection: selection,
                emptyText: query.count >= 2 ? "No Results" : "Type to search",
                style: .twoLine
            )
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 4)
        .onWheel { handle($0) }
        .onAppear { focused = true }
        .onDisappear { focused = false }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            guard !query.isEmpty else { return }
            moveListSelection(&selection, count: results.count, delta: d, settings: settings)
        case .select:
            let list = results
            guard list.indices.contains(selection) else { return }
            model.player.play(list, startingAt: selection)
            model.push(.nowPlaying)
        case .menu:
            if focused {
                focused = false
            } else {
                model.pop()
            }
        default:
            break
        }
    }
}
