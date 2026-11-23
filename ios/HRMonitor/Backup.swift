import Foundation

/// Back-up van alle app-data: dagdata, nachten, activiteiten, routes, schermtijden, bandlog en instellingen.
/// Maakt zip-bestanden van max. ca. 25 MB (zie ZipExport) die je in Bestanden of iCloud bewaart en na een
/// herinstallatie via AltStore terugzet. Ruwe ontwikkelopnames (CSV in de hoofdmap) gaan niet mee.
enum Backup {
    static let settingsName = "instellingen.plist"

    enum Failure: LocalizedError {
        case notZip(String), damaged(String)
        var errorDescription: String? {
            switch self {
            case .notZip(let n): return "\(n) is geen Pulse-back-up."
            case .damaged(let n): return "\(n) is beschadigd."
            }
        }
    }

    /// Bestanden die in de back-up gaan, met hun pad ten opzichte van de Documenten-map.
    static func files(in root: URL = Recorder.folder) -> [(url: URL, name: String)] {
        let base = root.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [(url: URL, name: String)] = []
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = u.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let rel = String(path.dropFirst(base.count + 1))
            // Ruwe opnames in de hoofdmap (honderden MB per nacht) en de Inbox van iOS niet meenemen.
            if !rel.contains("/") && u.pathExtension.lowercased() == "csv" { continue }
            if rel.hasPrefix("Inbox/") { continue }
            out.append((u, rel))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Maakt de back-up-zip(s). `defaults`: de instellingen van de app (UserDefaults).
    static func export(root: URL = Recorder.folder, defaults: [String: Any]? = Backup.appDefaults(),
                       now: Date = Date()) throws -> [URL] {
        var entries = files(in: root)
        if let defaults, !defaults.isEmpty {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-\(settingsName)")
            let d = try PropertyListSerialization.data(fromPropertyList: defaults, format: .binary, options: 0)
            try d.write(to: u, options: .atomic)
            entries.append((u, settingsName))
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return try ZipExport.make(name: "pulse-backup-\(f.string(from: now))", entries: entries)
    }

    static func appDefaults() -> [String: Any]? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return UserDefaults.standard.persistentDomain(forName: id)
    }

    struct Result: Equatable { var restored = 0, kept = 0, settings = false }

    /// Zet één of meer back-up-zips terug. Een bestand dat hier al groter is (bijv. vandaag na herinstallatie
    /// al verder gemeten) blijft staan; anders wint de back-up. Instellingen gaan via `applySettings`.
    static func restore(_ zips: [URL], root: URL = Recorder.folder,
                        applySettings: ([String: Any]) -> Void = Backup.applyDefaults) throws -> Result {
        var r = Result()
        let fm = FileManager.default
        for zip in zips {
            for (name, data) in try read(zip) {
                if name == settingsName {
                    if let v = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                        applySettings(v); r.settings = true
                    }
                    continue
                }
                guard let dest = safeURL(name, root: root) else { continue }
                if let size = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int, size > data.count {
                    r.kept += 1; continue
                }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest, options: .atomic)
                r.restored += 1
            }
        }
        return r
    }

    static func applyDefaults(_ v: [String: Any]) {
        let d = UserDefaults.standard
        for (k, val) in v { d.set(val, forKey: k) }
    }

    /// Alleen paden binnen de Documenten-map; nooit "..", absolute paden of verborgen bestanden.
    static func safeURL(_ name: String, root: URL) -> URL? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// Leest alle bestanden uit een zip (zoals ZipExport ze schrijft: opgeslagen of Deflate, met CRC-controle).
    static func read(_ zip: URL) throws -> [(String, Data)] {
        let label = zip.lastPathComponent
        let z = try Data(contentsOf: zip, options: .mappedIfSafe)
        func u16(_ o: Int) -> Int { Int(z[z.startIndex + o]) | Int(z[z.startIndex + o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard z.count >= 22 else { throw Failure.notZip(label) }
        // Einde van de centrale map zoeken (achteraan, na een eventueel commentaar).
        var eocd = -1
        var o = z.count - 22
        while o >= max(0, z.count - 22 - 65535) {
            if u32(o) == 0x0605_4b50 { eocd = o; break }
            o -= 1
        }
        guard eocd >= 0 else { throw Failure.notZip(label) }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var out: [(String, Data)] = []
        for _ in 0..<count {
            guard p + 46 <= z.count, u32(p) == 0x0201_4b50 else { throw Failure.damaged(label) }
            let method = u16(p + 10), crc = u32(p + 16), packedSize = u32(p + 20), size = u32(p + 24)
            let nl = u16(p + 28), el = u16(p + 30), cl = u16(p + 32), local = u32(p + 42)
            guard p + 46 + nl <= z.count else { throw Failure.damaged(label) }
            let name = String(decoding: z[(z.startIndex + p + 46)..<(z.startIndex + p + 46 + nl)], as: UTF8.self)
            p += 46 + nl + el + cl
            if name.hasSuffix("/") { continue }
            guard local + 30 <= z.count, u32(local) == 0x0403_4b50 else { throw Failure.damaged(label) }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + packedSize <= z.count else { throw Failure.damaged(label) }
            let packed = z.subdata(in: (z.startIndex + start)..<(z.startIndex + start + packedSize))
            let data: Data
            switch method {
            case 0: data = packed
            case 8:
                guard let d = try? (packed as NSData).decompressed(using: .zlib) as Data else { throw Failure.damaged(label) }
                data = d
            default: throw Failure.damaged(label)
            }
            guard data.count == size, Int(CRC32.checksum(data)) == crc else { throw Failure.damaged(label) }
            out.append((name, data))
        }
        return out
    }
}
