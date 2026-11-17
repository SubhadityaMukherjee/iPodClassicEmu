import Foundation
import Photos
import PhotosUI
import UIKit
import SwiftUI

/// Photo library access: one fetch of all image assets (newest first),
/// thumbnail caching, and full-size loading for the detail screen.
/// NOTE: never touch PHAsset/PHPhotoLibrary APIs before the user opens
/// Photos — an early fetch would trigger the permission prompt at launch.
@Observable
final class PhotoLibraryModel {
    /// All image assets, newest first; nil until the first `loadPhotos()`.
    /// PHFetchResult is a lazy container — assets materialize on access,
    /// so holding a huge library costs almost nothing.
    /// Concept: PHFetchResult → docs/concepts/photokit.md
    private(set) var assets: PHFetchResult<PHAsset>?
    /// Whether the app may read photos; `.limited` (user picked a subset)
    /// counts as authorized. Captured at init, updated by `requestAccess()`.
    private(set) var authorized = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
    /// True once the library has been fetched — screens use it to tell a
    /// first visit (request access) from a revisit (reload for new photos).
    private(set) var loaded = false
    /// Asset image decoder shared by thumbnails and full-size loads.
    /// PHCachingImageManager is the caching subclass, but only its
    /// inherited `requestImage` is used here; results arrive on
    /// PhotoKit's own queue, never main.
    private let imageManager = PHCachingImageManager()
    /// Evicts under pressure; a plain dictionary held every grid thumbnail
    /// for the whole session (a large library cost tens of MB that never
    /// came back). Cost = decoded bitmap bytes.
    private let thumbnails = NSCache<NSString, UIImage>()
    /// Asset+size keys with a decode in flight, so repeated cache misses
    /// (the grid polls) don't stack duplicate PHImageManager requests.
    private var inflight = Set<String>()

    /// Caps the decoded-thumbnail cache at 64 MB. NSCache enforces the
    /// cap itself by evicting under pressure (entry cost = bitmap bytes),
    /// which is exactly why a cache is used instead of a dictionary.
    /// Concept: NSCache → docs/concepts/nscache.md
    init() {
        thumbnails.totalCostLimit = 64 * 1024 * 1024
    }

    /// Number of photos in the library (0 before the first load).
    var count: Int { assets?.count ?? 0 }

    /// Bounds-checked asset access for the grid and detail screens.
    /// - Parameter index: Position in `assets` (grid order).
    /// - Returns: The asset, or nil when the library isn't loaded yet or
    ///   the index is past the end (the grid's trailing padding cells).
    func asset(at index: Int) -> PHAsset? {
        guard let assets, index >= 0 && index < assets.count else { return nil }
        return assets[index]
    }

    /// Cached bitmap for asset+size, or nil — which also kicks off the
    /// decode (deduped per key). The key includes the size: the home
    /// preview and the grid request different resolutions, and a shared
    /// key made one screen inherit the other's (blurry) bitmap.
    func thumbnail(for asset: PHAsset, size: CGSize) -> UIImage? {
        let key = thumbnailKey(asset, size: size)
        if let cached = thumbnails.object(forKey: key) { return cached }
        requestThumbnail(asset, size: size, key: key)
        return nil
    }

    /// Cache key for one asset at one pixel size: "<assetID>|<W>x<H>".
    /// The size MUST be part of the key — the home preview and the grid
    /// request different resolutions, and a shared key let one screen
    /// cache a bitmap that the other screen then rendered blurry. The
    /// key is NSString because NSCache predates Swift generics and its
    /// keys are still AnyObject.
    /// - Parameters:
    ///   - asset: The photo being decoded.
    ///   - size: Pixel dimensions of the request.
    /// - Returns: The compound cache key.
    private func thumbnailKey(_ asset: PHAsset, size: CGSize) -> NSString {
        "\(asset.localIdentifier)|\(Int(size.width))x\(Int(size.height))" as NSString
    }

    /// Starts (once per key) an asynchronous decode and caches the result.
    ///
    /// `inflight` dedups the grid's repeated polls so identical requests
    /// don't stack; it is main-thread state, mutated only on main.
    /// Delivery mode is `.opportunistic` — PhotoKit first delivers a
    /// quick degraded bitmap, then the final one — and ONLY the
    /// non-degraded final delivery may be cached: a degraded frame stored
    /// under the same key would stick as a permanently blurry thumbnail.
    /// Errors and cancellations re-open the dedup window so a later poll
    /// can retry. Callbacks arrive on an arbitrary PhotoKit queue, hence
    /// the hop to main before touching shared state.
    /// - Parameters:
    ///   - asset: The photo to decode.
    ///   - size: Target pixel size.
    ///   - key: Prebuilt cache key (see `thumbnailKey(_:size:)`).
    /// Concept: PHImageManager → docs/concepts/photokit.md
    private func requestThumbnail(_ asset: PHAsset, size: CGSize, key: NSString) {
        let k = key as String
        guard !inflight.contains(k) else { return }
        inflight.insert(k)
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        imageManager.requestImage(
            for: asset, targetSize: size, contentMode: .aspectFill, options: options
        ) { [weak self] image, info in
            // PHImageManager delivers on an arbitrary queue; `inflight` is
            // main-thread state, so hop before touching it.
            DispatchQueue.main.async {
                guard let self else { return }
                let errored = info?[PHImageErrorKey] != nil
                    || ((info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false)
                if errored {
                    self.inflight.remove(k)
                    return
                }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, let image else { return } // final delivery follows
                // Decoded final bitmap: cache it and open the dedup window.
                let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
                self.thumbnails.setObject(image, forKey: key, cost: cost)
                self.inflight.remove(k)
            }
        }
    }

    /// Full-size decode for the detail screen and the share path, capped
    /// at `maxSize` on the photo's longest side.
    ///
    /// `.highQualityFormat` asks for a single best-quality delivery
    /// instead of progressive previews; the continuation still ignores
    /// any degraded frame so the await can only resolve with the final
    /// bitmap.
    /// - Parameters:
    ///   - asset: The photo to decode.
    ///   - maxSize: Longest-side pixel cap (default 1800 — screen-sharp
    ///     without hauling the full multi-megapixel bitmap around).
    /// - Returns: The decoded image, or nil if PhotoKit delivered nothing.
    /// Concept: withCheckedContinuation → docs/concepts/swift-async-await.md
    func loadFullImage(_ asset: PHAsset, maxSize: CGFloat = 1800) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            let scale = maxSize / CGFloat(max(asset.pixelWidth, asset.pixelHeight))
            let target = CGSize(width: CGFloat(asset.pixelWidth) * min(1, scale), height: CGFloat(asset.pixelHeight) * min(1, scale))
            imageManager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded {
                    continuation.resume(returning: image)
                }
            }
        }
    }

    /// Prompts for read/write photo access (later calls just return the
    /// standing status) and loads the library when granted. `.limited`
    /// counts as success — the user's chosen subset is what gets fetched.
    /// Concept: PHPhotoLibrary authorization → docs/concepts/photokit.md
    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorized = status == .authorized || status == .limited
        if authorized { loadPhotos() }
    }

    /// Fetches every image asset (no videos), newest first, and marks the
    /// model loaded. Re-running simply replaces `assets`.
    func loadPhotos() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        assets = PHAsset.fetchAssets(with: .image, options: options)
        loaded = true
    }

    /// Re-fetches the library and drops the thumbnail cache so newly taken
    /// photos appear without restarting the app.
    func reload() {
        guard authorized else { return }
        thumbnails.removeAllObjects()
        loadPhotos()
    }

    /// Saves a captured UIImage into the photo library.
    func saveToLibrary(_ image: UIImage) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    // Home preview
    /// Newest photo's bitmap for the home-screen preview pane; nil until
    /// the final decode lands in the cache (the home screen re-reads it
    /// as it re-renders).
    var latestThumbnail: UIImage? {
        guard let assets, assets.count > 0 else { return nil }
        // 600 px covers the preview pane at 3x — the old 300 request made
        // the first photo (the one shown here) look soft on retina.
        return thumbnail(for: assets[0], size: CGSize(width: 600, height: 600))
    }
}
