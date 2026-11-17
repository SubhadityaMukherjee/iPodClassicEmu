# NSCache — the memory cache that evicts on its own

`NSCache` is a thread-safe, key/value in-memory cache that iOS can empty
under memory pressure. It's the "images and other expensive-to-recompute
data" store: unlike a dictionary, the system can make it drop entries to
save you from jetsam (the iOS out-of-memory killer).

```swift
let cache = NSCache<NSString, UIImage>()
cache.countLimit = 400                       // optional caps
cache.object(forKey: "songID|300x300")       // nil if evicted or never set
cache.setObject(img, forKey: "songID|300x300")
cache.removeObject(forKey: key)
cache.removeAllObjects()
```

## Why NSCache and not a Dictionary?

1. **Eviction.** A dictionary holds entries forever; artwork for a thousand
   albums would pile up until the process dies. NSCache evicts when memory
   gets tight, so the app trades recompute for survival automatically.
2. **Thread safety.** It's lock-free safe from any queue. Album art decodes
   finish on background callbacks; a plain dictionary there is a data race.
3. **It doesn't copy keys** (class identity), which for string keys is
   exactly what you want.

## The project's hard rules (photos pipeline)

These live in `PhotoLibraryModel` / `ArtworkLoader` and are invariant —
each one was a real bug:

- **The key must include the SIZE.** Keys look like
  `"<assetID>|<W>x<H>"`. Home previews (600px) and grid cells
  (display-scale pixels) request different sizes; a size-less key lets one
  screen cache its blurry variant where another screen expects a sharp
  one. Never "simplify" the key.
- **Never cache degraded/placeholder images.** Opportunistic image
  requests deliver a cheap degraded frame first, the final later. Caching
  the placeholder pins it forever (permanently soft cells) — only the
  final, full-quality delivery is cached.
- **Dedup in-flight requests** (`inflight: Set<String>`) so re-polls don't
  stack duplicate system loads; mutate that set on the main queue because
  image callbacks arrive on arbitrary queues.
- **Request at cell size × `displayScale`** — the old hardcoded 2× was soft
  on 3× screens.

## Eviction means: nil is normal

Code reads the cache expecting nil sometimes and falls through to a load
— never treat a cache miss as an error, and never store anything in NSCache
that you can't afford to lose (source-of-truth data lives in files /
UserDefaults, not here).

## Where to look

- `Sources/Features/Photos/PhotoLibraryModel.swift` — thumbnail cache with
  all rules above.
- `Sources/UI/ArtworkView.swift` — artwork actor cache for music covers.

## Related

[swift-actors-and-isolation.md](swift-actors-and-isolation.md) — the
artwork cache is an actor; [photokit.md](photokit.md) for where the
bitmaps come from.
