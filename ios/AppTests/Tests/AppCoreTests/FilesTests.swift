import XCTest
@testable import AppCore

/// FILE-01…05 uit docs/TESTPLAN.md: opsplitsen, zip-export en bestandsnamen.
final class FilesTests: XCTestCase {
    override class func setUp() { _ = TS.documents }
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("files-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func csv(_ name: String, lines: Int, width: Int = 40) throws -> URL {
        let u = dir.appendingPathComponent(name)
        var s = "tijd;hr\n"
        for i in 0..<lines { s += "\(i);" + String(repeating: "x", count: width) + "\n" }
        try s.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    func testFILE01_splitKeepsEveryLineAndHeader() throws {
        let u = try csv("RUW-ALLES_22-11_00u18-21.csv", lines: 500)
        let original = try String(contentsOf: u, encoding: .utf8)
        let parts = try FileSplitter.split(u, limit: 2000)
        XCTAssertGreaterThan(parts.count, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: u.path), "origineel pas weg als alles geschreven is")
        var body = ""
        for (k, p) in parts.enumerated() {
            XCTAssertEqual(p.lastPathComponent, "RUW-ALLES_22-11_00u18-21_deel\(k + 1).csv")
            let t = try String(contentsOf: p, encoding: .utf8)
            XCTAssertTrue(t.hasPrefix("tijd;hr\n"))
            XCTAssertLessThanOrEqual(t.utf8.count, 2000)
            XCTAssertTrue(t.hasSuffix("\n"), "alleen hele regels")
            body += t.dropFirst("tijd;hr\n".count)
        }
        XCTAssertEqual("tijd;hr\n" + body, original)
    }

    func testFILE02_lineLongerThanLimitStaysWhole() throws {
        let u = try csv("HARTSLAG_x.csv", lines: 3, width: 3000)
        let parts = try FileSplitter.split(u, limit: 2000)
        XCTAssertEqual(parts.count, 3)
    }

    func testFILE03_partNames() {
        let base = URL(fileURLWithPath: "/tmp/RUW-ALLES_22-11_00u18-21_deel3.csv")
        XCTAssertEqual(FileSplitter.baseStem("RUW-ALLES_22-11_00u18-21_deel3"), "RUW-ALLES_22-11_00u18-21")
        XCTAssertEqual(FileSplitter.baseStem("RUW-ALLES_deelx"), "RUW-ALLES_deelx")
        XCTAssertEqual(FileSplitter.partNumber(base), 3)
        XCTAssertEqual(FileSplitter.partNumber(URL(fileURLWithPath: "/tmp/a.csv")), 1)
        XCTAssertEqual(FileSplitter.partURL(base: base, part: 4).lastPathComponent, "RUW-ALLES_22-11_00u18-21_deel4.csv")
    }

    func testFILE04_zipIsValidAndComplete() throws {
        let a = try csv("HARTSLAG_a.csv", lines: 2000), b = try csv("WHOOP-HISTORIE_b.csv", lines: 10)
        let zips = try ZipExport.make(name: "test", files: [a, b])
        XCTAssertEqual(zips.count, 1)
        XCTAssertLessThan(try Data(contentsOf: zips[0]).count, try Data(contentsOf: a).count, "gecomprimeerd")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-t", zips[0].path]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run(); p.waitUntilExit()
        let log = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 0, log)
        XCTAssertTrue(log.contains("HARTSLAG_a.csv") && log.contains("WHOOP-HISTORIE_b.csv"), log)
    }

    func testFILE05_recordingKinds() {
        XCTAssertEqual(Recorder.Kind.of(URL(fileURLWithPath: "/x/HARTSLAG_21-11_16u34-02.csv")), .heartRate)
        XCTAssertEqual(Recorder.Kind.of(URL(fileURLWithPath: "/x/RUW-ALLES_22-11_00u18-21_deel2.csv")), .raw)
        XCTAssertEqual(Recorder.Kind.of(URL(fileURLWithPath: "/x/whoop-historie_1.csv")), .whoopHistory)
        XCTAssertNil(Recorder.Kind.of(URL(fileURLWithPath: "/x/2026-11-22.csv")))
        XCTAssertTrue(Recorder.fileName(.raw).hasPrefix("RUW-ALLES_"))
    }
}
