import XCTest
@testable import WhoopScores

final class InsightsTests: XCTestCase {
    private func hist() -> [NightMetrics] {
        (0..<10).map { i in NightMetrics(hrv: 30 + Double(i % 3), rhr: 55 + Double(i % 2), resp: 14 + 0.1 * Double(i % 3), skinTemp: 33.5 + 0.05 * Double(i % 2)) }
    }

    func testIllnessNeedsTwoSignals() {
        let h = hist()
        XCTAssertNil(Insights.illnessWarning(NightMetrics(hrv: 31, rhr: 55, resp: 14.1, skinTemp: 33.5), history: h))
        XCTAssertNil(Insights.illnessWarning(NightMetrics(hrv: 31, rhr: 62, resp: 14.1, skinTemp: 33.5), history: h))   // alleen rust-HR
        let w = Insights.illnessWarning(NightMetrics(hrv: 22, rhr: 62, resp: 14.1, skinTemp: 34.2), history: h)
        XCTAssertEqual(Set(w?.map(\.metric) ?? []), ["rhr", "hrv", "skin"])
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
