import XCTest
@testable import iPodClassic

/// Timer and stopwatch state machines: transitions, guards, and reset
/// behavior. Notifications / Live Activities degrade to no-ops in the
/// test runner, so only the observable state is asserted.
@MainActor
final class ClockStateTests: XCTestCase {
    func testTimerStartSetsState() {
        let timer = TimerModel()
        timer.reset()
        timer.start(duration: 90)
        XCTAssertTrue(timer.isRunning)
        XCTAssertEqual(timer.total, 90)
        XCTAssertGreaterThan(timer.remaining, 89, "remaining starts at the full duration")
        timer.reset()
    }

    func testTimerRejectsNonPositiveDuration() {
        let timer = TimerModel()
        timer.reset()
        timer.start(duration: 0)
        timer.start(duration: -5)
        XCTAssertFalse(timer.isRunning, "0 / negative durations must not start the timer")
        XCTAssertEqual(timer.remaining, 0)
    }

    func testTimerPauseHoldsRemainingAndBlocksResumeGuards() {
        let timer = TimerModel()
        timer.reset()
        timer.start(duration: 60)
        timer.pause()
        XCTAssertFalse(timer.isRunning)
        let held = timer.remaining
        XCTAssertGreaterThan(held, 58)
        timer.pause()  // pause while paused: guard, no change
        XCTAssertFalse(timer.isRunning)
        timer.resume()
        XCTAssertTrue(timer.isRunning, "resume after pause restarts the countdown")
        timer.reset()
        timer.resume()
        XCTAssertFalse(timer.isRunning, "resume with nothing remaining must stay stopped")
    }

    func testTimerResetClearsEverything() {
        let timer = TimerModel()
        timer.start(duration: 30)
        timer.reset()
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.remaining, 0)
        XCTAssertEqual(timer.total, 0)
    }

    func testStopwatchAccumulatesLapsAndResets() {
        let stopwatch = StopwatchModel()
        stopwatch.reset()
        stopwatch.start()
        // The stopwatch tick is a main-runloop Timer; Thread.sleep would
        // block the runloop and it would never fire.
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        stopwatch.lap()
        stopwatch.stop()
        let frozen = stopwatch.elapsed
        XCTAssertGreaterThan(frozen, 0.1, "elapsed reflects real time")
        stopwatch.lap()  // lapping while stopped still records the frozen time
        XCTAssertEqual(stopwatch.laps.count, 2)
        XCTAssertEqual(stopwatch.laps.last ?? -1, frozen, accuracy: 0.001,
                       "a lap while stopped records the frozen elapsed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertEqual(stopwatch.elapsed, frozen, accuracy: 0.001, "stopped stopwatch does not accumulate")
        stopwatch.reset()
        XCTAssertEqual(stopwatch.elapsed, 0)
        XCTAssertTrue(stopwatch.laps.isEmpty)
    }
}
