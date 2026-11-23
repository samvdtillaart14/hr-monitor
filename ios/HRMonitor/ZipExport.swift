import Foundation

/// Bundelt opnamebestanden in zip-bestanden van max. ca. 25 MB (Deflate), om ze in één keer
/// te kunnen delen of uploaden (Claude: max. 30 MB per bestand). Ruwe BLE-data wordt 6–7× kleiner.
enum ZipExport {
    static let zipLimit = 25_000_000

    /// Maakt zips in een tijdelijke map. Elk bestand gaat in z'n geheel in één zip;
    /// een nieuwe zip begint als het volgende bestand er niet meer bij past.
    static func make(name: String, files: [URL]) throws -> [URL] {
        try make(name: name, entries: files.map { ($0, $0.lastPathComponent) })
    }

    /// Zelfde, met een eigen naam (pad) per bestand in de zip, bijv. "data/2026-11-23.csv".
    static func make(name: String, entries files: [(url: URL, name: String)]) throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var zips: [URL] = []
        var writer: Writer?
        func next() throws {
            try writer?.finish()
            let u = dir.appendingPathComponent("\(name)_zip\(zips.count + 1).zip")
            writer = try Writer(url: u); zips.append(u)
        }
        for file in files {
            let entry = try Entry(file.url, name: file.name)
            if writer == nil || (writer!.size + entry.byteCount > zipLimit && writer!.count > 0) { try next() }
            try writer!.add(entry)
        }
        try writer?.finish()
        // Eén zip: zonder volgnummer.
        if zips.count == 1 {
            let single = dir.appendingPathComponent("\(name).zip")
            try FileManager.default.moveItem(at: zips[0], to: single)
            return [single]
        }
        return zips
    }

    /// Eén gecomprimeerd bestand.
    struct Entry {
        let name: Data, crc: UInt32, rawSize: UInt32, packed: Data, method: UInt16, date: (time: UInt16, day: UInt16)
        var byteCount: Int { 30 + name.count + packed.count + 46 + name.count }

        init(_ url: URL, name zipName: String? = nil) throws {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            name = Data((zipName ?? url.lastPathComponent).utf8)
            crc = CRC32.checksum(data)
            rawSize = UInt32(clamping: data.count)
            // NSData .zlib levert ruwe Deflate (RFC 1951), precies wat zip verwacht.
            if let c = try? (data as NSData).compressed(using: .zlib) as Data, c.count < data.count {
                packed = c; method = 8
            } else {
                packed = data; method = 0
            }
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: m)
            let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
            let year: Int = max(0, (c.year ?? 1980) - 1980), month: Int = c.month ?? 1, day: Int = c.day ?? 1
            let dosTime: Int = (hour << 11) | (minute << 5) | (second / 2)
            let dosDay: Int = (year << 9) | (month << 5) | day
            date = (UInt16(truncatingIfNeeded: dosTime), UInt16(truncatingIfNeeded: dosDay))
        }
    }

    final class Writer {
        private let handle: FileHandle
        private var central = Data()
        private(set) var size = 22
        private(set) var count = 0
        private var offset: UInt32 = 0

        init(url: URL) throws {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            handle = try FileHandle(forWritingTo: url)
        }

        func add(_ e: Entry) throws {
            var local = Data()
            local.le32(0x04034b50); local.le16(20); local.le16(0x0800); local.le16(e.method)
            local.le16(e.date.time); local.le16(e.date.day)
            local.le32(e.crc); local.le32(UInt32(e.packed.count)); local.le32(e.rawSize)
            local.le16(UInt16(e.name.count)); local.le16(0); local.append(e.name)
            try handle.write(contentsOf: local); try handle.write(contentsOf: e.packed)

            central.le32(0x02014b50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(e.method)
            central.le16(e.date.time); central.le16(e.date.day)
            central.le32(e.crc); central.le32(UInt32(e.packed.count)); central.le32(e.rawSize)
            central.le16(UInt16(e.name.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(0); central.le32(offset); central.append(e.name)

            offset += UInt32(local.count + e.packed.count)
            size += e.byteCount; count += 1
        }

        func finish() throws {
            var end = Data()
            end.le32(0x06054b50); end.le16(0); end.le16(0)
            end.le16(UInt16(count)); end.le16(UInt16(count))
            end.le32(UInt32(central.count)); end.le32(offset); end.le16(0)
            try handle.write(contentsOf: central); try handle.write(contentsOf: end)
            try handle.close()
        }
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        (0..<8).reduce(UInt32(i)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }
    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for b in p { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
}
