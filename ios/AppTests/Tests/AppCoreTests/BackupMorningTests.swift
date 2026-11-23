import XCTest
@testable import AppCore

/// Back-up (maken en terugzetten) en de teksten van het ochtendoverzicht.
final class BackupMorningTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("data"), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testBackupRoundTripRestoresFilesAndSettings() throws {
        try write("data/2026-11-22.csv", String(repeating: "1732000000;55;;\n", count: 500))
        try write("nights.json", #"{"2026-11-22":{"hrv":31}}"#)
        try write("RUW-ALLES_22-11.csv", "ruwe opname gaat niet mee")
        let zips = try Backup.export(root: dir, defaults: ["profile.maxHr": 195, "morning.enabled": true])
        XCTAssertEqual(zips.count, 1)
        XCTAssertTrue(zips[0].lastPathComponent.hasPrefix("pulse-backup-"))
        let names = try Backup.read(zips[0]).map(\.0)
        XCTAssertEqual(Set(names), ["data/2026-11-22.csv", "nights.json", Backup.settingsName])

        // Herinstallatie: lege map, plus vandaag al een groter bestand dat moet blijven staan.
        let fresh = dir.appendingPathComponent("nieuw")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try "{}".write(to: fresh.appendingPathComponent("nights.json"), atomically: true, encoding: .utf8)
        var settings: [String: Any] = [:]
        let r = try Backup.restore(zips, root: fresh) { settings = $0 }
        XCTAssertEqual(r, Backup.Result(restored: 2, kept: 0, settings: true))
        XCTAssertEqual(try String(contentsOf: fresh.appendingPathComponent("data/2026-11-22.csv"), encoding: .utf8),
                       try String(contentsOf: dir.appendingPathComponent("data/2026-11-22.csv"), encoding: .utf8))
        XCTAssertEqual(settings["profile.maxHr"] as? Int, 195)

        try String(repeating: "x", count: 10_000).write(to: fresh.appendingPathComponent("nights.json"), atomically: true, encoding: .utf8)
        let again = try Backup.restore(zips, root: fresh) { _ in }
        XCTAssertEqual(again.kept, 1, "groter bestand op de telefoon blijft staan")
    }

    func testRestoreRejectsUnsafePathsAndBadFiles() throws {
        XCTAssertNil(Backup.safeURL("../x.json", root: dir))
        XCTAssertNil(Backup.safeURL("/etc/x", root: dir))
        XCTAssertNil(Backup.safeURL("data/.verborgen", root: dir))
        XCTAssertEqual(Backup.safeURL("routes/a.json", root: dir)?.lastPathComponent, "a.json")
        let bad = dir.appendingPathComponent("geen.zip")
        try "dit is geen zip, echt niet".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Backup.read(bad))
    }

    func testMorningSummaryComparesWithYourselfWithoutDecimals() {
        let s = MorningSummary.make(.init(recovery: 78, asleepMin: 452, debtMin: 0, hrv: 36.4, rhr: 52.6,
                                          disturbances: 4, hrvBase: 30.2, rhrBase: 55.1, sleepBase: 470, baseNights: 20))
        XCTAssertEqual(s.headline, "Goed hersteld")
        XCTAssertEqual(s.sentence, "Je hartslagvariatie is 21% hoger dan normaal voor jou.")
        XCTAssertEqual(s.cards.map(\.value), ["7:32", "53", "4×"])
        XCTAssertEqual(s.cards[0].sentence, "0:18 korter dan je gemiddelde (7:50).")
        XCTAssertEqual(s.cards[1].sentence, "2 slagen lager dan normaal: goed teken.")
        XCTAssertEqual(s.advice, "Je lichaam kan vandaag een zware training aan.")
        let all = ([s.headline, s.sentence, s.advice] + s.cards.flatMap { [$0.value, $0.sentence] }).joined()
        XCTAssertNil(all.range(of: #"\d[.,]\d"#, options: .regularExpression), "geen decimalen")
    }

    func testMorningSummaryDebtAndNoBaseline() {
        let s = MorningSummary.make(.init(recovery: nil, asleepMin: 300, debtMin: 95, hrv: 28, rhr: 60))
        XCTAssertEqual(s.headline, "Herstel nog onbekend")
        XCTAssertTrue(s.cards[0].sentence.hasSuffix("Slaapschuld: 1:35."))
        XCTAssertEqual(s.advice, "Ga vanavond eerder naar bed om je slaapschuld van 1:35 in te halen.")
    }
}
