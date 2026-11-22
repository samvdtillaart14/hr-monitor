import XCTest
@testable import AppCore

/// BLE-01…13 uit docs/TESTPLAN.md, op dezelfde echte opnames als scores/test/ble.test.mjs.
final class WhoopParserTests: XCTestCase {
    override class func setUp() { _ = TS.documents }

    /// Verzamelt alles wat de parser via callbacks doorgeeft.
    final class Collector {
        let p = WhoopParser()
        var records: [WhoopParser.Record] = []
        var trims: [[UInt8]] = []
        var responses: [[Int]] = []
        var complete = 0
        init() {
            p.onRecord = { [unowned self] in self.records.append($0) }
            p.onHistoryEnd = { [unowned self] in self.trims.append($0) }
            p.onResponse = { [unowned self] c, r in self.responses.append([Int(c), Int(r)]) }
            p.onHistoryComplete = { [unowned self] in self.complete += 1 }
        }
        func feed(_ chunks: [(String, [UInt8])]) { for (c, b) in chunks { p.handle(Data(b), channel: c) } }
    }

    private static let fixtures = ["sync-sessie", "nacht-download", "live-rr"]

    /// Commando's die de app echt naar de band schreef (uit de ruwe opnames).
    private let writes: [(Int, UInt8, [UInt8], String)] = [
        (1, 0x91, [0x01], "aa0108000001e67123019101363e5c8d"),   // hello, zie docs/WHOOP5-PROTOCOL.md
        (1, 0x16, [0x00], "aa0108000001e671230116002c00998e"),
        (1, 0x03, [0x01], "aa0108000001e67123010301aed62bce"),
        (2, 0x16, [0x00], "aa0108000001e6712302160075bedf8c"),
        (2, 0x6a, [0x01, 0x01], "aa010c000001e74123026a01010000001cc9f7a9"),
        (3, 0x16, [0x00], "aa0108000001e6712303160042d41d8d"),
        (4, 0x6a, [0x01, 0x01], "aa010c000001e74123046a010100000026fc27ca"),
        (7, 0x91, [0x01], "aa0108000001e671230791018442d189"),
    ]

    func testBLE01_commandFramesMatchRealWrites() {
        for (seq, cmd, body, want) in writes {
            let p = WhoopParser()
            for _ in 1..<seq { _ = p.frame(cmd: 0, body: []) }   // volgnummer ophogen
            XCTAssertEqual(TS.hex([UInt8](p.frame(cmd: cmd, body: body))), want, "seq \(seq) cmd \(cmd)")
        }
    }

    func testBLE02_crcKnownValues() {
        let header: [UInt8] = [0xAA, 0x01, 0x08, 0x00, 0x00, 0x01]
        XCTAssertEqual(WhoopParser.crc16Modbus(header[...]), 0x71E6)
        XCTAssertEqual(WhoopParser.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testBLE03_everyRealFrameHasValidTrailer() throws {
        for name in Self.fixtures {
            let c = Collector(); c.feed(try BLEFixture.load(name).whoopChunks)
            XCTAssertEqual(c.p.badFrames, 0, name)
            XCTAssertGreaterThan(c.p.frames, 50, name)
        }
    }

    func testBLE04_fixtureMatchesReference() throws {
        for name in Self.fixtures {
            let fx = try BLEFixture.load(name), e = fx.expected
            let c = Collector(); c.feed(fx.whoopChunks)
            XCTAssertEqual(c.p.frames, e.frames, name)
            XCTAssertEqual(c.p.badFrames, e.badFrames, name)
            XCTAssertEqual(c.p.bursts, e.bursts, name)
            XCTAssertEqual(c.complete, e.complete, name)
            XCTAssertEqual(c.p.imuFrames, e.imuFrames, name)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: c.p.typeCounts.map { (String($0.key), $0.value) }), e.typeCounts, name)
            XCTAssertEqual(c.trims.map(TS.hex), e.trims, name)
            XCTAssertEqual(c.responses, e.responses, name)
            XCTAssertEqual(c.records.count, e.records.count, name)
            for (r, x) in zip(c.records, e.records) {
                XCTAssertEqual(r.time, x.time); XCTAssertEqual(r.hr, x.hr); XCTAssertEqual(r.rr, x.rr)
                XCTAssertEqual(r.skinTemp == nil, x.skinTemp == nil)
                if let a = r.skinTemp, let b = x.skinTemp { XCTAssertEqual(a, b, accuracy: 1e-9) }
                XCTAssertEqual(r.motion.count, 4)
                for (m, y) in zip(r.motion, x.motion) where y.isFinite { XCTAssertEqual(Double(m), y, accuracy: 1e-6) }
                XCTAssertEqual(r.temp2, x.temp2, accuracy: 1e-9); XCTAssertEqual(r.temp3, x.temp3, accuracy: 1e-9)
            }
            if let last = e.live.last {
                XCTAssertEqual(c.p.liveHR, last.hr, name); XCTAssertEqual(c.p.liveRR, last.rr, name)
            }
        }
    }

    func testBLE06_fragmentationDoesNotMatter() throws {
        for name in Self.fixtures {
            let chunks = try BLEFixture.load(name).whoopChunks
            let a = Collector(); a.feed(chunks)
            let b = Collector(); b.feed(chunks.flatMap { c, bytes in bytes.map { (c, [$0]) } })
            XCTAssertEqual(a.records.map(\.time), b.records.map(\.time), name)
            XCTAssertEqual(a.trims, b.trims, name); XCTAssertEqual(a.responses, b.responses, name)
        }
    }

    func testBLE07_garbageBetweenFrames() throws {
        let chunks = try BLEFixture.load("sync-sessie").whoopChunks
        let noisy = chunks.enumerated().flatMap { i, x in [(x.0, i % 3 == 0 ? [UInt8(0xAA)] : [0x00, 0xAA, 0x02, 0xAA]), x] }
        let a = Collector(); a.feed(chunks)
        let b = Collector(); b.feed(noisy)
        XCTAssertEqual(a.records.count, b.records.count)
        XCTAssertEqual(a.trims, b.trims)
    }

    func testBLE08_droppedNotificationNeverGivesWrongRecords() throws {
        let chunks = try BLEFixture.load("nacht-download").whoopChunks
        let ref = Collector(); ref.feed(chunks)
        let good = Dictionary(uniqueKeysWithValues: ref.records.map { ($0.time, $0) })
        for k in stride(from: 0, to: chunks.count, by: 7) {
            let c = Collector(); c.feed(chunks.enumerated().filter { $0.offset != k }.map(\.element))
            for r in c.records {
                let g = try XCTUnwrap(good[r.time], "record \(r.time) bestaat niet (na wegvallen #\(k))")
                XCTAssertEqual(r.hr, g.hr); XCTAssertEqual(r.rr, g.rr)
            }
        }
    }

    func testBLE09_corruptBodySkipped() throws {
        let chunks = try BLEFixture.load("sync-sessie").whoopChunks
        let i = try XCTUnwrap(chunks.firstIndex { $0.1.count == 124 && $0.1[8] == 0x2F && $0.1[9] == 0x12 })
        var bad = chunks; bad[i].1[22] ^= 0xFF
        let a = Collector(); a.feed(chunks)
        let b = Collector(); b.feed(bad)
        XCTAssertEqual(b.records.count, a.records.count - 1)
        XCTAssertGreaterThanOrEqual(b.p.badFrames, 1)
    }

    func testBLE10_resetBuffersDropsHalfFrame() throws {
        let chunks = try BLEFixture.load("sync-sessie").whoopChunks
        let one = try XCTUnwrap(chunks.first { $0.1.count == 124 && $0.1[8] == 0x2F })
        let c = Collector()
        c.p.handle(Data(one.1.prefix(60)), channel: one.0)
        c.p.resetBuffers()
        c.p.handle(Data(one.1), channel: one.0)
        XCTAssertEqual(c.records.count, 1)
        XCTAssertEqual(c.p.badFrames, 0)
    }

    func testBLE11_bufferBounded() {
        let c = Collector()
        for _ in 0..<100 { c.p.handle(Data(repeating: 0x55, count: 244), channel: "FD4B0005") }
        // geen crash en geen frames uit rommel
        XCTAssertEqual(c.p.frames, 0)
    }

    func testBLE12_plausibleTime() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        XCTAssertFalse(WhoopParser.plausibleTime(0, now: now))
        XCTAssertFalse(WhoopParser.plausibleTime(1_500_000_000, now: now))
        XCTAssertTrue(WhoopParser.plausibleTime(1_795_000_000, now: now))
        XCTAssertFalse(WhoopParser.plausibleTime(1_795_000_000 + 2 * 86_400, now: now))
    }

    func testBLE12b_recordWithClockNotSetIsIgnored() throws {
        // Echt R18-frame, tijd op 0 gezet en de CRC32 opnieuw berekend.
        let chunks = try BLEFixture.load("sync-sessie").whoopChunks
        var f = try XCTUnwrap(chunks.first { $0.1.count == 124 && $0.1[8] == 0x2F && $0.1[9] == 0x12 }).1
        for k in 15..<19 { f[k] = 0 }
        let c32 = WhoopParser.crc32(Array(f[8..<(f.count - 4)]))
        f.replaceSubrange((f.count - 4)..., with: [UInt8(c32 & 0xFF), UInt8((c32 >> 8) & 0xFF), UInt8((c32 >> 16) & 0xFF), UInt8(c32 >> 24)])
        let c = Collector(); c.p.handle(Data(f), channel: "FD4B0005")
        XCTAssertEqual(c.p.frames, 1)
        XCTAssertTrue(c.records.isEmpty)
    }
}
