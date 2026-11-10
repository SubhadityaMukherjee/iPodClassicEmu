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
        // Angles: 0° = east, positive clockwise. Buttons ±32° around each
        // label; diagonals are scroll zones (nil).
        XCTAssertEqual(WheelCoordinator.quadrantZone(0), .next)
        XCTAssertEqual(WheelCoordinator.quadrantZone(31), .next)
        XCTAssertEqual(WheelCoordinator.quadrantZone(33), nil)
        XCTAssertEqual(WheelCoordinator.quadrantZone(45), nil)
        XCTAssertEqual(WheelCoordinator.quadrantZone(57), nil)
        XCTAssertEqual(WheelCoordinator.quadrantZone(59), .play)
        XCTAssertEqual(WheelCoordinator.quadrantZone(90), .play)
        XCTAssertEqual(WheelCoordinator.quadrantZone(121), .play)
        XCTAssertEqual(WheelCoordinator.quadrantZone(123), nil)
        XCTAssertEqual(WheelCoordinator.quadrantZone(147), nil)
        XCTAssertEqual(WheelCoordinator.quadrantZone(149), .prev)
        XCTAssertEqual(WheelCoordinator.quadrantZone(180), .prev)
        XCTAssertEqual(WheelCoordinator.quadrantZone(211), .prev)
        XCTAssertEqual(WheelCoordinator.quadrantZone(213), nil)
        XCTAssertEqual(WheelCoordinator.quadrantZone(237), nil)
        XCTAssertEqual(WheelCoordinator.quadrantZone(239), .menu)
        XCTAssertEqual(WheelCoordinator.quadrantZone(270), .menu)
        XCTAssertEqual(WheelCoordinator.quadrantZone(301), .menu)
        XCTAssertEqual(WheelCoordinator.quadrantZone(303), nil)
        XCTAssertEqual(WheelCoordinator.quadrantZone(327), nil)
        XCTAssertEqual(WheelCoordinator.quadrantZone(329), .next)
    }

    func testAdaptiveScrollRowsPerDetent() {
        // A deliberate slow roll — and any single quick detent flick —
        // must stay 1 row so wheel navigation stays 1:1.
        XCTAssertEqual(WheelCoordinator.rowsPerDetent(speed: 0), 1)
        XCTAssertEqual(WheelCoordinator.rowsPerDetent(speed: 120), 1)
        XCTAssertEqual(WheelCoordinator.rowsPerDetent(speed: 290), 1)
        // Speed tiers up with the spin and never below 1.
        XCTAssertEqual(WheelCoordinator.rowsPerDetent(speed: 310), 2)
        XCTAssertEqual(WheelCoordinator.rowsPerDetent(speed: 690), 2)
        XCTAssertEqual(WheelCoordinator.rowsPerDetent(speed: 750), 3)
        XCTAssertEqual(WheelCoordinator.rowsPerDetent(speed: 1250), 4)
        XCTAssertEqual(WheelCoordinator.rowsPerDetent(speed: 2500), 6)
        XCTAssertEqual(WheelCoordinator.rowsPerDetent(speed: -400), 2, "direction-agnostic: speed is |°/s|-like")
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
