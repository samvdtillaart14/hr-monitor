import Foundation

/// Eigen benaderingen van dagelijkse scores. Geen Whoop-algoritmes: bekende, openbare methodes.
/// - Slaap: langste rustige periode (weinig beweging, lage HR) tussen 18:00 en 14:00, t.o.v. 8 u slaapbehoefte.
/// - Herstel: HRV (ln RMSSD) en rust-HR van de nacht t.o.v. je eigen 7-daagse baseline.
/// - Belasting: Edwards-TRIMP (minuten per hartslagzone × 1…5), logaritmisch geschaald naar 0–21.
/// - Stress: HR boven rust-HR bij weinig beweging, per 5 minuten, schaal 0–3.
@MainActor
enum Analytics {
    struct Day {
        var date: Date
        var sleepMinutes: Int = 0
        var sleepStart: Date?
        var sleepEnd: Date?
        var sleepScore: Int?         // %
        var rhr: Int?                // bpm
        var hrv: Double?             // ms (RMSSD)
        var recovery: Int?           // %
        var strain: Double = 0       // 0–21
        var zoneMinutes: [Int] = Array(repeating: 0, count: 6)
        var skin: Double?
        var stress: [(Date, Double)] = []
        var currentStress: Double?
        var measuredMinutes = 0
    }

    static let hrMax = 190

    static func rmssd(_ rr: [Int]) -> Double? {
        var s = 0.0, n = 0
        for i in 1..<max(1, rr.count) {
            let d = Double(rr[i] - rr[i - 1])
            if abs(d) < 250 { s += d * d; n += 1 }
        }
        return n >= 20 ? (s / Double(n)).squareRoot() : nil
    }

    /// Slaapvenster: langste aaneengesloten periode van rust (beweging laag, HR < daggemiddelde).
    static func sleepWindow(_ s: [DayStore.Sample]) -> (Int, Int)? {
        guard s.count > 600 else { return nil }
        let meanHR = Double(s.map(\.hr).reduce(0, +)) / Double(s.count)
        // Per minuut: rustig als gemiddelde beweging klein en HR onder gemiddelde.
        var minutes: [(t: UInt32, calm: Bool)] = []
        var i = 0
        while i < s.count {
            let t0 = s[i].t / 60
            var hr = 0, n = 0, mot: Float = 0, mn = 0
            while i < s.count, s[i].t / 60 == t0 {
                hr += s[i].hr; n += 1
                if let m = s[i].motion { mot += m; mn += 1 }
                i += 1
            }
            let avgM = mn > 0 ? mot / Float(mn) : 0
            minutes.append((t0 * 60, Double(hr) / Double(max(1, n)) < meanHR && avgM < 0.02))
        }
        // Langste reeks rustige minuten, gaten tot 10 min toegestaan.
        var best: (Int, Int)? = nil, start: Int? = nil, lastCalm = 0
        for (k, m) in minutes.enumerated() {
            if m.calm {
                if start == nil { start = k }
                lastCalm = k
            } else if let st = start, k - lastCalm > 10 {
                if best == nil || lastCalm - st > best!.1 - best!.0 { best = (st, lastCalm) }
                start = nil
            }
        }
        if let st = start, best == nil || lastCalm - st > best!.1 - best!.0 { best = (st, lastCalm) }
        guard let b = best, b.1 - b.0 >= 60 else { return nil }
        return (Int(minutes[b.0].t), Int(minutes[b.1].t))
    }

    static func day(_ date: Date, store: DayStore, baseline: (hrv: Double?, rhr: Double?) = (nil, nil)) -> Day {
        var d = Day(date: date)
        let all = store.samples(day: date, includeNight: true)
        let dayStart = UInt32(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
        let today = all.filter { $0.t >= dayStart }
        d.measuredMinutes = Set(today.map { $0.t / 60 }).count

        // Slaap (18:00 gisteren – 14:00 vandaag)
        let night = all.filter { $0.t < dayStart + 14 * 3600 }
        if let (a, b) = sleepWindow(night) {
            d.sleepStart = Date(timeIntervalSince1970: TimeInterval(a))
            d.sleepEnd = Date(timeIntervalSince1970: TimeInterval(b))
            d.sleepMinutes = (b - a) / 60
            d.sleepScore = min(100, Int(Double(d.sleepMinutes) / 480 * 100))
            let inSleep = night.filter { Int($0.t) >= a && Int($0.t) <= b }
            // Rust-HR: 10e percentiel tijdens slaap; HRV: RMSSD over de laatste 2 uur slaap (zoals veel wearables).
            let hrs = inSleep.map(\.hr).filter { $0 > 30 }.sorted()
            if !hrs.isEmpty { d.rhr = hrs[hrs.count / 10] }
            let late = inSleep.filter { Int($0.t) >= b - 7200 }.flatMap(\.rr)
            d.hrv = rmssd(late)
        }
        if d.rhr == nil {
            let hrs = today.map(\.hr).filter { $0 > 30 }.sorted()
            if hrs.count > 300 { d.rhr = hrs[hrs.count / 20] }
        }

        // Herstel: z-scores t.o.v. baseline, of vaste referentie zonder baseline.
        if let hrv = d.hrv, let rhr = d.rhr {
            let bHRV = baseline.hrv ?? hrv, bRHR = baseline.rhr ?? Double(rhr)
            let zh = (log(hrv) - log(bHRV)) / 0.15
            let zr = (Double(rhr) - bRHR) / 3
            d.recovery = max(1, min(99, Int(66 + 18 * zh - 10 * zr)))
        }

        // Belasting: Edwards-TRIMP over vandaag.
        var zoneSec = Array(repeating: 0, count: 6)
        for s in today where s.hr > 0 { zoneSec[Theme.zoneIndex(s.hr, max: hrMax)] += 1 }
        d.zoneMinutes = zoneSec.map { $0 / 60 }
        let trimp = (1...5).reduce(0.0) { $0 + Double(zoneSec[$1]) / 60 * Double($1) }
        d.strain = (21 * (1 - exp(-trimp / 250)) * 10).rounded() / 10

        d.skin = today.compactMap(\.skin).last

        // Stress per 5 minuten: HR boven rust-HR bij weinig beweging.
        let rhrRef = Double(d.rhr ?? 60)
        var buckets: [UInt32: (Double, Int)] = [:]
        for s in today where s.hr > 0 && (s.motion ?? 0) < 0.05 {
            let b = s.t / 300 * 300
            let v = max(0, min(3, (Double(s.hr) - rhrRef) / 12))
            buckets[b, default: (0, 0)].0 += v
            buckets[b, default: (0, 0)].1 += 1
        }
        d.stress = buckets.keys.sorted().compactMap { k in
            let (v, n) = buckets[k]!
            return n >= 30 ? (Date(timeIntervalSince1970: TimeInterval(k)), v / Double(n)) : nil
        }
        d.currentStress = d.stress.last.map(\.1)
        return d
    }

    /// Vandaag plus de 6 dagen ervoor; herstel t.o.v. het gemiddelde van de voorgaande dagen.
    static func week(store: DayStore) -> [Day] {
        let cal = Calendar.current
        let dates = (0..<7).reversed().map { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: Date()))! }
        var raw = dates.map { day($0, store: store) }
        for i in raw.indices {
            let prev = raw[..<i]
            let hrvs = prev.compactMap(\.hrv), rhrs = prev.compactMap(\.rhr)
            let b: (Double?, Double?) = (hrvs.isEmpty ? nil : exp(hrvs.map { log($0) }.reduce(0, +) / Double(hrvs.count)),
                     rhrs.isEmpty ? nil : Double(rhrs.reduce(0, +)) / Double(rhrs.count))
            if b.0 != nil || b.1 != nil { raw[i] = day(dates[i], store: store, baseline: (b.0, b.1)) }
        }
        return raw
    }
}
