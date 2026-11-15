import XCTest
@testable import iPodClassic

/// Binaural beats: preset set (Schumann 7.83 + the five EEG bands),
/// toggle semantics, preset switching, and volume cycling — against a
/// mock engine so no audio hardware is involved.
final class BinauralModelTests: XCTestCase {
    final class MockEngine: BinauralEngineType {
        var starts: [(beat: Double, carrier: Double, volume: Float)] = []
        var volumes: [Float] = []
        var stops = 0
        func start(beat: Double, carrier: Double, volume: Float) { starts.append((beat, carrier, volume)) }
        func setVolume(_ volume: Float) { volumes.append(volume) }
        func stop() { stops += 1 }
    }

    private var engine: MockEngine!
    private var model: BinauralModel!
    private var recents: RecentActivity!
    private let defaultsName = "binaural-test-\(UUID().uuidString)"
    private let recentsName = "binaural-recents-test-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        engine = MockEngine()
        let d = UserDefaults(suiteName: defaultsName)!
        d.removePersistentDomain(forName: defaultsName)
        let rd = UserDefaults(suiteName: recentsName)!
        rd.removePersistentDomain(forName: recentsName)
        recents = RecentActivity(defaults: rd)
        model = BinauralModel(engine: engine, defaults: d, recents: recents)
        model.usesSystemRemoteCommands = false
        var published: [(title: String?, elapsed: TimeInterval)] = []
        model.nowPlayingPublisher = { title, elapsed in
            published.append((title, elapsed))
            BinauralModelTests.lastPublished = published
        }
        BinauralModelTests.lastPublished = []
    }

    static var lastPublished: [(title: String?, elapsed: TimeInterval)] = []

    override func tearDown() {
        UserDefaults(suiteName: defaultsName)!.removePersistentDomain(forName: defaultsName)
        UserDefaults(suiteName: recentsName)!.removePersistentDomain(forName: recentsName)
        super.tearDown()
    }

    private func preset(_ name: String) -> BinauralModel.Preset {
        BinauralModel.presets.first { $0.name == name }!
    }

    func testPresetsCoverAllBands() {
        let names = BinauralModel.presets.map(\.name)
        XCTAssertEqual(names, ["Delta", "Theta", "Schumann", "Alpha", "Beta", "Gamma"])
        XCTAssertEqual(preset("Schumann").beat, 7.83, accuracy: 0.001, "Schumann resonance is 7.83 Hz")
        XCTAssertEqual(preset("Delta").beat, 3)
        XCTAssertEqual(preset("Theta").beat, 6)
        XCTAssertEqual(preset("Alpha").beat, 10)
        XCTAssertEqual(preset("Beta").beat, 18)
        XCTAssertEqual(preset("Gamma").beat, 40)
    }

    func testToggleStartsAndStops() {
        model.toggle(preset("Schumann"))
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.active?.name, "Schumann")
        XCTAssertEqual(engine.starts.last?.beat ?? 0, 7.83, accuracy: 0.001)
        XCTAssertEqual(engine.starts.last?.carrier ?? 0, 200, accuracy: 0.001, "carrier is the classic 200 Hz")
        model.toggle(preset("Schumann")) // same preset again = stop
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(engine.stops, 1)
    }

    func testSwitchingPresetsRestartsWithNewBeat() {
        model.toggle(preset("Theta"))
        model.toggle(preset("Gamma"))
        XCTAssertTrue(model.isPlaying, "switching presets keeps playing")
        XCTAssertEqual(model.active?.name, "Gamma")
        XCTAssertEqual(engine.starts.count, 2)
        XCTAssertEqual(engine.starts.last?.beat ?? 0, 40)
    }

    func testVolumeCyclesAndPersists() {
        let first = model.volumeIndex
        model.cycleVolume()
        XCTAssertEqual(model.volumeIndex, (first + 1) % BinauralModel.volumeLevels.count)
        XCTAssertEqual(engine.volumes.last, model.volume, "volume change reaches the engine")
        // A fresh model reads the persisted index.
        let again = BinauralModel(engine: engine, defaults: UserDefaults(suiteName: defaultsName)!)
        XCTAssertEqual(again.volumeIndex, model.volumeIndex)
    }

    func testStopWhenIdleIsANoop() {
        model.stop()
        XCTAssertEqual(engine.stops, 0, "stop without playback shouldn't touch the engine")
    }

    func testNowPlayingPublishesOnStartAndClearsOnStop() {
        model.toggle(preset("Schumann"))
        let last = Self.lastPublished.last
        XCTAssertEqual(last?.title, "Binaural · Schumann", "lock screen card titles the session")
        XCTAssertEqual(last?.elapsed, 0)
        model.stop()
        XCTAssertEqual(Self.lastPublished.last?.title, nil, "stopping clears the Now Playing card")
    }

    func testStartingASessionRecordsRecentsEntry() {
        model.toggle(preset("Alpha"))
        XCTAssertEqual(recents.binaural?.id, "Alpha")
        XCTAssertEqual(recents.binaural?.title, "Alpha")
        // Switching presets updates the entry…
        model.toggle(preset("Gamma"))
        XCTAssertEqual(recents.binaural?.id, "Gamma")
        // …and stopping keeps it — the home row jumps back to the last
        // session even after it ended.
        model.stop()
        XCTAssertEqual(recents.binaural?.id, "Gamma")
    }

    func testRecentsEntryPersistsAcrossInstances() {
        model.toggle(preset("Schumann"))
        let rd = UserDefaults(suiteName: recentsName)!
        let again = RecentActivity(defaults: rd)
        XCTAssertEqual(again.binaural?.title, "Schumann")
    }
}
