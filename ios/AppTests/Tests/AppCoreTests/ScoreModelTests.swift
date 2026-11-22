import XCTest
import WhoopScores
@testable import AppCore

/// SCORE-01…08 uit docs/TESTPLAN.md: ScoreModel.compute (nachten en dagen zoals de schermen ze krijgen).
final class ScoreModelTests: XCTestCase {
    private struct Input: Decodable { let t0: Double; let hr: [Double]; let rr: [[Double]]; let q: [[Double]?]; let skinTemp: [Double?] }
    private struct File: Decodable { let input: Input }

    /// Synthetische nacht (scores/test/fixtures/night.json), verschoven zodat hij om 23:30 lokale tijd begint
    /// in de nacht vóór `date`.
    private static let raw: Input = {
        let url = TS.repoRoot.appendingPathComponent("scores/test/fixtures/night.json")
        return try! JSONDecoder().decode(File.self, from: Data(contentsOf: url)).input
    }()
    private func night(before date: Date, dropRR: Bool = false) -> [Sample] {
        let start = Calendar.current.date(byAdding: .minute, value: -30, to: date)!.timeIntervalSince1970
        let i = Self.raw
        return i.hr.indices.map { k in
            Sample(t: start + Double(k), hr: i.hr[k], rr: dropRR ? [] : i.rr[k], q: i.q[k], skinTemp: i.skinTemp[k])
        }
    }
    private let cal = Calibration.standard
    private var day1: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10))! }
    private func day(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: day1)! }

    func testSCORE01_noDataNoNightsNoNegativeDays() {
        let (n, d) = ScoreModel.compute([(day(0), [], []), (day(1), [], [])], cal)
        XCTAssertTrue(n.isEmpty)
        XCTAssertEqual(d.count, 2)
        for x in d { XCTAssertEqual(x.strain, 0); XCTAssertEqual(x.kcal, 0); XCTAssertEqual(x.measuredMin, 0) }
    }

    func testSCORE02_oneNightGivesCompleteNight() throws {
        let s = night(before: day(0))
        let (n, _) = ScoreModel.compute([(day(0), s, [])], cal)
        let x = try XCTUnwrap(n.first)
        XCTAssertGreaterThan(x.r.asleepMin, 60)
        XCTAssertGreaterThan(x.needMin, 0)
        XCTAssertNotNil(x.performance)
        XCTAssertNotNil(x.recovery)
        XCTAssertTrue((1...99).contains(x.recovery ?? 0))
        XCTAssertEqual(x.stressMin.reduce(0, +), x.r.stressMin.low + x.r.stressMin.medium + x.r.stressMin.high)
        XCTAssertFalse(x.hr.isEmpty)
        XCTAssertNil(x.consistency, "consistentie pas vanaf 2 nachten")
    }

    func testSCORE03_noRRMeansNoRecoveryInsteadOfAGuess() throws {
        let (n, _) = ScoreModel.compute([(day(0), night(before: day(0), dropRR: true), [])], cal)
        let x = try XCTUnwrap(n.first)
        XCTAssertNil(x.metrics.hrv)
        XCTAssertNil(x.recovery)
    }

    func testSCORE04_tooLittleDataNoNight() {
        let (n, _) = ScoreModel.compute([(day(0), Array(night(before: day(0)).prefix(1800)), [])], cal)
        XCTAssertTrue(n.isEmpty)
    }

    func testSCORE05_debtCarriesOnlyOverConsecutiveNights() throws {
        let (n, _) = ScoreModel.compute([(day(0), night(before: day(0)), []), (day(1), night(before: day(1)), []),
                                         (day(4), night(before: day(4)), [])], cal)
        XCTAssertEqual(n.count, 3)
        // synthetische nacht is kort (~4 u) → tekort → schuld de volgende nacht
        XCTAssertGreaterThan(n[1].debtMin, 0)
        XCTAssertGreaterThan(n[1].needMin, n[0].needMin)
        XCTAssertEqual(n[2].debtMin, 0, "na een gat van dagen geen doorlopende schuld")
        XCTAssertNotNil(n[1].consistency)
    }

    func testSCORE06_dayStrainAndEnergy() throws {
        // 30 min op 150 bpm midden op de dag
        let noon = Calendar.current.date(byAdding: .hour, value: 12, to: day(0))!.timeIntervalSince1970
        let s = (0..<1800).map { Sample(t: noon + Double($0), hr: 150) }
        let (_, d) = ScoreModel.compute([(day(0), [], s)], cal)
        let x = try XCTUnwrap(d.first)
        XCTAssertGreaterThan(x.strain, 5); XCTAssertLessThanOrEqual(x.strain, 21)
        XCTAssertEqual(x.zoneMin.reduce(0, +), 30, accuracy: 0.1)
        XCTAssertEqual(x.measuredMin, 30, accuracy: 0.1)
        // energie: gemeten deel + rustverbruik over de rest van de dag ≥ rustverbruik van een hele dag
        XCTAssertGreaterThan(x.kcal, WhoopScores.restingKcalPerMin(cal) * 1440)
    }

    func testSCORE07_priorHistoryIsUsed() throws {
        let s = night(before: day(0))
        let (a, _) = ScoreModel.compute([(day(0), s, [])], cal)
        let m = try XCTUnwrap(a.first?.metrics)
        // historie die gelijk is aan deze nacht → herstel rond het midden
        let prior = (0..<10).map { _ in m }
        let (b, _) = ScoreModel.compute([(day(0), s, [])], cal, prior: prior)
        let r = try XCTUnwrap(b.first?.recovery)
        XCTAssertTrue((30...85).contains(r), "\(r)")
    }

    func testSCORE08_valuesFiniteForUI() throws {
        let (n, d) = ScoreModel.compute([(day(0), night(before: day(0)), night(before: day(0)))], cal)
        let x = try XCTUnwrap(n.first)
        for v in [x.needMin, x.sufficiency, x.efficiency, x.highStressPct, d[0].strain, d[0].kcal] { XCTAssertTrue(v.isFinite) }
        for (_, v) in x.stress { XCTAssertTrue((0...3).contains(v)) }
    }
}
