import Foundation
import MusicKit

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
            let list = detailed.tracks?.compactMap { $0 as? Song } ?? []
            if !list.isEmpty { return list }
        }
        // Fallback: filter the cached song list by album title.
        return songs.filter { ($0.albumTitle ?? "") == album.title }
            .sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
    }

    func tracks(forPlaylist playlist: Playlist) async -> [Song] {
        if let detailed = try? await playlist.with([.tracks]) {
            return detailed.tracks?.compactMap { $0 as? Song } ?? []
        }
        return []
    }

    /// Songs of an album from the cached library (used by Cover Flow overlay).
    func cachedTracks(forAlbum album: Album) -> [Song] {
        songs.filter { ($0.albumTitle ?? "") == album.title }
            .sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
    }
}
