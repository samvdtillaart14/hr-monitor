import Foundation

/// Bewaart automatisch de ruwe datapakketten van de Whoop-band, per dag in Documenten/band/<jjjj-mm-dd>.csv,
/// en ruimt alles ouder dan `keepDays` dagen op. Zo is de laatste week altijd te delen (bv. met Claude),
/// zonder dat er een opname aan hoeft te staan.
///
/// Kolommen: unix-ms ; type (hex) ; pakket (hex). Opgeslagen: historische records (0x2F, behalve de grote
/// IMU-blokken), live HR/RR (0x28) en status (0x31). Ongeveer 25–35 MB per dag; als zip veel kleiner.
final class BandLog: @unchecked Sendable {
    static let shared = BandLog()
    static let keepDays = 7

    static let folder: URL = {
        let u = Recorder.folder.appendingPathComponent("band", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private let queue = DispatchQueue(label: "bandlog", qos: .utility)
    private var buffer: [String: String] = [:]
    private var bufferedLines = 0
    private var lastFlush = Date()
    private var lastPrune = Date.distantPast

    private static let hexDigits = Array("0123456789abcdef".utf8)
    private static func hex(_ b: [UInt8]) -> String {
        var out = [UInt8](); out.reserveCapacity(b.count * 2)
        for x in b { out.append(hexDigits[Int(x >> 4)]); out.append(hexDigits[Int(x & 0x0F)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// Eén geldig frame vastleggen (wordt door de parser aangeroepen).
    func append(_ frame: [UInt8]) {
        guard frame.count > 9 else { return }
        let type = frame[8]
        switch type {
        case 0x2F where frame.count < 1000: break   // R18, R26 enz.; IMU-blokken (1244 B) niet
        case 0x28, 0x31: break
        default: return
        }
        let now = Date()
        let line = "\(Int64(now.timeIntervalSince1970 * 1000));\(String(format: "%02x", type));\(Self.hex(frame))\n"
        let day = DayStore.dayFmt.string(from: now)
        queue.async {
            self.buffer[day, default: ""] += line
            self.bufferedLines += 1
            if self.bufferedLines >= 600 || now.timeIntervalSince(self.lastFlush) > 30 { self.writeOut() }
        }
    }

    /// Buffer naar schijf (ook bij naar de achtergrond gaan).
    func flush() { queue.async { self.writeOut() } }

    private func writeOut() {
        for (day, text) in buffer {
            let url = Self.folder.appendingPathComponent("\(day).csv")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data("unix_ms;type;hex\n".utf8))
            }
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(text.utf8))
                try? h.close()
            }
        }
        buffer.removeAll(keepingCapacity: true)
        bufferedLines = 0
        lastFlush = Date()
        if Date().timeIntervalSince(lastPrune) > 3600 { prune(); lastPrune = Date() }
    }

    /// Dagbestanden ouder dan `keepDays` dagen verwijderen.
    private func prune() {
        let oldest = DayStore.key(Date(), minusDays: Self.keepDays - 1)
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "csv" && f.deletingPathExtension().lastPathComponent < oldest {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// Bestanden van de laatste week: ruwe bandpakketten en de dagbestanden (HR, RR, beweging, huidtemp).
    static func weekFiles() -> [URL] {
        let keys = Set((0..<keepDays).map { DayStore.key(Date(), minusDays: $0) })
        func pick(_ dir: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "csv" && keys.contains($0.deletingPathExtension().lastPathComponent) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return pick(folder) + pick(DayStore.folder)
    }

    /// Zipt de laatste week (max. ca. 25 MB per zip). De bestandsnamen in de zip krijgen een voorvoegsel
    /// band_ of dag_, zodat de twee soorten niet door elkaar lopen.
    static func exportWeek() throws -> [URL] {
        BandLog.shared.queue.sync { BandLog.shared.writeOut() }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("week", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var files: [URL] = []
        for f in weekFiles() {
            let prefix = f.deletingLastPathComponent().lastPathComponent == "band" ? "band_" : "dag_"
            let dst = tmp.appendingPathComponent(prefix + f.lastPathComponent)
            try FileManager.default.copyItem(at: f, to: dst)
            files.append(dst)
        }
        guard !files.isEmpty else { throw NSError(domain: "BandLog", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nog geen gegevens opgeslagen."]) }
        let name = "whoop-week-" + DayStore.dayFmt.string(from: Date())
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try ZipExport.make(name: name, files: files)
    }
}
