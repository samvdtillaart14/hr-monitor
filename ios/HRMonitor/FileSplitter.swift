import Foundation

/// Houdt exportbestanden klein genoeg om te uploaden (bv. naar Claude, limiet 30 MB):
/// grote CSV's worden opgedeeld in delen van max. ca. 25 MB, elk met de kopregel,
/// netjes op regelgrenzen: <naam>_deel1.csv, <naam>_deel2.csv, …
enum FileSplitter {
    static let partLimit = 25_000_000

    /// Naam van deel `n` bij een basisbestand, bv. RUW-ALLES_22-11_00u18-21_deel2.csv.
    static func partURL(base: URL, part: Int) -> URL {
        let stem = baseStem(base.deletingPathExtension().lastPathComponent)
        return base.deletingLastPathComponent().appendingPathComponent("\(stem)_deel\(part).csv")
    }

    /// Haalt een eventueel "_deelN"-achtervoegsel weg.
    static func baseStem(_ name: String) -> String {
        if let r = name.range(of: "_deel", options: .backwards),
           !name[r.upperBound...].isEmpty, name[r.upperBound...].allSatisfy(\.isNumber) {
            return String(name[..<r.lowerBound])
        }
        return name
    }

    /// Deelnummer uit de bestandsnaam (1 als er geen "_deelN" in staat).
    static func partNumber(_ url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        let stem = baseStem(name)
        return stem == name ? 1 : Int(name.dropFirst(stem.count + 5)) ?? 1
    }

    /// Deelt alle te grote CSV's in `folder` op. Bestanden in `skip` (lopende opnames) en
    /// bestanden die net nog beschreven zijn, blijven ongemoeid.
    static func splitLargeFiles(in folder: URL, skip: Set<String>) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        for url in urls where url.pathExtension.lowercased() == "csv" && !skip.contains(url.lastPathComponent) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  let size = v.fileSize, size > partLimit,
                  Date().timeIntervalSince(v.contentModificationDate ?? .distantPast) > 60 else { continue }
            _ = try? split(url)
        }
    }

    enum SplitError: Error { case create, incomplete }

    /// Deelt één bestand op. Het origineel wordt pas verwijderd als alle delen geschreven zijn
    /// en samen precies alle regels bevatten; bij een fout worden de half geschreven delen opgeruimd.
    @discardableResult
    static func split(_ url: URL, limit: Int = partLimit) throws -> [URL] {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let total = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        var parts: [URL] = []
        var out: FileHandle?
        var outSize = 0
        var header = Data()
        var haveHeader = false
        var buffer = Data()
        var bodyBytes = 0

        func closeOut() { try? out?.synchronize(); try? out?.close(); out = nil }
        func cleanup() { closeOut(); parts.forEach { try? FileManager.default.removeItem(at: $0) } }
        func newPart() throws {
            closeOut()
            let u = partURL(base: url, part: parts.count + 1)
            guard !FileManager.default.fileExists(atPath: u.path),
                  FileManager.default.createFile(atPath: u.path, contents: header),
                  let h = FileHandle.appending(to: u) else { throw SplitError.create }
            parts.append(u); out = h; outSize = header.count
        }
        func write(_ d: Data) throws {
            guard let out, out.safeWrite(d) else { throw SplitError.create }
            outSize += d.count; bodyBytes += d.count
        }

        do {
            while true {
                let chunk = try input.read(upToCount: 1 << 20) ?? Data()
                let eof = chunk.isEmpty
                buffer.append(chunk)

                if !haveHeader {
                    if let nl = buffer.firstIndex(of: 10) {
                        header = Data(buffer[buffer.startIndex...nl])
                        buffer = Data(buffer[(nl + 1)...])
                    } else if eof {
                        header = buffer; buffer = Data()
                    } else { continue }
                    haveHeader = true
                    try newPart()
                }

                // Alleen hele regels wegschrijven; de rest blijft in de buffer.
                let end = eof ? buffer.endIndex : (buffer.lastIndex(of: 10).map { $0 + 1 } ?? buffer.startIndex)
                var block = Data(buffer[buffer.startIndex..<end])
                buffer = Data(buffer[end...])

                while !block.isEmpty {
                    let room = limit - outSize
                    if block.count <= room { try write(block); break }
                    let cut = block.startIndex + max(room, 0)
                    if room > 0, let nl = block[block.startIndex..<cut].lastIndex(of: 10) {
                        try write(Data(block[block.startIndex...nl]))
                        block = Data(block[(nl + 1)...])
                        try newPart()
                    } else if outSize == header.count {
                        // Eén regel groter dan een heel deel: dan toch in z'n geheel.
                        let nl = block.firstIndex(of: 10) ?? (block.endIndex - 1)
                        try write(Data(block[block.startIndex...nl]))
                        block = Data(block[(nl + 1)...])
                        if !block.isEmpty { try newPart() }
                    } else {
                        try newPart()
                    }
                }
                if eof { break }
            }
            closeOut()
            guard header.count + bodyBytes == total else { throw SplitError.incomplete }
            try FileManager.default.removeItem(at: url)
            return parts
        } catch {
            cleanup()
            throw error
        }
    }
}
