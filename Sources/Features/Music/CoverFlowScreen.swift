import SwiftUI
import MusicKit

/// Cover Flow: tilted album covers with reflection, alphabet index bar,
/// artist/album captions — center click flips the cover like the old iPods
/// to reveal the track list on its back.
struct CoverFlowScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    /// Highlighted album (the center cover).
    @State private var index = 0
    /// True while the center cover shows its track-list back.
    @State private var flipped = false
    /// Highlighted track on the flipped back.
    @State private var overlaySelection = 0
    /// Tracks listed on the flipped back, loaded at flip time.
    @State private var overlayTracks: [Song] = []

    // Cover Flow runs in its own alphabetical-by-album order (the classic
    // flip-through-the-crate feel), independent of the Music menu's
    // album sort setting.
    /// Every album, in the flow's own order (see the note above).
    private var albums: [Album] {
        model.music.albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The album at `index`, nil when the library is empty.
    private var currentAlbum: Album? {
        albums.indices.contains(index) ? albums[index] : nil
    }

    /// Alphabet bar over the 3D flow over the caption; consumes a pending
    /// launch album on appear.
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

    /// The 3D carousel. Only covers within ±4 of the center are built —
    /// one 3D-transformed view per album brought large libraries to a
    /// crawl — with neighbors stepping 0.42×width to either side of the
    /// centered cover, everything clipped to the flow area.
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

    /// Artist (dimmed) and album title under the flow.
    private var caption: some View {
        VStack(spacing: 1) {
            Text(currentAlbum?.artistName ?? "")
                .font(Theme.font(12.5, .medium))
                .foregroundStyle(Theme.inkDim)
                .lineLimit(1)
            Text(currentAlbum?.title ?? "")
                .font(Theme.font(15.5, .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .padding(.bottom, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
    }

    // MARK: Flip

    /// Loads the album's tracks (cache first, library fetch on miss) and
    /// flips the center cover to its track-list back.
    private func flip() async {
        guard let album = currentAlbum else { return }
        overlayTracks = model.music.cachedTracks(forAlbum: album)
        if overlayTracks.isEmpty {
            overlayTracks = await model.music.tracks(forAlbum: album)
        }
        overlaySelection = 0
        withAnimation(.easeInOut(duration: 0.45)) { flipped = true }
    }

    /// Flips back to the cover front.
    private func unflip() {
        withAnimation(.easeInOut(duration: 0.4)) { flipped = false }
    }

    // MARK: Input

    /// Wheel input: ticks browse albums (tracks when flipped); center
    /// flips the cover or plays the highlighted track; MENU unflips
    /// before popping.
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
    /// True while the back (track list) faces the user.
    let flipped: Bool
    /// Tracks printed on the back (loaded by the parent at flip time).
    let tracks: [Song]
    /// Highlighted back row, driven by the parent's wheel handling.
    let trackSelection: Int

    /// Front and back cross-faded inside one 180° y-axis rotation.
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

    /// Cover art with a fading floor reflection beneath it.
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
                .font(Theme.font(12, .bold))
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
                    .font(Theme.font(22))
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
    /// Signed position relative to the center cover (negative = left).
    let offset: Double

    /// One side cover: scaled down 14% per step of distance (capped at 3)
    /// and rotated ±38° toward center, like covers fanned in a crate, with
    /// the same floor reflection as the center cover.
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
    /// The flow's albums, in flow order.
    let albums: [Album]
    /// Index of the current (highlighted) album.
    let index: Int

    /// "A"–"Z" plus "#" for non-letter initials.
    private static let letters: [String] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init) + ["#"]

    /// Evenly-spaced letters; the current one inverted in a highlight chip.
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.letters, id: \.self) { letter in
                Text(letter)
                    .font(Theme.font(10.5, .semibold))
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

    /// The current album's first letter, uppercased — "#" when it isn't a
    /// plain A–Z initial.
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
