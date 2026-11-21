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
    var highStressPct: Double { r.highStressPct.isFinite ? r.highStressPct : 0 }
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
        let fixedCal = UserProfile.calibration()
        Task {
            let (n, dl) = await Task.detached(priority: .utility) { Self.compute(input, fixedCal) }.value
            self.nights = n; self.days = dl; self.busy = false
            UserProfile.updateRestHr(from: n.compactMap { $0.metrics.rhr })
        }
    }

    nonisolated static func convert(_ s: DayStore.Sample) -> Sample {
        Sample(t: Double(s.t), hr: Double(s.hr), rr: s.rr.map(Double.init), q: s.q?.map(Double.init), skinTemp: s.skin)
    }

    nonisolated static func fin(_ v: Double) -> Double? { v.isFinite ? v : nil }

    nonisolated static func compute(_ input: [(Date, [Sample], [Sample])], _ c: Calibration) -> ([Night], [DayLoad]) {
        var nights: [Night] = [], days: [DayLoad] = [], history: [NightMetrics] = []
        var prevStrain = 0.0
        let tz = Double(TimeZone.current.secondsFromGMT()) / 60
        for (date, nightS, dayS) in input {
            // Belasting van deze kalenderdag
            let st = WhoopScores.strain(dayS, c)
            var dl = DayLoad(date: date, strain: st.strain, zoneMin: st.zoneMin)
            dl.kcal = WhoopScores.calories(dayS, c)
            defer { days.append(dl); prevStrain = st.strain }

            let base = WhoopScores.baseline(from: history, c)
            guard nightS.count > 1800, let r = WhoopScores.analyzeNight(nightS, c, baseline: base) else { continue }
            var n = Night(date: date, r: r)
            // Slaapbehoefte: gezond minimum + belasting van gisteren + slaaptekort (scores-module)
            if let p = nights.last, date.timeIntervalSince(p.date) < 2 * 86400 {
                n.debtMin = WhoopScores.sleepDebt(prevDebtMin: p.debtMin, prevNeedMin: p.needMin, prevAsleepMin: Double(p.r.asleepMin), c)
            }
            let naps = Double(r.naps.reduce(0) { $0 + $1.minutes })
            let parts = WhoopScores.sleepNeedParts(debtMin: n.debtMin, prevDayStrain: prevStrain, napMin: naps, c)
            n.needBase = parts.healthy; n.needStrain = parts.strain; n.needDebt = parts.debt; n.needMin = parts.total
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
            // Slaapstress uit de scores-module: per minuut in bed, hier per 5 min gemiddeld voor de grafiek.
            var k = 0
            while k < r.stress.count {
                let chunk = r.stress[k..<min(r.stress.count, k + 5)].filter { $0.isFinite }
                if !chunk.isEmpty { n.stress.append((Date(timeIntervalSince1970: r.onset + Double(k) * 60), chunk.reduce(0, +) / Double(chunk.count))) }
                k += 5
            }
            n.stressMin = [r.stressMin.low, r.stressMin.medium, r.stressMin.high]

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
