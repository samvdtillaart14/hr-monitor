import XCTest
@testable import AppCore

/// STORE-01…08 uit docs/TESTPLAN.md: samenvoegen van live en historie, opslaan/inlezen, dagindeling.
final class DayStoreTests: XCTestCase {
    override class func setUp() { _ = TS.documents }

    override func setUp() async throws {
        let dir = DayStore.folder
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: f) }
    }

    private func rec(_ t: UInt32, hr: Int = 60, rr: [Int] = [], q: [Float] = [1, 0, 0, 0]) -> WhoopParser.Record {
        WhoopParser.Record(time: t, hr: hr, skinTemp: 33.1, rr: rr, motion: q)
    }
    private var now: UInt32 { UInt32(Date().timeIntervalSince1970) }

    @MainActor private func makeStore() async -> DayStore {
        let s = DayStore()
        await s.load()       // init start ook een load; deze wachten we af
        return s
    }

    @MainActor func testSTORE01_historyRecordWinsOverLive() async {
        let s = await makeStore()
        let t = now
        s.addLive(hr: 70, rr: [850])
        s.addRecord(rec(t, hr: 64, rr: [930, 940]))
        let x = s.byDay[DayStore.dayKey(t)]?[t]
        XCTAssertEqual(x?.hr, 64); XCTAssertEqual(x?.rr, [930, 940]); XCTAssertEqual(x?.rec, true)
        s.addLive(hr: 99, rr: [600])     // live na historie: verandert niets meer
        XCTAssertEqual(s.byDay[DayStore.dayKey(t)]?[t]?.hr, 64)
    }

    @MainActor func testSTORE02_twoLivePacketsSameSecondKeepAllBeats() async {
        let s = await makeStore()
        s.addLive(hr: 70, rr: [850]); s.addLive(hr: 71, rr: [860])
        let all = s.byDay.values.flatMap(\.values).filter { !$0.rec }
        XCTAssertEqual(all.flatMap(\.rr).sorted(), [850, 860])
    }

    @MainActor func testSTORE03_duplicateRecordIgnored() async {
        let s = await makeStore()
        let t = now - 100
        s.addRecord(rec(t, hr: 60)); s.addRecord(rec(t, hr: 90))
        XCTAssertEqual(s.byDay[DayStore.dayKey(t)]?[t]?.hr, 60)
    }

    @MainActor func testSTORE04_motionFromOrientation() async {
        let s = await makeStore()
        let t = now - 1000
        s.addRecord(rec(t, q: [1, 0, 0, 0]))
        s.addRecord(rec(t + 1, q: [-1, 0, 0, 0]))          // −q is dezelfde stand: geen beweging
        s.addRecord(rec(t + 2, q: [0.7071, 0.7071, 0, 0]))  // 90° gedraaid: beweging
        s.addRecord(rec(t + 20, q: [1, 0, 0, 0]))           // na een gat: geen vergelijking
        let d = s.byDay[DayStore.dayKey(t)]!
        XCTAssertNil(d[t]?.motion)
        XCTAssertEqual(Double(d[t + 1]?.motion ?? -1), 0, accuracy: 1e-6)
        XCTAssertGreaterThan(d[t + 2]?.motion ?? 0, 0.5)
        XCTAssertNil(d[t + 20]?.motion)
    }

    @MainActor func testSTORE05_nonFiniteOrientationNotStored() async {
        let s = await makeStore()
        let t = now - 2000
        s.addRecord(rec(t, q: [.nan, 0, 0, 0]))
        XCTAssertNil(s.byDay[DayStore.dayKey(t)]?[t]?.q)
    }

    @MainActor func testSTORE06_saveAndReloadRoundTrip() async {
        let s = await makeStore()
        let t = now - 3000
        s.addRecord(rec(t, hr: 61, rr: [980, 990]))
        s.addRecord(rec(t + 1, hr: 62, rr: [970], q: [0.9, 0.1, 0, 0]))
        s.addLive(hr: 75, rr: [800])
        s.flush()
        let r = await makeStore()
        let a = r.byDay[DayStore.dayKey(t)]?[t]
        XCTAssertEqual(a?.hr, 61); XCTAssertEqual(a?.rr, [980, 990]); XCTAssertEqual(a?.rec, true)
        XCTAssertEqual(a?.q?.count, 4)
        XCTAssertNotNil(r.byDay[DayStore.dayKey(t)]?[t + 1]?.motion)
        XCTAssertEqual(r.byDay.values.flatMap(\.values).filter { !$0.rec }.first?.rr, [800])
    }

    @MainActor func testSTORE07_oldFileWithoutSourceColumn() async throws {
        // Oud formaat (6 kolommen): historie herkend aan q of huidtemperatuur.
        let t = now - 4000
        let key = DayStore.dayKey(t)
        let txt = "\(t);63;900;;33.2;1.0 0.0 0.0 0.0\n\(t + 1);70;850;;;\n"
        try txt.write(to: DayStore.folder.appendingPathComponent("\(key).csv"), atomically: true, encoding: .utf8)
        let s = await makeStore()
        XCTAssertEqual(s.byDay[key]?[t]?.rec, true)
        XCTAssertEqual(s.byDay[key]?[t + 1]?.rec, false)
    }

    @MainActor func testSTORE08_nightSamplesSortedEvenAfterTimezoneChange() async throws {
        // Bestand van gisteren bevat (na een tijdzonewissel) een seconde die later is dan de eerste van vandaag.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let t0 = UInt32(today.timeIntervalSince1970)
        let yKey = DayStore.key(Date(), minusDays: 1), tKey = DayStore.key(Date(), minusDays: 0)
        let yEvening = UInt32(cal.date(byAdding: .hour, value: -3, to: today)!.timeIntervalSince1970)
        try "\(yEvening);60;;;;;H\n\(t0 + 1800);61;;;;;H\n".write(to: DayStore.folder.appendingPathComponent("\(yKey).csv"), atomically: true, encoding: .utf8)
        try "\(t0 + 600);62;;;;;H\n\(t0 + 3600);63;;;;;H\n".write(to: DayStore.folder.appendingPathComponent("\(tKey).csv"), atomically: true, encoding: .utf8)
        let s = await makeStore()
        let out = s.samples(day: today, includeNight: true).map(\.t)
        XCTAssertEqual(out, out.sorted())
        XCTAssertEqual(out.count, 4)
    }

    @MainActor func testSTORE09_liveWithoutHeartRateIgnored() async {
        let s = await makeStore()
        s.addLive(hr: 0, rr: [800])
        XCTAssertTrue(s.byDay.values.allSatisfy { $0.isEmpty })
    }

    @MainActor func testSTORE10_dayKeyUsesLocalCalendar() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
        let t = UInt32(Date().timeIntervalSince1970)
        XCTAssertEqual(DayStore.dayKey(t), f.string(from: Date(timeIntervalSince1970: TimeInterval(t))))
    }

    /// STORE-STEPS: stappen = som van toenames; een daling (herstart band) telt de nieuwe waarde. Blijft na opslaan bewaard.
    func testSTORE_stepsSumAndReset() {
        func smp(_ t: UInt32, _ v: Int?) -> DayStore.Sample { var x = DayStore.Sample(t: t, hr: 60); x.steps = v; return x }
        XCTAssertEqual(DayStore.steps([smp(1, 179), smp(2, nil), smp(3, 200), smp(4, 274)]), 95)
        XCTAssertEqual(DayStore.steps([smp(1, 250), smp(2, 262), smp(3, 0), smp(4, 30)]), 42)
        XCTAssertEqual(DayStore.steps([]), 0)
    }

    @MainActor func testSTORE_stepsRoundTrip() async {
        let s = await makeStore()
        let t = now - 100
        var a = rec(t); a.steps = 10
        var b = rec(t + 1); b.steps = 13
        s.addRecord(a); s.addRecord(b)
        s.flush()
        let r = await makeStore()
        XCTAssertEqual(r.byDay[DayStore.dayKey(t)]?[t + 1]?.steps, 13)
        XCTAssertEqual(DayStore.steps(r.samples(day: Date(timeIntervalSince1970: TimeInterval(t)))), 3)
    }
}
