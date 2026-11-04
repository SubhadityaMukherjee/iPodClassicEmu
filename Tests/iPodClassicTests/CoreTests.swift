import XCTest
@testable import iPodClassic

final class TimeFormatTests: XCTestCase {
    func testMss() {
        XCTAssertEqual(TimeFormat.mss(0), "0:00")
        XCTAssertEqual(TimeFormat.mss(83), "1:23")
        XCTAssertEqual(TimeFormat.mss(3723), "1:02:03")
    }

    func testHms() {
        XCTAssertEqual(TimeFormat.hms(300), "00:05:00")
        XCTAssertEqual(TimeFormat.hms(0), "00:00:00")
        XCTAssertEqual(TimeFormat.hms(3723), "01:02:03")
    }

    func testStopwatch() {
        XCTAssertEqual(TimeFormat.stopwatch(135.456), "02:15.45")
    }

    func testDuration() {
        XCTAssertEqual(TimeFormat.duration(65), "1:05")
        XCTAssertEqual(TimeFormat.duration(3700), "01:01:40")
    }
}

final class WheelGeometryTests: XCTestCase {
    func testQuadrantZones() {
        // Angles: 0° = east, positive clockwise.
        XCTAssertEqual(WheelCoordinator.quadrantZone(0), .next)
        XCTAssertEqual(WheelCoordinator.quadrantZone(44), .next)
        XCTAssertEqual(WheelCoordinator.quadrantZone(46), .play)
        XCTAssertEqual(WheelCoordinator.quadrantZone(90), .play)
        XCTAssertEqual(WheelCoordinator.quadrantZone(134), .play)
        XCTAssertEqual(WheelCoordinator.quadrantZone(136), .prev)
        XCTAssertEqual(WheelCoordinator.quadrantZone(180), .prev)
        XCTAssertEqual(WheelCoordinator.quadrantZone(224), .prev)
        XCTAssertEqual(WheelCoordinator.quadrantZone(226), .menu)
        XCTAssertEqual(WheelCoordinator.quadrantZone(270), .menu)
        XCTAssertEqual(WheelCoordinator.quadrantZone(314), .menu)
        XCTAssertEqual(WheelCoordinator.quadrantZone(316), .next)
        XCTAssertEqual(WheelCoordinator.quadrantZone(350), .next)
    }
}

final class AlarmMathTests: XCTestCase {
    func testHour24Conversion() {
        let alarm = AlarmStore.shared
        alarm.isPM = false
        alarm.hour = 12
        XCTAssertEqual(alarm.hour24, 0)
        alarm.hour = 7
        XCTAssertEqual(alarm.hour24, 7)
        alarm.isPM = true
        XCTAssertEqual(alarm.hour24, 19)
        alarm.hour = 12
        XCTAssertEqual(alarm.hour24, 12)
        alarm.isPM = false
        alarm.hour = 7
    }
}

final class NotesStoreTests: XCTestCase {
    func testCreateReadDelete() {
        let store = NotesStore()
        let name = store.create("Test Note ZZ")
        defer { store.delete(name) }
        XCTAssertTrue(name.hasPrefix("Test Note ZZ"))
        store.write(name, "hello world")
        XCTAssertEqual(store.read(name), "hello world")
        store.delete(name)
        XCTAssertEqual(store.read(name), "")
    }

    func testDuplicateNamesGetSuffix() {
        let a = NotesStore()
        let name = "Dup Note QQ"
        a.write(name, "first")
        let created = a.create(name)
        defer {
            a.delete(name)
            a.delete(created)
        }
        XCTAssertNotEqual(created, name)
    }
}

final class SettingsTests: XCTestCase {
    func testDefaultsRoundTrip() {
        let s = AppSettings.shared
        let originalCRT = s.crtEnabled
        s.crtEnabled = !originalCRT
        XCTAssertEqual(AppSettings.shared.crtEnabled, !originalCRT)
        s.crtEnabled = originalCRT
    }
}
