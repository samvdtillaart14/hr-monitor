import XCTest
@testable import AppCore

/// Gedeelde hulpmiddelen: map met testdata, BLE-fixtures en een tijdelijke Documenten-map.
enum TS {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }   // Tests/AppCoreTests/x.swift → repo-root
        return url
    }()

    /// Alle app-bestanden (dagdata, opnames, nights.json, calibration.json) in één tijdelijke map,
    /// nooit in de echte Documenten-map van de Mac waarop de tests draaien.
    static let documents: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("hrmonitor-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        Recorder.folderOverride = u
        return u
    }()

    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []; out.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); out.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        return out
    }
    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
}

/// Fixture uit testdata/ble (gemaakt met scores/test/make-ble-fixture.mjs uit echte opnames).
struct BLEFixture: Decodable {
    struct Note: Decodable { let c: String; let h: String }
    struct Rec: Decodable { let time: UInt32; let hr: Int; let skinTemp: Double?; let rr: [Int]; let motion: [Double]; let temp2: Double; let temp3: Double }
    struct Live: Decodable { let time: UInt32; let hr: Int; let rr: [Int] }
    struct Expected: Decodable {
        let frames: Int, badFrames: Int, bursts: Int, complete: Int, imuFrames: Int
        let typeCounts: [String: Int]
        let trims: [String]
        let responses: [[Int]]
        let live: [Live]
        let records: [Rec]
    }
    let notifications: [Note]
    let expected: Expected

    static func load(_ name: String) throws -> BLEFixture {
        let url = TS.repoRoot.appendingPathComponent("testdata/ble/\(name).json")
        return try JSONDecoder().decode(BLEFixture.self, from: Data(contentsOf: url))
    }

    /// Alleen de Whoop-notificaties (FD4B…), als (characteristic, bytes).
    var whoopChunks: [(String, [UInt8])] { notifications.filter { $0.c.hasPrefix("FD4B") }.map { ($0.c, TS.bytes($0.h)) } }
}
