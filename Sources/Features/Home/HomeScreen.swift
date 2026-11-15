import SwiftUI
import Photos

/// Home: split menu of features with a preview pane, matching the classic
/// main menu layout.
struct HomeScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0

    private var items: [MenuItem] {
        var list: [MenuItem] = [
            MenuItem(id: "music", title: "Music"),
            MenuItem(id: "photos", title: "Photos"),
            MenuItem(id: "camera", title: "Camera"),
            MenuItem(id: "memos", title: "Voice Memos"),
            MenuItem(id: "notes", title: "Notes"),
            MenuItem(id: "reader", title: "Reader"),
            MenuItem(id: "extras", title: "Extras"),
            MenuItem(id: "settings", title: "Settings"),
            MenuItem(id: "shuffleAll", title: "Shuffle All", symbol: "shuffle", showsChevron: false, isActionRow: true),
            MenuItem(id: "nowplaying", title: "Now Playing"),
        ]
        // Recents: one jump-back row per type with something to resume.
        let r = model.recents
        if r.book != nil || r.playlist != nil || r.album != nil || r.recording != nil || r.binaural != nil || r.clock != nil {
            list.append(MenuItem(id: "recents.header", title: "Recents", showsChevron: false, isActionRow: true))
            if let e = r.book {
                list.append(MenuItem(id: "recents.book", title: e.title, detail: "Book", symbol: "book", showsChevron: false))
            }
            if let e = r.binaural {
                list.append(MenuItem(id: "recents.binaural", title: e.title, detail: "Binaural", symbol: "waveform", showsChevron: false))
            }
            if let e = r.playlist {
                list.append(MenuItem(id: "recents.playlist", title: e.title, detail: "Playlist", symbol: "music.note.list", showsChevron: false))
            }
            if let e = r.album {
                list.append(MenuItem(id: "recents.album", title: e.title, detail: "Album", symbol: "square.stack", showsChevron: false))
            }
            if let e = r.recording {
                list.append(MenuItem(id: "recents.recording", title: e.title, detail: "Recording", symbol: "mic", showsChevron: false))
            }
            if r.clock != nil {
                let isTimer = r.clock == "timer"
                let duration = Double(model.timer.durationHours) * 3600
                    + Double(model.timer.durationMinutes) * 60
                    + Double(model.timer.durationSeconds)
                list.append(MenuItem(id: "recents.clock", title: isTimer ? "Timer" : "Stopwatch",
                                     detail: isTimer ? TimeFormat.duration(duration) : "Clocks",
                                     symbol: isTimer ? "timer" : "stopwatch", showsChevron: false))
            }
        }
        return list
    }

    var body: some View {
        SplitMenuLayout(items: items, selection: selection) {
            preview
        }
        .onWheel { handle($0) }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: items.count, delta: d, settings: settings)
        case .select:
            select()
        case .menu:
            // Already at root; classic iPod does nothing.
            break
        default:
            break
        }
    }

    private func select() {
        switch items[selection].id {
        case "music": model.push(.music)
        case "photos": model.push(.photos)
        case "camera": model.push(.camera)
        case "memos": model.push(.recorder)
        case "notes": model.push(.notes)
        case "reader": model.push(.reader)
        case "extras": model.push(.extras)
        case "settings": model.push(.settings)
        case "shuffleAll":
            let songs = model.music.songs
            guard !songs.isEmpty else { return }
            model.player.shufflePlay(songs)
            model.push(.nowPlaying)
        case "nowplaying": model.push(.nowPlaying)
        case "recents.book": model.push(.readerBook(model.recents.book?.id ?? ""))
        case "recents.binaural":
            // Resume the session: open the screen and make sure the preset
            // plays. Music pauses first — two beat sources don't mix (same
            // rule as the Binaural screen).
            model.push(.binaural)
            if let name = model.recents.binaural?.id,
               let preset = BinauralModel.presets.first(where: { $0.id == name }) {
                if model.player.isPlaying { model.player.togglePlayPause() }
                model.binaural.resume(preset)
            }
        case "recents.playlist":
            // Shuffle-play the playlist straight into Now Playing; fall back
            // to the playlist page if it's gone from the library.
            let id = model.recents.playlist?.id ?? ""
            Task { @MainActor in
                guard let playlist = model.music.playlist(id) else {
                    model.push(.playlistDetail(id))
                    return
                }
                let tracks = await model.music.tracks(forPlaylist: playlist)
                guard !tracks.isEmpty else {
                    model.push(.playlistDetail(id))
                    return
                }
                model.player.shufflePlay(tracks)
                model.push(.nowPlaying)
            }
        case "recents.album":
            let id = model.recents.album?.id ?? ""
            Task { @MainActor in
                guard let album = model.music.album(id) else {
                    model.push(.albumDetail(id))
                    return
                }
                let tracks = await model.music.tracks(forAlbum: album)
                guard !tracks.isEmpty else {
                    model.push(.albumDetail(id))
                    return
                }
                model.player.shufflePlay(tracks)
                model.push(.nowPlaying)
            }
        case "recents.recording":
            // Resume the recorder activity: open Voice Memos and start a
            // new capture (silently skipped when mic access is missing).
            model.push(.recorder)
            model.recorder.start()
        case "recents.clock":
            if model.recents.clock == "stopwatch" {
                model.push(.stopwatch)
            } else {
                // Start the countdown with the last-set duration — the same
                // values the timer screen's own Start row uses.
                let duration = Double(model.timer.durationHours) * 3600
                    + Double(model.timer.durationMinutes) * 60
                    + Double(model.timer.durationSeconds)
                model.timer.start(duration: duration)
                model.push(.timer)
            }
        default: break // recents.header is a visual band, not an action
        }
    }

    // MARK: Preview pane

    @ViewBuilder
    private var preview: some View {
        switch items[selection].id {
        case "music":
            if let album = model.music.albums.first, let aw = album.artwork {
                ArtworkView(artwork: aw, width: 300, height: 300)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                glyph("music.note")
            }
        case "photos":
            if let image = model.photos.latestThumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                glyph("photo.on.rectangle")
            }
        case "camera":
            glyph("camera.fill")
        case "memos":
            glyph("mic.fill")
        case "notes":
            glyph("square.and.pencil")
        case "reader":
            glyph("book.fill")
        case "clocks":
            LiveClockPreview()
        case "extras":
            glyph("sparkles")
        case "shuffleAll":
            glyph("shuffle")
        case "settings":
            glyph("gearshape.fill")
        case "nowplaying":
            if let aw = model.player.currentSong?.artwork {
                ArtworkView(artwork: aw, width: 300, height: 300)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                glyph("play.rectangle.fill")
            }
        case "recents.book":
            glyph("book.fill")
        case "recents.binaural":
            glyph("waveform")
        case "recents.playlist":
            glyph("music.note.list")
        case "recents.album":
            glyph("square.stack.3d.up.fill")
        case "recents.recording":
            glyph("mic.fill")
        case "recents.clock":
            LiveClockPreview()
        default:
            glyph("circle.fill")
        }
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(Theme.font(40))
            .foregroundStyle(Theme.inkDim.opacity(0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Analog clock drawn live for the Clocks preview.
struct LiveClockPreview: View {
    @State private var now = Date()

    var body: some View {
        ClockFace(date: now, accent: Color(red: 0.22, green: 0.42, blue: 0.85))
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }
}
