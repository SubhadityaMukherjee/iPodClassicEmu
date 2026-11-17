import SwiftUI
import Photos

/// Photo gallery: 4-column grid navigated by the wheel, selected cell has a
/// blue frame; center opens the full photo.
struct PhotosGridScreen: View {
    /// App-wide model from the environment: navigation (`push`/`pop`) and
    /// the shared `photos` service.
    @Environment(AppModel.self) private var model
    /// User settings; `moveListSelection` reads tick-speed behavior from them.
    @EnvironmentObject private var settings: AppSettings
    /// Index of the highlighted cell; wheel ticks move it, center opens it.
    @State private var selection = 0
    /// Photo awaiting the share sheet; non-nil presents it.
    @State private var shareImage: UIImage?

    private let columns = 4

    /// Shows the grid when authorized (else a permission prompt) plus the
    /// share sheet; first appear requests access, later appears reload.
    var body: some View {
        ZStack {
            if model.photos.authorized {
                grid
            } else {
                PromptPane(symbol: "photo.on.rectangle", text: "Allow photo access to see your gallery.")
            }
        }
        .onWheel { handle($0) }
        .onAppear {
            if !model.photos.loaded {
                Task { await model.photos.requestAccess() }
            } else {
                // Pick up photos taken since the last visit.
                model.photos.reload()
            }
        }
        .sheet(isPresented: Binding(get: { shareImage != nil }, set: { if !$0 { shareImage = nil } })) {
            if let img = shareImage {
                ActivityView(items: [img])
            }
        }
    }

    /// The 4-column thumbnail grid, rendering only a moving window of rows.
    ///
    /// Cell side = (width − gaps) / columns. `visibleRows` rounds UP so a
    /// partial next row peeks in at the bottom edge — the grid always
    /// fills the screen instead of showing an empty band. `startRow` keeps
    /// the selected row `visibleRows − 4` rows below the window's top
    /// (look-ahead below the selection), clamped to 0…(rows − visibleRows)
    /// so short libraries pin to the top and never scroll past the end.
    /// Windowing is the point: only visible cells exist, so only their
    /// thumbnails decode — a huge library stays cheap.
    private var grid: some View {
        GeometryReader { geo in
            let cell = (geo.size.width - 5) / CGFloat(columns)
            let rows = (model.photos.count + columns - 1) / columns
            // Round UP: the next row peeks in at the bottom edge so the grid
            // always fills the screen (no white bar below).
            let visibleRows = max(1, Int(ceil(geo.size.height / (cell + 1))))
            let startRow = max(0, min(selection / columns - max(0, visibleRows - 4), max(0, rows - visibleRows)))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(startRow..<min(rows, startRow + visibleRows), id: \.self) { row in
                        HStack(spacing: 1) {
                            ForEach(0..<columns, id: \.self) { col in
                                let idx = row * columns + col
                                PhotoCell(
                                    asset: model.photos.asset(at: idx),
                                    selected: idx == selection,
                                    cellSize: cell
                                )
                            }
                        }
                    }
                }
            }
            .frame(width: geo.size.width)
        }
        .overlay {
            if model.photos.count == 0 {
                Text("No Photos")
                    .font(Theme.font(16, .semibold))
                    .foregroundStyle(Theme.inkDim)
            }
        }
    }

    /// Wheel input for the grid: ticks move the selection (honoring the
    /// adaptive tick settings), center opens the selected photo,
    /// hold-center loads it full-size and shares it (with a confirm
    /// haptic), MENU pops the screen.
    /// - Parameter event: The control event delivered by the click wheel.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: model.photos.count, delta: d, settings: settings)
        case .select:
            if selection < model.photos.count {
                model.push(.photoDetail(selection))
            }
        case .centerHold:
            // Hold center on the grid: share the selected photo.
            if selection < model.photos.count, let asset = model.photos.asset(at: selection) {
                Task {
                    if let img = await model.photos.loadFullImage(asset) {
                        WheelHaptics.shared.ensureRunning()
                        WheelHaptics.shared.buttonPress(strength: 0.9)
                        shareImage = img
                    }
                }
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}

/// One thumbnail cell with blue selection frame.
private struct PhotoCell: View {
    /// App model from the environment; provides the shared photo service.
    @Environment(AppModel.self) private var model
    /// Display pixel density (2x/3x). Cells request thumbnails at
    /// cellSize * displayScale — real pixels, not points — because a
    /// lower-resolution bitmap scaled up to fill the cell renders soft.
    @Environment(\.displayScale) private var displayScale
    /// The photo for this cell; nil for the empty grey cells that pad a
    /// partial last row.
    let asset: PHAsset?
    /// True when this cell is the wheel-selected one (blue frame).
    let selected: Bool
    /// Cell side in points; the decode multiplies it by `displayScale`.
    let cellSize: CGFloat

    /// The decoded thumbnail; nil renders the grey placeholder until the
    /// final bitmap lands in the model's cache.
    @State private var image: UIImage?

    /// Square aspect-filled thumbnail (or placeholder) with the blue
    /// selection frame; starts the decode on appear.
    var body: some View {
        ZStack {
            Color(white: 0.88)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: cellSize, height: cellSize)
        .clipped()
        .overlay {
            if selected {
                Rectangle().stroke(Color(red: 0.20, green: 0.42, blue: 0.85), lineWidth: 2.5)
            }
        }
        .task(id: asset?.localIdentifier) {
            guard let asset else { return }
            // Decode at the REAL pixel density: a 2x bitmap in a 3x cell
            // renders soft — the "blurry" gallery.
            let scale = max(1, displayScale)
            let size = CGSize(width: cellSize * scale, height: cellSize * scale)
            // Thumbnails decode async; the model returns nil until the
            // final (non-degraded) bitmap is cached — poll briefly.
            for _ in 0..<20 {
                if let cached = model.photos.thumbnail(for: asset, size: size) {
                    image = cached
                    return
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            image = model.photos.thumbnail(for: asset, size: size)
        }
    }
}

/// Full-screen photo with prev/next navigation, pinch/drag zoom, and
/// hold-center share.
struct PhotoDetailScreen: View {
    /// App-wide model from the environment: navigation and the shared
    /// `photos` service.
    @Environment(AppModel.self) private var model
    /// User settings; `moveListSelection` reads tick-speed behavior from them.
    @EnvironmentObject private var settings: AppSettings
    /// The photo to open first — the payload of `Route.photoDetail(index)`.
    let index: Int

    // Initialized from `index`, NOT 0 — a fresh screen must start decoding
    // the photo that was clicked. Starting at 0 raced: the cancelled
    // photo-0 load could land after the real one and overwrite it (the
    // "opened the first photo" bug).
    /// The photo currently shown; seeded from `index` by `init(index:)`.
    @State private var selection: Int
    /// The fully decoded photo; nil shows the progress spinner.
    @State private var image: UIImage?
    /// Photo awaiting the share sheet; non-nil presents it.
    @State private var shareImage: UIImage?

    // Pinch zoom / pan
    /// Current zoom factor (1…6); values ≤1.04 read as "not zoomed" —
    /// the photo springs back to 1 and panning is disabled.
    @State private var scale: CGFloat = 1
    /// Zoom captured when the current pinch began; the gesture ratio
    /// multiplies it, so a second pinch continues from the live zoom
    /// instead of restarting at 1.
    @State private var baseScale: CGFloat = 1
    /// Pan translation while zoomed; reset to center when zoom returns to 1.
    @State private var offset: CGSize = .zero

    /// Creates the detail screen showing photo `index`.
    ///
    /// `selection` must be seeded through `State(initialValue:)` rather
    /// than left at a default: ScreenRouter gives each route VALUE its
    /// own view identity, so opening a different photo builds a fresh
    /// screen whose `@State` runs this initializer. With a default of 0
    /// every fresh screen started on photo 0, and that superseded decode
    /// could land after the real one and overwrite it — the "opened the
    /// first photo" bug.
    /// - Parameter index: Index of the tapped photo in grid order.
    /// Concept: @State and view identity → docs/concepts/swiftui-views-and-state.md
    init(index: Int) {
        self.index = index
        _selection = State(initialValue: index)
    }

    /// The photo with pinch-zoom and pan (or a spinner while decoding),
    /// the zoom hint capsule, and the share sheet; wheel drives `handle`.
    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(scale)
                    .offset(offset)
                    .clipped()
                    .gesture(
                        MagnificationGesture()
                            .onChanged { v in
                                scale = min(6, max(1, baseScale * v))
                            }
                            .onEnded { _ in
                                baseScale = scale
                                if scale <= 1.04 {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        scale = 1; baseScale = 1; offset = .zero
                                    }
                                }
                            }
                    )
                    .gesture(
                        scale > 1.04
                            ? DragGesture()
                                .onChanged { v in offset = CGSize(width: v.translation.width, height: v.translation.height) }
                                .onEnded { _ in }
                            : nil
                    )
            } else {
                ProgressView().tint(.white)
            }

            if scale > 1.04 {
                VStack {
                    Spacer()
                    Text("Pinch to zoom · drag to pan")
                        .font(Theme.font(11, .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .padding(.bottom, 8)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: scale > 1.04)
        .onWheel { handle($0) }
        .task(id: selection) {
            await load()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                scale = 1; baseScale = 1; offset = .zero
            }
        }
        .sheet(isPresented: Binding(get: { shareImage != nil }, set: { if !$0 { shareImage = nil } })) {
            if let img = shareImage {
                ActivityView(items: [img])
            }
        }
    }

    /// Decodes the selected photo full-size and installs it; the caller
    /// (`.task(id: selection)`) then resets zoom for the new photo.
    ///
    /// `requested` snapshots `selection` BEFORE the await and the result
    /// is dropped unless it still matches and the task wasn't cancelled:
    /// PHImageManager ignores Swift task cancellation, so a decode
    /// superseded by a quick wheel step still resumes — without the
    /// guard it would install the photo that just scrolled off screen.
    /// Concept: async/await and cancellation → docs/concepts/swift-async-await.md
    private func load() async {
        guard let asset = model.photos.asset(at: selection) else { return }
        // PHImageManager ignores task cancellation: a superseded load still
        // resumes and must not overwrite the photo now on screen.
        let requested = selection
        let loaded = await model.photos.loadFullImage(asset)
        guard requested == selection, !Task.isCancelled else { return }
        image = loaded
    }

    /// Wheel input for the detail view: ticks move to the neighboring
    /// photo (`.task(id: selection)` reloads it and resets zoom),
    /// hold-center shares the shown photo (with a haptic), MENU pops.
    /// `.select` and `.playPause` are deliberately inert here.
    /// - Parameter event: The control event delivered by the click wheel.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: model.photos.count, delta: d, settings: settings)
        case .select, .playPause:
            break
        case .centerHold:
            // Hold center: share this photo.
            if let image {
                WheelHaptics.shared.ensureRunning()
                WheelHaptics.shared.buttonPress(strength: 0.9)
                shareImage = image
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}
