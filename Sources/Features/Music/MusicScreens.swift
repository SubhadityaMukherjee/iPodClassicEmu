import SwiftUI
import MusicKit

/// Music root: split menu (Cover Flow, Playlists, Artists, …) with an
/// artwork preview pane on the right.
struct MusicMenuScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0

    private var items: [MenuItem] {
        [
            MenuItem(id: "search", title: "Search", symbol: "magnifyingglass", showsChevron: false, isActionRow: true),
            MenuItem(id: "coverflow", title: "Cover Flow"),
            MenuItem(id: "playlists", title: "Playlists"),
            MenuItem(id: "artists", title: "Artists"),
            MenuItem(id: "albums", title: "Albums"),
            MenuItem(id: "songs", title: "Songs"),
            MenuItem(id: "genres", title: "Genres"),
            MenuItem(id: "recent", title: "Recent"),
            MenuItem(id: "nowplaying", title: "Now Playing"),
        ]
    }

    var body: some View {
        SplitMenuLayout(items: items, selection: selection) {
            preview
        }
        .onWheel { handle($0) }
        .onAppear {
            model.music.refreshStatus()
            if model.music.isAuthorized && !model.music.loaded && !model.music.loading {
                Task { await model.music.loadLibrary() }
            } else {
                // Re-check for new library content each time Music opens.
                Task { await model.music.refreshIfStale() }
            }
        }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: items.count, delta: d, settings: settings)
        case .select:
            select()
        case .menu:
            model.pop()
        default:
            break
        }
    }

    private func select() {
        switch items[selection].id {
        case "coverflow": model.push(.coverFlow)
        case "search": model.push(.musicSearch)
        case "playlists": model.push(.musicPlaylists)
        case "artists": model.push(.musicArtists)
        case "albums": model.push(.musicAlbums)
        case "songs": model.push(.musicSongs)
        case "genres": model.push(.musicGenres)
        case "recent": model.push(.musicRecent)
        case "nowplaying": model.push(.nowPlaying)
        default: break
        }
    }

    @ViewBuilder
    private var preview: some View {
        if !model.music.isAuthorized {
            PromptPane(
                symbol: "music.note.list",
                text: "Connect to Apple Music in Settings to see your library."
            )
        } else if model.music.loading {
            VStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(Theme.font(30))
                    .foregroundStyle(Theme.inkDim)
                Text("Loading Library…")
                    .font(Theme.font(13, .semibold))
                    .foregroundStyle(Theme.inkDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch items[selection].id {
            case "playlists":
                if let pl = model.music.playlists.first {
                    artworkPreview(pl.artwork)
                } else { fallback("music.note.list") }
            case "artists":
                if let artist = model.music.artists.first,
                   let album = model.music.albums(byArtist: artist).first {
                    artworkPreview(album.artwork)
                } else { fallback("person.fill") }
            case "albums":
                if let album = model.music.albums.first { artworkPreview(album.artwork) }
                else { fallback("square.stack") }
            case "songs":
                if let song = model.music.songs.first, let album = model.music.album(forSong: song) {
                    artworkPreview(album.artwork)
                } else { fallback("music.note") }
            case "genres":
                if let genre = model.music.genres.first,
                   let album = model.music.albums(inGenre: genre).first {
                    artworkPreview(album.artwork)
                } else { fallback("guitars.fill") }
            case "recent":
                if let album = model.music.recentlyAdded.first { artworkPreview(album.artwork) }
                else { fallback("clock") }
            case "nowplaying":
                if let song = model.player.currentSong, let aw = song.artwork {
                    ArtworkView(artwork: aw, width: 300, height: 300)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { fallback("play.rectangle") }
            default:
                if let album = model.music.albums.first { artworkPreview(album.artwork) }
                else { fallback("music.note") }
            }
        }
    }

    @ViewBuilder
    private func artworkPreview(_ artwork: Artwork?) -> some View {
        if let artwork {
            ArtworkView(artwork: artwork, width: 300, height: 300)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            fallback("music.note")
        }
    }

    private func fallback(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(Theme.font(34))
            .foregroundStyle(Theme.inkDim.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hint pane used when the library isn't available.
struct PromptPane: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(Theme.font(30))
                .foregroundStyle(Theme.inkDim)
            Text(text)
                .font(Theme.font(12.5, .semibold))
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Generic music list screens

/// Which library list a MusicListScreen shows.
enum MusicListKind {
    case artists, albums, songs, genres, playlists, recent
}

/// Wheel-driven list over one library section. Header rows (Play All,
/// Shuffle All, Sort By) sit full-width on top, like the album page.
/// Hold-center options for a song row (song lists, album and playlist
/// detail): a shared panel + input handler so all three screens behave
/// alike. Play Next puts the song immediately after the current entry;
/// Add to Queue appends it behind everything already up next.
@Observable
final class SongHoldState {
    /// A real MusicKit song, or (sim QA only — MusicKit Songs can't be
    /// constructed app-side) just a seed title so the panel is exercisable.
    enum Pending {
        case song(Song)
        case qaTitle(String)
    }

    private(set) var pending: Pending?
    private(set) var selection = 0

    var isShowing: Bool { pending != nil }

    /// Consumes wheel events while the panel is up; returns false when
    /// the panel is closed so the screen handles the event itself.
    @discardableResult
    func handle(_ event: ControlEvent, player: PlayerModel, toast: @escaping (String) -> Void) -> Bool {
        guard pending != nil else { return false }
        switch event {
        case .tick(let d):
            selection = min(2, max(0, selection + (d > 0 ? 1 : -1)))
            WheelFeedback.tick(dir: d)
        case .select:
            defer { pending = nil }
            switch selection {
            case 0:
                if case .song(let s) = pending {
                    toast(player.addToQueue(s, mode: .next) ? "Playing Next" : "Nothing Playing")
                } else {
                    toast("Nothing Playing")
                }
            case 1:
                if case .song(let s) = pending {
                    toast(player.addToQueue(s, mode: .end) ? "Added to Queue" : "Nothing Playing")
                } else {
                    toast("Nothing Playing")
                }
            default:
                break
            }
        case .menu, .menuHold:
            pending = nil
        default:
            break
        }
        return true
    }

    func begin(_ song: Song) {
        pending = .song(song)
        selection = 0
    }

    /// Sim QA entry point (FAKE_LIBRARY): no real Song exists, so the
    /// panel opens title-only and queueing toasts "Nothing Playing".
    func beginQA(title: String) {
        pending = .qaTitle(title)
        selection = 0
    }

    var panel: some View {
        ModalPanel(title: "Song Options", onClose: { self.pending = nil }) {
            VStack(spacing: 0) {
                MenuRow(item: MenuItem(id: "h.next", title: "Play Next", showsChevron: false), selected: self.selection == 0)
                    .frame(height: 30.5)
                MenuRow(item: MenuItem(id: "h.queue", title: "Add to Queue", showsChevron: false), selected: self.selection == 1)
                    .frame(height: 30.5)
                MenuRow(item: MenuItem(id: "h.cancel", title: "Cancel", showsChevron: false), selected: self.selection == 2)
                    .frame(height: 30.5)
            }
            .padding(.top, 2)
        }
    }
}

struct MusicListScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    let kind: MusicListKind

    @State private var selection = 0
    @State private var toast = ""
    @State private var hold = SongHoldState()

    private static let songSortLabels = ["Title", "Artist", "Duration", "Recently Added"]
    private static let albumSortLabels = ["Title", "Artist", "Recently Added"]

    // MARK: Entries (sorted) — cached in MusicService; see songsMenuItems.

    private var sortedSongs: [Song] {
        guard kind == .songs else { return model.music.songs }
        return model.music.songsSorted(by: settings.songSort)
    }

    private var sortedAlbums: [Album] {
        let list = kind == .recent ? model.music.recentlyAdded : model.music.albums
        guard kind == .albums else { return list }
        return model.music.albumsSorted(by: settings.albumSort)
    }

    private var entryItems: [MenuItem] {
        switch kind {
        case .artists:
            return model.music.artistsMenuItems()
        case .albums:
            return model.music.albumsMenuItems(sort: settings.albumSort)
        case .songs:
            if QASeed.active {
                return QASeed.songs.map { MenuItem(id: $0.id, title: $0.title, subtitle: $0.artist, showsChevron: false) }
            }
            return model.music.songsMenuItems(sort: settings.songSort)
        case .genres:
            return model.music.genresMenuItems()
        case .playlists:
            return model.music.playlistsMenuItems()
        case .recent:
            return model.music.recentMenuItems()
        }
    }

    // MARK: Headers

    private var headerItems: [MenuItem] {
        var h = [
            MenuItem(id: "hdr.play", title: "Play All", symbol: "play.fill", showsChevron: false, isActionRow: true),
            MenuItem(id: "hdr.shuffle", title: "Shuffle All", symbol: "shuffle", showsChevron: false, isActionRow: true),
        ]
        if sortLabels != nil {
            h.append(MenuItem(id: "hdr.sort", title: "Sort By", detail: sortLabels![sortIndex], showsChevron: false, isActionRow: true))
        }
        return h
    }

    private var sortLabels: [String]? {
        switch kind {
        case .songs: return Self.songSortLabels
        case .albums: return Self.albumSortLabels
        default: return nil
        }
    }

    private var sortIndex: Int {
        kind == .songs ? settings.songSort : settings.albumSort
    }

    private var allItems: [MenuItem] {
        // Read `loaded` so the list re-renders when the async library load
        // completes (the QA seed path touches no observable otherwise).
        _ = model.music.loaded
        return headerItems + entryItems
    }

    var body: some View {
        ZStack {
            MenuList(
                items: allItems,
                selection: selection,
                style: listStyle
            ) { item in
                // Thumbnails resolve by album id; only thumbnail-style lists render them.
                model.music.album(item.id)?.artwork
            }
            if !toast.isEmpty {
                ToastCapsule(text: toast)
                    .zIndex(2)
            }
            if hold.isShowing {
                ModalHost { hold.panel }
                    .zIndex(2)
            }
        }
        .onWheel { handle($0) }
        .onAppear {
            if !model.music.loaded && !model.music.loading {
                Task { await model.music.loadLibrary() }
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeIn(duration: 0.3)) { toast = "" }
        }
    }

    private var listStyle: MenuRowStyle {
        switch kind {
        case .albums, .recent: return .thumbnail
        case .songs: return .twoLine
        default: return .normal
        }
    }

    private var thumbStyle: Bool { kind == .albums || kind == .recent }

    private func thumbProvider(_ item: MenuItem) -> Artwork? {
        model.music.album(item.id)?.artwork
    }

    // MARK: Input

    private func handle(_ event: ControlEvent) {
        if hold.handle(event, player: model.player, toast: showToast) { return }
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: allItems.count, delta: d, settings: settings)
        case .select:
            if selection < headerItems.count {
                activateHeader(headerItems[selection].id)
            } else {
                selectEntry(at: selection - headerItems.count)
            }
        case .centerHold:
            // Hold on a song row: queue options (Play Next / Add to Queue).
            guard kind == .songs else { break }
            let idx = selection - headerItems.count
            WheelHaptics.shared.ensureRunning()
            WheelHaptics.shared.buttonPress(strength: 0.85)
            if QASeed.active {
                // Seed rows have no MusicKit Song; the panel still opens
                // (title-only) so QA can exercise it end-to-end.
                guard QASeed.songs.indices.contains(idx) else { break }
                hold.beginQA(title: QASeed.songs[idx].title)
            } else {
                let songs = sortedSongs
                guard songs.indices.contains(idx) else { break }
                hold.begin(songs[idx])
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }

    /// Songs this list can play in full: the sorted list itself for Songs,
    /// album-ordered library for album/recent, the whole library otherwise.
    private var allSongs: [Song] {
        if QASeed.active { return [] }
        switch kind {
        case .songs: return sortedSongs
        case .albums, .recent:
            return model.music.songs.sorted {
                ($0.albumTitle ?? "") == ($1.albumTitle ?? "")
                    ? ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0)
                    : ($0.albumTitle ?? "").localizedCaseInsensitiveCompare($1.albumTitle ?? "") == .orderedAscending
            }
        default: return model.music.songs
        }
    }

    private func activateHeader(_ id: String) {
        switch id {
        case "hdr.play":
            guard !allSongs.isEmpty else { return }
            model.player.play(allSongs)
            model.push(.nowPlaying)
        case "hdr.shuffle":
            guard !allSongs.isEmpty else { return }
            model.player.shufflePlay(allSongs)
            model.push(.nowPlaying)
        case "hdr.sort":
            if kind == .songs {
                settings.songSort = (settings.songSort + 1) % Self.songSortLabels.count
            } else if kind == .albums {
                settings.albumSort = (settings.albumSort + 1) % Self.albumSortLabels.count
            }
            WheelHaptics.shared.buttonPress(strength: 0.6)
        default:
            break
        }
    }

    private func selectEntry(at idx: Int) {
        guard idx >= 0 else { return }
        switch kind {
        case .artists:
            let artists = model.music.artists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard artists.indices.contains(idx) else { return }
            model.push(.artistDetail(artists[idx].id.rawValue))
        case .albums:
            let albums = sortedAlbums
            guard albums.indices.contains(idx) else { return }
            model.push(.albumDetail(albums[idx].id.rawValue))
        case .songs:
            let songs = sortedSongs
            guard songs.indices.contains(idx) else { return }
            model.player.play(songs, startingAt: idx)
            model.push(.nowPlaying)
        case .genres:
            let genres = model.music.genres.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            guard genres.indices.contains(idx) else { return }
            model.push(.genreAlbums(genres[idx]))
        case .playlists:
            let playlists = model.music.playlists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard playlists.indices.contains(idx) else { return }
            model.push(.playlistDetail(playlists[idx].id.rawValue))
        case .recent:
            let albums = model.music.recentlyAdded
            guard albums.indices.contains(idx) else { return }
            model.push(.albumDetail(albums[idx].id.rawValue))
        }
    }
}

/// Albums by one artist, with full-width Play/Shuffle headers.
struct ArtistDetailScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    let artistID: String
    @State private var selection = 0

    private var artist: Artist? { model.music.artist(artistID) }
    private var albums: [Album] {
        guard let artist else { return [] }
        return model.music.albums(byArtist: artist)
    }
    private var headerItems: [MenuItem] {
        [
            MenuItem(id: "hdr.play", title: "Play All", symbol: "play.fill", showsChevron: false, isActionRow: true),
            MenuItem(id: "hdr.shuffle", title: "Shuffle All", symbol: "shuffle", showsChevron: false, isActionRow: true),
        ]
    }
    private var totalRows: Int { headerItems.count + albums.count }
    private var artistSongs: [Song] {
        albums.flatMap { model.music.cachedTracks(forAlbum: $0) }
    }

    var body: some View {
        MenuList(
            items: headerItems + albums.map { al in MenuItem(id: al.id.rawValue, title: al.title, subtitle: "\(al.trackCount) Songs") },
            selection: selection, style: .thumbnail
        ) { item in
            model.music.album(item.id)?.artwork
        }
        .onWheel { handle($0) }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: totalRows, delta: d, settings: settings)
        case .select:
            if selection == 0 {
                guard !artistSongs.isEmpty else { return }
                model.player.play(artistSongs)
                model.push(.nowPlaying)
            } else if selection == 1 {
                guard !artistSongs.isEmpty else { return }
                model.player.shufflePlay(artistSongs)
                model.push(.nowPlaying)
            } else {
                let idx = selection - headerItems.count
                if albums.indices.contains(idx) {
                    model.push(.albumDetail(albums[idx].id.rawValue))
                }
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}

/// Albums in one genre, with full-width Play/Shuffle headers.
struct GenreAlbumsScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    let genre: String
    @State private var selection = 0

    private var albums: [Album] { model.music.albums(inGenre: genre) }
    private var headerItems: [MenuItem] {
        [
            MenuItem(id: "hdr.play", title: "Play All", symbol: "play.fill", showsChevron: false, isActionRow: true),
            MenuItem(id: "hdr.shuffle", title: "Shuffle All", symbol: "shuffle", showsChevron: false, isActionRow: true),
        ]
    }
    private var genreSongs: [Song] {
        albums.flatMap { model.music.cachedTracks(forAlbum: $0) }
    }

    var body: some View {
        MenuList(
            items: headerItems + albums.map { al in MenuItem(id: al.id.rawValue, title: al.title, subtitle: al.artistName) },
            selection: selection, style: .thumbnail
        ) { item in
            model.music.album(item.id)?.artwork
        }
        .onWheel { handle($0) }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: headerItems.count + albums.count, delta: d, settings: settings)
        case .select:
            if selection == 0 {
                guard !genreSongs.isEmpty else { return }
                model.player.play(genreSongs)
                model.push(.nowPlaying)
            } else if selection == 1 {
                guard !genreSongs.isEmpty else { return }
                model.player.shufflePlay(genreSongs)
                model.push(.nowPlaying)
            } else {
                let idx = selection - headerItems.count
                if albums.indices.contains(idx) {
                    model.push(.albumDetail(albums[idx].id.rawValue))
                }
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}

/// Album page: View in Cover Flow, Shuffle Songs, then the track list with
/// thumbnails — exactly the classic layout.
struct AlbumDetailScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    let albumID: String

    @State private var selection = 0
    @State private var tracks: [Song] = []
    @State private var toast = ""
    @State private var hold = SongHoldState()

    private var album: Album? { model.music.album(albumID) }

    var body: some View {
        ZStack {
            // Shared MenuList (mixed action-row/track heights) so the rows
            // fill the screen exactly — the old hand-rolled windowing
            // assumed 47pt rows everywhere and always left white space at
            // the bottom.
            MenuList(
                items: headerItems + trackItems,
                selection: selection,
                emptyText: "No Tracks",
                style: .thumbnail
            ) { item in
                item.id.hasPrefix("track.") ? album?.artwork : nil
            }
            if !toast.isEmpty {
                ToastCapsule(text: toast)
                    .zIndex(2)
            }
            if hold.isShowing {
                ModalHost { hold.panel }
                    .zIndex(2)
            }
        }
        .onWheel { handle($0) }
        .task(id: albumID) {
            if let album {
                tracks = await model.music.tracks(forAlbum: album)
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeIn(duration: 0.3)) { toast = "" }
        }
    }

    private var headerItems: [MenuItem] {
        [
            MenuItem(id: "header.coverflow", title: "View in Cover Flow", symbol: "rectangle.stack", showsChevron: false, isActionRow: true),
            MenuItem(id: "header.play", title: "Play All", symbol: "play.fill", showsChevron: false, isActionRow: true),
            MenuItem(id: "header.shuffle", title: "Shuffle Songs", symbol: "shuffle", showsChevron: false, isActionRow: true),
        ]
    }

    private var trackItems: [MenuItem] {
        tracks.enumerated().map { i, s in
            MenuItem(id: "track.\(s.id.rawValue)", title: s.title, subtitle: s.artistName, showsChevron: false)
        }
    }

    private var totalRows: Int { headerItems.count + tracks.count }

    private func handle(_ event: ControlEvent) {
        if hold.handle(event, player: model.player, toast: showToast) { return }
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: totalRows, delta: d, settings: settings)
        case .select:
            activateCurrent()
        case .centerHold:
            // Hold a track row: queue options (Play Next / Add to Queue).
            let idx = selection - headerItems.count
            guard tracks.indices.contains(idx) else { break }
            WheelHaptics.shared.ensureRunning()
            WheelHaptics.shared.buttonPress(strength: 0.85)
            hold.begin(tracks[idx])
        case .menu:
            model.pop()
        default:
            break
        }
    }

    private func activateCurrent() {
        guard let album else { return }
        switch selection {
        case 0:
            CoverFlowLaunch.shared.pendingAlbumID = albumID
            model.push(.coverFlow)
        case 1:
            model.player.play(tracks.isEmpty ? model.music.songs : tracks)
            model.push(.nowPlaying)
        case 2:
            model.player.shufflePlay(tracks.isEmpty ? model.music.songs : tracks)
            model.push(.nowPlaying)
        default:
            let idx = selection - headerItems.count
            if tracks.indices.contains(idx) {
                model.player.play(tracks, startingAt: idx)
                model.push(.nowPlaying)
            }
        }
    }
}

/// Tracks of one playlist.
struct PlaylistDetailScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    let playlistID: String

    @State private var selection = 0
    @State private var tracks: [Song] = []
    @State private var toast = ""
    @State private var hold = SongHoldState()

    private var playlist: Playlist? { model.music.playlist(playlistID) }

    private var headerItems: [MenuItem] {
        [
            MenuItem(id: "hdr.play", title: "Play All", symbol: "play.fill", showsChevron: false, isActionRow: true),
            MenuItem(id: "hdr.shuffle", title: "Shuffle All", symbol: "shuffle", showsChevron: false, isActionRow: true),
        ]
    }
    private var totalRows: Int { headerItems.count + tracks.count }

    var body: some View {
        ZStack {
            MenuList(
                items: headerItems + tracks.enumerated().map { i, s in
                    MenuItem(id: s.id.rawValue, title: s.title, subtitle: s.artistName, showsChevron: false)
                },
                selection: selection, emptyText: "No Songs", style: .twoLine
            )
            if !toast.isEmpty {
                ToastCapsule(text: toast)
                    .zIndex(2)
            }
            if hold.isShowing {
                ModalHost { hold.panel }
                    .zIndex(2)
            }
        }
        .onWheel { handle($0) }
        .task(id: playlistID) {
            if let playlist {
                tracks = await model.music.tracks(forPlaylist: playlist)
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeIn(duration: 0.3)) { toast = "" }
        }
    }

    private func handle(_ event: ControlEvent) {
        if hold.handle(event, player: model.player, toast: showToast) { return }
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: totalRows, delta: d, settings: settings)
        case .select:
            if selection == 0 {
                guard !tracks.isEmpty else { return }
                model.player.play(tracks)
                model.push(.nowPlaying)
            } else if selection == 1 {
                guard !tracks.isEmpty else { return }
                model.player.shufflePlay(tracks)
                model.push(.nowPlaying)
            } else {
                let idx = selection - headerItems.count
                if tracks.indices.contains(idx) {
                    model.player.play(tracks, startingAt: idx)
                    model.push(.nowPlaying)
                }
            }
        case .centerHold:
            // Hold a track row: queue options (Play Next / Add to Queue).
            let idx = selection - headerItems.count
            guard tracks.indices.contains(idx) else { break }
            WheelHaptics.shared.ensureRunning()
            WheelHaptics.shared.buttonPress(strength: 0.85)
            hold.begin(tracks[idx])
        case .menu:
            model.pop()
        default:
            break
        }
    }
}

/// Handoff for "View in Cover Flow": which album the flow should land on.
final class CoverFlowLaunch {
    static let shared = CoverFlowLaunch()
    var pendingAlbumID: String?
}
