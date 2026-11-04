import SwiftUI
import Photos

/// Home: split menu of features with a preview pane, matching the classic
/// main menu layout.
struct HomeScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0

    private var items: [MenuItem] {
        [
            MenuItem(id: "music", title: "Music"),
            MenuItem(id: "photos", title: "Photos"),
            MenuItem(id: "camera", title: "Camera"),
            MenuItem(id: "memos", title: "Voice Memos"),
            MenuItem(id: "notes", title: "Notes"),
            MenuItem(id: "clocks", title: "Clocks"),
            MenuItem(id: "calendar", title: "Calendar"),
            MenuItem(id: "settings", title: "Settings"),
            MenuItem(id: "nowplaying", title: "Now Playing"),
        ]
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
        case "clocks": model.push(.clocks)
        case "calendar": model.push(.calendar)
        case "settings": model.push(.settings)
        case "nowplaying": model.push(.nowPlaying)
        default: break
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
        case "clocks":
            LiveClockPreview()
        case "calendar":
            glyph("calendar")
        case "settings":
            glyph("gearshape.fill")
        case "nowplaying":
            if let aw = model.player.currentSong?.artwork {
                ArtworkView(artwork: aw, width: 300, height: 300)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                glyph("play.rectangle.fill")
            }
        default:
            glyph("circle.fill")
        }
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 40))
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
