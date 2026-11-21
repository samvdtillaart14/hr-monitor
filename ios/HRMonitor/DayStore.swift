import Foundation

/// Bewaart metingen per seconde, per dag in Documenten/data/<jjjj-mm-dd>.csv,
/// zodat scores over meerdere dagen berekend kunnen worden.
/// Bronnen: historische Whoop-records (R18) en de live hartslag (0x2A37).
@MainActor
final class DayStore: ObservableObject {
    struct Sample {
        var t: UInt32          // Unix-seconden
        var hr: Int
        var rr: [Int] = []     // ms
        var motion: Float?     // beweging t.o.v. vorige seconde (0 = stil)
        var skin: Double?
        var q: [Float]?        // 4 oriëntatie-floats (R18), voor slaapdetectie
    }

    @Published private(set) var revision = 0
    private(set) var byDay: [String: [UInt32: Sample]] = [:]
    private var lastQ: [Float]?
    private var pending: [String: String] = [:]
    private var flushScheduled = false

    nonisolated static let folder: URL = {
        let u = Recorder.folder.appendingPathComponent("data", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    nonisolated(unsafe) static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f
    }()
    nonisolated static func dayKey(_ t: UInt32) -> String { dayFmt.string(from: Date(timeIntervalSince1970: TimeInterval(t))) }

    init() { Task { await load() } }

    /// Laadt de laatste 8 dagen van schijf.
    func load() async {
        let keys = (0..<8).map { Self.dayFmt.string(from: Date().addingTimeInterval(-86400 * Double($0))) }
        let loaded: [String: [UInt32: Sample]] = await Task.detached {
            var out: [String: [UInt32: Sample]] = [:]
            for k in keys {
                guard let txt = try? String(contentsOf: Self.folder.appendingPathComponent("\(k).csv"), encoding: .utf8) else { continue }
                var d: [UInt32: Sample] = [:]
                for line in txt.split(separator: "\n") {
                    let p = line.split(separator: ";", omittingEmptySubsequences: false)
                    guard p.count >= 5, let t = UInt32(p[0]), let hr = Int(p[1]) else { continue }
                    var s = d[t] ?? Sample(t: t, hr: hr)
                    if hr > 0 { s.hr = hr }
                    let rr = p[2].split(separator: " ").compactMap { Int($0) }
                    if !rr.isEmpty { s.rr = rr }
                    if let m = Float(p[3]) { s.motion = m }
                    if let sk = Double(p[4]) { s.skin = sk }
                    if p.count >= 6 {
                        let q = p[5].split(separator: " ").compactMap { Float($0) }
                        if q.count == 4 { s.q = q }
                    }
                    d[t] = s
                }
                out[k] = d
            }
            return out
        }.value
        for (k, v) in loaded { byDay[k, default: [:]].merge(v) { a, _ in a } }
        revision += 1
    }

    func addLive(hr: Int, rr: [Int]) {
        guard hr > 0 else { return }
        let t = UInt32(Date().timeIntervalSince1970)
        add(Sample(t: t, hr: hr, rr: rr))
    }

    func addRecord(_ r: WhoopParser.Record) {
        var m: Float?
        if r.motion.count == 4, r.motion.allSatisfy({ $0.isFinite }) {
            if let q = lastQ { m = zip(r.motion, q).map { abs($0 - $1) }.reduce(0, +) }
            lastQ = r.motion
        }
        let q: [Float]? = r.motion.count == 4 && r.motion.allSatisfy({ $0.isFinite }) ? r.motion : nil
        add(Sample(t: r.time, hr: r.hr, rr: r.rr, motion: m, skin: r.skinTemp, q: q))
    }

    private func add(_ s: Sample) {
        let k = Self.dayKey(s.t)
        var cur = byDay[k]?[s.t] ?? s
        if s.hr > 0 { cur.hr = s.hr }
        if !s.rr.isEmpty { cur.rr = s.rr }
        if s.motion != nil { cur.motion = s.motion }
        if s.skin != nil { cur.skin = s.skin }
        if s.q != nil { cur.q = s.q }
        byDay[k, default: [:]][s.t] = cur
        let line = "\(s.t);\(s.hr);\(s.rr.map(String.init).joined(separator: " "));\(s.motion.map { String($0) } ?? "");\(s.skin.map { String($0) } ?? "");\(s.q.map { $0.map { String($0) }.joined(separator: " ") } ?? "")\n"
        pending[k, default: ""] += line
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { @MainActor in self?.flush() }
        }
    }

    func flush() {
        flushScheduled = false
        for (k, txt) in pending {
            let url = Self.folder.appendingPathComponent("\(k).csv")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(txt.utf8)); try? h.close() }
        }
        pending = [:]
        revision += 1
    }

    /// Alle samples van een dag (op tijd gesorteerd), plus de nacht ervoor vanaf 18:00.
    func samples(day: Date, includeNight: Bool = false) -> [Sample] {
        let k = Self.dayFmt.string(from: day)
        var s = Array((byDay[k] ?? [:]).values)
        if includeNight {
            let prevKey = Self.dayFmt.string(from: day.addingTimeInterval(-86400))
            let start = UInt32(Calendar.current.startOfDay(for: day).timeIntervalSince1970) - 6 * 3600
            s += (byDay[prevKey] ?? [:]).values.filter { $0.t >= start }
        }
        return s.sorted { $0.t < $1.t }
    }
}
