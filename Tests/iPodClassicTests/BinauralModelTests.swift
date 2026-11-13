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
    private let defaultsName = "binaural-test-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        engine = MockEngine()
        let d = UserDefaults(suiteName: defaultsName)!
        d.removePersistentDomain(forName: defaultsName)
        model = BinauralModel(engine: engine, defaults: d)
    }

    override func tearDown() {
        UserDefaults(suiteName: defaultsName)!.removePersistentDomain(forName: defaultsName)
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
}
