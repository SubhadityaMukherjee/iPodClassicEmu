import SwiftUI
import UIKit

/// Renders the navigation stack inside the LCD. Deeper routes stay alive
/// (state preserved); the top route slides in/out iPod-style and is the only
/// one that receives wheel input.
struct ScreenRouter: View {
    @Environment(AppModel.self) private var model

    static func title(for model: AppModel) -> String {
        switch model.stack.last {
        case .home: return "iPodClassic"
        case .music: return "Music"
        case .musicArtists: return "Artists"
        case .musicAlbums: return "Albums"
        case .musicSongs: return "Songs"
        case .musicGenres: return "Genres"
        case .musicPlaylists: return "Playlists"
        case .musicRecent: return "Recently Added"
        case .coverFlow: return "Cover Flow"
        case .artistDetail(let id): return model.music.artistName(id)
        case .albumDetail(let id): return model.music.albumTitle(id)
        case .playlistDetail(let id): return model.music.playlistName(id)
        case .genreAlbums(let genre): return genre
        case .nowPlaying: return model.player.currentSong?.title ?? "Now Playing"
        case .photos: return "All Photos"
        case .photoDetail: return "Photo"
        case .camera: return "Camera"
        case .recorder: return "Voice Memos"
        case .recordings: return "All Recordings"
        case .recordingDetail: return "Recording"
        case .notes: return "Notes"
        case .noteEditor: return "Edit Note"
        case .clocks: return "Clocks"
        case .alarm: return "Alarm Clock"
        case .timer: return "Timer"
        case .stopwatch: return "Stopwatch"
        case .settings: return "Settings"
        case .settingsClickwheel: return "Clickwheel"
        case .settingsDisplay: return "Display"
        case .settingsPlayback: return "Playback"
        case .settingsAbout: return "About"
        case nil: return "iPodClassic"
        }
    }

    var body: some View {
        ZStack {
            ForEach(Array(model.stack.enumerated()), id: \.element) { index, route in
                screen(for: route)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)  // layers always fill the screen…
                    .background(PaperBackground())                     // …so this paper covers everything below
                    .environment(\.acceptsWheelInput, index == model.stack.count - 1)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                    .zIndex(Double(index))
                    .allowsHitTesting(index == model.stack.count - 1)
            }
        }
        .clipped()
    }

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
        case .recordingDetail(let name): RecordingDetailScreen(fileName: name)
        // Notes
        case .notes: NotesListScreen()
        case .noteEditor(let name): NoteEditorScreen(fileName: name)
        // Clocks
        case .clocks: ClocksMenuScreen()
        case .alarm: AlarmScreen()
        case .timer: TimerScreen()
        case .stopwatch: StopwatchScreen()
        // Settings
        case .settings: SettingsScreen()
        case .settingsClickwheel: ClickwheelSettingsScreen()
        case .settingsDisplay: DisplaySettingsScreen()
        case .settingsPlayback: PlaybackSettingsScreen()
        case .settingsAbout: AboutScreen()
        }
    }
}

extension AppModel {
    var batteryLevel: Double {
        let l = UIDevice.current.batteryLevel
        return l >= 0 ? Double(l) : 1.0
    }
}
