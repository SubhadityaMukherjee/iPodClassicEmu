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
                        .font(Theme.font(12, .bold))
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
                            font: Theme.font(16.5, .bold),
                            color: Theme.ink)
                MarqueeText(text: song?.artistName ?? "",
                            font: Theme.font(14, .medium),
                            color: Theme.inkDim)
                MarqueeText(text: song?.albumTitle ?? "",
                            font: Theme.font(13, .medium),
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
                        .font(Theme.font(30))
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
                .font(Theme.font(12.5, .semibold))
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
                    Image(systemName: "speaker.fill").font(Theme.font(12))
                    Spacer()
                    Text("\(Int(player.volume * 100))")
                        .font(Theme.font(12.5, .bold))
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
            MenuItem(id: "artist", title: "Go to Artist"),
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

    private func goToArtist() async {
        guard let song else { return }
        let name = song.artistName
        guard let artist = model.music.artists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                ?? model.music.artists.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
            toast = "Artist not found"
            closeMenu()
            return
        }
        closeMenu()
        model.push(.artistDetail(artist.id.rawValue))
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
                    case "artist": Task { await goToArtist() }
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

/// Single-line text that marquees like the classic iPod: fixed width, and
/// when it overflows it scrolls continuously right-to-left, wrapping around
/// with a gap — no bouncing.
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    @State private var textWidth: CGFloat = 0
    @State private var scrolling = false
    @State private var offset: CGFloat = 0
    private let gap: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let overflows = textWidth > geo.size.width + 1
            ZStack(alignment: .leading) {
                if overflows {
                    HStack(spacing: gap) {
                        tickerText
                        tickerText  // second copy closes the loop seamlessly
                    }
                    .background(
                        // Measure one copy's width to size the loop.
                        tickerText.hidden().background(
                            GeometryReader { g in
                                Color.clear.onAppear { textWidth = g.size.width }
                                    .onChange(of: g.size.width) { textWidth = $1 }
                            }
                        )
                    )
                    .offset(x: offset)
                } else {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
            .onChange(of: geo.size.width) { _ in restartIfNeeded(overflows: overflows) }
            .onChange(of: overflows) { newOverflows in
                restartIfNeeded(overflows: newOverflows)
            }
            .onAppear { restartIfNeeded(overflows: overflows) }
            .onDisappear { stop() }
        }
        .frame(height: 22)
    }

    private var tickerText: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    private func restartIfNeeded(overflows: Bool) {
        guard overflows, textWidth > 0, !scrolling else { return }
        scrolling = true
        offset = 0
        let distance = textWidth + gap
        let duration = Double(distance) / 32.0  // ~32 pt/s, classic pace
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            offset = -distance
        }
    }

    private func stop() {
        scrolling = false
        offset = 0
    }
}
