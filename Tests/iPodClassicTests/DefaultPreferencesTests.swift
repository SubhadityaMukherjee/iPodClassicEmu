import XCTest
@testable import iPodClassic

/// The factory preferences requested for first-run setup: small font,
/// vibration off, medium scanlines. Verified against explicit key clears
/// so the test is deterministic regardless of other tests in the process.
final class DefaultPreferencesTests: XCTestCase {
    @MainActor
    func testFactoryDefaults() {
        UserDefaults.standard.removeObject(forKey: "display.fontScale")
        UserDefaults.standard.removeObject(forKey: "display.scanlines")
        UserDefaults.standard.removeObject(forKey: "wheel.haptics")
        UserDefaults.standard.removeObject(forKey: "wheel.scrollHaptics")
        UserDefaults.standard.removeObject(forKey: "wheel.buttonHaptics")
        UserDefaults.standard.removeObject(forKey: "wheel.tickSounds")

        let settings = AppSettings.shared
        XCTAssertEqual(settings.fontScale, 0, "factory font size should be Small")
        XCTAssertEqual(settings.scanlineIntensity, 2, "factory scanlines should be Medium")
        XCTAssertTrue(settings.hapticsEnabled, "factory haptics should be On")
        XCTAssertEqual(settings.scrollingHaptics, 3, "factory scroll haptics should be Strong")
        XCTAssertEqual(settings.buttonHaptics, 2, "factory button haptics should be Heavy")
        XCTAssertFalse(settings.tickSounds, "factory tick sounds should be Off")
    }
}
