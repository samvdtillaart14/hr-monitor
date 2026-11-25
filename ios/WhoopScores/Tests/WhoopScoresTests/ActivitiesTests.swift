import XCTest
@testable import WhoopScores

final class ActivitiesTests: XCTestCase {
    private var cal: Calibration {
        var c = Calibration.standard
        c.profile.restingHr = 50; c.profile.maxHr = 190      // reserve 140 → 30% = 92 bpm
        return c
    }

    /// 1 Hz-samples: per minuut een vaste hartslag.
    private func series(_ t0: Double, _ perMinute: [Double]) -> [Sample] {
        perMinute.enumerated().flatMap { m, hr in (0..<60).map { Sample(t: t0 + Double(m * 60 + $0), hr: hr) } }
    }

    private let t0 = 1_700_000_040.0   // op een minuutgrens

    func testDetectsTennisLikeSession() {
        let hr = Array(repeating: 60.0, count: 20) + Array(repeating: 125.0, count: 32) + Array(repeating: 62.0, count: 20)
        let d = WhoopScores.detectActivities(series(t0, hr), cal, now: t0 + 1e5)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].start, t0 + 20 * 60, accuracy: 1)
        XCTAssertEqual(d[0].end, t0 + 52 * 60, accuracy: 1)
    }

    func testWarmUpCounts() {
        // 5 min opwarmen op 85 bpm (25% reserve, onder de actieve drempel) telt mee in de activiteit
        let hr = Array(repeating: 60.0, count: 10) + Array(repeating: 85.0, count: 5) + Array(repeating: 130.0, count: 20) + Array(repeating: 60.0, count: 10)
        let d = WhoopScores.detectActivities(series(t0, hr), cal, now: t0 + 1e5)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].start, t0 + 10 * 60, accuracy: 1)
    }

    func testShortBurstIgnored() {
        let hr = Array(repeating: 60.0, count: 10) + Array(repeating: 140.0, count: 8) + Array(repeating: 60.0, count: 10)
        XCTAssertTrue(WhoopScores.detectActivities(series(t0, hr), cal, now: t0 + 1e5).isEmpty)
    }

    func testShortPausesBridgedLongPausesSplit() {
        let a = Array(repeating: 130.0, count: 20), pause2 = Array(repeating: 70.0, count: 2), pause10 = Array(repeating: 70.0, count: 10)
        XCTAssertEqual(WhoopScores.detectActivities(series(t0, a + pause2 + a), cal, now: t0 + 1e5).count, 1)
        XCTAssertEqual(WhoopScores.detectActivities(series(t0, a + pause10 + a), cal, now: t0 + 1e5).count, 2)
    }

    func testLightElevationNotAnActivity() {
        // 95 bpm: net boven de actieve drempel maar gemiddeld onder minMeanReserve (≈ 103 bpm)
        let hr = Array(repeating: 95.0, count: 40)
        XCTAssertTrue(WhoopScores.detectActivities(series(t0, hr), cal, now: t0 + 1e5).isEmpty)
    }

    func testExcludedAndOngoing() {
        let hr = Array(repeating: 130.0, count: 30)
        let s = series(t0, hr)
        XCTAssertTrue(WhoopScores.detectActivities(s, cal, exclude: [(t0, t0 + 1800)], now: t0 + 1e5).isEmpty)
        // net afgelopen: kan nog doorlopen
        XCTAssertTrue(WhoopScores.detectActivities(s, cal, now: t0 + 1800 + 60).isEmpty)
    }

    func testSummaryAndZones() {
        let s = series(t0, Array(repeating: 125.0, count: 30) + [190])
        let sum = WhoopScores.activitySummary(s, start: t0, end: t0 + 31 * 60, cal)
        XCTAssertEqual(sum.avgHr, (125 * 30 + 190) / 31, accuracy: 0.5)
        XCTAssertEqual(sum.maxHr, 190, accuracy: 0.1)
        XCTAssertEqual(sum.zoneSec.reduce(0, +), 31 * 60, accuracy: 2)
        XCTAssertEqual(sum.zoneSec[1], 30 * 60, accuracy: 2)   // 125 bpm = 53,6% reserve → zone 1
        XCTAssertGreaterThan(sum.strain, 0)
        XCTAssertGreaterThan(sum.kcal, 0)
        XCTAssertEqual(WhoopScores.zoneLowerBounds(cal.profile), [0, 120, 134, 148, 162, 176])
    }

    func testMeasuredSecondsAndRestingKcal() {
        // 10 min aaneengesloten, dan 1 uur gat, dan 1 sample: gat telt 5 s, laatste 1 s.
        let s = series(t0, Array(repeating: 60.0, count: 10)) + [Sample(t: t0 + 4200, hr: 60)]
        XCTAssertEqual(WhoopScores.measuredSeconds(s), 600 - 1 + 5 + 1, accuracy: 1e-9)
        XCTAssertEqual(WhoopScores.measuredSeconds([]), 0)
        // Mifflin-St Jeor, man 75 kg, 180 cm, 30 jaar: 1730 kcal/dag
        XCTAssertEqual(WhoopScores.restingKcalPerMin(.standard) * 1440, 1730, accuracy: 1e-6)
    }

    func testHeartRateRecovery() {
        // 150 bpm tot het einde, dan lineair −0,5 bpm/s tot 120 s erna: daling 30 na 1 min, 60 na 2 min.
        let end = 1_000_000.0
        let s = (0..<300).map { i -> Sample in
            let t = end - 120 + Double(i)
            return Sample(t: t, hr: t < end ? 150 : 150 - 0.5 * (t - end))
        }
        let r = WhoopScores.heartRateRecovery(s, end: end)
        XCTAssertEqual(r.one ?? 0, 30, accuracy: 1)
        XCTAssertEqual(r.two ?? 0, 60, accuracy: 1)
        // Geen data na het einde of te lage hartslag: geen waarde.
        XCTAssertNil(WhoopScores.heartRateRecovery(s.filter { $0.t < end }, end: end).one)
        XCTAssertNil(WhoopScores.heartRateRecovery(s.map { Sample(t: $0.t, hr: 80) }, end: end).one)
    }
}
