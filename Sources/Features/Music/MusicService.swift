import Foundation
import MusicKit
import os

/// Apple Music library access: one-time library fetch, cached in memory,
/// plus per-item lookups used by screens and the title bar.
@Observable
final class MusicService {
    private(set) var status: MusicAuthorization.Status = MusicAuthorization.currentStatus
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var songs: [Song] = []
    private(set) var playlists: [Playlist] = []
    private(set) var loaded = false
    private(set) var loading = false

    var isAuthorized: Bool { status == .authorized }

    func refreshStatus() {
        status = MusicAuthorization.currentStatus
    }

    func requestAccess() async {
        status = await MusicAuthorization.request()
        if isAuthorized { await loadLibrary() }
    }

    /// Loads the whole library once. Screens filter/slice the cached arrays.
    func loadLibrary() async {
        // QA hook: seed a deterministic fake library for simulator testing.
        let qaEnv = ProcessInfo.processInfo.environment["FAKE_LIBRARY"]
        Logger(subsystem: "com.ipodclassic.app", category: "qa").notice("loadLibrary entered, FAKE_LIBRARY=\(qaEnv ?? "nil", privacy: .public)")
        if qaEnv == "1" {
            seedFakeLibrary()
            loaded = true
            return
        }
        guard isAuthorized, !loading else { return }
        loading = true
        defer { loading = false }

        var fetchedAlbums = (try? await MusicLibraryRequest<Album>().response())?.items.compactMap { $0 } ?? []
        fetchedAlbums.sort { a, b in
            if a.artistName.localizedCaseInsensitiveCompare(b.artistName) != .orderedSame {
                return a.artistName.localizedCaseInsensitiveCompare(b.artistName) == .orderedAscending
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        albums = fetchedAlbums

        var fetchedArtists = (try? await MusicLibraryRequest<Artist>().response())?.items.compactMap { $0 } ?? []
        fetchedArtists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        artists = fetchedArtists

        var fetchedSongs = (try? await MusicLibraryRequest<Song>().response())?.items.compactMap { $0 } ?? []
        fetchedSongs.sort { a, b in
            if a.artistName.localizedCaseInsensitiveCompare(b.artistName) != .orderedSame {
                return a.artistName.localizedCaseInsensitiveCompare(b.artistName) == .orderedAscending
            }
            if (a.albumTitle ?? "").localizedCaseInsensitiveCompare(b.albumTitle ?? "") != .orderedSame {
                return (a.albumTitle ?? "").localizedCaseInsensitiveCompare(b.albumTitle ?? "") == .orderedAscending
            }
            return (a.trackNumber ?? 0) < (b.trackNumber ?? 0)
        }
        songs = fetchedSongs

        var fetchedPlaylists = (try? await MusicLibraryRequest<Playlist>().response())?.items.compactMap { $0 } ?? []
        fetchedPlaylists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        playlists = fetchedPlaylists

        clearMenuCaches()
        loaded = true
    }

    /// Deterministic fake library for wheel/scroll QA in the simulator.
    /// Song is immutable MusicKit data, so we can't construct real songs;
    /// QA uses the raw list shape instead via the UI. We instead fake the
    /// *screen-level* data path: titles/artists come from a JSON the tests
    /// can assert against. (Songs themselves stay empty — the songs screen
    /// builds MenuItems from `songs`, so for QA we construct Song-like
    /// placeholders is impossible; instead the fake library only fills
    /// albums/artists names. The scroll test asserts on row scrolling.)
    private func seedFakeLibrary() {
        QASeed.songs = (0..<300).map { i in
            QASeed.FakeSong(
                id: "qa.song.\(i)",
                title: String(format: "Song %03d", i),
                artist: "Artist \(i % 12)",
                album: "Album \(i / 10)",
                duration: Double(90 + i % 200)
            )
        }
        UserDefaults.standard.set(QASeed.songs.count, forKey: "qa.seed.count")
        loaded = true
    }

    // MARK: Lookups (used by ScreenRouter for titles)

    func album(_ id: String) -> Album? { albums.first { $0.id.rawValue == id } }
    func artist(_ id: String) -> Artist? { artists.first { $0.id.rawValue == id } }
    func playlist(_ id: String) -> Playlist? { playlists.first { $0.id.rawValue == id } }

    func albumTitle(_ id: String) -> String { album(id)?.title ?? "Album" }
    func artistName(_ id: String) -> String { artist(id)?.name ?? "Artist" }
    func playlistName(_ id: String) -> String { playlist(id)?.name ?? "Playlist" }

    /// Best-effort album lookup for a song (songs don't carry album ids; we
    /// match by title + artist).
    func album(forSong song: Song) -> Album? {
        albums.first { $0.title == song.albumTitle && $0.artistName == song.artistName }
            ?? albums.first { $0.title == song.albumTitle }
    }

    // MARK: Cached menu lists
    // Sorting + MenuItem construction over a whole library is expensive;
    // doing it per wheel tick froze scrolling on large libraries. Caches
    // are keyed by (sort option, library count) and rebuilt only when
    // either changes.

    private var songsMenuCache: (sort: Int, count: Int, items: [MenuItem])?
    private var albumsMenuCache: (sort: Int, count: Int, items: [MenuItem])?
    private var artistsMenuCache: (count: Int, items: [MenuItem])?
    private var playlistsMenuCache: (count: Int, items: [MenuItem])?
    private var genresMenuCache: (count: Int, items: [MenuItem])?
    private var recentMenuCache: (count: Int, items: [MenuItem])?

    func clearMenuCaches() {
        songsMenuCache = nil
        albumsMenuCache = nil
        artistsMenuCache = nil
        playlistsMenuCache = nil
        genresMenuCache = nil
        recentMenuCache = nil
    }

    /// Songs sorted by 0 Title / 1 Artist / 2 Duration / 3 Recently Added,
    /// with an id tiebreaker (Swift's sort is not stable).
    func songsSorted(by sort: Int) -> [Song] {
        let list = songs
        func stable(_ key: (Song) -> String) -> [Song] {
            list.sorted { a, b in
                let ka = key(a).lowercased(), kb = key(b).lowercased()
                if ka == kb { return a.id.rawValue < b.id.rawValue }
                return ka < kb
            }
        }
        switch sort {
        case 1: return stable { $0.artistName }
        case 2: return list.sorted { ($0.duration ?? 0) != ($1.duration ?? 0) ? ($0.duration ?? 0) < ($1.duration ?? 0) : $0.id.rawValue < $1.id.rawValue }
        case 3: return list.sorted { ($0.releaseDate ?? .distantPast) != ($1.releaseDate ?? .distantPast) ? ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) : $0.id.rawValue < $1.id.rawValue }
        default: return stable { $0.title }
        }
    }

    /// Albums sorted by 0 Title / 1 Artist / 2 Recently Added.
    func albumsSorted(by sort: Int) -> [Album] {
        let list = albums
        func stable(_ key: (Album) -> String) -> [Album] {
            list.sorted { a, b in
                let ka = key(a).lowercased(), kb = key(b).lowercased()
                if ka == kb { return a.id.rawValue < b.id.rawValue }
                return ka < kb
            }
        }
        switch sort {
        case 1: return stable { $0.artistName }
        case 2: return list.sorted { ($0.libraryAddedDate ?? .distantPast) != ($1.libraryAddedDate ?? .distantPast) ? ($0.libraryAddedDate ?? .distantPast) > ($1.libraryAddedDate ?? .distantPast) : $0.id.rawValue < $1.id.rawValue }
        default: return stable { $0.title }
        }
    }

    func songsMenuItems(sort: Int) -> [MenuItem] {
        if let c = songsMenuCache, c.sort == sort, c.count == songs.count { return c.items }
        let items = songsSorted(by: sort).map { MenuItem(id: $0.id.rawValue, title: $0.title, subtitle: $0.artistName, showsChevron: false) }
        songsMenuCache = (sort, songs.count, items)
        return items
    }

    func albumsMenuItems(sort: Int) -> [MenuItem] {
        if let c = albumsMenuCache, c.sort == sort, c.count == albums.count { return c.items }
        let items = albumsSorted(by: sort).map { MenuItem(id: $0.id.rawValue, title: $0.title, subtitle: $0.artistName) }
        albumsMenuCache = (sort, albums.count, items)
        return items
    }

    func artistsMenuItems() -> [MenuItem] {
        if let c = artistsMenuCache, c.count == artists.count { return c.items }
        let items = artists
            .sorted { $0.name.lowercased() != $1.name.lowercased() ? $0.name.lowercased() < $1.name.lowercased() : $0.id.rawValue < $1.id.rawValue }
            .map { MenuItem(id: $0.id.rawValue, title: $0.name) }
        artistsMenuCache = (artists.count, items)
        return items
    }

    func playlistsMenuItems() -> [MenuItem] {
        if let c = playlistsMenuCache, c.count == playlists.count { return c.items }
        let items = playlists
            .sorted { $0.name.lowercased() != $1.name.lowercased() ? $0.name.lowercased() < $1.name.lowercased() : $0.id.rawValue < $1.id.rawValue }
            .map { MenuItem(id: $0.id.rawValue, title: $0.name) }
        playlistsMenuCache = (playlists.count, items)
        return items
    }

    func genresMenuItems() -> [MenuItem] {
        if let c = genresMenuCache, c.count == albums.count { return c.items }
        let items = genres
            .sorted { $0.lowercased() != $1.lowercased() ? $0.lowercased() < $1.lowercased() : $0 < $1 }
            .map { MenuItem(id: $0, title: $0) }
        genresMenuCache = (albums.count, items)
        return items
    }

    func recentMenuItems() -> [MenuItem] {
        if let c = recentMenuCache, c.count == albums.count { return c.items }
        let items = recentlyAdded.map { MenuItem(id: $0.id.rawValue, title: $0.title, subtitle: $0.artistName) }
        recentMenuCache = (albums.count, items)
        return items
    }

    // MARK: Collections

    func albums(byArtist artist: Artist) -> [Album] {
        albums.filter { $0.artistName.caseInsensitiveCompare(artist.name) == .orderedSame }
    }

    func albums(inGenre genre: String) -> [Album] {
        albums.filter { $0.genreNames.contains(genre) }
            .sorted { $0.artistName.localizedCaseInsensitiveCompare($1.artistName) == .orderedAscending }
    }

    var genres: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for album in albums {
            for genre in album.genreNames where !seen.contains(genre) {
                seen.insert(genre)
                out.append(genre)
            }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var recentlyAdded: [Album] {
        albums.sorted { a, b in
            let ad = a.libraryAddedDate ?? .distantPast
            let bd = b.libraryAddedDate ?? .distantPast
            if ad != bd { return ad > bd }
            return a.artistName.localizedCaseInsensitiveCompare(b.artistName) == .orderedAscending
        }
    }

    /// Album tracks via the album relation (correct order, includes guests).
    func tracks(forAlbum album: Album) async -> [Song] {
        if let detailed = try? await album.with([.tracks]) {
            let list = Self.songs(from: detailed.tracks)
            if !list.isEmpty { return list }
        }
        // Fallback: filter the cached song list by album title.
        return songs.filter { ($0.albumTitle ?? "") == album.title }
            .sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
    }

    func tracks(forPlaylist playlist: Playlist) async -> [Song] {
        if let detailed = try? await playlist.with([.tracks]) {
            let list = Self.songs(from: detailed.tracks)
            if !list.isEmpty { return list }
        }
        // Fallback: re-fetch from the library with tracks included.
        var req = MusicLibraryRequest<Playlist>()
        req.filter(matching: \.id, equalTo: playlist.id)
        if let found = try? await req.response().items.first,
           let detailed = try? await found.with([.tracks]) {
            return Self.songs(from: detailed.tracks)
        }
        return []
    }

    /// Playlist.Track / Album.Track is an enum (song | musicVideo) — the
    /// `as? Song` cast NEVER matches; pattern-match instead.
    private static func songs(from tracks: MusicItemCollection<Track>?) -> [Song] {
        tracks?.compactMap { track in
            if case let .song(song) = track { return song }
            return nil
        } ?? []
    }

    /// Songs of an album from the cached library (used by Cover Flow overlay).
    func cachedTracks(forAlbum album: Album) -> [Song] {
        songs.filter { ($0.albumTitle ?? "") == album.title }
            .sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
    }
}
