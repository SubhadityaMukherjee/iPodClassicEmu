import SwiftUI
import MusicKit

/// Cover Flow: tilted album covers with reflection, alphabet index bar,
/// artist/album captions — center click flips the cover like the old iPods
/// to reveal the track list on its back.
struct CoverFlowScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    @State private var index = 0
    @State private var flipped = false
    @State private var overlaySelection = 0
    @State private var overlayTracks: [Song] = []

    private var albums: [Album] { model.music.albums }

    private var currentAlbum: Album? {
        albums.indices.contains(index) ? albums[index] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            AlphabetBar(albums: albums, index: index)
            flowArea
            caption
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
                        Group {
                            if offset == 0 {
                                FlippableCover(
                                    album: album,
                                    size: coverSize,
                                    flipped: flipped,
                                    tracks: overlayTracks,
                                    trackSelection: overlaySelection
                                )
                            } else {
                                FlowCover(album: album, size: coverSize, offset: offset)
                            }
                        }
                        .position(
                            x: w / 2 + CGFloat(offset) * w * (abs(offset) > 0 ? 0.42 : 0.0),
                            y: h * 0.52
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

    // MARK: Flip

    private func flip() async {
        guard let album = currentAlbum else { return }
        overlayTracks = model.music.cachedTracks(forAlbum: album)
        if overlayTracks.isEmpty {
            overlayTracks = await model.music.tracks(forAlbum: album)
        }
        overlaySelection = 0
        withAnimation(.easeInOut(duration: 0.45)) { flipped = true }
    }

    private func unflip() {
        withAnimation(.easeInOut(duration: 0.4)) { flipped = false }
    }

    // MARK: Input

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            if flipped {
                moveListSelection(&overlaySelection, count: overlayTracks.count, delta: d, settings: settings)
            } else {
                moveListSelection(&index, count: albums.count, delta: d, settings: settings)
            }
        case .select:
            if flipped {
                if overlayTracks.indices.contains(overlaySelection) {
                    model.player.play(overlayTracks, startingAt: overlaySelection)
                    model.push(.nowPlaying)
                }
            } else {
                Task { await flip() }
            }
        case .menu:
            if flipped {
                unflip()
            } else {
                model.pop()
            }
        case .menuHold:
            if flipped { unflip() }
            model.popToRoot()
        default:
            break
        }
    }
}

/// Center cover that flips in 3D to show the track list on its back.
private struct FlippableCover: View {
    let album: Album
    let size: CGFloat
    let flipped: Bool
    let tracks: [Song]
    let trackSelection: Int

    var body: some View {
        ZStack {
            front
                .opacity(flipped ? 0 : 1)
            back
                .opacity(flipped ? 1 : 0)
        }
        .rotation3DEffect(
            .degrees(flipped ? 180 : 0),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.6
        )
        .shadow(color: .black.opacity(0.25), radius: 5, y: 3)
    }

    private var front: some View {
        VStack(spacing: 2) {
            ArtworkView(artwork: album.artwork, width: size, height: size, placeholderSymbol: "square.stack")
                .frame(width: size, height: size)
                .overlay(Rectangle().stroke(Color.black.opacity(0.4), lineWidth: 0.7))
            ArtworkView(artwork: album.artwork, width: size, height: size, placeholderSymbol: "square.stack")
                .frame(width: size, height: size)
                .scaleEffect(y: -1)
                .opacity(0.22)
                .mask(
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: size * 0.35)
                        .frame(maxHeight: .infinity, alignment: .top)
                )
                .frame(height: size * 0.22, alignment: .top)
                .clipped()
        }
    }

    /// The "back cover": paper card with the numbered track list.
    private var back: some View {
        VStack(spacing: 0) {
            Text(album.title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .frame(maxWidth: .infinity)
                .background(BrushedMetal())
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.barBorder).frame(height: 0.7) }

            if tracks.isEmpty {
                Spacer()
                Image(systemName: "music.note")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.inkDim)
                Spacer()
            } else {
                MenuList(
                    items: tracks.enumerated().map { i, s in
                        MenuItem(id: s.id.rawValue, title: s.title, showsChevron: false)
                    },
                    selection: trackSelection,
                    compact: true,
                    numbered: true
                )
            }
        }
        .frame(width: size, height: size)
        .background(PaperBackground())
        .overlay(Rectangle().stroke(Color.black.opacity(0.4), lineWidth: 0.7))
        .scaleEffect(x: -1) // mirrored: reads correctly once the card is flipped
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
