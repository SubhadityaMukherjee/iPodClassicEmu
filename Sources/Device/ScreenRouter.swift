import SwiftUI
import UIKit

/// Renders the navigation stack inside the LCD. Deeper routes stay alive
/// (state preserved); the top route slides in/out iPod-style and is the only
/// one that receives wheel input.
struct ScreenRouter: View {
    @Environment(AppModel.self) private var model

    /// Maps the top of the navigation stack to the title-bar string.
    /// Detail routes (album, artist, book…) resolve their names through the
    /// model's stores.
    ///
    /// - Parameter model: App model supplying names for detail routes.
    /// - Returns: The title for the current screen (empty stack → "iPod").
    static func title(for model: AppModel) -> String {
        switch model.stack.last {
        case .home: return "iPod"
        case .music: return "Music"
        case .musicArtists: return "Artists"
        case .musicAlbums: return "Albums"
        case .musicSongs: return "Songs"
        case .musicGenres: return "Genres"
        case .musicPlaylists: return "Playlists"
        case .musicRecent: return "Recently Added"
        case .coverFlow: return "Cover Flow"
        case .artistDetail(let id): return model.music.artistName(id)
        case .artistSearch(let id): return model.music.artistName(id)
        case .albumDetail(let id): return model.music.albumTitle(id)
        case .playlistDetail(let id): return model.music.playlistName(id)
        case .genreAlbums(let genre): return genre
        case .nowPlaying: return model.player.currentSong?.title ?? "Now Playing"
        case .photos: return "All Photos"
        case .photoDetail: return "Photo"
        case .camera: return "Camera"
        case .recorder: return "Voice Memos"
        case .recordings: return "All Recordings"
        case .recordingsTrash: return "Recently Deleted"
        case .recordingsDictionary: return "Custom Dictionary"
        case .recordingDetail: return "Recording"
        case .transcript(let name): return TranscriptStore.displayTitle(for: name)
        case .notes: return "Notes"
        case .noteEditor: return "Edit Note"
        case .noteTrash: return "Trash"
        case .clocks: return "Clocks"
        case .extras: return "Extras"
        case .flashlight: return "Flashlight"
        case .binaural: return "Binaural"
        case .reader: return "Reader"
        case .readerBooks: return "Books"
        case .readerArticles: return "Articles"
        case .readerBook(let id): return model.reader.book(id: id)?.title ?? "Reader"
        case .calendar: return "Calendar"
        case .musicSearch: return "Search"
        case .timer: return "Timer"
        case .stopwatch: return "Stopwatch"
        case .settings: return "Settings"
        case .settingsClickwheel: return "Clickwheel"
        case .settingsDisplay: return "Display"
        case .settingsPlayback: return "Playback"
        case .settingsReadAloud: return "Read Aloud"
        case .settingsAbout: return "About"
        case .setup: return "Setup"
        case .tour: return "Welcome"
        case nil: return "iPod"
        }
    }

    /// Layers every route in the stack (not just the top) so deeper screens
    /// stay alive and keep their state through pops; only the topmost layer
    /// accepts wheel input and hit-testing.
    var body: some View {
        ZStack {
            ForEach(Array(model.stack.enumerated()), id: \.element) { index, route in
                screen(for: route)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)  // layers always fill the screen…
                    .background(PaperBackground())                     // …so this paper covers everything below
                    .environment(\.acceptsWheelInput, index == model.stack.count - 1)
                    .transition(transition(for: route))
                    .zIndex(Double(index))
                    .allowsHitTesting(index == model.stack.count - 1)
            }
        }
        .clipped()
    }

    /// Classic iPod motion: screens slide in iPod-style; Now Playing gets
    /// the video-iPod "flip" — it rotates in around the Y axis when you
    /// pick a song and flips back out.
    private func transition(for route: Route) -> AnyTransition {
        route == .nowPlaying
            ? .asymmetric(
                insertion: .modifier(active: Flip(angle: 96, fade: 0), identity: Flip(angle: 0, fade: 1)),
                removal: .modifier(active: Flip(angle: -96, fade: 0), identity: Flip(angle: 0, fade: 1)))
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity))
    }

    /// Instantiates the view for a route — the single Route → screen
    /// registry; adding a screen means adding a case plus a line here.
    ///
    /// - Parameter route: Route to render.
    /// - Returns: The screen for that route.
    @ViewBuilder
    private func screen(for route: Route) -> some View {
        switch route {
        case .home: HomeScreen()
        // Music
        case .music: MusicMenuScreen()
        case .musicArtists: MusicListScreen(kind: .artists)
        case .musicAlbums: MusicListScreen(kind: .albums)
        case .musicSongs: MusicListScreen(kind: .songs)
        case .musicGenres: MusicListScreen(kind: .genres)
        case .musicPlaylists: MusicListScreen(kind: .playlists)
        case .musicRecent: MusicListScreen(kind: .recent)
        case .coverFlow: CoverFlowScreen()
        case .artistDetail(let id): ArtistDetailScreen(artistID: id)
        case .artistSearch(let id): ArtistSearchScreen(artistID: id)
        case .albumDetail(let id): AlbumDetailScreen(albumID: id)
        case .playlistDetail(let id): PlaylistDetailScreen(playlistID: id)
        case .genreAlbums(let genre): GenreAlbumsScreen(genre: genre)
        case .nowPlaying: NowPlayingScreen()
        // Photos
        case .photos: PhotosGridScreen()
        case .photoDetail(let index): PhotoDetailScreen(index: index)
        // Camera
        case .camera: CameraScreen()
        // Voice Memos
        case .recorder: RecorderScreen()
        case .recordings: RecordingsListScreen()
        case .recordingsTrash: RecordingsTrashScreen()
        case .recordingsDictionary: DictionaryScreen()
        case .recordingDetail(let name): RecordingDetailScreen(fileName: name)
        case .transcript(let name): TranscriptScreen(fileName: name)
        // Notes
        case .notes: NotesListScreen()
        case .noteEditor(let name): NoteEditorScreen(fileName: name)
        case .noteTrash: NoteTrashScreen()
        // Clocks
        case .clocks: ClocksMenuScreen()
        case .extras: ExtrasScreen()
        case .flashlight: FlashlightScreen()
        case .binaural: BinauralScreen()
        case .reader: ReaderHomeScreen()
        case .readerBooks: ReaderScreen()
        case .readerArticles: ArticleListScreen()
        case .readerBook(let id): BookScreen(bookID: id)
        case .musicSearch: MusicSearchScreen()
        case .calendar: CalendarScreen()
        case .timer: TimerScreen()
        case .stopwatch: StopwatchScreen()
        // Settings
        case .settings: SettingsScreen()
        case .settingsClickwheel: ClickwheelSettingsScreen()
        case .settingsDisplay: DisplaySettingsScreen()
        case .settingsPlayback: PlaybackSettingsScreen()
        case .settingsReadAloud: ReadAloudSettingsScreen()
        case .settingsAbout: AboutScreen()
        case .setup: SetupScreen()
        case .tour: TourScreen()
        }
    }
}

/// The video-iPod flip: rotate around the Y axis while fading, used for
/// Now Playing push/pop.
private struct Flip: ViewModifier {
    /// Y-axis rotation in degrees applied to the content.
    let angle: Double
    /// Opacity paired with that rotation step.
    let fade: Double
    /// Applies the flip: fade plus a 3D Y-axis rotation with a slightly
    /// compressed perspective for the video-iPod feel.
    func body(content: Content) -> some View {
        content
            .opacity(fade)
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
    }
}

/// UIKit battery bridge for the title-bar battery icon.
extension AppModel {
    /// Battery charge as 0…1. UIDevice reports −1 when monitoring is off or
    /// on the simulator, which maps to a full 1.0 so the icon always shows
    /// something sane.
    var batteryLevel: Double {
        let l = UIDevice.current.batteryLevel
        return l >= 0 ? Double(l) : 1.0
    }

    /// True while the device is plugged in and charging.
    var batteryCharging: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: return true
        default: return false
        }
    }
}
