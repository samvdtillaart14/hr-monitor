import XCTest
@testable import WhoopScores

final class ImprovementsTests: XCTestCase {
    /// 1 januari 2026 00:00 UTC; tz +1 uur (CET).
    private let day0 = 1_767_225_600.0
    private let tz = 3600

    /// Nacht k: inslapen om `bed` (minuten na middernacht lokaal, mag > 1440), opstaan om `wake`.
    private func night(_ k: Int, bed: Int, wake: Int, asleep: Double = 420, eff: Double = 92, rhr: Double? = 55, cons: Double = 60) -> ImprovementInput.NightInfo {
        let base = day0 + Double(k) * 86400 - Double(tz)
        return .init(onset: base + Double(bed) * 60, wake: base + Double(wake) * 60, asleepMin: asleep, needMin: 480,
                     efficiency: eff, awakeMin: 30, rhr: rhr, consistency: cons)
    }

    private func input(_ nights: [ImprovementInput.NightInfo], days: [ImprovementInput.DayInfo] = []) -> ImprovementInput {
        ImprovementInput(nights: nights, days: days, maxHr: 196, restHr: 52, tzOffsetSec: tz)
    }

    func testLateIrregularBedtimeGivesConcreteTarget() {
        // 01:00, 01:50, 02:40 → gemiddeld 01:50; opstaan 09:00
        let i = input([night(1, bed: 1440 + 60, wake: 1440 + 540), night(2, bed: 1440 + 110, wake: 1440 + 540),
                       night(3, bed: 1440 + 160, wake: 1440 + 540)])
        let p = Improvements.sleepPlan(i)!
        XCTAssertEqual(Improvements.hhmm(p.bedMean), "01:50")
        XCTAssertEqual(Improvements.hhmm(p.target), "01:00")     // hooguit 45 min eerder, per kwartier
        XCTAssertTrue(p.moreLater)
        let t = Improvements.build(i)
        let reg = t.first { $0.id == "sleep.regular" }!
        XCTAssertFalse(reg.generic)
        XCTAssertTrue(reg.title.contains("01:00"), reg.title)
        XCTAssertTrue(reg.why.contains("01:50"), reg.why)
    }

    func testBedtimeAroundMidnightDoesNotWrap() {
        let i = input([night(1, bed: 1410, wake: 1440 + 450), night(2, bed: 1440 + 30, wake: 1440 + 450),
                       night(3, bed: 1440, wake: 1440 + 450)])
        XCTAssertEqual(Improvements.hhmm(Improvements.sleepPlan(i)!.bedMean), "00:00")
    }

    func testTooLittleDataGivesGenericStarters() {
        let t = Improvements.build(input([]))
        XCTAssertFalse(t.isEmpty)
        XCTAssertTrue(t.allSatisfy(\.generic))
        XCTAssertNotNil(t.first { $0.id == "sleep.regular" })
    }

    func testSortedByImpactAndUsesOwnNumbers() {
        var i = input((1...5).map { night($0, bed: 1440 + 110, wake: 1440 + 480, asleep: 330, rhr: $0 >= 4 ? 63 : 54) },
                      days: (0..<5).map { _ in ImprovementInput.DayInfo(strain: 8, zones13: 10, zones45: 0, measuredMin: 1200) })
        i.rhrBaseline = 55
        i.stepsPerDay = 5200; i.stepsMeasured = true
        i.strengthMinWeek = 0; i.strengthFromActivities = true
        i.factorYears = [.zones13: 1.5, .sleepHours: 1.0, .steps: 0.7, .strength: 1.5, .zones45: 0.5]
        let t = Improvements.build(i)
        XCTAssertEqual(t.map(\.impact), t.map(\.impact).sorted(by: >))
        let steps = t.first { $0.id == "move.steps" }!
        XCTAssertTrue(steps.title.contains("3.000"), steps.title)
        XCTAssertTrue(steps.why.contains("5.200"), steps.why)
        let rhr = t.first { $0.id == "recovery.rhr" }!
        XCTAssertTrue(rhr.why.contains("2 van de laatste 5"), rhr.why)
        let hours = t.first { $0.id == "sleep.hours" }!
        XCTAssertTrue(hours.title.contains("60 minuten"), hours.title)
        XCTAssertTrue(t.allSatisfy { !$0.generic })
    }

    func testNothingToImproveIsEmpty() {
        var i = input((1...5).map { night($0, bed: 1380, wake: 1440 + 420, asleep: 480, cons: 90) },
                      days: (0..<5).map { _ in ImprovementInput.DayInfo(strain: 12, zones13: 40, zones45: 6, measuredMin: 1300) })
        i.stepsPerDay = 10000; i.strengthMinWeek = 120; i.rhrBaseline = 55
        XCTAssertTrue(Improvements.build(i).isEmpty)
    }
}
