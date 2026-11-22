import XCTest
@testable import WhoopScores

final class SleepPlannerTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: schema

    func testWeekdayEveningPlansNextMorning() {
        // vrijdag 21-11-2026 22:00 → zaterdag 10:00, slaapdoel
        let s = AlarmSchedule.standard
        let n = s.nextWake(after: date(2026, 11, 20, 22), cal)
        XCTAssertEqual(n.date, date(2026, 11, 21, 10))
        XCTAssertEqual(n.rule.mode, .sleepGoal)
        // zondag 22:00 → maandag 07:00, vaste tijd
        let m = s.nextWake(after: date(2026, 11, 22, 22), cal)
        XCTAssertEqual(m.date, date(2026, 11, 23, 7))
        XCTAssertEqual(m.rule.mode, .exact)
    }

    func testAfterMidnightBeforeWakeIsSameMorning() {
        let n = AlarmSchedule.standard.nextWake(after: date(2026, 11, 24, 2), cal)
        XCTAssertEqual(n.date, date(2026, 11, 24, 7))
        // net na de wektijd: de volgende ochtend
        XCTAssertEqual(AlarmSchedule.standard.nextWake(after: date(2026, 11, 24, 7, 1), cal).date, date(2026, 11, 25, 7))
    }

    func testOverrideOnlyForThatMorning() {
        var s = AlarmSchedule.standard
        s.override = .init(day: "2026-11-25", rule: AlarmRule(minutes: 8 * 60 + 30, mode: .recovered))
        XCTAssertEqual(s.nextWake(after: date(2026, 11, 24, 22), cal).date, date(2026, 11, 25, 8, 30))
        XCTAssertEqual(s.nextWake(after: date(2026, 11, 25, 22), cal).date, date(2026, 11, 26, 7))
        s.dropExpiredOverride(now: date(2026, 11, 26, 9), cal)
        XCTAssertNil(s.override)
    }

    func testScheduleRoundTripsAsJSON() throws {
        let s = AlarmSchedule(enabled: true, weekday: AlarmRule(minutes: 400, mode: .recovered), weekend: AlarmRule(minutes: 600, mode: .exact))
        let back = try JSONDecoder().decode(AlarmSchedule.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    // MARK: slaapbehoefte en bedtijd

    func testNeedGrowsWithDebtAndStrainAndShrinksWithNaps() {
        let base = SleepPlanner.tonightNeed(prevDebtMin: nil, prevNeedMin: nil, prevAsleepMin: nil, strainToday: 0, napMinToday: 0)
        XCTAssertEqual(base.parts.total, Calibration.standard.sleep.needBaseMin, accuracy: 0.01)
        XCTAssertEqual(base.debtMin, 0)
        // 3 uur te kort geslapen → schuld en hogere behoefte
        let short = SleepPlanner.tonightNeed(prevDebtMin: 0, prevNeedMin: 480, prevAsleepMin: 300, strainToday: 0, napMinToday: 0)
        XCTAssertGreaterThan(short.debtMin, 0)
        XCTAssertGreaterThan(short.parts.total, base.parts.total)
        let hard = SleepPlanner.tonightNeed(prevDebtMin: nil, prevNeedMin: nil, prevAsleepMin: nil, strainToday: 16, napMinToday: 0)
        XCTAssertGreaterThan(hard.parts.total, base.parts.total)
        let nap = SleepPlanner.tonightNeed(prevDebtMin: nil, prevNeedMin: nil, prevAsleepMin: nil, strainToday: 0, napMinToday: 30)
        XCTAssertEqual(nap.parts.total, base.parts.total - 30, accuracy: 0.01)
    }

    func testBedtimeFromGoalEfficiencyAndLatency() {
        let need = WhoopScores.NeedParts(healthy: 480, strain: 0, debt: 0, naps: 0, total: 480)
        let wake = date(2026, 11, 24, 7)
        let p = SleepPlanner.plan(need: need, goal: .full, wake: wake, efficiency: 90, latencyMin: 15)
        // 480 / 0,9 = 533,3 + 15 = 548,3 → 550 min in bed → 21:50
        XCTAssertEqual(p.inBedMin, 550)
        XCTAssertEqual(p.bedtime, date(2026, 11, 23, 21, 50))
        let p85 = SleepPlanner.plan(need: need, goal: .perform, wake: wake, efficiency: 90, latencyMin: 15)
        XCTAssertEqual(p85.goalSleepMin, 408, accuracy: 0.01)
        XCTAssertLessThan(p85.inBedMin, p.inBedMin)
        XCTAssertGreaterThan(p85.bedtime, p.bedtime)
    }

    func testPlanFallsBackWithoutMeasurements() {
        let need = WhoopScores.NeedParts(healthy: 460, strain: 0, debt: 0, naps: 0, total: 460)
        let p = SleepPlanner.plan(need: need, goal: .full, wake: date(2026, 11, 24, 7), efficiency: .nan, latencyMin: nil)
        XCTAssertEqual(p.efficiency, SleepPlanner.defaultEfficiency)
        XCTAssertEqual(p.latencyMin, SleepPlanner.defaultLatencyMin)
    }

    // MARK: ritme

    func testUsualWindowAroundMidnight() {
        let tz = 3600
        func n(_ day: Int, bed: Int, wake: Int) -> (onset: Double, wake: Double) {
            let base = 1_767_225_600.0 + Double(day) * 86400 - Double(tz)
            return (base + Double(bed) * 60, base + Double(wake) * 60)
        }
        let w = SleepPlanner.usualWindow([n(1, bed: 1410, wake: 1440 + 450), n(2, bed: 1440 + 45, wake: 1440 + 450),
                                          n(3, bed: 1440 + 15, wake: 1440 + 460)], tzOffsetSec: tz, fallback: (0, 0))
        XCTAssertTrue(w.measured)
        XCTAssertEqual(w.bed, 15)
        XCTAssertEqual(w.wake, 450)
        let f = SleepPlanner.usualWindow([], tzOffsetSec: tz, fallback: (1410, 450))
        XCTAssertFalse(f.measured)
        XCTAssertEqual(f.bed, 1410)
    }

    // MARK: slimme wekker

    func testExactOnlyAtSetTime() {
        let latest = date(2026, 11, 24, 7)
        XCTAssertFalse(SleepPlanner.shouldWake(mode: .exact, now: date(2026, 11, 24, 6, 50), latest: latest, asleepMin: 600, goalSleepMin: 400, recovery: 90))
        XCTAssertTrue(SleepPlanner.shouldWake(mode: .exact, now: latest, latest: latest, asleepMin: nil, goalSleepMin: 400, recovery: nil))
    }

    func testSleepGoalWakesEarlyOnlyInsideWindow() {
        let latest = date(2026, 11, 24, 10)
        // doel gehaald, maar ruim voor het venster: niet wekken
        XCTAssertFalse(SleepPlanner.shouldWake(mode: .sleepGoal, now: date(2026, 11, 24, 8), latest: latest, asleepMin: 500, goalSleepMin: 400, recovery: nil))
        // in het venster (vanaf 08:30) en doel gehaald
        XCTAssertTrue(SleepPlanner.shouldWake(mode: .sleepGoal, now: date(2026, 11, 24, 8, 45), latest: latest, asleepMin: 500, goalSleepMin: 400, recovery: nil))
        // in het venster, doel nog niet gehaald
        XCTAssertFalse(SleepPlanner.shouldWake(mode: .sleepGoal, now: date(2026, 11, 24, 9), latest: latest, asleepMin: 380, goalSleepMin: 400, recovery: nil))
    }

    func testRecoveredNeedsGreen() {
        let latest = date(2026, 11, 24, 7)
        let now = date(2026, 11, 24, 6)
        XCTAssertFalse(SleepPlanner.shouldWake(mode: .recovered, now: now, latest: latest, asleepMin: 500, goalSleepMin: 400, recovery: 66))
        XCTAssertTrue(SleepPlanner.shouldWake(mode: .recovered, now: now, latest: latest, asleepMin: 500, goalSleepMin: 400, recovery: 67))
        XCTAssertFalse(SleepPlanner.shouldWake(mode: .recovered, now: now, latest: latest, asleepMin: 500, goalSleepMin: 400, recovery: nil))
    }

    // MARK: band

    func testBandAlarmBodies() {
        let t: UInt32 = 0x666536D0
        XCTAssertEqual(SleepPlanner.BandAlarm.setBody(unix: t, variant: 0), [0x01, 0xD0, 0x36, 0x65, 0x66, 0, 0])
        XCTAssertEqual(SleepPlanner.BandAlarm.setBody(unix: t, variant: 1), [0xD0, 0x36, 0x65, 0x66, 0, 0, 0, 0])
        XCTAssertEqual(SleepPlanner.BandAlarm.setBody(unix: t, variant: 2, tzOffsetSec: 3600), [0x01, 0xD0, 0x36, 0x65, 0x66, 0x10, 0x0E, 0, 0])
        XCTAssertEqual(SleepPlanner.BandAlarm.setBody(unix: t, variant: 3).first, 0x02)
        XCTAssertTrue(SleepPlanner.BandAlarm.isAlarmCommand(66) && SleepPlanner.BandAlarm.isAlarmCommand(69))
        XCTAssertFalse(SleepPlanner.BandAlarm.isAlarmCommand(22))
        XCTAssertEqual(SleepPlanner.BandAlarm.parseGet([0x01, 0xD0, 0x36, 0x65, 0x66, 0, 0]), t)
        XCTAssertNil(SleepPlanner.BandAlarm.parseGet([0x01, 0, 0]))
    }
}
