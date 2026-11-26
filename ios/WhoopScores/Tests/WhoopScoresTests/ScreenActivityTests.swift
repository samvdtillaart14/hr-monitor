import XCTest
@testable import WhoopScores

final class ScreenActivityTests: XCTestCase {
    private let day = 1795305600.0   // 22-11-2026 00:00 UTC
    private let cet = 60.0           // UTC+1

    /// Stille nacht: 8 uur rust-HR zonder beweging.
    private func quietNight(minutes: Int = 480) -> [Epoch] {
        (0..<minutes).map { Epoch(t: day + Double($0) * 60, hr: 55, hrSd: 1, move: 0.01, skinTemp: .nan, n: 60) }
    }
    private var cal: Calibration { var c = Calibration.standard; c.sleep.moveThreshold = 1; return c }

    func testShortFlashWithoutUnlockIgnored() {
        let spans = [ScreenSpan(start: 100, end: 108, unlocked: false),    // melding licht het scherm op
                     ScreenSpan(start: 200, end: 260, unlocked: false),    // een minuut kijken
                     ScreenSpan(start: 400, end: 405, unlocked: true)]     // snel ontgrendeld
        XCTAssertEqual(ScreenActivity.wakeIntervals(spans), [200..<260, 400..<405])
    }

    func testOverlappingSpansMerge() {
        let spans = [ScreenSpan(start: 0, end: 100, unlocked: true), ScreenSpan(start: 50, end: 200, unlocked: true),
                     ScreenSpan(start: 300, end: 400, unlocked: true)]
        XCTAssertEqual(ScreenActivity.wakeIntervals(spans), [0..<200, 300..<400])
    }

    func testScreenOnMidNightIsWakeNotSleep() {
        let eps = quietNight()
        let plain = WhoopScores.detectSleep(eps, cal)
        XCTAssertEqual(plain.periods.count, 1)
        // 03:00–03:20 telefoon in de hand (epoch 180..<200)
        let awake = [day + 180 * 60 ..< day + 200 * 60]
        let d = WhoopScores.detectSleep(eps, cal, awake: awake)
        for i in 180..<200 { XCTAssertFalse(d.candidate[i], "minuut \(i) telt als slaap") }
        XCTAssertTrue(d.candidate[179]); XCTAssertTrue(d.candidate[200])
        // kleiner dan maxGapMin? dan één blok met wakker-minuten erin, anders twee blokken
        let covered = d.periods.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThanOrEqual(covered, 480 - 20 - 2 * 7)
    }

    func testScreenOnInMorningEndsSleep() throws {
        // Whoop ziet nog 40 min stil liggen, maar de telefoon is vanaf minuut 440 in gebruik.
        let eps = quietNight()
        let awake = [day + 440 * 60 ..< day + 480 * 60]
        let d = WhoopScores.detectSleep(eps, cal, awake: awake)
        let last = try XCTUnwrap(d.periods.last)
        XCTAssertLessThanOrEqual(last.upperBound, 440)
    }

    func testAnalyzeNightUsesAwake() throws {
        var samples: [Sample] = []
        for s in 0..<(480 * 60) {
            let rr = s % 2 == 0 ? 1080.0 : 1120.0
            samples.append(Sample(t: day + Double(s), hr: 55, rr: [rr], q: [1, 0, 0, 0], skinTemp: 34))
        }
        var c = Calibration.standard; c.sleep.moveThreshold = 1
        let base = try XCTUnwrap(WhoopScores.analyzeNight(samples, c, tzOffsetMin: cet))
        let cut = try XCTUnwrap(WhoopScores.analyzeNight(samples, c, tzOffsetMin: cet, awake: [day + 420 * 60 ..< day + 480 * 60]))
        XCTAssertLessThan(cut.wake, base.wake)
        XCTAssertLessThanOrEqual(cut.wake, day + 420 * 60)
    }

    func testMorningBriefWindowAndOncePerDay() {
        let at = { (h: Double) in self.day + (h - 1) * 3600 }   // lokale tijd h:00 bij UTC+1
        XCTAssertFalse(ScreenActivity.morningBriefDue(now: at(3), tzOffsetMin: cet, lastBriefDay: nil))
        XCTAssertTrue(ScreenActivity.morningBriefDue(now: at(7.2), tzOffsetMin: cet, lastBriefDay: nil))
        let today = ScreenActivity.localDay(at(7.2), tzOffsetMin: cet)
        XCTAssertFalse(ScreenActivity.morningBriefDue(now: at(9), tzOffsetMin: cet, lastBriefDay: today))
        XCTAssertTrue(ScreenActivity.morningBriefDue(now: at(7.2) + 86400, tzOffsetMin: cet, lastBriefDay: today))
        XCTAssertFalse(ScreenActivity.morningBriefDue(now: at(13), tzOffsetMin: cet, lastBriefDay: nil))
        // zelf ingestelde start: 06:30
        XCTAssertFalse(ScreenActivity.morningBriefDue(now: at(6.2), tzOffsetMin: cet, lastBriefDay: nil, startHour: 6.5))
    }

    /// 25-11: tot ~23:00 af en toe op de telefoon, ertussen stil: inslapen pas na het laatste telefoonmoment.
    func testPhoneBeforeBedPostponesOnset() throws {
        let eps = quietNight()
        // 3× 3 min telefoon met 25 min stil ertussen, laatste eindigt op minuut 84
        let awake = [0, 28, 81].map { day + Double($0) * 60 ..< day + Double($0 + 3) * 60 }
        let d = WhoopScores.detectSleep(eps, cal, awake: awake)
        let r = try XCTUnwrap(WhoopScores.mainSleep(eps, periods: d.periods, cal, tzOffsetMin: 0, awake: awake))
        XCTAssertGreaterThanOrEqual(r.main.lowerBound, 84)
    }
}
