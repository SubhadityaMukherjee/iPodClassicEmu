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
    private(set) var assets: PHFetchResult<PHAsset>?
    private(set) var authorized = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
    private(set) var loaded = false
    private let imageManager = PHCachingImageManager()
    /// Evicts under pressure; a plain dictionary held every grid thumbnail
    /// for the whole session (a large library cost tens of MB that never
    /// came back). Cost = decoded bitmap bytes.
    private let thumbnails = NSCache<NSString, UIImage>()
    /// Asset+size keys with a decode in flight, so repeated cache misses
    /// (the grid polls) don't stack duplicate PHImageManager requests.
    private var inflight = Set<String>()

    init() {
        thumbnails.totalCostLimit = 64 * 1024 * 1024
    }

    var count: Int { assets?.count ?? 0 }

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

    private func thumbnailKey(_ asset: PHAsset, size: CGSize) -> NSString {
        "\(asset.localIdentifier)|\(Int(size.width))x\(Int(size.height))" as NSString
    }

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

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorized = status == .authorized || status == .limited
        if authorized { loadPhotos() }
    }

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
    var latestThumbnail: UIImage? {
        guard let assets, assets.count > 0 else { return nil }
        // 600 px covers the preview pane at 3x — the old 300 request made
        // the first photo (the one shown here) look soft on retina.
        return thumbnail(for: assets[0], size: CGSize(width: 600, height: 600))
    }
}
