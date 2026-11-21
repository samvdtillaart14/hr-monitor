import Foundation
import WhoopScores

/// Eén nacht (genoemd naar de dag waarop je wakker wordt), berekend met de scores-module.
struct Night: Identifiable {
    var id: Date { date }
    let date: Date
    let r: NightResult
    var needMin = 0.0, needBase = 0.0, needStrain = 0.0, needDebt = 0.0, debtMin = 0.0
    var sufficiency = 0.0, efficiency = 0.0, consistency: Double?, performance: Double?
    var stress: [(Date, Double)] = []            // slaapstress per 5 min, 0–3
    var stressMin = [0, 0, 0]                     // laag, middel, hoog (minuten tijdens slaap)
    var hr: [(Date, Double)] = []                 // HR per minuut rond de slaap
    var recovery: Int?
    var metrics = NightMetrics()

    var onset: Date { Date(timeIntervalSince1970: r.onset) }
    var wake: Date { Date(timeIntervalSince1970: r.wake) }
    var restorativeMin: Int { r.deepMin + r.remMin }
    var highStressPct: Double {
        let t = stressMin.reduce(0, +); return t > 0 ? 100 * Double(stressMin[2]) / Double(t) : 0
    }
    func stageTime(_ k: Int) -> Date { Date(timeIntervalSince1970: r.onset + Double(k) * 60) }
}

/// Eén kalenderdag: belasting, zones en geschatte energie.
struct DayLoad: Identifiable {
    var id: Date { date }
    let date: Date
    var strain = 0.0
    var zoneMin = [Double](repeating: 0, count: 6)
    var kcal = 0.0
    var zones13: Double { zoneMin[1] + zoneMin[2] + zoneMin[3] }
    var zones45: Double { zoneMin[4] + zoneMin[5] }
}

/// Rekent nachten (slaap, herstel) en dagen (belasting) uit op de achtergrond.
@MainActor
final class ScoreModel: ObservableObject {
    @Published private(set) var nights: [Night] = []
    @Published private(set) var days: [DayLoad] = []
    private var busy = false

    var lastNight: Night? {
        guard let n = nights.last, Calendar.current.isDateInToday(n.date) else { return nil }
        return n
    }
    var today: DayLoad? { days.last.flatMap { Calendar.current.isDateInToday($0.date) ? $0 : nil } }

    func refresh(store: DayStore) {
        guard !busy else { return }
        busy = true
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dates = (0..<7).reversed().map { cal.date(byAdding: .day, value: -$0, to: today)! }
        // Invoer op de main actor verzamelen, rekenen los daarvan.
        var input: [(Date, [Sample], [Sample])] = []
        for d in dates {
            let start = d.timeIntervalSince1970
            let night = store.samples(day: d, includeNight: true).filter { Double($0.t) < start + 14 * 3600 }.map(Self.convert)
            let day = store.samples(day: d).map(Self.convert)
            input.append((d, night, day))
        }
        Task {
            let (n, dl) = await Task.detached(priority: .utility) { Self.compute(input) }.value
            self.nights = n; self.days = dl; self.busy = false
        }
    }

    nonisolated static func convert(_ s: DayStore.Sample) -> Sample {
        Sample(t: Double(s.t), hr: Double(s.hr), rr: s.rr.map(Double.init), q: s.q?.map(Double.init), skinTemp: s.skin)
    }

    nonisolated static func fin(_ v: Double) -> Double? { v.isFinite ? v : nil }

    /// Energie (kcal) uit hartslag; formule van Keytel e.a. (2005), standaardprofiel man 75 kg, 30 jaar.
    /// In rust: ~1,2 kcal/min (ruststofwisseling). Een schatting, geen meting.
    nonisolated static func kcal(_ samples: [Sample]) -> Double {
        var k = 0.0
        for i in samples.indices where samples[i].hr > 0 {
            let dt = i + 1 < samples.count ? min(5, samples[i + 1].t - samples[i].t) : 1
            let hr = samples[i].hr
            let active = (-55.0969 + 0.6309 * hr + 0.1988 * 75 + 0.2017 * 30) / 4.184
            k += max(1.2, hr > 90 ? active : 1.2) * dt / 60
        }
        return k
    }

    nonisolated static func compute(_ input: [(Date, [Sample], [Sample])]) -> ([Night], [DayLoad]) {
        let c = Calibration.standard
        var nights: [Night] = [], days: [DayLoad] = [], history: [NightMetrics] = []
        var prevStrain = 0.0
        let tz = Double(TimeZone.current.secondsFromGMT()) / 60
        for (date, nightS, dayS) in input {
            // Belasting van deze kalenderdag
            let st = WhoopScores.strain(dayS, c)
            var dl = DayLoad(date: date, strain: st.strain, zoneMin: st.zoneMin)
            dl.kcal = kcal(dayS)
            defer { days.append(dl); prevStrain = st.strain }

            guard nightS.count > 1800, let r = WhoopScores.analyzeNight(nightS, c) else { continue }
            var n = Night(date: date, r: r)
            // Slaapbehoefte: basis + belasting van gisteren + tekort van de vorige nacht
            if let p = nights.last, date.timeIntervalSince(p.date) < 2 * 86400 {
                n.debtMin = max(0, p.needMin - Double(p.r.asleepMin))
            }
            let naps = Double(r.naps.reduce(0) { $0 + $1.minutes })
            n.needBase = c.sleep.needBaseMin
            n.needStrain = c.sleep.needPerStrainMin * max(0, prevStrain - c.sleep.strainRef)
            n.needDebt = c.sleep.needPerDebtMin * n.debtMin
            n.needMin = WhoopScores.sleepNeedMin(debtMin: n.debtMin, prevDayStrain: prevStrain, napMin: naps, c)
            n.sufficiency = WhoopScores.sleepSufficiency(asleepMin: Double(r.asleepMin), needMin: n.needMin)
            n.efficiency = r.efficiency
            let windows = nights.map { (onset: $0.r.onset, wake: $0.r.wake) } + [(onset: r.onset, wake: r.wake)]
            n.consistency = fin(WhoopScores.sleepConsistency(windows, tzOffsetMin: tz))
            n.performance = fin(WhoopScores.sleepPerformance(asleepMin: Double(r.asleepMin), needMin: n.needMin,
                                                             efficiency: r.efficiency, consistency: n.consistency, c))

            // HR per minuut en slaapstress per 5 min, van 30 min voor tot 30 min na de slaap
            let lo = r.onset - 1800, hi = r.wake + 1800
            var perMin: [Int: (Double, Int)] = [:]
            for s in nightS where s.t >= lo && s.t <= hi && s.hr > 0 {
                let k = Int(s.t / 60); perMin[k, default: (0, 0)].0 += s.hr; perMin[k, default: (0, 0)].1 += 1
            }
            n.hr = perMin.keys.sorted().map { k in (Date(timeIntervalSince1970: Double(k * 60)), perMin[k]!.0 / Double(perMin[k]!.1)) }
            // Stress: HR boven de rust-HR van de nacht; 8 bpm erboven = 1 punt.
            let rhr = fin(r.rhr) ?? (n.hr.map(\.1).min() ?? 55)
            var b5: [Int: (Double, Int)] = [:]
            for (t, h) in n.hr {
                let k = Int(t.timeIntervalSince1970 / 300)
                b5[k, default: (0, 0)].0 += max(0, min(3, (h - rhr) / 8)); b5[k, default: (0, 0)].1 += 1
            }
            n.stress = b5.keys.sorted().map { k in (Date(timeIntervalSince1970: Double(k * 300)), b5[k]!.0 / Double(b5[k]!.1)) }
            for (t, v) in n.stress where t.timeIntervalSince1970 >= r.onset && t.timeIntervalSince1970 < r.wake {
                n.stressMin[v >= 2 ? 2 : v >= 1 ? 1 : 0] += 5
            }

            n.metrics = NightMetrics(hrv: fin(r.hrv), rhr: fin(r.rhr), resp: fin(r.resp), sleepPerf: n.performance,
                                     skinTemp: fin(r.skinTemp), sufficiency: n.sufficiency, efficiency: r.efficiency,
                                     consistency: n.consistency)
            n.recovery = n.metrics.hrv == nil ? nil : WhoopScores.recovery(n.metrics, history: history, c)
            history.append(n.metrics)
            nights.append(n)
        }
        return (nights, days)
    }
}
