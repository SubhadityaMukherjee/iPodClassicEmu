import SwiftUI
import UIKit
import MusicKit

/// Async-loading artwork view (replaces MusicKitUI's ArtworkImage, which
/// isn't available as a public module anymore). Caches by URL.
struct ArtworkView: View {
    /// MusicKit artwork descriptor; nil renders the placeholder.
    let artwork: Artwork?
    /// Requested display width in points.
    let width: CGFloat
    /// Requested display height in points.
    let height: CGFloat
    /// SF Symbol shown in the placeholder while loading / when there is no artwork.
    var placeholderSymbol = "music.note"

    /// The loaded bitmap; nil until the async fetch finishes (placeholder shows).
    @State private var image: UIImage?

    /// Shows the loaded bitmap (or placeholder) and starts an async load
    /// keyed by `cacheKey`, so a recycled row whose artwork changed re-fetches.
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.82))
                    Image(systemName: placeholderSymbol)
                        .font(.system(size: min(width, height) * 0.3))
                        .foregroundStyle(Theme.inkDim.opacity(0.7))
                }
            }
        }
        .task(id: cacheKey) {
            image = await ArtworkLoader.shared.image(for: artwork, width: width, height: height)
        }
    }

    /// Stable identity for `.task(id:)` — songs' artwork has no stable id,
    /// so a tiny 1×1-pixel URL serves as a cheap unique key.
    private var cacheKey: String {
        guard let artwork else { return "none" }
        // Songs' artwork has no stable id; a tiny URL is a cheap stable key.
        return artwork.url(width: 1, height: 1)?.absoluteString ?? "unknown-\(width)x\(height)"
    }
}

/// Fetches + caches artwork bitmaps off the main actor.
actor ArtworkLoader {
    /// Shared singleton used by every ArtworkView.
    static let shared = ArtworkLoader()
    /// URL-keyed decoded-bitmap cache. NSCache is used because it evicts
    /// under system memory pressure on its own — no manual LRU needed.
    private let cache = NSCache<NSString, UIImage>()

    /// Sets a total cost limit (~96 MB of decoded pixels) so covers evict
    /// long before system pressure, keeping scroll memory flat.
    init() {
        // Covers decode to ~1.4 MB bitmaps each; without a cost limit the
        // cache only evicts under system pressure, long after it should.
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    /// Returns a decoded bitmap for the artwork, fetching on first request
    /// and serving from the cache afterwards. Everything runs on the actor,
    /// so cache reads/writes are serialized without manual locking, and the
    /// decode (`preparingForDisplay`) happens off the main thread so first
    /// draw never hitches a grid scroll. Fetch failures resolve to nil
    /// rather than throwing — a missing cover just shows the placeholder.
    ///
    /// - Parameters:
    ///   - artwork: MusicKit artwork descriptor.
    ///   - width: Display width in points (asset requested at 2× for retina).
    ///   - height: Display height in points (asset requested at 2× for retina).
    /// - Returns: The decoded image, or nil when artwork/URL is missing or
    ///   the fetch/decode fails.
    ///
    /// Concept: nscache → docs/concepts/nscache.md
    /// Concept: swift-actors-and-isolation → docs/concepts/swift-actors-and-isolation.md
    func image(for artwork: Artwork?, width: CGFloat, height: CGFloat) async -> UIImage? {
        guard let artwork else { return nil }
        let pixelW = max(50, Int(width * 2))
        let pixelH = max(50, Int(height * 2))
        guard let url = artwork.url(width: pixelW, height: pixelH) else { return nil }
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let img = UIImage(data: data) else { return nil }
            // Decode NOW, off the main thread: UIImage(data:) is lazy and
            // would otherwise decode on first draw, hitching grid scrolls.
            let decoded = img.preparingForDisplay() ?? img
            let cost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
            cache.setObject(decoded, forKey: key, cost: cost)
            return decoded
        } catch {
            return nil
        }
    }
}
