import SwiftUI
import Photos

/// Photo gallery: 4-column grid navigated by the wheel, selected cell has a
/// blue frame; center opens the full photo.
struct PhotosGridScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0

    private let columns = 4

    var body: some View {
        ZStack {
            if model.photos.authorized {
                grid
            } else {
                PromptPane(symbol: "photo.on.rectangle", text: "Allow photo access to see your gallery.")
            }
        }
        .onReceive(model.controlBus) { handle($0) }
        .onAppear {
            if !model.photos.loaded { Task { await model.photos.requestAccess() } }
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let cell = (geo.size.width - 5) / CGFloat(columns)
            let rows = (model.photos.count + columns - 1) / columns
            let visibleRows = max(1, Int((geo.size.height / (cell + 1)).rounded(.down)))
            let startRow = max(0, min(selection / columns - max(0, visibleRows - 3), max(0, rows - visibleRows)))

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
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.inkDim)
            }
        }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: model.photos.count, delta: d, settings: settings)
        case .select:
            if selection < model.photos.count {
                model.push(.photoDetail(selection))
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
    @Environment(AppModel.self) private var model
    let asset: PHAsset?
    let selected: Bool
    let cellSize: CGFloat

    @State private var image: UIImage?

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
            let size = CGSize(width: cellSize * 2, height: cellSize * 2)
            if let cached = model.photos.thumbnail(for: asset, size: size) {
                image = cached
            } else {
                // Thumbnails decode async; re-check shortly after.
                try? await Task.sleep(nanoseconds: 250_000_000)
                image = model.photos.thumbnail(for: asset, size: size)
            }
        }
    }
}

/// Full-screen photo with prev/next navigation.
struct PhotoDetailScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    let index: Int

    @State private var selection = 0
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white)
            }
        }
        .onReceive(model.controlBus) { handle($0) }
        .task(id: selection) { await load() }
        .onAppear { selection = index }
    }

    private func load() async {
        guard let asset = model.photos.asset(at: selection) else { return }
        image = await model.photos.loadFullImage(asset)
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: model.photos.count, delta: d, settings: settings)
        case .select, .playPause:
            break
        case .menu:
            model.pop()
        case .prev:
            _ = moveListSelection(&selection, count: model.photos.count, delta: -1, settings: settings)
        case .next:
            _ = moveListSelection(&selection, count: model.photos.count, delta: 1, settings: settings)
        default:
            break
        }
    }
}
