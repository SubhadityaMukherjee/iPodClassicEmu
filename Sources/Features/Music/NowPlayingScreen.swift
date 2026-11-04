import SwiftUI
import MusicKit

/// Classic Now Playing: artwork on the left, track info on the right (title
/// marquees when too long), progress bar below; wheel adjusts volume.
/// Hold center opens Song Options (Add to Playlist, …).
struct NowPlayingScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var volumeFlash = false
    @State private var menuOpen = false
    @State private var menuSelection = 0
    @State private var playlistMode = false
    @State private var playlistSelection = 0
    @State private var toast = ""

    private var player: PlayerModel { model.player }
    private var song: Song? { player.currentSong }
    private var playlists: [Playlist] { model.music.playlists }

    var body: some View {
        ZStack {
            VStack(spacing: 6) {
                // Centered in the space above the progress bar, like the
                // classic Now Playing layout.
                Spacer(minLength: 0)

                infoRow
                    .padding(.horizontal, 8)

                Spacer(minLength: 0)

                bottomBar
            }
            .padding(.bottom, 8)

            if menuOpen {
                ModalHost { optionsPanel }
                    .zIndex(2)
            }

            if !toast.isEmpty {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(white: 0.85)))
                        .padding(.bottom, 30)
                }
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .onWheel { handle($0) }
    }

    // MARK: Layout

    /// Artwork left, track text right — the text column marquees the title
    /// when it overflows.
    @ViewBuilder
    private var infoRow: some View {
        HStack(alignment: .top, spacing: 10) {
            artwork
                .frame(width: 132, height: 132)

            VStack(alignment: .leading, spacing: 3) {
                MarqueeText(text: song?.title ?? "Not Playing",
                            font: .system(size: 16.5, weight: .bold),
                            color: Theme.ink)
                MarqueeText(text: song?.artistName ?? "",
                            font: .system(size: 14, weight: .medium),
                            color: Theme.inkDim)
                MarqueeText(text: song?.albumTitle ?? "",
                            font: .system(size: 13, weight: .medium),
                            color: Theme.inkDim.opacity(0.85))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var artwork: some View {
        if let aw = song?.artwork {
            ArtworkView(artwork: aw, width: 300, height: 300)
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.35), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        } else {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(white: 0.85))
                .frame(width: 132, height: 132)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.inkDim)
                )
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.2), lineWidth: 0.8))
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if volumeFlash {
            volumeBar
                .padding(.horizontal, 14)
                .transition(.opacity)
        } else {
            progressBar
                .padding(.horizontal, 14)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let progress = player.duration > 0 ? player.playbackTime / player.duration : 0
            VStack(spacing: 3) {
                HStack {
                    Text(TimeFormat.mss(player.playbackTime))
                        .monospacedDigit()
                    Spacer()
                    Text(player.isPlaying ? "-\(TimeFormat.mss(max(0, player.duration - player.playbackTime)))" : TimeFormat.mss(player.duration))
                        .monospacedDigit()
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.inkDim)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.22))
                        .frame(height: 10)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Theme.selMid, Theme.selTop],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, geo.size.width * progress), height: 10)
                }
            }
        }
        .frame(height: 38)
    }

    private var volumeBar: some View {
        GeometryReader { geo in
            VStack(spacing: 3) {
                HStack {
                    Image(systemName: "speaker.fill").font(.system(size: 12))
                    Spacer()
                    Text("\(Int(player.volume * 100))")
                        .font(.system(size: 12.5, weight: .bold))
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.inkDim)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.22))
                        .frame(height: 10)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Theme.selMid, Theme.selTop],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, geo.size.width * player.volume), height: 10)
                }
            }
        }
        .frame(height: 38)
    }

    // MARK: Song options

    private var optionItems: [MenuItem] {
        [
            MenuItem(id: "playlist", title: "Add to Playlist"),
            MenuItem(id: "album", title: "Go to Album"),
        ]
    }

    private var optionsPanel: some View {
        ModalPanel(title: playlistMode ? "Add to Playlist" : "Song Options", onClose: { closeMenu() }) {
            if playlistMode {
                MenuList(
                    items: playlists.map { MenuItem(id: $0.id.rawValue, title: $0.name) },
                    selection: playlistSelection,
                    compact: true,
                    emptyText: "No Playlists"
                )
                .padding(.top, 2)
            } else {
                MenuList(items: optionItems, selection: menuSelection, compact: true)
                    .padding(.top, 2)
            }
        }
    }

    private func closeMenu() {
        withAnimation(.easeIn(duration: 0.15)) {
            menuOpen = false
            playlistMode = false
        }
    }

    private func showPlaylistPicker() {
        playlistSelection = 0
        withAnimation(.easeOut(duration: 0.18)) { playlistMode = true }
    }

    private func addToPlaylist(_ playlist: Playlist) async {
        guard let song else { return }
        do {
            _ = try await MusicLibrary.shared.add(song, to: playlist)
            toast = "Added to \(playlist.name)"
        } catch {
            toast = "Couldn't add to playlist"
        }
        closeMenu()
        withAnimation(.easeOut(duration: 0.2)) {}
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeIn(duration: 0.3)) { toast = "" }
        }
    }

    private func goToAlbum() async {
        guard let song, let album = model.music.album(forSong: song) else {
            toast = "Album not found"
            closeMenu()
            return
        }
        closeMenu()
        model.push(.albumDetail(album.id.rawValue))
    }

    // MARK: Input

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            if menuOpen {
                if playlistMode {
                    moveListSelection(&playlistSelection, count: playlists.count, delta: d, settings: settings)
                } else {
                    moveListSelection(&menuSelection, count: optionItems.count, delta: d, settings: settings)
                }
            } else {
                player.bumpVolume(Double(d) * settings.volumeStep)
                withAnimation(.easeOut(duration: 0.15)) { volumeFlash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    withAnimation(.easeIn(duration: 0.3)) { volumeFlash = false }
                }
            }
        case .select:
            if menuOpen {
                if playlistMode {
                    if playlists.indices.contains(playlistSelection) {
                        Task { await addToPlaylist(playlists[playlistSelection]) }
                    }
                } else {
                    switch optionItems[min(menuSelection, optionItems.count - 1)].id {
                    case "playlist": showPlaylistPicker()
                    case "album": Task { await goToAlbum() }
                    default: break
                    }
                }
            } else {
                player.togglePlayPause()
            }
        case .centerHold:
            guard song != nil else { return }
            WheelHaptics.shared.ensureRunning()
            WheelHaptics.shared.buttonPress(strength: 0.9)
            menuSelection = 0
            playlistMode = false
            withAnimation(.easeOut(duration: 0.18)) { menuOpen = true }
        case .menu:
            if menuOpen {
                closeMenu()
            } else {
                model.pop()
            }
        case .menuHold:
            if menuOpen { closeMenu() }
            model.popToRoot()
        default:
            break
        }
    }
}

/// Single-line text that marquees horizontally when it overflows.
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let approxCharWidth: CGFloat = 8.0
    @State private var overflowing = false

    var body: some View {
        GeometryReader { geo in
            let approx = CGFloat(text.count) * approxCharWidth
            if text.isEmpty {
                Color.clear
            } else if approx > geo.size.width {
                // Overflow: slide back and forth.
                TimelineView(.animation(minimumInterval: 0.05)) { tl in
                    let phase = tl.date.timeIntervalSinceReferenceDate
                    let cycle = Double(max(3, Double(text.count) * 0.14))
                    let t = phase.truncatingRemainder(dividingBy: cycle) / cycle
                    let slide: CGFloat = t < 0.5
                        ? -max(0, approx - geo.size.width + 8) * smoothstep(t * 2)
                        : -max(0, approx - geo.size.width + 8) * smoothstep((1 - t) * 2)
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: slide)
                }
            } else {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
        .frame(height: 22)
    }

    private func smoothstep(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }
}
