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
            MenuItem(id: "coverflow", title: "Cover Flow"),
            MenuItem(id: "playlists", title: "Playlists"),
            MenuItem(id: "artists", title: "Artists"),
            MenuItem(id: "albums", title: "Albums"),
            MenuItem(id: "songs", title: "Songs"),
            MenuItem(id: "genres", title: "Genres"),
            MenuItem(id: "recent", title: "Recent"),
            MenuItem(id: "search", title: "Search", symbol: "magnifyingglass", showsChevron: false, isActionRow: true),
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
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.inkDim)
                Text("Loading Library…")
                    .font(.system(size: 13, weight: .semibold))
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
            .font(.system(size: 34))
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
                .font(.system(size: 30))
                .foregroundStyle(Theme.inkDim)
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
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
struct MusicListScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    let kind: MusicListKind

    @State private var selection = 0

    private static let songSortLabels = ["Title", "Artist", "Duration", "Recently Added"]
    private static let albumSortLabels = ["Title", "Artist", "Recently Added"]

    // MARK: Entries (sorted)

    /// Swift's sort isn't stable — without an id tiebreaker, equal-keyed
    /// rows reshuffled under the selection on every wheel tick, which felt
    /// like broken scrolling in All Songs.
    private func sortedBy<T>(_ list: [T], key: (T) -> String, descending: Bool = false) -> [T] {
        func idOf(_ x: T) -> String {
            (x as? Song)?.id.rawValue ?? (x as? Album)?.id.rawValue ?? "\(x as? String ?? "")" + String(describing: x)
        }
        return list.sorted { a, b in
            let ka = key(a).lowercased(), kb = key(b).lowercased()
            if ka == kb { return idOf(a) < idOf(b) }
            return descending ? ka > kb : ka < kb
        }
    }

    private var sortedSongs: [Song] {
        let list = model.music.songs
        guard kind == .songs else { return list }
        switch settings.songSort {
        case 1: return sortedBy(list, key: { $0.artistName })
        case 2: return list.sorted { ($0.duration ?? 0) != ($1.duration ?? 0) ? ($0.duration ?? 0) < ($1.duration ?? 0) : $0.id.rawValue < $1.id.rawValue }
        case 3: return list.sorted { ($0.releaseDate ?? .distantPast) != ($1.releaseDate ?? .distantPast) ? ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) : $0.id.rawValue < $1.id.rawValue }
        default: return sortedBy(list, key: { $0.title })
        }
    }

    private var sortedAlbums: [Album] {
        let list = kind == .recent ? model.music.recentlyAdded : model.music.albums
        guard kind == .albums else { return list }
        switch settings.albumSort {
        case 1: return sortedBy(list, key: { $0.artistName })
        case 2: return list.sorted { ($0.releaseDate ?? .distantPast) != ($1.releaseDate ?? .distantPast) ? ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) : $0.id.rawValue < $1.id.rawValue }
        default: return sortedBy(list, key: { $0.title })
        }
    }

    private var entryItems: [MenuItem] {
        switch kind {
        case .artists:
            return model.music.artists
                .sorted { $0.name.lowercased() != $1.name.lowercased() ? $0.name.lowercased() < $1.name.lowercased() : $0.id.rawValue < $1.id.rawValue }
                .map { MenuItem(id: $0.id.rawValue, title: $0.name) }
        case .albums:
            return sortedAlbums.map { MenuItem(id: $0.id.rawValue, title: $0.title, subtitle: $0.artistName) }
        case .songs:
            return sortedSongs.map { MenuItem(id: $0.id.rawValue, title: $0.title, subtitle: $0.artistName, showsChevron: false) }
        case .genres:
            return model.music.genres
                .sorted { $0.lowercased() != $1.lowercased() ? $0.lowercased() < $1.lowercased() : $0 < $1 }
                .map { MenuItem(id: $0, title: $0) }
        case .playlists:
            return model.music.playlists
                .sorted { $0.name.lowercased() != $1.name.lowercased() ? $0.name.lowercased() < $1.name.lowercased() : $0.id.rawValue < $1.id.rawValue }
                .map { MenuItem(id: $0.id.rawValue, title: $0.name) }
        case .recent:
            return model.music.recentlyAdded.map { MenuItem(id: $0.id.rawValue, title: $0.title, subtitle: $0.artistName) }
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

    private var allItems: [MenuItem] { headerItems + entryItems }

    var body: some View {
        MenuList(
            items: allItems,
            selection: selection,
            style: listStyle
        ) { item in
            // Thumbnails resolve by album id; only thumbnail-style lists render them.
            model.music.album(item.id)?.artwork
        }
        .onWheel { handle($0) }
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
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: allItems.count, delta: d, settings: settings)
        case .select:
            if selection < headerItems.count {
                activateHeader(headerItems[selection].id)
            } else {
                selectEntry(at: selection - headerItems.count)
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

    private var album: Album? { model.music.album(albumID) }

    var body: some View {
        list
            .onWheel { handle($0) }
            .task(id: albumID) {
                if let album {
                    tracks = await model.music.tracks(forAlbum: album)
                }
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

    @ViewBuilder
    private var list: some View {
        GeometryReader { geo in
            let rowH: CGFloat = 47
            let visible = max(1, Int((geo.size.height / rowH).rounded(.down)))
            let start = max(0, min(selection - max(0, visible - 3), max(0, totalRows - visible)))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(0..<min(headerItems.count, max(0, totalRows - start)), id: \.self) { i in
                        if start <= i && i < start + visible {
                            MenuRow(item: headerItems[i], selected: selection == i, compact: true)
                                .frame(height: 33)
                        }
                    }
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, song in
                        let row = headerItems.count + i
                        if row >= start && row < start + visible {
                            MenuRow(
                                item: trackItems[i],
                                selected: selection == row,
                                compact: true,
                                style: .thumbnail,
                                thumb: album?.artwork
                            )
                            .frame(height: rowH)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: totalRows, delta: d, settings: settings)
        case .select:
            activateCurrent()
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

    private var playlist: Playlist? { model.music.playlist(playlistID) }

    private var headerItems: [MenuItem] {
        [
            MenuItem(id: "hdr.play", title: "Play All", symbol: "play.fill", showsChevron: false, isActionRow: true),
            MenuItem(id: "hdr.shuffle", title: "Shuffle All", symbol: "shuffle", showsChevron: false, isActionRow: true),
        ]
    }
    private var totalRows: Int { headerItems.count + tracks.count }

    var body: some View {
        MenuList(
            items: headerItems + tracks.enumerated().map { i, s in
                MenuItem(id: s.id.rawValue, title: s.title, subtitle: s.artistName, showsChevron: false)
            },
            selection: selection, emptyText: "No Songs", style: .twoLine
        )
        .onWheel { handle($0) }
        .task(id: playlistID) {
            if let playlist {
                tracks = await model.music.tracks(forPlaylist: playlist)
            }
        }
    }

    private func handle(_ event: ControlEvent) {
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
