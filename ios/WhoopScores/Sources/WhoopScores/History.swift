import Foundation

/// Eén dag/nacht in de geschiedenis: uit de Whoop-export (startdata) of uit eigen analyses.
/// Tijden in Unix-s, duur in minuten, percentages 0–100.
public struct DayRecord: Codable, Sendable, Equatable {
    public var cycleStart: Double
    public var onset: Double?, wake: Double?
    public var recovery: Double?, hrv: Double?, rhr: Double?, resp: Double?, skinTemp: Double?, spo2: Double?
    public var dayStrain: Double?, kcal: Double?, maxHr: Double?, avgHr: Double?
    public var sleepPerf: Double?, inBedMin: Double?, asleepMin: Double?, lightMin: Double?, deepMin: Double?, remMin: Double?, awakeMin: Double?
    public var needMin: Double?, debtMin: Double?, efficiency: Double?, consistency: Double?
    public var highStressPct: Double?
    public var source: String = "whoop"

    public init(cycleStart: Double) { self.cycleStart = cycleStart }

    public var sufficiency: Double? {
        guard let a = asleepMin, let n = needMin, n > 0 else { return nil }
        return min(100, 100 * a / n)
    }
    public var restorativeMin: Double? { deepMin.flatMap { d in remMin.map { d + $0 } } }
    public var metrics: NightMetrics {
        NightMetrics(hrv: hrv, rhr: rhr, resp: resp, sleepPerf: sleepPerf, skinTemp: skinTemp,
                     sufficiency: sufficiency, efficiency: efficiency, consistency: consistency)
    }
}

public enum History {
    /// Gemiddelde van een waarde over de `days` records vóór index `i` (zoals Whoop's "vs. last 30 days").
    public static func trailingMean(_ records: [DayRecord], before i: Int, days: Int = 30, _ f: (DayRecord) -> Double?) -> Double? {
        let v = records[max(0, i - days)..<min(i, records.count)].compactMap(f).filter { $0.isFinite }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    /// Normaalbereik (25e–75e percentiel) over de `days` records vóór index `i`.
    public static func typicalRange(_ records: [DayRecord], before i: Int, days: Int = 30, _ f: (DayRecord) -> Double?) -> ClosedRange<Double>? {
        let v = records[max(0, i - days)..<min(i, records.count)].compactMap(f).filter { $0.isFinite }
        guard v.count >= 3 else { return nil }
        return M.percentile(v, 0.25)...M.percentile(v, 0.75)
    }

    /// Slaapschuld voor de volgende nacht uit het laatste record.
    public static func nextDebt(after r: DayRecord, _ cal: Calibration = .standard) -> Double {
        WhoopScores.sleepDebt(prevDebtMin: r.debtMin ?? 0, prevNeedMin: r.needMin ?? .nan, prevAsleepMin: r.asleepMin ?? .nan, cal)
    }

    /// Leest physiological_cycles.csv en (optioneel) sleeps.csv uit de Whoop-export; oudste eerst.
    public static func importWhoop(cycles: String, sleeps: String? = nil) -> [DayRecord] {
        var out: [DayRecord] = []
        for row in CSV.parse(cycles) {
            let tz = row["Cycle timezone"] ?? ""
            guard let start = CSV.time(row["Cycle start time"], tz) else { continue }
            var r = DayRecord(cycleStart: start)
            r.onset = CSV.time(row["Sleep onset"], tz); r.wake = CSV.time(row["Wake onset"], tz)
            r.recovery = CSV.num(row["Recovery score %"]); r.hrv = CSV.num(row["Heart rate variability (ms)"])
            r.rhr = CSV.num(row["Resting heart rate (bpm)"]); r.resp = CSV.num(row["Respiratory rate (rpm)"])
            r.skinTemp = CSV.num(row["Skin temp (celsius)"]); r.spo2 = CSV.num(row["Blood oxygen %"])
            r.dayStrain = CSV.num(row["Day Strain"]); r.kcal = CSV.num(row["Energy burned (cal)"])
            r.maxHr = CSV.num(row["Max HR (bpm)"]); r.avgHr = CSV.num(row["Average HR (bpm)"])
            r.sleepPerf = CSV.num(row["Sleep performance %"]); r.inBedMin = CSV.num(row["In bed duration (min)"])
            r.asleepMin = CSV.num(row["Asleep duration (min)"]); r.lightMin = CSV.num(row["Light sleep duration (min)"])
            r.deepMin = CSV.num(row["Deep (SWS) duration (min)"]); r.remMin = CSV.num(row["REM duration (min)"])
            r.awakeMin = CSV.num(row["Awake duration (min)"]); r.needMin = CSV.num(row["Sleep need (min)"])
            r.debtMin = CSV.num(row["Sleep debt (min)"]); r.efficiency = CSV.num(row["Sleep efficiency %"])
            r.consistency = CSV.num(row["Sleep consistency %"])
            out.append(r)
        }
        return out.sorted { $0.cycleStart < $1.cycleStart }
    }
}

/// Kleine CSV-lezer (komma's, aanhalingstekens, BOM).
public enum CSV {
    public static func parse(_ text: String) -> [[String: String]] {
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
        var it = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text).makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? it.next() {
            pending = nil
            if quoted {
                if ch == "\"" { if let n = it.next() { if n == "\"" { cell.append("\"") } else { quoted = false; pending = n } } else { quoted = false } }
                else { cell.append(ch) }
                continue
            }
            switch ch {
            case "\"": quoted = true
            case ",": row.append(cell); cell = ""
            case "\n", "\r", "\r\n": row.append(cell); rows.append(row); row = []; cell = ""
            default: cell.append(ch)
            }
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        guard let head = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces) }) else { return [] }
        return rows.dropFirst().filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }.map { r in
            Dictionary(uniqueKeysWithValues: head.enumerated().map { ($0.element, $0.offset < r.count ? r[$0.offset] : "") })
        }
    }
    public static func num(_ s: String?) -> Double? {
        guard let s = s?.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return Double(s)
    }
    /// "2026-11-21 01:47:13" met tijdzone "UTC+01:00" → Unix-s.
    public static func time(_ s: String?, _ tz: String) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var secs = 0
        if let r = tz.range(of: #"[+-]\d\d:\d\d"#, options: .regularExpression) {
            let p = tz[r]; let sign = p.first == "-" ? -1 : 1
            secs = sign * ((Int(p.dropFirst().prefix(2)) ?? 0) * 3600 + (Int(p.suffix(2)) ?? 0) * 60)
        }
        f.timeZone = TimeZone(secondsFromGMT: secs)
        return f.date(from: s)?.timeIntervalSince1970
    }
}
