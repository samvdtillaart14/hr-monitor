import XCTest
@testable import WhoopScores

/// Randgevallen (zie docs/TESTPLAN.md, RG-xx; zelfde gevallen als scores/test/randgevallen.test.mjs).
/// Bekende bugs staan in `XCTExpectFailure`: de test faalt dan niet, maar zodra de bug is opgelost
/// meldt XCTest "expected failure not found" en moet het blok weg (dan bewaakt de test de oplossing).
final class RandgevallenTests: XCTestCase {
    private struct Input: Decodable { let t0: Double; let hr: [Double]; let rr: [[Double]]; let q: [[Double]?]; let skinTemp: [Double?] }
    private struct File: Decodable { let input: Input }

    /// De synthetische nacht uit scores/test/fixtures/night.json.
    private static let night: [Sample] = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("scores/test/fixtures/night.json")
        let i = try! JSONDecoder().decode(File.self, from: Data(contentsOf: url)).input
        return i.hr.indices.map { Sample(t: i.t0 + Double($0), hr: i.hr[$0], rr: i.rr[$0], q: i.q[$0], skinTemp: i.skinTemp[$0]) }
    }()
    private var night: [Sample] { Self.night }
    private let cal = Calibration.standard
    private let day = 1795305600.0   // 22-11-2026 00:00 UTC

    private func flatEpochs(_ t0: Double, _ n: Int) -> [Epoch] {
        (0..<n).map { Epoch(t: t0 + Double($0) * 60, hr: 55, hrSd: 1, move: 0, skinTemp: .nan, n: 60) }
    }

    func testRG01_noData() {
        XCTAssertNil(WhoopScores.analyzeNight([], cal))
        XCTAssertEqual(WhoopScores.strain([], cal).zoneMin, [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(WhoopScores.calories([], cal), 0)
        XCTAssertTrue(WhoopScores.epochs([]).isEmpty)
    }

    func testRG02_lessThan30Minutes() {
        XCTAssertNil(WhoopScores.analyzeNight(Array(night.prefix(25 * 60)), cal, tzOffsetMin: 0))
    }

    func testRG03_noRR() throws {
        let n = try XCTUnwrap(WhoopScores.analyzeNight(night.map { Sample(t: $0.t, hr: $0.hr, q: $0.q, skinTemp: $0.skinTemp) }, cal, tzOffsetMin: 0))
        XCTAssertGreaterThan(n.asleepMin, 60)
        XCTAssertTrue(n.hrv.isNaN); XCTAssertTrue(n.resp.isNaN)
    }

    func testRG04_liveOnly() throws {
        let ref = try XCTUnwrap(WhoopScores.analyzeNight(night, cal, tzOffsetMin: 0))
        // RR in 2 van elke 10 seconden, geen oriëntatie of huidtemperatuur: zoals alleen live-data
        let live = night.enumerated().map { i, s in Sample(t: s.t, hr: s.hr, rr: i % 10 < 2 ? s.rr : []) }
        let n = try XCTUnwrap(WhoopScores.analyzeNight(live, cal, tzOffsetMin: 0))
        XCTAssertTrue(n.hrv.isFinite && n.hrv > 5 && n.hrv < 200, "hrv \(n.hrv)")
        XCTAssertGreaterThanOrEqual(n.asleepMin, ref.asleepMin)
    }

    func testRG05_twoHourGap() throws {
        let t0 = night[0].t
        let gap = night.filter { !($0.t > t0 + 7200 && $0.t < t0 + 14400) }
        let n = try XCTUnwrap(WhoopScores.analyzeNight(gap, cal, tzOffsetMin: 0))
        XCTAssertLessThanOrEqual(Double(n.asleepMin), Double(gap.count) / 60 + 1)
    }

    func testRG06_duplicateSeconds() throws {
        let ref = try XCTUnwrap(WhoopScores.analyzeNight(night, cal, tzOffsetMin: 0))
        let n = try XCTUnwrap(WhoopScores.analyzeNight(night.flatMap { [$0, $0] }, cal, tzOffsetMin: 0))
        XCTAssertEqual(n.asleepMin, ref.asleepMin); XCTAssertEqual(n.inBedMin, ref.inBedMin)
    }

    func testRG07_unsortedInput() throws {
        // In Swift is dit een crash (index −1 in epochs) en een crash stopt de hele testrun; daarom overgeslagen.
        // De JS-test RG-07 bewaakt het algoritme; de app sorteert sinds deze versie in DayStore.samples.
        throw XCTSkip("BUG-3: epochs crasht op ongesorteerde invoer (zie JS-test RG-07)")
    }

    func testRG08_strainNeverNegative() {
        let s = [Sample(t: 100, hr: 150), Sample(t: 50, hr: 150), Sample(t: 51, hr: 150)]
        XCTExpectFailure("BUG-3: negatieve tijdstap telt als negatieve zoneminuten")
        XCTAssertTrue(WhoopScores.strain(s, cal).zoneMin.allSatisfy { $0 >= 0 })
        XCTAssertGreaterThanOrEqual(WhoopScores.calories(s, cal), 0)
    }

    func testRG09_firstNightsRecoveryNotExtreme() {
        let sam = NightMetrics(hrv: 31, rhr: 62, resp: 15.5, sleepPerf: 75, skinTemp: 33.5)
        for h in [0, 1, 3] {
            let hist = (0..<h).map { _ in NightMetrics(hrv: 31, rhr: 62, resp: 15.5, skinTemp: 33.5) }
            let r = WhoopScores.recovery(sam, history: hist, cal)
            XCTAssertTrue((20...80).contains(r), "\(h) nachten historie → \(r)%")
        }
    }

    func testRG10_identicalHistory() {
        let hist = (0..<5).map { _ in NightMetrics(hrv: 31, rhr: 62, resp: 15.5, skinTemp: 33.5) }
        let r = WhoopScores.recovery(.init(hrv: 31, rhr: 62, resp: 15.5, sleepPerf: 75, skinTemp: 33.5), history: hist, cal)
        XCTAssertTrue((30...80).contains(r), "\(r)")
        let worse = WhoopScores.recovery(.init(hrv: 28, rhr: 64, resp: 15.5, sleepPerf: 75, skinTemp: 33.5), history: hist, cal)
        XCTAssertLessThan(worse, r)
    }

    func testRG11_recoveryBounds() {
        for hrv in [1.0, 5, 300] { for rhr in [35.0, 110] {
            let r = WhoopScores.recovery(.init(hrv: hrv, rhr: rhr, resp: 15, sleepPerf: 50), history: [], cal)
            XCTAssertTrue((1...99).contains(r))
        } }
    }

    func testRG12_sleepingInAfter8IsStillNight() throws {
        let r = try XCTUnwrap(WhoopScores.mainSleep(flatEpochs(day, 1440), periods: [120..<430, 455..<570], cal, tzOffsetMin: 60))
        XCTAssertEqual(r.main, 120..<570)
        XCTAssertTrue(r.naps.isEmpty)
    }

    func testRG14_timezoneShift() throws {
        let a = try XCTUnwrap(WhoopScores.mainSleep(flatEpochs(day, 1440), periods: [114..<171, 232..<457], cal, tzOffsetMin: 60))
        let b = try XCTUnwrap(WhoopScores.mainSleep(flatEpochs(day - 3600, 1440), periods: [114..<171, 232..<457], cal, tzOffsetMin: 120))
        XCTAssertEqual(a.main, b.main)
    }

    func testRG15_tooLittleForConsistencyOrPerformance() {
        XCTAssertTrue(WhoopScores.sleepConsistency([(onset: 0, wake: 3600)]).isNaN)
        XCTAssertTrue(WhoopScores.sleepSufficiency(asleepMin: 400, needMin: 0).isNaN)
        XCTAssertTrue(WhoopScores.sleepPerformance(asleepMin: 400, needMin: 0, cal).isNaN)
    }

    func testRG16_singleSpikeBarelyCounts() {
        let s = (0..<600).map { Sample(t: 1000 + Double($0), hr: $0 == 300 ? 220 : 60) }
        XCTAssertLessThan(WhoopScores.strain(s, cal).strain, 0.5)
    }

    func testRG18_debtBounded() {
        for (d, need, slept) in [(0.0, 480.0, 0.0), (500, 480, 0), (0, 480, 900), (0, .nan, 300)] {
            let v = WhoopScores.sleepDebt(prevDebtMin: d, prevNeedMin: need, prevAsleepMin: slept, cal)
            XCTAssertTrue(v >= 0 && v <= cal.sleep.debtCapMin)
        }
    }

    // MARK: datagaten en handmatige slaaptijden (25-11-2026)

    func testDataGapInNightDoesNotSplitSleep() throws {
        let full = try XCTUnwrap(WhoopScores.analyzeNight(night, cal, tzOffsetMin: 0))
        // Een uur zonder metingen midden in de slaap (app gepauzeerd): zelfde nacht, gat telt niet als wakker.
        let mid = (full.onset + full.wake) / 2
        let gapped = night.filter { $0.t < mid - 1800 || $0.t >= mid + 1800 }
        let r = try XCTUnwrap(WhoopScores.analyzeNight(gapped, cal, tzOffsetMin: 0))
        XCTAssertEqual(r.onset, full.onset, accuracy: 300)
        XCTAssertEqual(r.wake, full.wake, accuracy: 300)
        XCTAssertGreaterThanOrEqual(r.asleepMin, full.asleepMin - 10)
    }

    func testManualSleepWindowOverridesDetection() throws {
        let full = try XCTUnwrap(WhoopScores.analyzeNight(night, cal, tzOffsetMin: 0))
        // Begin een uur vóór de eerste meting (niet gesynct): telt als slaap, eind zoals opgegeven.
        let start = night[0].t - 3600, end = full.wake - 600
        let r = try XCTUnwrap(WhoopScores.analyzeNight(night, cal, tzOffsetMin: 0, manual: start..<end))
        XCTAssertEqual(r.onset, start, accuracy: 60)
        XCTAssertEqual(r.wake, end, accuracy: 60)
        XCTAssertEqual(r.inBedMin, Int(((end - start) / 60).rounded()), accuracy: 2)
        XCTAssertGreaterThanOrEqual(r.asleepMin, 60)
        // Telefoon 5 min aan midden in de nacht: wakker binnen de slaap, nacht blijft heel.
        let mid = (start + end) / 2
        let p = try XCTUnwrap(WhoopScores.analyzeNight(night, cal, tzOffsetMin: 0, awake: [mid..<(mid + 300)], manual: start..<end))
        XCTAssertEqual(p.onset, start, accuracy: 60)
        XCTAssertEqual(p.wake, end, accuracy: 60)
        XCTAssertGreaterThanOrEqual(p.awakeMin, 5)
    }

    func testPhoneAfterToiletKeepsNightWhole() throws {
        // 23:00–07:00 slaap met om 03:00 wc + 5 min telefoon (15 min wakker): één nacht.
        let eps = flatEpochs(day - 3600, 1440)   // 23:00 lokaal (UTC+1) = 22:00 UTC
        let phone = [(eps[240].t)..<(eps[245].t)]
        let d = WhoopScores.detectSleep(eps, cal, awake: phone)
        let r = try XCTUnwrap(WhoopScores.mainSleep(eps, periods: d.periods.filter { $0.lowerBound < 480 }.map { $0.clamped(to: 0..<480) },
                                                    cal, tzOffsetMin: 60, awake: phone))
        XCTAssertEqual(r.main.lowerBound, 0)
        XCTAssertGreaterThanOrEqual(r.main.upperBound, 470)
    }

    /// 25-11: stil op de bank (HR ~76, geen bewegingsdata) telde als slaap; inslapen pas bij de HR-daling.
    func testCouchWithoutMotionIsNotSleep() {
        let eps = (0..<600).map { i in
            Epoch(t: day + Double(i) * 60, hr: i < 90 ? 76 : 57, hrSd: 1, move: 0, skinTemp: .nan, n: 60, hasMotion: false)
        }
        let d = WhoopScores.detectSleep(eps, cal)
        XCTAssertEqual(d.periods.first?.lowerBound ?? -1, 90, accuracy: 3)
    }

    /// Wel bewegingsdata, stil liggen met verhoogde HR: inslapen schuift op naar de HR-daling.
    func testOnsetWaitsForHrDrop() {
        let eps = (0..<600).map { i in
            Epoch(t: day + Double(i) * 60, hr: i < 60 ? 72 : 56, hrSd: 1, move: 0, skinTemp: .nan, n: 60)
        }
        let d = WhoopScores.detectSleep(eps, cal)
        XCTAssertEqual(d.periods.first?.lowerBound ?? -1, 60, accuracy: 6)
    }
}
