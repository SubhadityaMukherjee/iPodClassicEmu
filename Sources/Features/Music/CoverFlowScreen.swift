import SwiftUI
import MusicKit

/// Cover Flow: tilted album covers with reflection, alphabet index bar,
/// artist/album captions, and the classic numbered track overlay on center.
struct CoverFlowScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    @State private var index = 0
    @State private var overlayOpen = false
    @State private var overlaySelection = 0
    @State private var overlayTracks: [Song] = []

    private var albums: [Album] { model.music.albums }

    private var currentAlbum: Album? {
        albums.indices.contains(index) ? albums[index] : nil
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                AlphabetBar(albums: albums, index: index)
                flowArea
                caption
            }
            if overlayOpen {
                ModalHost {
                    trackOverlay
                }
                .zIndex(2)
            }
        }
        .onWheel { handle($0) }
        .onAppear {
            if let pending = CoverFlowLaunch.shared.pendingAlbumID,
               let i = albums.firstIndex(where: { $0.id.rawValue == pending }) {
                index = i
            }
            CoverFlowLaunch.shared.pendingAlbumID = nil
        }
    }

    // MARK: Pieces

    private var flowArea: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let coverSize = min(w * 0.58, h * 0.78)
            ZStack {
                ForEach(Array(albums.enumerated()), id: \.element.id) { i, album in
                    let offset = Double(i - index)
                    if abs(offset) <= 4 {
                        FlowCover(album: album, size: coverSize, offset: offset)
                            .position(
                                x: w / 2 + CGFloat(offset) * w * (abs(offset) > 0 ? 0.42 : 0.0),
                                y: h * 0.44
                            )
                            .opacity(offset == 0 ? 1 : 0.92)
                    }
                }
            }
            .frame(width: w, height: h)
            .clipped()
        }
    }

    private var caption: some View {
        VStack(spacing: 1) {
            Text(currentAlbum?.artistName ?? "")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.inkDim)
                .lineLimit(1)
            Text(currentAlbum?.title ?? "")
                .font(.system(size: 15.5, weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .padding(.bottom, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
    }

    // MARK: Track overlay

    private var trackOverlay: some View {
        ModalPanel(title: currentAlbum?.title ?? "", onClose: { closeOverlay() }) {
            MenuList(
                items: overlayTracks.enumerated().map { i, s in
                    MenuItem(id: s.id.rawValue, title: s.title)
                },
                selection: overlaySelection, compact: true, numbered: true
            )
            .padding(.top, 4)
        }
    }

    private func openOverlay() async {
        guard let album = currentAlbum else { return }
        overlayTracks = model.music.cachedTracks(forAlbum: album)
        if overlayTracks.isEmpty {
            overlayTracks = await model.music.tracks(forAlbum: album)
        }
        overlaySelection = 0
        overlayOpen = true
    }

    private func closeOverlay() {
        overlayOpen = false
    }

    // MARK: Input

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            if overlayOpen {
                moveListSelection(&overlaySelection, count: overlayTracks.count, delta: d, settings: settings)
            } else {
                moveListSelection(&index, count: albums.count, delta: d, settings: settings)
            }
        case .select:
            if overlayOpen {
                if overlayTracks.indices.contains(overlaySelection) {
                    model.player.play(overlayTracks, startingAt: overlaySelection)
                    model.push(.nowPlaying)
                }
            } else {
                Task { await openOverlay() }
            }
        case .menu:
            if overlayOpen {
                closeOverlay()
            } else {
                model.pop()
            }
        default:
            break
        }
    }
}

/// One 3D cover with floor reflection.
private struct FlowCover: View {
    let album: Album
    let size: CGFloat
    let offset: Double

    var body: some View {
        let isCenter = offset == 0
        let side = offset > 0 ? 1 : -1
        let distance = abs(offset)

        VStack(spacing: 2) {
            ArtworkView(artwork: album.artwork, width: size, height: size, placeholderSymbol: "square.stack")
                .frame(width: size, height: size)
                .overlay(
                    Rectangle().stroke(Color.black.opacity(0.4), lineWidth: 0.7)
                )
                .scaleEffect(1 - min(distance, 3.0) * 0.14)
                .rotation3DEffect(
                    .degrees(isCenter ? 0 : Double(side) * 38),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.55
                )

            // Reflection
            ArtworkView(artwork: album.artwork, width: size, height: size, placeholderSymbol: "square.stack")
                .frame(width: size, height: size)
                .scaleEffect(y: -1)
                .opacity(0.22)
                .mask(
                    LinearGradient(
                        colors: [.black, .black.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: size * 0.35)
                    .frame(maxHeight: .infinity, alignment: .top)
                )
                .rotation3DEffect(
                    .degrees(isCenter ? 0 : Double(side) * 38),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.55
                )
                .frame(height: size * 0.22, alignment: .top)
                .clipped()
        }
        .shadow(color: .black.opacity(0.25), radius: 5, y: 3)
        .animation(.easeOut(duration: 0.18), value: offset)
    }
}

/// A–Z# letter strip highlighting the current album's first letter.
private struct AlphabetBar: View {
    let albums: [Album]
    let index: Int

    private static let letters: [String] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init) + ["#"]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(
                        letter == currentLetter ? Color.white : Theme.inkDim
                    )
                    .background {
                        if letter == currentLetter {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(red: 0.22, green: 0.30, blue: 0.45))
                                .frame(width: 13, height: 13)
                        }
                    }
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
    }

    private var currentLetter: String {
        guard albums.indices.contains(index) else { return "A" }
        let title = albums[index].title
        let first = title.first.map { String($0).uppercased() } ?? "#"
        if first.range(of: "^[A-Z]$", options: .regularExpression) != nil {
            return first
        }
        return "#"
    }
}
