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

/// Wheel-driven list over one library section.
struct MusicListScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    let kind: MusicListKind

    @State private var selection = 0

    var body: some View {
        listBody
            .onWheel { handle($0) }
    }

    @ViewBuilder
    private var listBody: some View {
        switch kind {
        case .artists:
            MenuList(
                items: model.music.artists.map { MenuItem(id: $0.id.rawValue, title: $0.name) },
                selection: selection, compact: false, style: .normal
            )
        case .albums:
            MenuList(
                items: model.music.albums.map { al in
                    MenuItem(id: al.id.rawValue, title: al.title, subtitle: al.artistName)
                },
                selection: selection, style: .thumbnail
            ) { item in
                model.music.album(item.id)?.artwork
            }
        case .songs:
            MenuList(
                items: model.music.songs.map { s in
                    MenuItem(id: s.id.rawValue, title: s.title, subtitle: s.artistName)
                },
                selection: selection, style: .twoLine
            )
        case .genres:
            MenuList(
                items: model.music.genres.map { MenuItem(id: $0, title: $0) },
                selection: selection, style: .normal
            )
        case .playlists:
            MenuList(
                items: model.music.playlists.map { MenuItem(id: $0.id.rawValue, title: $0.name) },
                selection: selection, style: .normal
            )
        case .recent:
            MenuList(
                items: model.music.recentlyAdded.map { al in
                    MenuItem(id: al.id.rawValue, title: al.title, subtitle: al.artistName)
                },
                selection: selection, style: .thumbnail
            ) { item in
                model.music.album(item.id)?.artwork
            }
        }
    }

    private var count: Int {
        switch kind {
        case .artists: return model.music.artists.count
        case .albums: return model.music.albums.count
        case .songs: return model.music.songs.count
        case .genres: return model.music.genres.count
        case .playlists: return model.music.playlists.count
        case .recent: return model.music.recentlyAdded.count
        }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: count, delta: d, settings: settings)
        case .select:
            selectCurrent()
        case .menu:
            model.pop()
        default:
            break
        }
    }

    private func selectCurrent() {
        guard count > 0 else { return }
        let idx = selection
        switch kind {
        case .artists:
            let artist = model.music.artists[idx]
            model.push(.artistDetail(artist.id.rawValue))
        case .albums, .recent:
            let album = kind == .albums ? model.music.albums[idx] : model.music.recentlyAdded[idx]
            model.push(.albumDetail(album.id.rawValue))
        case .songs:
            let songs = model.music.songs
            model.player.play(songs, startingAt: idx)
            model.push(.nowPlaying)
        case .genres:
            model.push(.genreAlbums(model.music.genres[idx]))
        case .playlists:
            let pl = model.music.playlists[idx]
            model.push(.playlistDetail(pl.id.rawValue))
        }
    }
}

/// Albums by one artist.
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

    var body: some View {
        MenuList(
            items: albums.map { al in MenuItem(id: al.id.rawValue, title: al.title, subtitle: "\(al.trackCount) Songs") },
            selection: selection, style: .thumbnail
        ) { item in
            model.music.album(item.id)?.artwork
        }
        .onWheel { handle($0) }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: albums.count, delta: d, settings: settings)
        case .select:
            if albums.indices.contains(selection) {
                model.push(.albumDetail(albums[selection].id.rawValue))
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}

/// Albums in one genre.
struct GenreAlbumsScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    let genre: String
    @State private var selection = 0

    private var albums: [Album] { model.music.albums(inGenre: genre) }

    var body: some View {
        MenuList(
            items: albums.map { al in MenuItem(id: al.id.rawValue, title: al.title, subtitle: al.artistName) },
            selection: selection, style: .thumbnail
        ) { item in
            model.music.album(item.id)?.artwork
        }
        .onWheel { handle($0) }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: albums.count, delta: d, settings: settings)
        case .select:
            if albums.indices.contains(selection) {
                model.push(.albumDetail(albums[selection].id.rawValue))
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
            MenuItem(id: "header.coverflow", title: "View in Cover Flow", symbol: "rectangle.stack", showsChevron: false),
            MenuItem(id: "header.shuffle", title: "Shuffle Songs", symbol: "shuffle", showsChevron: false),
        ]
    }

    private var trackItems: [MenuItem] {
        tracks.enumerated().map { i, s in
            MenuItem(id: "track.\(s.id.rawValue)", title: s.title, subtitle: s.artistName)
        }
    }

    private var totalRows: Int { headerItems.count + tracks.count }

    @ViewBuilder
    private var list: some View {
        GeometryReader { geo in
            let rowH: CGFloat = 44
            let visible = max(1, Int((geo.size.height / rowH).rounded(.down)))
            let start = max(0, min(selection - max(0, visible - 3), max(0, totalRows - visible)))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(0..<min(headerItems.count, max(0, totalRows - start)), id: \.self) { i in
                        if start <= i && i < start + visible {
                            MenuRow(item: headerItems[i], selected: selection == i, compact: true)
                                .frame(height: 30.5)
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
        if selection == 0 {
            CoverFlowLaunch.shared.pendingAlbumID = albumID
            model.push(.coverFlow)
        } else if selection == 1 {
            model.player.shufflePlay(tracks.isEmpty ? model.music.songs : tracks)
            model.push(.nowPlaying)
        } else {
            let idx = selection - 2
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

    var body: some View {
        MenuList(
            items: tracks.enumerated().map { i, s in
                MenuItem(id: s.id.rawValue, title: s.title, subtitle: s.artistName)
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
            moveListSelection(&selection, count: tracks.count, delta: d, settings: settings)
        case .select:
            if tracks.indices.contains(selection) {
                model.player.play(tracks, startingAt: selection)
                model.push(.nowPlaying)
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
