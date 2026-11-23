import XCTest
@testable import WhoopScores

final class SleepHabitsTests: XCTestCase {
    func testWeekDebtSumsShortfallAndNeverNegative() {
        let n: [(asleepMin: Double, needMin: Double)] = [(400, 480), (420, 480), (540, 480), (300, 480)]
        // 80 + 60 − 60 + 180 = 260
        XCTAssertEqual(SleepHabits.weekDebtMin(n), 260, accuracy: 0.001)
        XCTAssertEqual(SleepHabits.weekDebtMin([(600, 480), (480, 480)]), 0, accuracy: 0.001)
    }

    func testWeekDebtOnlyLastSevenNights() {
        let n = [(asleepMin: 0.0, needMin: 480.0)] + Array(repeating: (asleepMin: 470.0, needMin: 480.0), count: 7)
        XCTAssertEqual(SleepHabits.weekDebtMin(n), 70, accuracy: 0.001)
    }

    func testLatencyFromLastScreenOff() {
        let onset = 10_000.0
        let awake: [Range<Double>] = [1_000..<2_000, 8_000..<8_800]   // laatste keer scherm uit 8800 → 20 min
        XCTAssertEqual(SleepHabits.latencyMin(onset: onset, awake: awake), 20)
    }

    func testLatencyUnknownWithoutPhone() {
        XCTAssertNil(SleepHabits.latencyMin(onset: 10_000, awake: []))
        XCTAssertNil(SleepHabits.latencyMin(onset: 100_000, awake: [1_000..<2_000]))   // > 2 uur ervoor
    }

    func testLatencyZeroWhenScreenOverlapsOnset() {
        XCTAssertEqual(SleepHabits.latencyMin(onset: 10_000, awake: [9_500..<10_300]), 0)
    }
}
