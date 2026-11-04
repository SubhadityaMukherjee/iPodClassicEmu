import SwiftUI
import MusicKit

/// One row in an iPod-style menu.
struct MenuItem: Identifiable, Equatable {
    let id: String
    let title: String
    /// Second line (e.g. artist under a song title).
    var subtitle: String? = nil
    /// Right-aligned value text ("On", "Medium", …).
    var detail: String? = nil
    /// Trailing SF Symbol replacing the chevron (Shuffle, Cover Flow…).
    var symbol: String? = nil
    var showsChevron: Bool = true

    init(id: String, title: String, subtitle: String? = nil, detail: String? = nil, symbol: String? = nil, showsChevron: Bool = true) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.symbol = symbol
        self.showsChevron = showsChevron
    }

    static func == (lhs: MenuItem, rhs: MenuItem) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && lhs.detail == rhs.detail && lhs.symbol == rhs.symbol && lhs.showsChevron == rhs.showsChevron
    }
}

/// Row height for two-line or thumbnail rows.
enum MenuRowStyle {
    case normal      // single line, bold
    case twoLine     // title + subtitle
    case thumbnail   // artwork + title + subtitle
}

/// Moves a list selection with wheel ticks, honoring the Infinite Tick and
/// Rubber Band Tick settings. Returns true when the selection changed.
@discardableResult
func moveListSelection(_ selection: inout Int, count: Int, delta: Int, settings: AppSettings) -> Bool {
    guard count > 0 else { return false }
    let next = selection + delta
    if next >= 0 && next < count {
        selection = next
        WheelFeedback.tick(dir: delta)
        return true
    }
    if settings.infiniteTick {
        selection = (next + count) % count
        WheelFeedback.tick(dir: delta)
        return true
    }
    // End of list: stop silently (no overscroll sound).
    return false
}

/// The classic list: bold rows, blue gradient on the selected row, chevrons
/// and right-aligned detail values. Rows keep the selection pinned near the
/// middle once the list scrolls, like the original.
struct MenuList: View {
    let items: [MenuItem]
    let selection: Int
    var compact = false
    var emptyText = "No Items"
    var numbered = false
    var style: MenuRowStyle = .normal

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        GeometryReader { geo in
            let rowH = rowHeight(for: geo.size.width) * settings.fontMultiplier
            let visible = max(1, Int((geo.size.height / rowH).rounded(.down)))
            let start = max(0, min(selection - max(0, visible - 3), max(0, items.count - visible)))
            let slice = items.dropFirst(start).prefix(visible)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(slice.enumerated()), id: \.element.id) { offset, item in
                        MenuRow(item: item, selected: start + offset == selection, compact: compact, index: numbered ? start + offset + 1 : nil, style: style, thumb: thumbProvider?(item))
                            .frame(height: rowH)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: geo.size.width)
        }
        .overlay {
            if items.isEmpty {
                Text(emptyText)
                    .font(.system(size: compact ? 14 : 16, weight: .semibold))
                    .foregroundStyle(Theme.inkDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    var thumbProvider: ((MenuItem) -> Artwork?)? = nil

    private func rowHeight(for width: CGFloat) -> CGFloat {
        switch style {
        case .normal: return compact ? 26 : 30.5
        case .twoLine: return compact ? 36 : 40
        case .thumbnail: return compact ? 38 : 44
        }
    }
}

/// A single menu row.
struct MenuRow: View {
    let item: MenuItem
    let selected: Bool
    var compact = false
    var index: Int? = nil
    var style: MenuRowStyle = .normal
    var thumb: Artwork? = nil

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let m = settings.fontMultiplier
        HStack(spacing: 0) {
            if style == .thumbnail {
                thumbnail
                    .padding(.leading, 3)
                    .padding(.trailing, 5)
            }
            if let index, style != .thumbnail {
                Text("\(index)")
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Theme.inkDim)
                    .frame(width: compact ? 18 : 22, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(Theme.row((compact ? 15 : (style == .normal ? 17 : 15.5)) * m))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.subtitle != nil && style != .normal {
                    Text(item.subtitle!)
                        .font(.system(size: (compact ? 11.5 : 12.5) * m, weight: .medium))
                        .foregroundStyle(selected ? Color.white.opacity(0.82) : Theme.inkDim)
                        .lineLimit(1)
                        .padding(.top, 1)
                }
            }
            .padding(.leading, index == nil && style == .normal ? 6 : 2)
            Spacer(minLength: 4)
            if let detail = item.detail {
                Text(detail)
                    .font(Theme.row((compact ? 14 : 16) * m))
                    .lineLimit(1)
                    .padding(.trailing, 6)
            }
            if let symbol = item.symbol {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .padding(.trailing, 4)
            }
            if item.showsChevron && item.symbol == nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: compact ? 11 : 13, weight: .bold))
                    .padding(.trailing, 5)
            }
        }
        .foregroundStyle(selected ? Color.white : Theme.ink)
        .background {
            if selected {
                SelectionGradient()
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.selEdge.opacity(0.9), lineWidth: 0.7))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumb {
            ArtworkView(artwork: thumb, width: 34, height: 34)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.2), lineWidth: 0.5))
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(white: 0.82))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "music.note").font(.system(size: 13)).foregroundStyle(Theme.inkDim))
        }
    }
}

/// Left menu column + right preview pane, like the Music menu screens.
struct SplitMenuLayout<Preview: View>: View {
    let items: [MenuItem]
    let selection: Int
    @ViewBuilder var preview: () -> Preview

    var body: some View {
        GeometryReader { geo in
            let menuW = geo.size.width * 0.52
            HStack(alignment: .top, spacing: 0) {
                MenuList(items: items, selection: selection, compact: true)
                    .frame(width: menuW, height: geo.size.height)
                Rectangle()
                    .fill(Color.black.opacity(0.16))
                    .frame(width: 1, height: geo.size.height)
                ZStack {
                    PaperBackground()
                    preview()
                }
                .frame(maxWidth: .infinity, maxHeight: geo.size.height)
                .clipped()
            }
        }
    }
}

/// iPod-style modal panel (Camera Options, confirmations…).
struct ModalPanel<Content: View>: View {
    let title: String
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(Theme.barTitle(19))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.14)).frame(height: 1) }

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(PaperBackground().clipShape(RoundedRectangle(cornerRadius: 6)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.black.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }
}

/// Overlay container for modal panels inside the screen.
struct ModalHost<Panel: View>: View {
    @ViewBuilder var panel: () -> Panel

    var body: some View {
        ZStack {
            Color.black.opacity(0.30)
            panel()
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
        }
        .transition(.opacity)
    }
}
