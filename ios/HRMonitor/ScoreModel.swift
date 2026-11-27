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
    /// > 0: zoveel nachten extra nodig voordat herstel eerlijk te berekenen is
    var recoveryNeedsNights = 0
    var metrics = NightMetrics()
    /// slaaptijden door jou aangepast (niet automatisch herkend)
    var manual = false
    /// minuten dat het telefoonscherm aan stond tussen inslapen en wakker worden
    var phoneMin = 0
    /// minuten van scherm uit tot inslapen (nil = geen telefoon gebruikt vlak voor het slapen)
    var latencyMin: Int?
    /// slaapschuld over de laatste 7 nachten (min)
    var weekDebtMin = 0.0

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
    /// minuten met metingen op deze dag
    var measuredMin = 0.0
    var zones13: Double { zoneMin[1] + zoneMin[2] + zoneMin[3] }
    var zones45: Double { zoneMin[4] + zoneMin[5] }
}

/// Rekent nachten (slaap, herstel) en dagen (belasting) uit op de achtergrond.
@MainActor
final class ScoreModel: ObservableObject {
    @Published private(set) var nights: [Night] = []
    @Published private(set) var days: [DayLoad] = []
    private var busy = false
    private var waiters: [() -> Void] = []
    private var rerun = false
    /// Periodes dat het telefoonscherm aan stond (wakker); gezet door AppServices.
    var awakeIntervals: () -> [Range<Double>] = { [] }

    /// Dag waarop de berekening eindigt (vandaag, of een eerdere dag bij terugbladeren).
    @Published private(set) var anchor = Date()
    private var requestedEnd: Date?

    var lastNight: Night? {
        guard let n = nights.last, Calendar.current.isDate(n.date, inSameDayAs: anchor) else { return nil }
        return n
    }
    var today: DayLoad? { days.last.flatMap { Calendar.current.isDate($0.date, inSameDayAs: anchor) ? $0 : nil } }

    /// `completion` volgt na de berekening; loopt er al een, dan volgt er nog één met de nieuwste data.
    /// - end: laatste dag van het venster (nil = vandaag).
    func refresh(store: DayStore, end: Date? = nil, completion: (() -> Void)? = nil) {
        if let completion { waiters.append(completion) }
        requestedEnd = end
        guard !busy else { rerun = true; return }
        busy = true
        let cal = Calendar.current
        let endDay = end ?? Date()
        let today = cal.startOfDay(for: endDay)
        let dates = (0..<7).reversed().map { cal.date(byAdding: .day, value: -$0, to: today)! }
        // Invoer op de main actor verzamelen (alleen kopieën), omrekenen en rekenen los daarvan.
        var input: [(Date, [DayStore.Sample], [DayStore.Sample])] = []
        for d in dates {
            let end = UInt32((cal.date(byAdding: .hour, value: 14, to: d) ?? d).timeIntervalSince1970)
            input.append((d, store.samples(day: d, includeNight: true).filter { $0.t < end }, store.samples(day: d)))
        }
        let fixedCal = UserProfile.calibration()
        // Eerdere nachten (buiten dit venster) als basislijn voor herstel, zoals "laatste 30 dagen".
        let firstKey = DayStore.dayFmt.string(from: dates[0])
        let prior = NightArchive.shared.metrics(before: firstKey, limit: fixedCal.recovery.windowDays)
        let awake = awakeIntervals()
        let personal = UserProfile.hasPersonalBaseline
        let manual = SleepEdits.all
        Task {
            let (computed, dl, ds) = await Task.detached(priority: .utility) { () -> ([Night], [DayLoad], [(String, DayStats)]) in
                let conv = input.map { ($0.0, $0.1.map(Self.convert), $0.2.map(Self.convert)) }
                let (n, dl) = Self.compute(conv, fixedCal, prior: prior, personalBaseline: personal, awake: awake, manual: manual)
                return (n, dl, Self.dayStats(input.map { ($0.0, $0.2) }, nights: n, days: dl))
            }.value
            // Vermoedelijke SpO2 per nacht: mediaan van de bandwaarden tussen inslapen en wakker worden.
            var n = computed
            for i in n.indices {
                let lo = UInt32(n[i].r.onset), hi = UInt32(n[i].r.wake)
                let v = input.first { Calendar.current.isDate($0.0, inSameDayAs: n[i].date) }?.1
                    .filter { $0.t >= lo && $0.t <= hi }.compactMap(\.spo2).sorted() ?? []
                if v.count >= 30 { n[i].metrics.spo2 = Double(v[v.count / 2]) }
            }
            self.nights = n; self.days = dl; self.anchor = endDay; self.busy = false
            if self.rerun { self.rerun = false; self.refresh(store: store, end: self.requestedEnd) }
            else { let w = self.waiters; self.waiters = []; w.forEach { $0() } }
            NightArchive.shared.store(n.map { (DayStore.dayFmt.string(from: $0.date), $0.metrics) })
            DayArchive.shared.store(ds)
            if end == nil { UserProfile.updateRestHr(from: NightArchive.shared.recentRhr(30)) }
        }
    }

    nonisolated static func convert(_ s: DayStore.Sample) -> Sample {
        Sample(t: Double(s.t), hr: Double(s.hr), rr: s.rr.map(Double.init), q: s.q?.map(Double.init), skinTemp: s.skin)
    }

    /// Dagwaarden voor het maandrapport: belasting, stappen en inactiviteit (slaap telt niet als inactief).
    /// Alleen dagen met minstens 2 uur metingen.
    nonisolated static func dayStats(_ input: [(Date, [DayStore.Sample])], nights: [Night], days: [DayLoad]) -> [(String, DayStats)] {
        let cal = Calendar.current
        return input.compactMap { (item: (Date, [DayStore.Sample])) -> (String, DayStats)? in
            let (date, s) = item
            guard let d = days.first(where: { cal.isDate($0.date, inSameDayAs: date) }), d.measuredMin >= 120 else { return nil }
            let excl = nights.filter { cal.isDate($0.date, inSameDayAs: date) }.map { (start: $0.r.onset, end: $0.r.wake) }
            let hasSteps = s.contains { $0.steps != nil }
            let ina = DayStore.inactivity(s, exclude: excl)
            return (DayStore.dayFmt.string(from: date),
                    DayStats(strain: d.strain, steps: hasSteps ? DayStore.steps(s) : nil,
                             inactiveMin: ina.measured >= 60 ? ina.inactive : nil))
        }
    }

    nonisolated static func fin(_ v: Double) -> Double? { v.isFinite ? v : nil }

    /// - personalBaseline: true als de kalibratie (met jouw Whoop-basislijn) is geladen. Zonder die kalibratie
    ///   en met minder dan `minHistory` eerdere nachten is er geen eerlijke basislijn: dan geen herstelscore.
    /// - awake: periodes dat het telefoonscherm aan stond; die minuten zijn nooit slaap.
    nonisolated static func compute(_ input: [(Date, [Sample], [Sample])], _ c: Calibration, prior: [NightMetrics] = [],
                                    personalBaseline: Bool = false, awake: [Range<Double>] = [],
                                    manual: [String: Range<Double>] = [:]) -> ([Night], [DayLoad]) {
        var nights: [Night] = [], days: [DayLoad] = [], history: [NightMetrics] = prior
        var prevStrain = 0.0
        let tz = Double(TimeZone.current.secondsFromGMT()) / 60
        for (date, nightS, dayS) in input {
            // Belasting van deze kalenderdag
            let st = WhoopScores.strain(dayS, c)
            var dl = DayLoad(date: date, strain: st.strain, zoneMin: st.zoneMin)
            dl.kcal = WhoopScores.calories(dayS, c)
            // Tijd zonder metingen (band af, app niet verbonden) telt mee als rustverbruik.
            let measured = WhoopScores.measuredSeconds(dayS)
            dl.measuredMin = measured / 60
            if !dayS.isEmpty {
                let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
                let elapsed = max(0, min(Date(), dayEnd).timeIntervalSince(date))
                dl.kcal += WhoopScores.restingKcalPerMin(c) * max(0, elapsed - measured) / 60 * c.profile.kcalScale
            }
            defer { days.append(dl); prevStrain = st.strain }

            let base = WhoopScores.baseline(from: history, c)
            let edit = manual[DayStore.dayFmt.string(from: date)]
            guard nightS.count > (edit == nil ? 1800 : 60),
                  let r = WhoopScores.analyzeNight(nightS, c, baseline: base, awake: awake, manual: edit) else { continue }
            var n = Night(date: date, r: r)
            n.manual = edit != nil
            n.phoneMin = Int((awake.reduce(0.0) { $0 + max(0, min($1.upperBound, r.wake) - max($1.lowerBound, r.onset)) } / 60).rounded())
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
            n.latencyMin = SleepHabits.latencyMin(onset: r.onset, awake: awake)
            n.weekDebtMin = SleepHabits.weekDebtMin((nights + [n]).map { (asleepMin: Double($0.r.asleepMin), needMin: $0.needMin) })
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
            let enoughHistory = personalBaseline || history.filter { $0.hrv != nil }.count >= c.recovery.minHistory
            n.recovery = n.metrics.hrv == nil || !enoughHistory ? nil : WhoopScores.recovery(n.metrics, history: history, c)
            n.recoveryNeedsNights = enoughHistory ? 0 : c.recovery.minHistory - history.filter { $0.hrv != nil }.count
            n.metrics.recovery = n.recovery.map(Double.init)
            n.metrics.asleepMin = Double(r.asleepMin)
            history.append(n.metrics)
            nights.append(n)
        }
        return (nights, days)
    }
}

/// Nachtwaarden per dag (Documenten/nights.json), zodat herstel en rust-HR met meer dan de
/// geladen ~7 nachten kunnen vergelijken. Houdt 90 dagen bij.
@MainActor
final class NightArchive {
    static let shared = NightArchive()
    private var byDay: [String: NightMetrics] = [:]
    private static var url: URL { Recorder.folder.appendingPathComponent("nights.json") }

    /// Rekenwijze van HRV/rust-HR; ophogen bij een wijziging zodat oude nachtwaarden de basislijn niet scheeftrekken.
    private static let hrvMethod = 2
    private static let hrvMethodKey = "nightArchive.hrvMethod"

    private init() {
        if let d = try? Data(contentsOf: Self.url), let v = try? JSONDecoder().decode([String: NightMetrics].self, from: d) { byDay = v }
        let ud = UserDefaults.standard
        if ud.integer(forKey: Self.hrvMethodKey) < Self.hrvMethod {
            // Oude nachten met de vorige HRV/rust-HR-berekening wissen; de basislijn bouwt zich opnieuw op
            // (de laatste 7 nachten worden bij elke verversing opnieuw uit de ruwe data berekend).
            for k in byDay.keys { byDay[k]?.hrv = nil; byDay[k]?.rhr = nil }
            if let d = try? JSONEncoder().encode(byDay) { try? d.write(to: Self.url, options: .atomic) }
            ud.set(Self.hrvMethod, forKey: Self.hrvMethodKey)
        }
    }

    /// Nachten vóór `key` (jjjj-mm-dd), oudste eerst, hooguit `limit`.
    func metrics(before key: String, limit: Int) -> [NightMetrics] {
        byDay.keys.filter { $0 < key }.sorted().suffix(limit).compactMap { byDay[$0] }
    }

    /// Alle bewaarde nachten (jjjj-mm-dd → waarden).
    var all: [String: NightMetrics] { byDay }

    func recentRhr(_ n: Int) -> [Double] {
        byDay.keys.sorted().suffix(n).compactMap { byDay[$0]?.rhr }
    }

    func store(_ items: [(String, NightMetrics)]) {
        guard !items.isEmpty else { return }
        for (k, m) in items { byDay[k] = m }
        let keys = byDay.keys.sorted()
        if keys.count > 90 { for k in keys.prefix(keys.count - 90) { byDay[k] = nil } }
        if let d = try? JSONEncoder().encode(byDay) { try? d.write(to: Self.url, options: .atomic) }
    }
}

/// Dagwaarden per kalenderdag (Documenten/days.json) voor het maandrapport. Houdt 100 dagen bij.
struct DayStats: Codable, Sendable {
    var strain: Double
    var steps: Int?
    var inactiveMin: Int?
}

@MainActor
final class DayArchive {
    static let shared = DayArchive()
    private var byDay: [String: DayStats] = [:]
    private static var url: URL { Recorder.folder.appendingPathComponent("days.json") }

    private init() {
        if let d = try? Data(contentsOf: Self.url), let v = try? JSONDecoder().decode([String: DayStats].self, from: d) { byDay = v }
    }

    var all: [String: DayStats] { byDay }

    func store(_ items: [(String, DayStats)]) {
        guard !items.isEmpty else { return }
        for (k, m) in items { byDay[k] = m }
        let keys = byDay.keys.sorted()
        if keys.count > 100 { for k in keys.prefix(keys.count - 100) { byDay[k] = nil } }
        if let d = try? JSONEncoder().encode(byDay) { try? d.write(to: Self.url, options: .atomic) }
    }
}

/// Handmatig aangepaste slaaptijden per ochtend (jjjj-mm-dd → begin/eind, Unix-seconden).
/// Opgeslagen op de telefoon (UserDefaults), niet in de repo.
enum SleepEdits {
    private static let key = "sleep.manualWindows"
    static var all: [String: Range<Double>] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        return raw.compactMapValues { $0.count == 2 && $0[0] < $0[1] ? $0[0]..<$0[1] : nil }
    }
    static func get(_ day: Date) -> Range<Double>? { all[DayStore.dayFmt.string(from: day)] }
    static func set(_ day: Date, _ window: Range<Double>?) {
        var raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        raw[DayStore.dayFmt.string(from: day)] = window.map { [$0.lowerBound, $0.upperBound] }
        UserDefaults.standard.set(raw, forKey: key)
    }
}
