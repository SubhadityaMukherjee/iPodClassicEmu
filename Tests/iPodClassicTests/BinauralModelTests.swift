import XCTest
import AVFoundation
@testable import iPodClassic

/// Binaural beats: preset set (Schumann 7.83 + the five EEG bands +
/// Gateway + the Solfeggio pure tones), toggle semantics, preset
/// switching, and the fixed render gain — against a mock engine so no
/// audio hardware is involved. Loudness is the device volume; there is
/// deliberately no in-app volume control.
final class BinauralModelTests: XCTestCase {
    final class MockEngine: BinauralEngineType {
        var starts: [(beat: Double, carrier: Double, volume: Float)] = []
        var stops = 0
        func start(beat: Double, carrier: Double, volume: Float) { starts.append((beat, carrier, volume)) }
        func stop() { stops += 1 }
    }

    private var engine: MockEngine!
    private var model: BinauralModel!
    private var recents: RecentActivity!
    private let recentsName = "binaural-recents-test-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        engine = MockEngine()
        let rd = UserDefaults(suiteName: recentsName)!
        rd.removePersistentDomain(forName: recentsName)
        recents = RecentActivity(defaults: rd)
        model = BinauralModel(engine: engine, recents: recents)
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
        UserDefaults(suiteName: recentsName)!.removePersistentDomain(forName: recentsName)
        super.tearDown()
    }

    private func preset(_ name: String) -> BinauralModel.Preset {
        BinauralModel.presets.first { $0.name == name }!
    }

    func testPresetsCoverAllBands() {
        let names = BinauralModel.presets.map(\.name)
        XCTAssertEqual(names, ["Delta", "Gateway", "Theta", "Schumann", "Alpha", "Beta", "Gamma",
                               "Intuition", "Oneness"])
        XCTAssertEqual(preset("Schumann").beat, 7.83, accuracy: 0.001, "Schumann resonance is 7.83 Hz")
        XCTAssertEqual(preset("Delta").beat, 3)
        XCTAssertEqual(preset("Theta").beat, 6)
        XCTAssertEqual(preset("Alpha").beat, 10)
        XCTAssertEqual(preset("Beta").beat, 18)
        XCTAssertEqual(preset("Gamma").beat, 40)
    }

    func testGatewayPinsThe299And302EarFrequencies() {
        let gateway = preset("Gateway")
        XCTAssertEqual(gateway.beat, 3, accuracy: 0.001)
        XCTAssertEqual(gateway.carrier ?? 0, 300.5, accuracy: 0.001,
                       "carrier 300.5 ± 1.5 puts the ears exactly on 299/302 Hz")
        model.toggle(gateway)
        XCTAssertEqual(engine.starts.last?.carrier ?? 0, 300.5, accuracy: 0.001,
                       "the pinned carrier reaches the engine, not the 200 Hz default")
    }

    func testSolfeggioPresetsArePureTonesAtTheirCarrier() {
        // Beat 0 renders identical sines into both ears — a pure tone.
        for (name, hz) in [("Intuition", 852.0), ("Oneness", 963.0)] {
            let p = preset(name)
            XCTAssertEqual(p.beat, 0, accuracy: 0.001, "\(name) is a pure tone, not a beat")
            XCTAssertEqual(p.carrier ?? 0, hz, accuracy: 0.001)
            model.toggle(p)
            XCTAssertEqual(engine.starts.last?.beat ?? -1, 0, accuracy: 0.001)
            XCTAssertEqual(engine.starts.last?.carrier ?? 0, hz, accuracy: 0.001)
            model.stop()
        }
    }

    func testClassicPresetsKeepTheDefaultCarrier() {
        model.toggle(preset("Theta"))
        XCTAssertEqual(engine.starts.last?.carrier ?? 0, 200, accuracy: 0.001,
                       "presets without a pinned carrier stay on the classic 200 Hz")
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

    func testRenderGainIsFixedAndReachesTheEngine() {
        // Loudness is the device volume; the model renders every preset
        // at the same fixed amplitude.
        model.toggle(preset("Schumann"))
        XCTAssertEqual(engine.starts.last?.volume ?? 0, BinauralModel.renderGain, accuracy: 0.001)
        model.toggle(preset("Gateway"))
        XCTAssertEqual(engine.starts.last?.volume ?? 0, BinauralModel.renderGain, accuracy: 0.001)
        XCTAssertGreaterThan(BinauralModel.renderGain, 0)
        XCTAssertLessThanOrEqual(BinauralModel.renderGain, 1)
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

    func testResumePlaysWithoutTogglingOff() {
        model.resume(preset("Alpha"))
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(engine.starts.count, 1)
        // Already playing that preset: resume must not restart (or stop) it.
        model.resume(preset("Alpha"))
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(engine.starts.count, 1)
        // A different preset switches seamlessly.
        model.resume(preset("Gamma"))
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.active?.name, "Gamma")
        XCTAssertEqual(engine.starts.count, 2)
    }

    // MARK: Ghost-card regression (session events end the session)

    /// An audio-session interruption (call, Siri, another app's session)
    /// derails the engine without telling the model — the ghost-lock-
    /// screen-card bug: a "playing" card producing no sound forever.
    /// The interruption must stop the session AND clear the card.
    func testInterruptionStopsSessionAndClearsCard() {
        model.toggle(preset("Schumann"))
        XCTAssertTrue(model.isPlaying)

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])

        XCTAssertFalse(model.isPlaying, "interruption must end the session")
        XCTAssertEqual(engine.stops, 1, "interruption must stop the engine")
        XCTAssertEqual(Self.lastPublished.last?.title, nil, "interruption must clear the Now Playing card")
    }

    /// Unplugging headphones (route change, old device unavailable) must
    /// do the same — the engine loses its output and the card must not
    /// linger as a silent "playing" ghost.
    func testHeadphoneUnplugStopsSessionAndClearsCard() {
        model.toggle(preset("Theta"))
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(Self.lastPublished.last?.title, nil)
    }

    /// And a media-services reset (rare, but terminal for audio) must
    /// not leave the ghost either.
    func testMediaServicesResetStopsSession() {
        model.toggle(preset("Gamma"))
        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(Self.lastPublished.last?.title, nil)
    }
}
