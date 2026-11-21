import Foundation

/// Schrijft metingen direct naar een CSV in Documenten (zichtbaar in de Bestanden-app),
/// zodat een opname ook bewaard blijft als iOS de app op de achtergrond afsluit.
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var rows = 0
    @Published private(set) var currentURL: URL?
    @Published private(set) var files: [URL] = []

    private var handle: FileHandle?
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var folder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    init() { refresh() }

    func start() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = Self.folder.appendingPathComponent("hartslag_\(df.string(from: Date())).csv")
        // Puntkomma als scheidingsteken: opent direct goed in een Nederlandse Excel.
        FileManager.default.createFile(atPath: url.path, contents: Data("tijd;hr_bpm;rr_ms;batterij_pct\n".utf8))
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        currentURL = url
        rows = 0
        isRecording = true
        refresh()
    }

    func stop() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        isRecording = false
        refresh()
    }

    func append(time: Date, bpm: Int, rr: [Double], battery: Int?) {
        guard isRecording, let handle else { return }
        let rrs = rr.map { String(Int($0.rounded())) }.joined(separator: " ")
        let line = "\(iso.string(from: time));\(bpm);\(rrs);\(battery.map(String.init) ?? "")\n"
        handle.write(Data(line.utf8))
        rows += 1
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        files = urls.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
