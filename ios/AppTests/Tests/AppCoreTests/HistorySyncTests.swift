import XCTest
@testable import AppCore

/// SYNC-01…09 uit docs/TESTPLAN.md: beslislogica rond cmd 22/23 en de bursts van de band.
final class HistorySyncTests: XCTestCase {
    private let trimA: [UInt8] = [0xd0, 0xe7, 0x01, 0x00, 0x07, 0x00, 0x00, 0x00]
    private let trimB: [UInt8] = [0xd3, 0xe7, 0x01, 0x00, 0x07, 0x00, 0x00, 0x00]

    func testSYNC01_ackBodyVariants() {
        XCTAssertEqual(HistorySync.ackBody(trimA, variant: 0), [0x01] + trimA)
        XCTAssertEqual(HistorySync.ackBody(trimA, variant: 1), [0x01, 0xd0, 0xe7, 0x01, 0x00, 0, 0, 0, 0])
    }

    func testSYNC02_manualAckIsRecognisedAndBlocked() {
        let p = WhoopParser()
        XCTAssertTrue(HistorySync.isAckCommand([UInt8](p.frame(cmd: 23, body: [0x01] + trimA))))
        XCTAssertFalse(HistorySync.isAckCommand([UInt8](p.frame(cmd: 22, body: [0x00]))))
        XCTAssertFalse(HistorySync.isAckCommand([0xAA, 0x01, 0x23]))
    }

    func testSYNC03_whoopAppRunning_weNeverAck() {
        var s = HistorySync()
        XCTAssertEqual(s.burstEnded(trim: trimA), 3)                       // eerst ruimte voor de Whoop-app
        XCTAssertEqual(s.response(cmd: 23, result: 1), .whoopAcked)        // Whoop-app bevestigt zelf
        XCTAssertNil(s.ackDue(trim: trimA, variant: 0))                    // dus wij niet
        XCTAssertEqual(s.burstEnded(trim: trimB), 3)                       // blijft ruim wachten
        XCTAssertEqual(s.reset(), 0)
    }

    func testSYNC04_standalone_weAckEachBurstQuickly() {
        var s = HistorySync()
        XCTAssertEqual(s.burstEnded(trim: trimA), 3)
        XCTAssertEqual(s.ackDue(trim: trimA, variant: 0), [0x01] + trimA)
        s.ackSent()
        XCTAssertEqual(s.response(cmd: 23, result: 1), .accepted)
        XCTAssertEqual(s.burstEnded(trim: trimB), 0.3)                     // volgende bursts vlot
        XCTAssertNotNil(s.ackDue(trim: trimB, variant: 0)); s.ackSent()
        XCTAssertEqual(s.response(cmd: 23, result: 1), .accepted)
        XCTAssertEqual(s.reset(), 2)
        XCTAssertEqual(s.burstEnded(trim: trimA), 3)                       // nieuwe sync: weer ruimte voor de Whoop-app
    }

    func testSYNC05_newerBurstReplacesPending() {
        var s = HistorySync()
        _ = s.burstEnded(trim: trimA); _ = s.burstEnded(trim: trimB)
        XCTAssertNil(s.ackDue(trim: trimA, variant: 0))
        XCTAssertEqual(s.ackDue(trim: trimB, variant: 0), [0x01] + trimB)
        XCTAssertNil(s.ackDue(trim: trimB, variant: 0), "nooit twee keer dezelfde ack uit één END")
    }

    func testSYNC06_rejectedOnlyForOurOwnAck() {
        var s = HistorySync()
        XCTAssertEqual(s.response(cmd: 23, result: 0), .ignored)           // fout op ack van de Whoop-app: niet onze zaak
        _ = s.burstEnded(trim: trimA); _ = s.ackDue(trim: trimA, variant: 0); s.ackSent()
        XCTAssertEqual(s.response(cmd: 23, result: 0), .rejected)
    }

    func testSYNC07_busyThenOkIsStillOurAck() {
        var s = HistorySync()
        _ = s.burstEnded(trim: trimA); _ = s.ackDue(trim: trimA, variant: 0); s.ackSent()
        XCTAssertEqual(s.response(cmd: 23, result: 2), .ignored)           // bezig
        XCTAssertEqual(s.response(cmd: 23, result: 1), .accepted)          // eindantwoord hoort bij ons
        XCTAssertFalse(s.whoopAckedThisSync)
    }

    func testSYNC08_otherCommandsIgnored() {
        var s = HistorySync()
        _ = s.burstEnded(trim: trimA); _ = s.ackDue(trim: trimA, variant: 0); s.ackSent()
        XCTAssertEqual(s.response(cmd: 22, result: 1), .ignored)
        XCTAssertTrue(s.ourAckPending)
    }

    /// Echte sync van de Whoop-app (sync-sessie): elke END die de Whoop-app binnen dezelfde burst bevestigde,
    /// bevestigen wij niet nog eens.
    func testSYNC09_realSyncWithWhoopAppNoDoubleAcks() throws {
        _ = TS.documents
        let fx = try BLEFixture.load("sync-sessie")
        let p = WhoopParser()
        var s = HistorySync()
        var pending: [[UInt8]] = []          // ENDs waarvan onze wachttijd nog loopt
        var doubleAcks = 0, endsAnswered = 0
        p.onHistoryEnd = { t in pending = [t]; _ = s.burstEnded(trim: t) }
        p.onResponse = { c, r in
            guard s.response(cmd: c, result: r) == .whoopAcked else { return }
            endsAnswered += 1
            // Onze timer loopt pas na 3 s af, ruim na de ack van de Whoop-app: dan mag er niets meer te sturen zijn.
            for t in pending where s.ackDue(trim: t, variant: 0) != nil { doubleAcks += 1 }
            pending = []
        }
        p.onHistoryComplete = { s.reset() }
        for (c, b) in fx.whoopChunks { p.handle(Data(b), channel: c) }
        XCTAssertGreaterThanOrEqual(endsAnswered, 12)
        XCTAssertEqual(doubleAcks, 0)
        for t in fx.expected.trims { XCTAssertEqual(t.count, 16, "trim is 8 bytes") }
    }
}
