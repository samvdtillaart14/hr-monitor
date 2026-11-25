import XCTest
@testable import WhoopScores

final class InsightsTests: XCTestCase {
    private func hist() -> [NightMetrics] {
        (0..<10).map { (i: Int) -> NightMetrics in
            let a: Double = Double(i % 3)
            let b: Double = Double(i % 2)
            let hrv: Double = 30 + a
            let rhr: Double = 55 + b
            let resp: Double = 14 + 0.1 * a
            let skin: Double = 33.5 + 0.05 * b
            return NightMetrics(hrv: hrv, rhr: rhr, resp: resp, skinTemp: skin)
        }
    }

    func testIllnessNeedsTwoSignals() {
        let h = hist()
        XCTAssertNil(Insights.illnessWarning(NightMetrics(hrv: 31, rhr: 55, resp: 14.1, skinTemp: 33.5), history: h))
        XCTAssertNil(Insights.illnessWarning(NightMetrics(hrv: 31, rhr: 62, resp: 14.1, skinTemp: 33.5), history: h))   // alleen rust-HR
        let w = Insights.illnessWarning(NightMetrics(hrv: 22, rhr: 62, resp: 14.1, skinTemp: 34.2), history: h)
        XCTAssertEqual(Set(w?.map(\.metric) ?? []), ["rhr", "hrv", "skin"])
    }

    func testIllnessOneSignalTwoNights() {
        var h = hist()
        let sick = NightMetrics(hrv: 31, rhr: 55, resp: 14.1, skinTemp: 34.3)
        XCTAssertNil(Insights.illnessWarning(sick, history: h))                    // eerste nacht: alleen huidtemp
        h.append(sick)
        XCTAssertEqual(Insights.illnessWarning(sick, history: h)?.map(\.metric), ["skin"])   // tweede nacht op rij
    }

    func testSpo2Drop() {
        let h = hist().map { m -> NightMetrics in var x = m; x.spo2 = 96 + Double(Int(m.rhr ?? 0) % 2); return x }
        var n = NightMetrics(hrv: 22, rhr: 55, resp: 14.1, skinTemp: 33.5); n.spo2 = 91
        XCTAssertEqual(Set(Insights.illnessWarning(n, history: h)?.map(\.metric) ?? []), ["hrv", "spo2"])
    }

    func testIllnessNeedsHistory() {
        XCTAssertNil(Insights.illnessWarning(NightMetrics(hrv: 10, rhr: 80, skinTemp: 36), history: Array(hist().prefix(4))))
    }

    func testWeekAdvice() {
        var short = NightMetrics(hrv: 30, rhr: 55); short.asleepMin = 360
        let w = Insights.summary(Array(repeating: short, count: 5))
        XCTAssertEqual(Insights.advice(this: w, prev: Insights.WeekSummary()).key, "sleep")
        XCTAssertEqual(Insights.advice(this: Insights.summary([short]), prev: Insights.WeekSummary()).key, "data")
        var ok = NightMetrics(hrv: 30, rhr: 58, consistency: 90); ok.asleepMin = 480
        var prev = NightMetrics(hrv: 30, rhr: 55); prev.asleepMin = 480
        XCTAssertEqual(Insights.advice(this: Insights.summary(Array(repeating: ok, count: 5)), prev: Insights.summary([prev])).key, "rhr")
    }

    func testJournalEffects() {
        var entries: [String: Set<String>] = [:], nights: [String: NightMetrics] = [:]
        for d in 0..<12 {
            let alcohol = d % 2 == 0
            entries["d\(d)"] = alcohol ? ["alcohol"] : []
            var n = NightMetrics(hrv: alcohol ? 24 : 32, rhr: alcohol ? 60 : 55); n.recovery = alcohol ? 40 : 70
            nights["d\(d + 1)"] = n
        }
        let next = { (k: String) in "d\(Int(k.dropFirst())! + 1)" }
        let e = Insights.effects(entries: entries, nights: nights, tags: ["alcohol", "sport"], nextDay: next)
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].tag, "alcohol")
        XCTAssertEqual(e[0].recovery!, -30, accuracy: 1e-9)
        XCTAssertEqual(e[0].hrv!, -8, accuracy: 1e-9)
    }
}
