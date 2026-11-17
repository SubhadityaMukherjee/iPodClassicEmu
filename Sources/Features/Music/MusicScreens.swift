import SwiftUI
import MusicKit

/// Music root: split menu (Cover Flow, Playlists, Artists, …) with an
/// artwork preview pane on the right.
struct MusicMenuScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    /// Highlighted menu row.
    @State private var selection = 0

    /// The fixed Music menu rows; row ids are matched in `select()`.
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

    /// Split menu with the artwork preview pane; loads (or refreshes) the
    /// library on appear.
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

    /// Wheel input: ticks move the selection, center activates, MENU pops.
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

    /// Pushes the route matching the highlighted row.
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

    /// Right-hand pane: artwork previewing the highlighted section — the
    /// first playlist's, artist's, album's, genre's, or recently added
    /// cover, or the now-playing track's artwork. Anything missing falls
    /// back to a dimmed symbol so the pane never renders blank.
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

    /// One piece of artwork at pane scale, or the music-note fallback when
    /// the artwork is nil.
    @ViewBuilder
    private func artworkPreview(_ artwork: Artwork?) -> some View {
        if let artwork {
            ArtworkView(artwork: artwork, width: 300, height: 300)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            fallback("music.note")
        }
    }

    /// Dimmed, centered SF Symbol used when a section has nothing to show.
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

    /// Symbol over a short message, centered in the preview pane.
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

    /// The song (or QA title) whose options are showing; nil = closed.
    private(set) var pending: Pending?
    /// Highlighted row of the three-row panel.
    private(set) var selection = 0

    /// True while the Song Options panel is up.
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

    /// Opens the panel for a real song, resetting the selection.
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

    /// The modal "Song Options" panel: Play Next / Add to Queue / Cancel.
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

/// One library section as a wheel-driven list: Play All / Shuffle All
/// (plus Sort By where sortable) header rows above the entries,
/// letter-snap fast scrolling on big lists, and hold-center queue options
/// on song rows via the shared `SongHoldState`.
struct MusicListScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    /// Which library section this instance shows.
    let kind: MusicListKind

    /// Highlighted row, headers included.
    @State private var selection = 0
    /// Transient confirmation message ("Playing Next", …).
    @State private var toast = ""
    /// Hold-center song options (shared panel + input handler).
    @State private var hold = SongHoldState()
    // Letter snapping: a fast spin (≥5 net ticks inside 0.4 s) jumps the
    // selection to the next letter group instead of crawling row by row,
    // with the classic big-letter overlay while it's active.
    /// Net wheel ticks in the current burst — the letter-snap detector.
    @State private var tickBurst = 0
    /// Timestamp of the most recent tick (defines the 0.4 s burst window).
    @State private var lastTickAt = Date.distantPast
    /// The big letter shown while snapping; nil while hidden.
    @State private var letterOverlay: String?
    /// Cancelable delayed hide of the letter overlay (replaced per snap).
    @State private var letterHideWork: DispatchWorkItem?

    /// Labels the Songs Sort By header cycles through.
    private static let songSortLabels = ["Title", "Artist", "Duration", "Recently Added"]
    /// Labels the Albums Sort By header cycles through.
    private static let albumSortLabels = ["Title", "Artist", "Recently Added"]

    // MARK: Entries (sorted) — cached in MusicService; see songsMenuItems.

    /// Songs in the active sort (Songs list only; other kinds don't sort).
    private var sortedSongs: [Song] {
        guard kind == .songs else { return model.music.songs }
        return model.music.songsSorted(by: settings.songSort)
    }

    /// Albums for this list: recently-added order for Recents, the active
    /// sort for Albums.
    private var sortedAlbums: [Album] {
        let list = kind == .recent ? model.music.recentlyAdded : model.music.albums
        guard kind == .albums else { return list }
        return model.music.albumsSorted(by: settings.albumSort)
    }

    /// The list's rows, served from the matching MusicService menu cache.
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

    /// Full-width action rows: Play All, Shuffle All, plus Sort By for the
    /// sortable kinds.
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

    /// Sort option labels for sortable kinds; nil when the kind can't sort.
    private var sortLabels: [String]? {
        switch kind {
        case .songs: return Self.songSortLabels
        case .albums: return Self.albumSortLabels
        default: return nil
        }
    }

    /// Current sort as an index into `sortLabels` (from settings).
    private var sortIndex: Int {
        kind == .songs ? settings.songSort : settings.albumSort
    }

    /// Header + entry rows in one array — the list's row source.
    ///
    /// Concept: SwiftUI views & state → docs/concepts/swiftui-views-and-state.md
    private var allItems: [MenuItem] {
        // Read `loaded` so the list re-renders when the async library load
        // completes (the QA seed path touches no observable otherwise).
        _ = model.music.loaded
        return headerItems + entryItems
    }

    /// The list with overlays layered above: snap letter, toast, hold panel.
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
            if let letter = letterOverlay {
                Text(letter)
                    .font(.system(size: 50, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 76, height: 76)
                    .background(Capsule().fill(Color.white.opacity(0.92)))
                    .overlay(Capsule().stroke(Theme.inkDim.opacity(0.4), lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 16)
                    .zIndex(1)
                    .allowsHitTesting(false)
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

    /// Letter snapping only on the big alphabetical lists (songs, albums,
    /// artists).
    private var letterSnapEnabled: Bool {
        kind == .songs || kind == .albums || kind == .artists
    }

    /// Jumps to the next letter group in `d`'s direction and shows the
    /// classic letter overlay. Returns false when the row can't snap
    /// (edge of the list) so the caller falls back to a normal move.
    private func snapToLetter(by d: Int) -> Bool {
        let titles = entryItems.map(\.title)
        let entry = selection - headerItems.count
        guard titles.indices.contains(entry),
              let target = Self.letterSnapTarget(titles: titles, from: entry, dir: d)
        else { return false }
        selection = target + headerItems.count
        letterOverlay = titles[target].first.map { String($0).uppercased() } ?? "#"
        WheelFeedback.tick(dir: d)
        letterHideWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.25)) { letterOverlay = nil }
        }
        letterHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        return true
    }

    /// Index of the next row whose leading letter differs from
    /// `titles[index]`'s, scanning in `dir`; nil at the edge.
    nonisolated static func letterSnapTarget(titles: [String], from index: Int, dir: Int) -> Int? {
        guard titles.indices.contains(index) else { return nil }
        /// First-letter grouping key for the list's letter index: the
    /// uppercased first character, or "#" when the title is empty.
    func key(_ s: String) -> String { s.first.map { String($0).uppercased() } ?? "#" }
        let current = key(titles[index])
        var i = index
        while true {
            let next = i + dir
            guard titles.indices.contains(next) else { return nil }
            if key(titles[next]) != current { return next }
            i = next
        }
    }

    /// Shows a transient toast, auto-hiding after 1.6 s.
    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeIn(duration: 0.3)) { toast = "" }
        }
    }

    /// Row style per section: artwork thumbnails for albums/recent,
    /// two-line (title + artist) for songs.
    private var listStyle: MenuRowStyle {
        switch kind {
        case .albums, .recent: return .thumbnail
        case .songs: return .twoLine
        default: return .normal
        }
    }

    /// Wheel input for the list.
    ///
    /// The hold panel consumes events first while open. Ticks letter-snap
    /// on a fast burst, otherwise move row by row; center activates the
    /// highlighted header/entry; center-hold on a song row opens the
    /// queue-options panel; MENU pops.
    private func handle(_ event: ControlEvent) {
        if hold.handle(event, player: model.player, toast: showToast) { return }
        switch event {
        case .tick(let d):
            let now = Date()
            tickBurst = now.timeIntervalSince(lastTickAt) <= 0.4 ? tickBurst + d : d
            lastTickAt = now
            if letterSnapEnabled, abs(tickBurst) >= 5, snapToLetter(by: d) { break }
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

    /// Runs a header action: Play All / Shuffle All play `allSongs` and
    /// push Now Playing; Sort By cycles the setting with a light haptic.
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

    /// Activates the highlighted entry: pushes the matching detail screen,
    /// or (Songs) plays from that track and pushes Now Playing.
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
    /// Raw MusicKit ID of the artist this page shows.
    let artistID: String
    /// Highlighted row (headers included).
    @State private var selection = 0
    /// Songs behind Play All / Shuffle All, loaded async — the cached
    /// library songs fill LAST during loadLibrary, so deriving them
    /// synchronously from the cache silently no-op'd (the tap did
    /// nothing) when the page opened mid-load.
    @State private var songs: [Song] = []

    /// The cached Artist for `artistID`, nil if it's gone from the library.
    private var artist: Artist? { model.music.artist(artistID) }
    /// This artist's albums from the cache.
    private var albums: [Album] {
        guard let artist else { return [] }
        return model.music.albums(byArtist: artist)
    }
    /// Play All / Shuffle All / Search action rows.
    private var headerItems: [MenuItem] {
        [
            MenuItem(id: "hdr.play", title: "Play All", symbol: "play.fill", showsChevron: false, isActionRow: true),
            MenuItem(id: "hdr.shuffle", title: "Shuffle All", symbol: "shuffle", showsChevron: false, isActionRow: true),
            MenuItem(id: "hdr.search", title: "Search", symbol: "magnifyingglass"),
        ]
    }
    /// Headers + albums (the selection's clamp bound).
    private var totalRows: Int { headerItems.count + albums.count }

    /// Thumbnail album list with headers; loads the Play All songs async.
    var body: some View {
        MenuList(
            items: headerItems + albums.map { al in MenuItem(id: al.id.rawValue, title: al.title, subtitle: "\(al.trackCount) Songs") },
            selection: selection, style: .thumbnail
        ) { item in
            model.music.album(item.id)?.artwork
        }
        .onWheel { handle($0) }
        .task(id: artistID) {
            guard let artist else { return }
            songs = await model.music.songs(forArtist: artist)
        }
    }

    /// Wheel input: rows 0–1 play all / shuffle the songs, row 2 opens
    /// Search, an album opens its page; MENU pops.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: totalRows, delta: d, settings: settings)
        case .select:
            if selection == 0 {
                guard !songs.isEmpty else { return }
                model.player.play(songs)
                model.push(.nowPlaying)
            } else if selection == 1 {
                guard !songs.isEmpty else { return }
                model.player.shufflePlay(songs)
                model.push(.nowPlaying)
            } else if selection == 2 {
                model.push(.artistSearch(artistID))
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

/// Search limited to one artist's songs (Search row on the artist page):
/// touch keyboard, wheel-driven results; select plays from the result.
struct ArtistSearchScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    /// Raw MusicKit ID of the artist whose songs are searched.
    let artistID: String

    /// Live query text from the touch keyboard.
    @State private var query = ""
    /// Highlighted result row.
    @State private var selection = 0
    /// Keyboard focus; while focused, MENU dismisses the keyboard instead
    /// of popping the screen.
    ///
    /// Concept: property wrappers → docs/concepts/swift-property-wrappers.md
    @FocusState private var focused: Bool
    /// The artist's songs, loaded async — deriving them from the cache
    /// synchronously no-ops when the page opens mid-library-load (see
    /// ArtistDetailScreen).
    @State private var songs: [Song] = []

    /// Ranked title matches within the artist; album title as fallback.
    private var results: [Song] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var titleStart: [Song] = []
        var titleContains: [Song] = []
        var albumMatch: [Song] = []
        for s in songs {
            let t = s.title.lowercased()
            if t.hasPrefix(q) {
                titleStart.append(s)
            } else if t.contains(q) {
                titleContains.append(s)
            } else if (s.albumTitle ?? "").lowercased().contains(q) {
                albumMatch.append(s)
            }
        }
        return titleStart + titleContains + albumMatch
    }

    /// Search field above the ranked results; focus is delayed until the
    /// push transition settles.
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(Theme.font(13, .semibold))
                    .foregroundStyle(Theme.inkDim)
                TextField("Search \(model.music.artistName(artistID))", text: $query)
                    .focused($focused)
                    .font(Theme.font(15, .medium))
                    .foregroundStyle(Theme.ink)
                    .submitLabel(.search)
                    .padding(.vertical, 4)
                    // Dark keyboard without global appearance proxies
                    // (those crash the input assistant's layout engine).
                    .environment(\.colorScheme, .dark)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Theme.font(13))
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
            // Keep the selection inside the shrinking result list, or the
            // wheel would be stuck at an out-of-range index (could not scroll).
            .onChange(of: query) {
                if selection >= results.count {
                    selection = max(0, results.count - 1)
                }
            }

            MenuList(
                items: results.map { s in
                    MenuItem(id: s.id.rawValue, title: s.title, subtitle: s.albumTitle ?? "", showsChevron: false)
                },
                selection: selection,
                emptyText: query.isEmpty ? "Type to search" : "No Results",
                style: .twoLine
            )
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 4)
        .onWheel { handle($0) }
        .task(id: artistID) {
            guard let artist = model.music.artist(artistID) else { return }
            songs = await model.music.songs(forArtist: artist)
        }
        .onAppear {
            // Focusing during the push transition corrupts the layout engine
            // (SIGABRT in NSISEngine) — wait for the transition to settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                focused = true
            }
        }
        .onDisappear { focused = false }
    }

    /// Wheel input: ticks move through the results (only with a query),
    /// center plays from the selection, MENU unfocuses before popping.
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

/// Albums in one genre, with full-width Play/Shuffle headers.
struct GenreAlbumsScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    /// Genre name this page lists albums for.
    let genre: String
    /// Highlighted row (headers included).
    @State private var selection = 0
    /// Songs behind Play All / Shuffle All, loaded async (see
    /// ArtistDetailScreen — sync cache derivation no-op'd mid-load).
    @State private var songs: [Song] = []

    /// Albums tagged with this genre, artist-sorted.
    private var albums: [Album] { model.music.albums(inGenre: genre) }
    /// Play All / Shuffle All action rows.
    private var headerItems: [MenuItem] {
        [
            MenuItem(id: "hdr.play", title: "Play All", symbol: "play.fill", showsChevron: false, isActionRow: true),
            MenuItem(id: "hdr.shuffle", title: "Shuffle All", symbol: "shuffle", showsChevron: false, isActionRow: true),
        ]
    }

    /// Thumbnail album list with Play/Shuffle headers; loads the genre's
    /// songs async.
    var body: some View {
        MenuList(
            items: headerItems + albums.map { al in MenuItem(id: al.id.rawValue, title: al.title, subtitle: al.artistName) },
            selection: selection, style: .thumbnail
        ) { item in
            model.music.album(item.id)?.artwork
        }
        .onWheel { handle($0) }
        .task(id: genre) {
            songs = await model.music.tracks(forGenre: genre)
        }
    }

    /// Wheel input: the headers play/shuffle the genre, an album opens its
    /// page; MENU pops.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: headerItems.count + albums.count, delta: d, settings: settings)
        case .select:
            if selection == 0 {
                guard !songs.isEmpty else { return }
                model.player.play(songs)
                model.push(.nowPlaying)
            } else if selection == 1 {
                guard !songs.isEmpty else { return }
                model.player.shufflePlay(songs)
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
    /// Raw MusicKit ID of the album this page shows.
    let albumID: String

    /// Highlighted row (headers included).
    @State private var selection = 0
    /// The album's tracks, loaded async on appear.
    @State private var tracks: [Song] = []
    /// Transient confirmation message.
    @State private var toast = ""
    /// Hold-center track options (shared panel).
    @State private var hold = SongHoldState()

    /// The cached Album for `albumID`, nil if it's gone from the library.
    private var album: Album? { model.music.album(albumID) }

    /// Classic album page: action headers above the thumbnail track list,
    /// with toast and hold panel layered above.
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
            .onAppear {
                // Recents: continuing this album from home.
                model.recents.record(album: .init(id: albumID, title: model.music.albumTitle(albumID)))
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

    /// Shows a transient toast, auto-hiding after 1.6 s.
    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeIn(duration: 0.3)) { toast = "" }
        }
    }

    /// View in Cover Flow / Play All / Shuffle Songs action rows.
    private var headerItems: [MenuItem] {
        [
            MenuItem(id: "header.coverflow", title: "View in Cover Flow", symbol: "rectangle.stack", showsChevron: false, isActionRow: true),
            MenuItem(id: "header.play", title: "Play All", symbol: "play.fill", showsChevron: false, isActionRow: true),
            MenuItem(id: "header.shuffle", title: "Shuffle Songs", symbol: "shuffle", showsChevron: false, isActionRow: true),
        ]
    }

    /// Track rows; ids are "track.<songID>" so the thumbnail closure can
    /// give tracks (and only tracks) the album art.
    private var trackItems: [MenuItem] {
        tracks.enumerated().map { i, s in
            MenuItem(id: "track.\(s.id.rawValue)", title: s.title, subtitle: s.artistName, showsChevron: false)
        }
    }

    /// Headers + tracks (the selection's clamp bound).
    private var totalRows: Int { headerItems.count + tracks.count }

    /// Wheel input: the hold panel consumes events first; ticks move;
    /// center activates; center-hold on a track opens queue options;
    /// MENU pops.
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

    /// Center press: row 0 hands the album to Cover Flow, rows 1–2 play or
    /// shuffle the tracks (guarded until they load — playing the whole
    /// library instead was a bug, not a fallback), a track row plays from
    /// that track.
    private func activateCurrent() {
        guard let album else { return }
        switch selection {
        case 0:
            CoverFlowLaunch.shared.pendingAlbumID = albumID
            model.push(.coverFlow)
        case 1:
            // Guard like PlaylistDetail: playing the whole library because
            // this album's tracks hadn't finished loading was a surprise,
            // not a fallback.
            guard !tracks.isEmpty else { return }
            model.player.play(tracks)
            model.push(.nowPlaying)
        case 2:
            guard !tracks.isEmpty else { return }
            model.player.shufflePlay(tracks)
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
    /// Raw MusicKit ID of the playlist this page shows.
    let playlistID: String

    /// Highlighted row (headers included).
    @State private var selection = 0
    /// The playlist's tracks, loaded async on appear.
    @State private var tracks: [Song] = []
    /// Transient confirmation message.
    @State private var toast = ""
    /// Hold-center track options (shared panel).
    @State private var hold = SongHoldState()

    /// The cached Playlist for `playlistID`, nil if it's gone from the
    /// library.
    private var playlist: Playlist? { model.music.playlist(playlistID) }

    /// Play All / Shuffle All action rows.
    private var headerItems: [MenuItem] {
        [
            MenuItem(id: "hdr.play", title: "Play All", symbol: "play.fill", showsChevron: false, isActionRow: true),
            MenuItem(id: "hdr.shuffle", title: "Shuffle All", symbol: "shuffle", showsChevron: false, isActionRow: true),
        ]
    }
    /// Headers + tracks (the selection's clamp bound).
    private var totalRows: Int { headerItems.count + tracks.count }

    /// Playlist track list with Play/Shuffle headers; toast and hold panel
    /// layered above.
    var body: some View {
        ZStack {
            MenuList(
                items: headerItems + tracks.enumerated().map { i, s in
                    MenuItem(id: s.id.rawValue, title: s.title, subtitle: s.artistName, showsChevron: false)
                },
                selection: selection, emptyText: "No Songs", style: .twoLine
            )
            .onAppear {
                // Recents: jumping back into this playlist from home.
                model.recents.record(playlist: .init(id: playlistID, title: model.music.playlistName(playlistID)))
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
        .task(id: playlistID) {
            if let playlist {
                tracks = await model.music.tracks(forPlaylist: playlist)
            }
        }
    }

    /// Shows a transient toast, auto-hiding after 1.6 s.
    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeIn(duration: 0.3)) { toast = "" }
        }
    }

    /// Wheel input: the hold panel consumes events first; headers play or
    /// shuffle, a track plays from itself; center-hold opens queue
    /// options; MENU pops.
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
    /// Process-wide handoff point.
    static let shared = CoverFlowLaunch()
    /// Album ID Cover Flow should land on; consumed (set to nil) on the
    /// flow's first appear.
    var pendingAlbumID: String?
}
