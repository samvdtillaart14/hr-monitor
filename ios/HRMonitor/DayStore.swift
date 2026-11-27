import Foundation

/// Bewaart metingen per seconde, per dag in Documenten/data/<jjjj-mm-dd>.csv,
/// zodat scores over meerdere dagen berekend kunnen worden.
/// Bronnen: historische Whoop-records (R18) en de live hartslag (0x2A37).
///
/// Kolommen: unix-s ; hr ; rr (ms, spatie) ; beweging ; huidtemp ; q (4 floats) ; bron (L = live, H = historie) ; stappenteller.
/// Oudere bestanden hebben nog geen bronkolom.
@MainActor
final class DayStore: ObservableObject {
    struct Sample: Sendable {
        var t: UInt32          // Unix-seconden
        var hr: Int
        var rr: [Int] = []     // ms
        var motion: Float?     // beweging t.o.v. vorige seconde (0 = stil)
        var skin: Double?
        var q: [Float]?        // 4 oriëntatie-floats (R18), voor slaapdetectie
        /// komt uit een historisch Whoop-record (dan zijn hr/rr/q compleet voor deze seconde)
        var rec = false
        /// stappenteller van de band (R18 @61), cumulatief sinds herstart van de band
        var steps: Int?
        /// vermoedelijke SpO2 (%) uit het historierecord, voorlopig
        var spo2: Int?
    }

    /// Aantal dagen dat in het geheugen blijft (en bij de start wordt ingelezen).
    nonisolated static let keepDays = 8

    @Published private(set) var revision = 0
    /// true zodra de laatste dagen bij het opstarten van schijf zijn ingelezen
    @Published private(set) var initialLoaded = false
    private(set) var byDay: [String: [UInt32: Sample]] = [:]
    /// gesorteerde samples per dag; vervalt zodra er voor die dag iets bijkomt
    private var sortedCache: [String: [Sample]] = [:]
    private var lastQ: [Float]?
    private var lastQTime: UInt32 = 0
    private var pending: [String: String] = [:]
    private var flushScheduled = false
    /// schrijven mislukte (bv. opslag vol); buffer wordt begrensd
    @Published private(set) var writeError = false

    nonisolated static let folder: URL = {
        let u = Recorder.folder.appendingPathComponent("data", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    nonisolated(unsafe) static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
        return f
    }()
    nonisolated static func dayKey(_ t: UInt32) -> String { dayFmt.string(from: Date(timeIntervalSince1970: TimeInterval(t))) }
    /// Dag `n` dagen vóór `date`, via de kalender (klopt ook rond de zomertijdwissel).
    nonisolated static func key(_ date: Date, minusDays n: Int) -> String {
        let cal = Calendar.current
        return dayFmt.string(from: cal.date(byAdding: .day, value: -n, to: cal.startOfDay(for: date)) ?? date)
    }

    init() { Task { await load() } }

    /// Laadt de laatste `keepDays` dagen van schijf.
    func load() async {
        let now = Date()
        await load(keys: (0..<Self.keepDays).map { Self.key(now, minusDays: $0) })
        initialLoaded = true
    }

    /// Dagen die bij het terugbladeren in het geheugen blijven (niet opgeruimd).
    private var pinned: Set<String> = []

    /// Oudere dagen (en de nacht ervoor) inlezen voor terugbladeren: 7 dagen tot en met `end`.
    func ensureLoaded(end: Date) async {
        let keys = (0..<9).map { Self.key(end, minusDays: $0) }
        pinned = Set(keys)
        let missing = keys.filter { byDay[$0] == nil }
        if !missing.isEmpty { await load(keys: missing) }
    }

    private func load(keys: [String]) async {
        let loaded: [String: [UInt32: Sample]] = await Task.detached(priority: .utility) {
            var out: [String: [UInt32: Sample]] = [:]
            for k in keys {
                guard let txt = try? String(contentsOf: Self.folder.appendingPathComponent("\(k).csv"), encoding: .utf8) else { continue }
                var d: [UInt32: Sample] = [:]
                for line in txt.split(separator: "\n") {
                    let p = line.split(separator: ";", omittingEmptySubsequences: false)
                    guard p.count >= 5, let t = UInt32(p[0]), let hr = Int(p[1]) else { continue }
                    let rr = p[2].split(separator: " ").compactMap { Int($0) }
                    var q: [Float]? = nil
                    if p.count >= 6 {
                        let v = p[5].split(separator: " ").compactMap { Float($0) }
                        if v.count == 4 { q = v }
                    }
                    let skin = Double(p[4])
                    // Bron: expliciet (nieuwe bestanden) of afgeleid (oude: alleen records hebben q of huidtemp).
                    let isRec = p.count >= 7 ? p[6] == "H" : (q != nil || skin != nil)
                    var s = d[t] ?? Sample(t: t, hr: hr)
                    if isRec {
                        if s.rec { continue }                // dubbele historieregel
                        if hr > 0 { s.hr = hr }
                        if !rr.isEmpty { s.rr = rr }
                        s.rec = true
                    } else {
                        if hr > 0 && !s.rec { s.hr = hr }
                        if !rr.isEmpty && !s.rec { s.rr += rr }   // meerdere live-pakketten in dezelfde seconde
                    }
                    if let m = Float(p[3]) { s.motion = m }
                    if let skin { s.skin = skin }
                    if let q { s.q = q }
                    if p.count >= 8, let st = Int(p[7]) { s.steps = st }
                    if p.count >= 9, let o = Int(p[8]) { s.spo2 = o }
                    d[t] = s
                }
                out[k] = d
            }
            return out
        }.value
        for (k, v) in loaded { byDay[k, default: [:]].merge(v) { a, _ in a }; sortedCache[k] = nil }
        revision += 1
    }

    /// Wordt aangeroepen bij elke live hartslag (voor automatisch GPS bij een activiteit).
    var onLive: ((Int) -> Void)?

    func addLive(hr: Int, rr: [Int]) {
        guard hr > 0 else { return }
        onLive?(hr)
        let t = UInt32(Date().timeIntervalSince1970)
        add(Sample(t: t, hr: hr, rr: rr))
    }

    func addRecord(_ r: WhoopParser.Record) {
        let k = Self.dayKey(r.time)
        if byDay[k]?[r.time]?.rec == true { return }    // al eerder uitgelezen: niet nog eens opslaan
        let valid = r.motion.count == 4 && r.motion.allSatisfy({ $0.isFinite })
        var m: Float?
        if valid {
            // Alleen vergelijken met de vorige seconde; q en −q zijn dezelfde oriëntatie (teken negeren).
            if let q = lastQ, r.time > lastQTime, r.time - lastQTime <= 5 {
                let diff = zip(r.motion, q).map { abs($0 - $1) }.reduce(0, +)
                let sum = zip(r.motion, q).map { abs($0 + $1) }.reduce(0, +)
                m = min(diff, sum)
            }
            lastQ = r.motion; lastQTime = r.time
        }
        add(Sample(t: r.time, hr: r.hr, rr: r.rr, motion: m, skin: r.skinTemp, q: valid ? r.motion : nil, rec: true, steps: r.steps, spo2: r.spo2))
    }

    private func add(_ s: Sample) {
        let k = Self.dayKey(s.t)
        var cur = byDay[k]?[s.t] ?? Sample(t: s.t, hr: 0)
        if s.rec {
            // Historisch record is compleet voor deze seconde.
            if s.hr > 0 { cur.hr = s.hr }
            if !s.rr.isEmpty { cur.rr = s.rr }
            cur.rec = true
        } else if !cur.rec {
            if s.hr > 0 { cur.hr = s.hr }
            cur.rr += s.rr     // tweede live-pakket in dezelfde seconde: slagen toevoegen, niet overschrijven
        }
        if s.motion != nil { cur.motion = s.motion }
        if s.skin != nil { cur.skin = s.skin }
        if s.q != nil { cur.q = s.q }
        if s.steps != nil { cur.steps = s.steps }
        if s.spo2 != nil { cur.spo2 = s.spo2 }
        byDay[k, default: [:]][s.t] = cur
        sortedCache[k] = nil
        let line = "\(s.t);\(s.hr);\(s.rr.map(String.init).joined(separator: " "));\(s.motion.map { String($0) } ?? "");\(s.skin.map { String($0) } ?? "");\(s.q.map { $0.map { String($0) }.joined(separator: " ") } ?? "");\(s.rec ? "H" : "L");\(s.steps.map(String.init) ?? "");\(s.spo2.map(String.init) ?? "")\n"
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
        var failed = false
        for (k, txt) in pending {
            let url = Self.folder.appendingPathComponent("\(k).csv")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            if let h = FileHandle.appending(to: url), h.safeWrite(Data(txt.utf8)) {
                try? h.close()
                pending[k] = nil
            } else {
                failed = true
                // Bewaren voor een volgende poging, maar niet onbeperkt (≈ 2 MB per dag).
                if txt.utf8.count > 2_000_000 { pending[k] = nil }
            }
        }
        writeError = failed
        if failed && !pending.isEmpty { scheduleFlush() }
        pruneMemory()
        revision += 1
    }

    /// Dagen ouder dan `keepDays` uit het geheugen halen (de app kan wekenlang op de achtergrond blijven draaien).
    private func pruneMemory() {
        let oldest = Self.key(Date(), minusDays: Self.keepDays - 1)
        for k in byDay.keys where k < oldest && !pinned.contains(k) { byDay[k] = nil; sortedCache[k] = nil }
    }

    private func sorted(_ k: String) -> [Sample] {
        if let c = sortedCache[k] { return c }
        let s = (byDay[k] ?? [:]).values.sorted { $0.t < $1.t }
        sortedCache[k] = s
        return s
    }

    /// Stappen op een dag: som van de toenames van de stappenteller. Daalt de teller (herstart van de band),
    /// dan telt de nieuwe waarde als stappen sinds die herstart.
    nonisolated static func steps(_ samples: [Sample]) -> Int {
        var total = 0, prev: Int?
        for s in samples {
            guard let v = s.steps else { continue }
            if let p = prev { total += v >= p ? v - p : v }
            prev = v
        }
        return total
    }

    /// Inactiviteit: minuten zonder één stap, alleen minuten waarin de stappenteller van de band is gemeten,
    /// buiten de opgegeven perioden (slaap, activiteiten). Geeft (inactief, gemeten) in minuten.
    nonisolated static func inactivity(_ samples: [Sample], exclude: [(start: Double, end: Double)]) -> (inactive: Int, measured: Int) {
        var minutes: [UInt32: (min: Int, max: Int, stepped: Bool)] = [:]
        var prev: Int?
        for s in samples {
            guard let v = s.steps else { continue }
            let t = Double(s.t)
            if exclude.contains(where: { t >= $0.start && t < $0.end }) { prev = v; continue }
            let m = s.t / 60
            let stepped = prev.map { v > $0 } ?? false
            prev = v
            var e = minutes[m] ?? (v, v, false)
            e.stepped = e.stepped || stepped
            minutes[m] = e
        }
        let inactive = minutes.values.filter { !$0.stepped }.count
        return (inactive, minutes.count)
    }

    /// Stappen van een dag, of nil als er die dag geen stappenteller is gemeten.
    func steps(day: Date) -> Int? {
        let s = samples(day: day)
        guard s.contains(where: { $0.steps != nil }) else { return nil }
        return Self.steps(s)
    }

    /// Alle samples van een dag (op tijd gesorteerd), plus de nacht ervoor vanaf 18:00.
    func samples(day: Date, includeNight: Bool = false) -> [Sample] {
        let cal = Calendar.current
        let k = Self.dayFmt.string(from: day)
        guard includeNight else { return sorted(k) }
        let prevDay = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: day)) ?? day
        let prevKey = Self.dayFmt.string(from: prevDay)
        let start = UInt32((cal.date(bySettingHour: 18, minute: 0, second: 0, of: prevDay) ?? prevDay).timeIntervalSince1970)
        let out = sorted(prevKey).filter { $0.t >= start } + sorted(k)
        // Na een tijdzonewissel kan het bestand van gisteren latere seconden bevatten dan dat van vandaag;
        // de scores verwachten een oplopende reeks (anders negatieve tijdstappen in belasting en calorieën).
        return zip(out, out.dropFirst()).allSatisfy { $0.t <= $1.t } ? out : out.sorted { $0.t < $1.t }
    }
}
