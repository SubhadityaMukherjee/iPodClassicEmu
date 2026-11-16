# Adding a feature

The recipe, using a hypothetical "Podcasts" feature as the example.
Every step maps to an existing feature you can copy from.

## 1. Create the feature folder

```
Sources/Features/Podcasts/
  PodcastModel.swift    @Observable @MainActor model: state + business logic
  PodcastScreens.swift  the screens (list, detail, …)
```

Conventions:

- The model is `@Observable`, `@MainActor`, and owned by `AppModel` as a
  `let` (`let podcasts = PodcastModel()`). Services that other features
  need (like `MusicService`) follow the same pattern.
- Screens are plain structs; they take IDs/values as parameters (route
  values), read `@Environment(AppModel.self)` and
  `@EnvironmentObject(AppSettings)`.
- A feature folder never reaches into another feature's screens.

## 2. Register the route

In `Sources/App/AppModel.swift`:

```swift
enum Route: Hashable {
    ...
    case podcasts                 // top level
    case podcastDetail(String)    // value-driven deep route
}
```

Then three mandatory wiring points — the test suite enforces coverage:

1. `ScreenRouter` (Sources/Device/ScreenRouter.swift): a case that
   renders your screen.
2. `AppModel.title(for:)`: the title-bar string. `RouteTests` FAILS if
   a route has no title — that's your checklist.
3. If the route should be reachable from a QA launch, add it to
   `AppModel.route(named:)` (`START_ROUTE=podcasts`).

## 3. Handle input the standard way

```swift
struct PodcastListScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0

    var body: some View {
        MenuList(items: items, selection: selection)
            .onReceive(model.controlBus) { handle($0) }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: items.count, delta: d, settings: settings)
        case .select:
            model.push(.podcastDetail(items[selection].id))
        case .menu:
            model.pop()
        default:
            break
        }
    }
}
```

Rules of the road:

- **Lists use `moveListSelection`** (Sources/UI/MenuComponents) — it
  honors the Infinite Tick / Rubber Band Tick clickwheel settings and
  clamps. Never hand-roll index math.
- **Center hold opens an options panel** via `ModalPanel`/`ModalHost`
  (look at any `*Screen` with a hold menu — camera, notes, Now Playing).
- **MENU pops; MENU-hold goes home globally** — don't try to intercept
  `.menuHold` (it never reaches screens).
- If your screen needs the transport buttons (prev/next/play/pause) for
  itself, set `model.transportClaimedByScreen = true` in `onAppear` and
  clear it in `onDisappear` (camera does this).
- **Scroll surfaces get a fixed-size clipped container** owned by that
  view — never let list growth move surrounding layout.

## 4. Add it to a menu

Add a row wherever it's exposed (usually `HomeScreen` or `ExtrasScreens`),
pushing `.podcasts`. If it's a "recent" kind of thing, look at
`RecentActivity` — one entry type + record it in your model + a row in
HomeScreen.

## 5. Regenerate the project

```sh
xcodegen generate     # after adding files
```

`project.yml` is the source of truth; adding files without regenerating
means they're not in the build.

## 6. Test it

- **Unit tests** for the model's state machine (`Tests/iPodClassicTests/`),
  with mocks at the seams (see `AudiobookModelTests` for the pattern:
  engine + synthesizer protocols, controllable fakes, `waitUntil`
  helper).
- **UI test** for the real gesture path if the feature is core
  (`Tests/UITests/`). Remember: `START_ROUTE` REPLACES the nav stack
  (no home in it — you can't MENU out at depth 1), and split menus only
  render rows near the selection.
- **QA env hooks** for anything you'll want to verify on the device
  (e.g. auto-open a screen, seed content). Read them in `init`/`onAppear`
  via `ProcessInfo.processInfo.environment`. See TESTING.md for the
  full existing set.

## 7. Verify on the running app

Build for the simulator, launch with your hooks, exercise it with the
wheel. Then the real device for anything touching MusicKit, camera,
Metal/MLX, or background audio. Update `AGENTS.md`'s feature list with a
dense summary of what you added.

## Gotchas checklist

- [ ] `xcodegen generate` run after file changes
- [ ] `title(for:)` branch added (RouteTests will tell you)
- [ ] Lists use `moveListSelection`, not custom index math
- [ ] Scrolling still works in all major lists after your layout change
      (songs, search, home, reader — regressions here are a known pattern)
- [ ] No `.menuHold`/`.playPause` interception unless you claimed
      transport explicitly
- [ ] Audio: never deactivate the shared session; no temp-file WAVs
      (in-memory data only)
- [ ] Swift/JS string escaping: `\\(x)` inside a Swift string emits the
      LITERAL `\(x)` — single backslash interpolates. Verify generated
      JS/CSS with a standalone script before shipping.
- [ ] Periodic re-renders read `model.clockTick` in `body` — a `@State`
      that nothing reads never re-renders
- [ ] Regression test for the bug you just fixed
