# PhotoKit — reading the user's photo library

PhotoKit (the `PH*` classes) is the framework for browsing the system
photo library: `PHPhotoLibrary` (permission), `PHFetchResult` (query
results), `PHAsset` (a photo/video item), `PHImageManager` (bitmaps).

## Permission

Any access prompts once via `PHPhotoLibrary.requestAuthorization`; the
status (`PHAuthorizationStatus`) can later be *limited* (user picked a
subset), and users can flip it in Settings at any time — so code rechecks
status rather than assuming one prompt settles it. A denied library is a
normal state the Photos screens render ("Allow photo access"), not an
error.

## Fetching assets is cheap; loading pixels is not

```swift
let fetch = PHAsset.fetchAssets(with: .image, options: sortOptions)
fetch.countAt(i), fetch.object(at: i)   // metadata from the store — fast
```

`PHFetchResult` is a lazy, live view over the library; enumerate/index it
freely on the main thread. But the actual bitmap must be *requested*:

```swift
PHImageManager.default().requestImage(
    for: asset, targetSize: CGSize(width: W, height: H),
    contentMode: .aspectFill,
    options: opts) { image, info in
        // arrives on an arbitrary queue, possibly MORE THAN ONCE
    }
```

## The rules this project enforces (each was a real bug)

`PhotoLibraryModel` implements thumbnail loading with hard invariants:

1. **Cache key includes the size** — `"<assetID>|<W>x<H>"`. Home previews
   (600px) and grid cells (screen-scale pixels) request different sizes;
   a size-less NSCache key lets one screen read the other's blurry
   bitmap. See [nscache.md](nscache.md).
2. **Never cache degraded deliveries.** With
   `.opportunistic` delivery, iOS calls back twice: once with a cheap
   degraded frame, later with the final. Caching the first call pins a
   blurry cell *forever*. Only the final (non-degraded) delivery is
   cached; degraded frames render but are allowed to be replaced.
3. **Poll until the final bitmap lands** — the first delivery is not
   good enough to keep.
4. **`inflight` set dedups re-polls** (SwiftUI re-asks while scrolling);
   mutate it on the **main queue** because callbacks arrive on arbitrary
   queues ([dispatch-queues.md](dispatch-queues.md)).
5. **Request at cellSize × `displayScale`** — pixels, not points;
   hardcoded 2× was soft on 3× screens.

## The detail-screen race (why `State(initialValue:)`)

`ScreenRouter` identifies views by route *value*
(`photoDetail(index)`), and a re-created view with an equal value is the
"same" view with **fresh @State**. The old bug: pushing photo 40 started
a `@State selection = 0`, and the cancelled load of photo 0
(PHImageManager ignores task cancellation) landed *after* the real load
and overwrote it. Fixes living in `PhotoDetailScreen`: selection is
seeded from the pushed index via a custom `init` +
`State(initialValue:)`, and `load()` captures `requested = selection`
before its `await`, dropping any result that no longer matches.

## Where to look

- `Sources/Features/Photos/PhotoLibraryModel.swift` — fetch, thumbnail
  pipeline, all five invariants.
- `Sources/Features/Photos/PhotosScreens.swift` — grid/detail UI.

## Related

[nscache.md](nscache.md); [swiftui-views-and-state.md](swiftui-views-and-state.md)
(view identity — the root of the detail-screen race).
