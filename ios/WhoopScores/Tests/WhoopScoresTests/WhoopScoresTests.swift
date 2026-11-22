import XCTest
@testable import WhoopScores

/// Gedeelde fixture, gemaakt door `node scores/test/make-fixture.mjs` met de JS-versie.
private struct Fixture: Decodable {
    struct Input: Decodable { let t0: Double; let hr: [Double]; let rr: [[Double]]; let q: [[Double]?]; let skinTemp: [Double?] }
    struct Night: Decodable {
        let onset: Double, wake: Double, inBedMin: Int, asleepMin: Int, awakeMin: Int, lightMin: Int, deepMin: Int, remMin: Int
        let disturbances: Int, hrv: Double, rhr: Double, resp: Double, skinTemp: Double, stages: String
        let stressMin: StressMinutes; let highStressPct: Double
    }
    struct Parts: Decodable { let healthy: Double, strain: Double, debt: Double, naps: Double, total: Double }
    struct Debt: Decodable { let prevDebtMin: Double, prevNeedMin: Double, prevAsleepMin: Double, debt: Double }
    struct Workout: Decodable { let input: [Double]; let strain: Double; let load: Double; let zoneMin: [Double] }
    struct Rec: Decodable { let history: [NightMetrics]; let night: NightMetrics; let calibration: Calibration; let score: Int; let scoreDefault: Int }
    struct Need: Decodable { let debtMin: Double; let prevDayStrain: Double; let napMin: Double; let need: Double }
    struct Perf: Decodable { let asleepMin: Double; let needMin: Double; let efficiency: Double; let consistency: Double; let perf: Double }
    struct Cons: Decodable { struct N: Decodable { let onset: Double; let wake: Double }; let nights: [N]; let value: Double }
    struct Expected: Decodable { let night: Night; let workout: Workout; let recovery: Rec; let sleepNeed: Need; let sleepPerf: Perf; let consistency: Cons; let needParts: Parts; let debt: Debt; let calories: Double }
    let calibration: Calibration
    let input: Input
    let expected: Expected

    static let shared: Fixture = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }   // → repo-root
        url.appendPathComponent("scores/test/fixtures/night.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    var samples: [Sample] {
        input.hr.indices.map { i in Sample(t: input.t0 + Double(i), hr: input.hr[i], rr: input.rr[i], q: input.q[i], skinTemp: input.skinTemp[i]) }
    }
}

final class WhoopScoresTests: XCTestCase {

    private func secs(_ rr: [Double]) -> [Sample] { rr.enumerated().map { Sample(t: 1000 + Double($0.offset), hr: 60, rr: [$0.element]) } }

    func testRMSSD() {
        let rr = (0..<60).map { $0 % 2 == 1 ? 1050.0 : 1000.0 }
        XCTAssertEqual(WhoopScores.rmssd(WhoopScores.beats(secs(rr))), 50, accuracy: 1e-9)
    }

    func testArtefacts() {
        var rr = (0..<60).map { $0 % 2 == 1 ? 1050.0 : 1000.0 }
        rr[20] = 2040; rr[40] = 250
        let b = WhoopScores.beats(secs(rr))
        XCTAssertEqual(b.filter { !$0.ok }.count, 2)
        XCTAssertEqual(WhoopScores.rmssd(b), 50, accuracy: 1e-9)
    }

    func testRespiratoryRate() {
        var s: [Double] = []; var t = 0.0
        for _ in 0..<180 { let rr = 1000 + 40 * sin(2 * Double.pi * 0.25 * t); t += rr / 1000; s.append(rr) }
        XCTAssertEqual(WhoopScores.respRateWindow(WhoopScores.beats(secs(s))), 15, accuracy: 0.5)
    }

    func testZonesAndStrain() {
        let p = Calibration.Profile(maxHr: 195, restingHr: 55, zoneMode: "hrr")
        XCTAssertEqual(WhoopScores.hrZone(100, p), 0)
        XCTAssertEqual(WhoopScores.hrZone(125, p), 1)
        XCTAssertEqual(WhoopScores.hrZone(139, p), 2)
        XCTAssertEqual(WhoopScores.hrZone(195, p), 5)
        XCTAssertEqual(WhoopScores.strainFromLoad(0), 0)
        var prev = 0.0
        for T in [10.0, 50, 100, 300, 1000] { let s = WhoopScores.strainFromLoad(T); XCTAssert(s > prev && s < 21); prev = s }
        XCTAssertEqual(WhoopScores.strainFromLoad(1e9), 21)
    }

    func testCalibrationRoundTrip() throws {
        let data = try JSONEncoder().encode(Calibration.standard)
        XCTAssertEqual(try JSONDecoder().decode(Calibration.self, from: data), .standard)
        XCTAssertEqual(Fixture.shared.calibration, .standard, "Swift-standaardwaarden wijken af van DEFAULT_CALIBRATION in JS")
    }

    // MARK: pariteit met de JS-versie

    func testNightMatchesJS() throws {
        let f = Fixture.shared, e = f.expected.night
        let n = try XCTUnwrap(WhoopScores.analyzeNight(f.samples, f.calibration, tzOffsetMin: 0))
        XCTAssertEqual(n.onset, e.onset); XCTAssertEqual(n.wake, e.wake)
        XCTAssertEqual(n.inBedMin, e.inBedMin); XCTAssertEqual(n.asleepMin, e.asleepMin); XCTAssertEqual(n.awakeMin, e.awakeMin)
        XCTAssertEqual(n.lightMin, e.lightMin); XCTAssertEqual(n.deepMin, e.deepMin); XCTAssertEqual(n.remMin, e.remMin)
        XCTAssertEqual(n.disturbances, e.disturbances)
        XCTAssertEqual(n.stressMin, e.stressMin); XCTAssertEqual(n.highStressPct, e.highStressPct, accuracy: 1e-9)
        XCTAssertEqual(n.stages.map { String(Array("WLDR")[$0.rawValue]) }.joined(), e.stages)
        XCTAssertEqual(n.hrv, e.hrv, accuracy: 1e-6); XCTAssertEqual(n.rhr, e.rhr, accuracy: 1e-6)
        XCTAssertEqual(n.resp, e.resp, accuracy: 1e-6); XCTAssertEqual(n.skinTemp, e.skinTemp, accuracy: 1e-6)
        // en inhoudelijk: de synthetische nacht heeft rust-HR 50 en ademfrequentie 15/min
        XCTAssertEqual(n.rhr, 55, accuracy: 2); XCTAssertEqual(n.resp, 15, accuracy: 0.6)
    }

    func testStrainMatchesJS() {
        let f = Fixture.shared, w = f.expected.workout
        let s = w.input.enumerated().map { Sample(t: 5000 + Double($0.offset), hr: $0.element) }
        let r = WhoopScores.strain(s, f.calibration)
        XCTAssertEqual(r.strain, w.strain, accuracy: 1e-9); XCTAssertEqual(r.load, w.load, accuracy: 1e-9)
        for z in 0..<6 { XCTAssertEqual(r.zoneMin[z], w.zoneMin[z], accuracy: 1e-9) }
    }

    func testRecoveryAndNeedMatchJS() {
        let f = Fixture.shared, r = f.expected.recovery, n = f.expected.sleepNeed
        XCTAssertEqual(WhoopScores.recovery(r.night, history: r.history, f.calibration), r.scoreDefault)
        XCTAssertEqual(WhoopScores.recovery(r.night, history: r.history, r.calibration), r.score)
        XCTAssertEqual(WhoopScores.sleepNeedMin(debtMin: n.debtMin, prevDayStrain: n.prevDayStrain, napMin: n.napMin, f.calibration), n.need, accuracy: 1e-9)
    }

    func testSleepPerformanceAndConsistencyMatchJS() {
        let f = Fixture.shared, p = f.expected.sleepPerf, c = f.expected.consistency
        XCTAssertEqual(WhoopScores.sleepPerformance(asleepMin: p.asleepMin, needMin: p.needMin, efficiency: p.efficiency, consistency: p.consistency, f.calibration), p.perf, accuracy: 1e-9)
        XCTAssertEqual(WhoopScores.sleepConsistency(c.nights.map { (onset: $0.onset, wake: $0.wake) }), c.value, accuracy: 1e-9)
        let n = { (d: Double, on: Double, off: Double) in (onset: d * 86400 + on * 3600, wake: d * 86400 + off * 3600) }
        XCTAssertEqual(WhoopScores.sleepConsistency([n(0, 23, 31), n(1, 23, 31), n(2, 23, 31), n(3, 25, 33)]), 60, accuracy: 1e-9)
    }

    func testNeedDebtCaloriesMatchJS() {
        let f = Fixture.shared, e = f.expected
        let p = WhoopScores.sleepNeedParts(debtMin: 100, prevDayStrain: 14, napMin: 20, f.calibration)
        XCTAssertEqual(p.healthy, e.needParts.healthy, accuracy: 1e-9); XCTAssertEqual(p.strain, e.needParts.strain, accuracy: 1e-9)
        XCTAssertEqual(p.debt, e.needParts.debt, accuracy: 1e-9); XCTAssertEqual(p.total, e.needParts.total, accuracy: 1e-9)
        XCTAssertEqual(WhoopScores.sleepDebt(prevDebtMin: e.debt.prevDebtMin, prevNeedMin: e.debt.prevNeedMin, prevAsleepMin: e.debt.prevAsleepMin, f.calibration), e.debt.debt, accuracy: 1e-9)
        let run = e.workout.input.enumerated().map { Sample(t: 5000 + Double($0.offset), hr: $0.element) }
        XCTAssertEqual(WhoopScores.calories(run, f.calibration), e.calories, accuracy: 1e-6)
    }

    func testLenientCalibrationLoad() throws {
        let old = #"{"profile":{"maxHr":205,"restingHr":57,"zoneMode":"hrr"},"recovery":{"windowDays":30}}"#
        let c = try Calibration.decodeLenient(Data(old.utf8))
        XCTAssertEqual(c.profile.maxHr, 205); XCTAssertEqual(c.profile.weightKg, 75); XCTAssertEqual(c.stress, .init())
    }

    func testRecoveryOrdering() {
        let hist = (0..<20).map { NightMetrics(hrv: 60 + Double($0 % 5) - 2, rhr: 55 + Double($0 % 3) - 1, resp: 15, skinTemp: 33.5) }
        let base = WhoopScores.recovery(.init(hrv: 60, rhr: 55, resp: 15, sleepPerf: 85, skinTemp: 33.5), history: hist)
        let good = WhoopScores.recovery(.init(hrv: 75, rhr: 52, resp: 15, sleepPerf: 95, skinTemp: 33.5), history: hist)
        let bad = WhoopScores.recovery(.init(hrv: 45, rhr: 60, resp: 16.5, sleepPerf: 60, skinTemp: 33.5), history: hist)
        XCTAssert(bad < base && base < good)
    }
}

final class HistoryTests: XCTestCase {
    func testImportWhoopAndTrends() {
        let csv = """
        \u{FEFF}Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Sleep performance %,Asleep duration (min),Sleep need (min),Sleep debt (min),Deep (SWS) duration (min),REM duration (min),Sleep onset
        2026-11-21 01:47:13,,UTC+01:00,68,72,31,56,354,596,127,48,96,"2026-11-21 01:47:13"
        2026-11-20 00:30:00,2026-11-21 01:47:13,UTC+01:00,67,57,29,64,343,595,126,40,90,
        2026-11-19 00:30:00,2026-11-20 00:30:00,UTC+01:00,22,58,21,40,242,596,128,30,60,
        """
        let r = History.importWhoop(cycles: csv)
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.last?.recovery, 68)
        XCTAssertEqual(r.last?.cycleStart, 1795222033)   // 01:47:13 UTC+1 = 00:47:13 UTC
        XCTAssertEqual(r.last?.onset, r.last?.cycleStart)
        XCTAssertEqual(r.last?.restorativeMin, 144)
        XCTAssertEqual(r.last!.sufficiency!, 100 * 354 / 596, accuracy: 1e-9)
        XCTAssertEqual(History.trailingMean(r, before: 2) { $0.hrv }!, 25, accuracy: 1e-9)
        XCTAssertEqual(History.nextDebt(after: r.last!), 127, accuracy: 1e-9)
        XCTAssertNil(History.typicalRange(r, before: 2) { $0.deepMin })
    }

    // MARK: nachtslaap versus dutjes

    func testNightBlocksMergeNapStays() throws {
        let day = 1795305600.0 // 22-11-2026 00:00 UTC
        let eps = (0..<1440).map { Epoch(t: day + Double($0) * 60, hr: 55, hrSd: 1, move: 0, skinTemp: .nan, n: 60) }
        let early = 114..<171, late = 232..<457, nap = 840..<880
        let r = try XCTUnwrap(WhoopScores.mainSleep(eps, periods: [early, late, nap], .standard, tzOffsetMin: 60))
        XCTAssertEqual(r.main, 114..<457)
        XCTAssertEqual(r.naps, [nap])
    }

    func testTrailingSnippetTrimmed() {
        let eps = (0..<168).map { i in Epoch(t: Double(i) * 60, hr: 55, hrSd: 1, move: i >= 150 && i < 157 ? 5 : 0.01, skinTemp: .nan, n: 60) }
        var cal = Calibration.standard; cal.sleep.moveThreshold = 1
        let d = WhoopScores.detectSleep(eps, cal)
        XCTAssertEqual(d.periods.count, 1)
        XCTAssertLessThanOrEqual(d.periods[0].upperBound, 150)
    }

    func testFirstNightsRecoveryUsesOwnValues() {
        let sam = NightMetrics(hrv: 31, rhr: 62, resp: 15.5, sleepPerf: 75, skinTemp: 33.5)
        for h in [0, 1, 3] {
            let hist = (0..<h).map { _ in NightMetrics(hrv: 31, rhr: 62, resp: 15.5, skinTemp: 33.5) }
            XCTAssertTrue((20...80).contains(WhoopScores.recovery(sam, history: hist, .standard)))
        }
    }

    func testSleepingInAfter8StaysNight() throws {
        let eps = (0..<1440).map { Epoch(t: 1795305600 + Double($0) * 60, hr: 55, hrSd: 1, move: 0, skinTemp: .nan, n: 60) }
        let r = try XCTUnwrap(WhoopScores.mainSleep(eps, periods: [120..<430, 455..<570], .standard, tzOffsetMin: 60))
        XCTAssertEqual(r.main, 120..<570); XCTAssertTrue(r.naps.isEmpty)
        let nap = try XCTUnwrap(WhoopScores.mainSleep(eps, periods: [120..<430, 780..<840], .standard, tzOffsetMin: 60))
        XCTAssertEqual(nap.main, 120..<430); XCTAssertEqual(nap.naps, [780..<840])
    }
}
