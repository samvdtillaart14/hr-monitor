import Foundation

/// Schrijft metingen direct naar een CSV in Documenten (zichtbaar in de Bestanden-app),
/// zodat een opname ook bewaard blijft als iOS de app op de achtergrond afsluit.
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var rows = 0
    @Published private(set) var currentURL: URL?
    @Published private(set) var files: [URL] = []
    /// Melding als schrijven mislukt (bv. iPhone-opslag vol); de opname is dan gestopt.
    @Published private(set) var error: String?

    private var handle: FileHandle?
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Soorten opnames. Bestandsnaam: <SOORT>_<dag>-<maand>_<uu>u<mm>.csv, bv. HARTSLAG_21-11_16u34.csv
    enum Kind: String, CaseIterable {
        case heartRate = "HARTSLAG", raw = "RUW-ALLES", whoopHistory = "WHOOP-HISTORIE"
        var title: String {
            switch self { case .heartRate: "Hartslag (bpm + RR)"; case .raw: "Ruwe BLE-data (alles)"; case .whoopHistory: "Whoop-historie (per seconde)" }
        }
        var icon: String {
            switch self { case .heartRate: "heart.fill"; case .raw: "waveform"; case .whoopHistory: "clock.arrow.circlepath" }
        }
        static func of(_ url: URL) -> Kind? {
            let n = url.lastPathComponent.uppercased()
            if let k = allCases.first(where: { n.hasPrefix($0.rawValue + "_") }) { return k }
            if n.hasPrefix("HARTSLAG") { return .heartRate }
            if n.hasPrefix("RUW") { return .raw }
            if n.hasPrefix("WHOOP") { return .whoopHistory }
            return nil
        }
    }

    static func fileName(_ kind: Kind) -> String {
        let df = DateFormatter(); df.dateFormat = "dd-MM_HH'u'mm-ss"
        return "\(kind.rawValue)_\(df.string(from: Date())).csv"
    }

    static var folder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    private static let activeKey = "recorder.activeFile"
    private static let rowsKey = "recorder.rows"

    /// Hervat een lopende opname als iOS de app op de achtergrond heeft afgesloten en opnieuw gestart.
    init() {
        if let name = UserDefaults.standard.string(forKey: Self.activeKey) {
            let url = Self.folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path), let h = FileHandle.appending(to: url) {
                handle = h; currentURL = url; isRecording = true
                rows = UserDefaults.standard.integer(forKey: Self.rowsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeKey)
            }
        }
        refresh()
    }

    func start() {
        let url = Self.folder.appendingPathComponent(Self.fileName(.heartRate))
        // Puntkomma als scheidingsteken: opent direct goed in een Nederlandse Excel.
        guard FileManager.default.createFile(atPath: url.path, contents: Data("tijd;hr_bpm;rr_ms;batterij_pct\n".utf8)),
              let h = FileHandle.appending(to: url) else {
            error = "Kon geen opnamebestand maken (opslag vol?)."
            return
        }
        handle = h
        error = nil
        currentURL = url
        rows = 0
        isRecording = true
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.activeKey)
        UserDefaults.standard.set(0, forKey: Self.rowsKey)
        refresh()
    }

    func stop() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        isRecording = false
        UserDefaults.standard.removeObject(forKey: Self.activeKey)
        refresh()
    }

    func append(time: Date, bpm: Int, rr: [Double], battery: Int?) {
        guard isRecording, let handle else { return }
        let rrs = rr.map { String(Int($0.rounded())) }.joined(separator: " ")
        let line = "\(iso.string(from: time));\(bpm);\(rrs);\(battery.map(String.init) ?? "")\n"
        guard handle.safeWrite(Data(line.utf8)) else {
            stop()
            error = "Opname gestopt: schrijven mislukt (iPhone-opslag vol?)."
            return
        }
        rows += 1
        if rows % 60 == 0 { UserDefaults.standard.set(rows, forKey: Self.rowsKey) }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }

    /// Deelt bestaande te grote opnames (> 25 MB) op de achtergrond op in delen, en ververst daarna de lijst.
    func splitLargeFiles() {
        guard !splitting else { return }
        splitting = true
        let skip = Set([Self.activeKey, RawLogger.activeKey].compactMap { UserDefaults.standard.string(forKey: $0) })
        DispatchQueue.global(qos: .utility).async {
            FileSplitter.splitLargeFiles(in: Self.folder, skip: skip)
            DispatchQueue.main.async { self.splitting = false; self.refresh() }
        }
    }
    private var splitting = false

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let date = { (u: URL) in (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        files = urls.filter { $0.pathExtension == "csv" }.sorted { date($0) > date($1) }
    }
}
