import Foundation

/// Ruwe BLE-log: laatste regels in het geheugen voor de verkenner, en optioneel naar een CSV-bestand
/// (ruw_<datum>.csv in Documenten) om het eigen Whoop-protocol te analyseren.
final class RawLogger: ObservableObject {
    struct Line: Identifiable { let id = UUID(); let text: String }
    @Published private(set) var lines: [Line] = []
    @Published private(set) var isRecording = false
    @Published private(set) var rows = 0
    private var handle: FileHandle?
    private var url: URL?
    /// Bytes in het huidige deel; boven ca. 25 MB begint een nieuw deel (_deel2.csv, …).
    private var fileBytes = 0
    private static let header = "tijd;type;service;characteristic;len;hex;opmerking\n"
    static let activeKey = "raw.activeFile"
    private static let rowsKey = "raw.rows"

    /// Hervat een lopende ruwe opname (met de teller) als iOS de app heeft afgesloten of hij is uitgevallen.
    init() {
        if let name = UserDefaults.standard.string(forKey: Self.activeKey) {
            let url = Recorder.folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path), let h = FileHandle.appending(to: url) {
                handle = h; isRecording = true; self.url = url
                fileBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                rows = UserDefaults.standard.integer(forKey: Self.rowsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeKey)
            }
        }
    }
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    func start() {
        let url = Recorder.folder.appendingPathComponent(Recorder.fileName(.raw))
        guard openPart(url) else { return }
        rows = 0
        isRecording = true
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.activeKey)
        UserDefaults.standard.set(0, forKey: Self.rowsKey)
    }

    private func openPart(_ url: URL) -> Bool {
        guard FileManager.default.createFile(atPath: url.path, contents: Data(Self.header.utf8)),
              let h = FileHandle.appending(to: url) else { return false }
        handle = h; self.url = url; fileBytes = Self.header.utf8.count
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.activeKey)
        return true
    }

    /// Sluit het huidige deel en gaat verder in een nieuw deel. Het eerste deel krijgt achteraf "_deel1".
    private func rotate() {
        guard let cur = url else { return }
        try? handle?.synchronize(); try? handle?.close(); handle = nil
        let n = FileSplitter.partNumber(cur)
        if FileSplitter.baseStem(cur.deletingPathExtension().lastPathComponent) == cur.deletingPathExtension().lastPathComponent {
            try? FileManager.default.moveItem(at: cur, to: FileSplitter.partURL(base: cur, part: 1))
        }
        if !openPart(FileSplitter.partURL(base: cur, part: n + 1)) { stop() }
    }

    func stop() {
        try? handle?.synchronize(); try? handle?.close(); handle = nil; url = nil
        isRecording = false
        UserDefaults.standard.removeObject(forKey: Self.activeKey)
    }

    func clear() { lines = [] }

    func log(service: String, char: String, kind: String, data: Data, note: String = "") {
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        let t = iso.string(from: Date())
        let short = { (u: String) in u.count > 8 ? String(u.prefix(8)) : u }
        lines.append(Line(text: "\(t.suffix(13)) \(kind) \(short(service))/\(short(char)) [\(data.count)] \(hex) \(note)"))
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        if isRecording {
            let line = Data("\(t);\(kind);\(service);\(char);\(data.count);\(hex);\(note)\n".utf8)
            if fileBytes + line.count > FileSplitter.partLimit { rotate() }
            guard let handle else { return }
            if handle.safeWrite(line) {
                fileBytes += line.count
                rows += 1
                if rows % 200 == 0 { UserDefaults.standard.set(rows, forKey: Self.rowsKey) }
            } else { stop() }
        }
    }
}
