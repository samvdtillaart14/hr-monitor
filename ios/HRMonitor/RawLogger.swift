import Foundation

/// Ruwe BLE-log: laatste regels in het geheugen voor de verkenner, en optioneel naar een CSV-bestand
/// (ruw_<datum>.csv in Documenten) om het eigen Whoop-protocol te analyseren.
final class RawLogger: ObservableObject {
    struct Line: Identifiable { let id = UUID(); let text: String }
    @Published private(set) var lines: [Line] = []
    @Published private(set) var isRecording = false
    @Published private(set) var rows = 0
    private var handle: FileHandle?
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    func start() {
        let url = Recorder.folder.appendingPathComponent(Recorder.fileName(.raw))
        guard FileManager.default.createFile(atPath: url.path, contents: Data("tijd;type;service;characteristic;len;hex;opmerking\n".utf8)),
              let h = FileHandle.appending(to: url) else { return }
        handle = h
        rows = 0
        isRecording = true
    }

    func stop() {
        try? handle?.synchronize(); try? handle?.close(); handle = nil
        isRecording = false
    }

    func clear() { lines = [] }

    func log(service: String, char: String, kind: String, data: Data, note: String = "") {
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        let t = iso.string(from: Date())
        let short = { (u: String) in u.count > 8 ? String(u.prefix(8)) : u }
        lines.append(Line(text: "\(t.suffix(13)) \(kind) \(short(service))/\(short(char)) [\(data.count)] \(hex) \(note)"))
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        if isRecording, let handle {
            if handle.safeWrite(Data("\(t);\(kind);\(service);\(char);\(data.count);\(hex);\(note)\n".utf8)) { rows += 1 } else { stop() }
        }
    }
}
