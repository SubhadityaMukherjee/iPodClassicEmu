import SwiftUI
import UIKit
import MusicKit

/// Async-loading artwork view (replaces MusicKitUI's ArtworkImage, which
/// isn't available as a public module anymore). Caches by URL.
struct ArtworkView: View {
    let artwork: Artwork?
    let width: CGFloat
    let height: CGFloat
    var placeholderSymbol = "music.note"

    @State private var image: UIImage?

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

    private var cacheKey: String {
        guard let artwork else { return "none" }
        // Songs' artwork has no stable id; a tiny URL is a cheap stable key.
        return artwork.url(width: 1, height: 1)?.absoluteString ?? "unknown-\(width)x\(height)"
    }
}

/// Fetches + caches artwork bitmaps off the main actor.
actor ArtworkLoader {
    static let shared = ArtworkLoader()
    private let cache = NSCache<NSString, UIImage>()

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
            cache.setObject(img, forKey: key)
            return img
        } catch {
            return nil
        }
    }
}
