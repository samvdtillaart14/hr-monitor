import Foundation
import SwiftUI
import WhoopScores

/// Slaapplanner en wekker. Rekent de planning voor vannacht uit (SleepPlanner in de scores-module)
/// en zet de wekker op de band; er is geen wekker op de iPhone.
///
/// - Vaste tijd: de band krijgt de wektijd (cmd 66) en trilt zelf, ook als de app slaapt.
/// - Slimme modi (slaapdoel, groen herstel): de band krijgt de laatste tijd als vangnet; in het laatste
///   anderhalf uur rekent de app elke 5 minuten op de binnenkomende hartslag en laat de band direct trillen
///   (cmd 68) zodra het doel is gehaald.
/// - De vorm van cmd 66 op de Whoop 5.0 is niet zeker: de app probeert de vormen uit SleepPlanner.BandAlarm
///   op volgorde en onthoudt welke de band accepteert. Na elke ok leest hij de wekker terug (cmd 67).
@MainActor
final class SleepAlarm: ObservableObject {
    private static let scheduleKey = "alarm.schedule", goalKey = "alarm.goal",
                       armedKey = "alarm.armed", usualBedKey = "alarm.usualBed", usualWakeKey = "alarm.usualWake",
                       workStartKey = "alarm.workStart", variantKey = "alarm.bandVariant", bandSetKey = "alarm.bandSet"

    struct Armed: Codable, Equatable {
        var wake: Date
        var mode: AlarmMode
        var goalSleepMin: Double
        var fired = false
    }

    @Published var schedule: AlarmSchedule { didSet { saveSchedule(); rearm() } }
    @Published var goal: SleepGoal { didSet { d.set(goal.rawValue, forKey: Self.goalKey); rearm() } }
    /// Gebruikelijke bedtijd en opstaantijd (minuten na middernacht) zolang er te weinig nachten zijn.
    @Published var usualBed: Int { didSet { d.set(usualBed, forKey: Self.usualBedKey) } }
    @Published var usualWake: Int { didSet { d.set(usualWake, forKey: Self.usualWakeKey) } }
    /// Begintijd werk op werkdagen (minuten na middernacht), alleen ter controle van de wektijd.
    @Published var workStart: Int { didSet { d.set(workStart, forKey: Self.workStartKey) } }

    @Published private(set) var armed: Armed?
    @Published private(set) var bandStatus: String?
    /// Laatste antwoord van de band in bytes, voor het ontcijferen (alleen zichtbaar met ontwikkelaarsopties).
    @Published private(set) var bandRaw: String?
    /// Tussenstand tijdens het slimme venster, bv. "Geslapen 6:40 van 7:10".
    @Published private(set) var progress: String?

    private let d = UserDefaults.standard
    private let ble: BLEManager, store: DayStore, scores: ScoreModel
    private var lastCheck = Date.distantPast
    private var estimating = false
    /// Tijd die als laatste met SET naar de band ging (en de vorm), wacht op antwoord.
    private var pendingSet: (time: Date, variant: Int)?
    private var bandSentFor: Date?

    init(ble: BLEManager, store: DayStore, scores: ScoreModel) {
        self.ble = ble; self.store = store; self.scores = scores
        var s = (d.data(forKey: Self.scheduleKey)).flatMap { try? JSONDecoder().decode(AlarmSchedule.self, from: $0) } ?? .standard
        s.dropExpiredOverride(now: Date())
        schedule = s
        goal = d.string(forKey: Self.goalKey).flatMap(SleepGoal.init(rawValue:)) ?? .perform
        usualBed = d.object(forKey: Self.usualBedKey) as? Int ?? 23 * 60 + 30
        usualWake = d.object(forKey: Self.usualWakeKey) as? Int ?? 7 * 60 + 30
        workStart = d.object(forKey: Self.workStartKey) as? Int ?? 9 * 60
        armed = d.data(forKey: Self.armedKey).flatMap { try? JSONDecoder().decode(Armed.self, from: $0) }
    }

    // MARK: planning

    /// Planning voor de eerstvolgende nacht.
    func plan(now: Date = Date()) -> TonightPlan {
        let next = schedule.nextWake(after: now)
        let c = UserProfile.calibration()
        let cal = Calendar.current
        // De laatste afgeronde nacht (niet de nacht die misschien nog bezig is).
        let prev = scores.nights.last { $0.wake < now.addingTimeInterval(-3600) && now.timeIntervalSince($0.wake) < 36 * 3600 }
        // Belasting van de dag vóór de wektijd (om 02:00 telt gisteren nog).
        let strainDay = next.date.addingTimeInterval(-12 * 3600)
        let strain = scores.days.first { cal.isDate($0.date, inSameDayAs: strainDay) }?.strain ?? 0
        let naps = prev.map { n in
            n.r.naps.filter { $0.onset > n.r.wake && cal.isDate(Date(timeIntervalSince1970: $0.onset), inSameDayAs: strainDay) }
                .reduce(0) { $0 + Double($1.minutes) }
        } ?? 0
        let need = SleepPlanner.tonightNeed(prevDebtMin: prev?.debtMin, prevNeedMin: prev?.needMin,
                                            prevAsleepMin: prev.map { Double($0.r.asleepMin) },
                                            strainToday: strain, napMinToday: naps, c)
        let effs = scores.nights.suffix(7).map(\.r.efficiency).filter { $0.isFinite && $0 > 0 }
        let eff = effs.isEmpty ? nil : effs.reduce(0, +) / Double(effs.count)
        return SleepPlanner.plan(need: need.parts, debtMin: need.debtMin, goal: goal, wake: next.date, efficiency: eff)
    }

    var nextRule: AlarmRule { schedule.nextWake(after: Date()).rule }

    /// Gebruikelijk slaapvenster: uit de gemeten nachten, anders de ingestelde tijden.
    var usualWindow: (bed: Int, wake: Int, measured: Bool) {
        SleepPlanner.usualWindow(scores.nights.map { (onset: $0.r.onset, wake: $0.r.wake) },
                                 tzOffsetSec: TimeZone.current.secondsFromGMT(), fallback: (usualBed, usualWake))
    }

    /// Wekker alleen voor de eerstvolgende ochtend op een andere tijd/modus zetten.
    func setOverride(minutes: Int, mode: AlarmMode) {
        let wake = schedule.nextWake(after: Date())
        let key = DayStore.dayFmt.string(from: wake.date)
        let base = schedule.rule(for: wake.date)
        var s = schedule
        if base.minutes == minutes && base.mode == mode { s.override = nil }
        else { s.override = .init(day: key, rule: AlarmRule(minutes: minutes, mode: mode)) }
        schedule = s
    }

    // MARK: wekker zetten

    /// Zet de wekker voor de eerstvolgende ochtend (na elke wijziging, bij openen en na het afgaan).
    func rearm() {
        let now = Date()
        let next = schedule.nextWake(after: now)
        guard schedule.enabled, next.rule.enabled else { disarm(); return }
        let p = plan(now: now)
        let a = Armed(wake: next.date, mode: next.rule.mode, goalSleepMin: p.goalSleepMin)
        if a == armed { return }
        armed = a; saveArmed(); progress = nil
        sendBandIfNeeded()
    }

    private func disarm() {
        guard armed != nil else { return }
        armed = nil; saveArmed(); progress = nil
        if d.bool(forKey: Self.bandSetKey), ble.state == .connected,
           ble.sendBandAlarm(SleepPlanner.BandAlarm.disable, body: SleepPlanner.BandAlarm.simpleBody) == nil {
            bandSentFor = nil
            d.set(false, forKey: Self.bandSetKey)
            bandStatus = "Wekker op de band uitgezet."
        }
    }

    /// Aanroepen bij elke live hartslag (ook op de achtergrond). Goedkoop buiten het slimme venster.
    func tick() {
        guard let a = armed else { return }
        let now = Date()
        // Wektijd voorbij: de volgende ochtend instellen.
        if now > a.wake.addingTimeInterval(120) { armed = nil; rearm(); return }
        guard !a.fired, a.mode != .exact, !estimating,
              now >= a.wake.addingTimeInterval(-SleepPlanner.smartWindowMin * 60),
              now.timeIntervalSince(lastCheck) >= 300 else { return }
        lastCheck = now; estimating = true
        let samples = store.samples(day: now, includeNight: true)
        let c = UserProfile.calibration()
        let prior = NightArchive.shared.metrics(before: DayStore.dayFmt.string(from: now), limit: c.recovery.windowDays)
        let personal = UserProfile.importedCalibration != nil
        let goalMin = plan(now: now).goalSleepMin
        Task {
            let est = await Task.detached(priority: .utility) {
                Self.estimate(samples.map(ScoreModel.convert), c, prior: prior, needMin: goalMin, personal: personal)
            }.value
            estimating = false
            guard var cur = armed, cur.wake == a.wake, !cur.fired else { return }
            cur.goalSleepMin = goalMin
            if let s = est.asleep {
                progress = "Geslapen \(SleepPlanner.hm(s)) van \(SleepPlanner.hm(goalMin))"
                    + (est.recovery.map { " · herstel nu ~\($0)%" } ?? "")
            }
            armed = cur; saveArmed()
            if SleepPlanner.shouldWake(mode: cur.mode, now: Date(), latest: cur.wake, asleepMin: est.asleep,
                                       goalSleepMin: goalMin, recovery: est.recovery) {
                fire()
            }
        }
    }

    /// Slaap en herstel tot nu toe, uit de metingen sinds 18:00 gisteren.
    nonisolated static func estimate(_ s: [Sample], _ c: Calibration, prior: [NightMetrics], needMin: Double,
                                     personal: Bool) -> (asleep: Double?, recovery: Int?) {
        guard s.count > 1800,
              let r = WhoopScores.analyzeNight(s, c, baseline: WhoopScores.baseline(from: prior, c)) else { return (nil, nil) }
        func fin(_ v: Double) -> Double? { v.isFinite ? v : nil }
        let need = needMin > 0 ? needMin : c.sleep.needBaseMin
        let perf = WhoopScores.sleepPerformance(asleepMin: Double(r.asleepMin), needMin: need, efficiency: r.efficiency, consistency: nil, c)
        let m = NightMetrics(hrv: fin(r.hrv), rhr: fin(r.rhr), resp: fin(r.resp), sleepPerf: fin(perf), skinTemp: fin(r.skinTemp),
                             sufficiency: fin(WhoopScores.sleepSufficiency(asleepMin: Double(r.asleepMin), needMin: need)),
                             efficiency: fin(r.efficiency))
        let enough = personal || prior.filter { $0.hrv != nil }.count >= c.recovery.minHistory
        let rec = m.hrv == nil || !enough ? nil : WhoopScores.recovery(m, history: prior, c)
        return (Double(r.asleepMin), rec)
    }

    /// Slim doel gehaald: de band nu laten trillen.
    private func fire() {
        guard var a = armed else { return }
        a.fired = true; armed = a; saveArmed()
        if ble.state == .connected, ble.sendBandAlarm(SleepPlanner.BandAlarm.run, body: SleepPlanner.BandAlarm.simpleBody) == nil {
            bandStatus = "Doel gehaald: band gevraagd nu te trillen (\(Self.clock(Date(), seconds: true)))."
        } else {
            bandStatus = "Doel gehaald, maar de band is niet verbonden; de wekker gaat op de ingestelde tijd."
        }
    }

    // MARK: band

    private var variant: Int { d.integer(forKey: Self.variantKey) }

    private func sendSet(_ time: Date, variant v: Int) -> String? {
        let t = UInt32(max(0, min(Double(UInt32.max), time.timeIntervalSince1970)))
        let e = ble.sendBandAlarm(SleepPlanner.BandAlarm.set,
                                  body: SleepPlanner.BandAlarm.setBody(unix: t, variant: v, tzOffsetSec: TimeZone.current.secondsFromGMT(for: time)))
        if e == nil { pendingSet = (time, v) }
        return e
    }

    private func sendBandIfNeeded() {
        guard let a = armed, bandSentFor != a.wake else { return }
        guard ble.state == .connected else { bandStatus = "Band niet verbonden; de wekker wordt verstuurd zodra hij verbindt."; return }
        if let e = sendSet(a.wake, variant: variant) { bandStatus = e; return }
        bandSentFor = a.wake
        bandStatus = "Wekker \(Self.clock(a.wake)) naar de band gestuurd, wacht op antwoord…"
    }

    /// Na (her)verbinden opnieuw versturen: de band kan een herstart of een Whoop-sync gehad hebben.
    func bandResend() {
        bandSentFor = nil
        if armed != nil { sendBandIfNeeded() }
    }

    func bandResponse(cmd: UInt8, result: UInt8, body: [UInt8]) {
        bandRaw = "cmd \(cmd) → \(result) · " + body.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
        switch cmd {
        case SleepPlanner.BandAlarm.set:
            guard let p = pendingSet else { return }
            if result == 1 {
                pendingSet = nil
                d.set(p.variant, forKey: Self.variantKey)
                d.set(true, forKey: Self.bandSetKey)
                bandStatus = "Band accepteerde de wekker (\(Self.clock(p.time, seconds: true))), vorm \(p.variant)."
                _ = ble.sendBandAlarm(SleepPlanner.BandAlarm.get, body: SleepPlanner.BandAlarm.simpleBody)
            } else if p.variant + 1 < SleepPlanner.BandAlarm.variantCount {
                // Geweigerd of onbekend: volgende vorm proberen.
                _ = sendSet(p.time, variant: p.variant + 1)
                bandStatus = "Vorm \(p.variant) geweigerd, vorm \(p.variant + 1) wordt geprobeerd…"
            } else {
                pendingSet = nil
                d.set(0, forKey: Self.variantKey)
                bandStatus = "De band weigerde alle bekende vormen van het wekkercommando. Deel de bandgegevens, dan zoek ik de juiste vorm."
                _ = ble.sendBandAlarm(SleepPlanner.BandAlarm.get, body: SleepPlanner.BandAlarm.simpleBody)
            }
        case SleepPlanner.BandAlarm.get:
            if let t = SleepPlanner.BandAlarm.parseGet(body) {
                let date = Date(timeIntervalSince1970: Double(t))
                bandStatus = (bandStatus.map { $0 + " " } ?? "") + "Band meldt wekker: \(date.formatted(date: .abbreviated, time: .standard))."
            }
        case SleepPlanner.BandAlarm.run:
            if result != 1 { bandStatus = "Band weigerde direct trillen (code \(result)); de wekker gaat op de ingestelde tijd." }
        default:
            break
        }
    }

    /// Test: laat de band over 30 seconden trillen (probeert zo nodig alle vormen).
    func testBand() {
        let at = Date().addingTimeInterval(30)
        if let e = sendSet(at, variant: variant) { bandStatus = e; return }
        bandSentFor = nil
        // Daarna de echte wekker terugzetten (de band onthoudt maar één wekker).
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.bandResend() }
        bandStatus = "Test verstuurd (vorm \(variant)): de band zou om \(Self.clock(at, seconds: true)) moeten trillen."
    }

    // MARK: opslag en opmaak

    private func saveSchedule() {
        if let v = try? JSONEncoder().encode(schedule) { d.set(v, forKey: Self.scheduleKey) }
    }

    private func saveArmed() {
        if let a = armed, let v = try? JSONEncoder().encode(a) { d.set(v, forKey: Self.armedKey) }
        else { d.removeObject(forKey: Self.armedKey) }
    }

    nonisolated static func clock(_ d: Date, seconds: Bool = false) -> String {
        let f = DateFormatter(); f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        return f.string(from: d)
    }
    nonisolated static func clock(minutes m: Int) -> String {
        let x = ((m % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", x / 60, x % 60)
    }
}

extension AlarmMode {
    var title: String {
        switch self { case .exact: return "Vaste tijd"; case .sleepGoal: return "Slaapdoel"; case .recovered: return "Groen herstel" }
    }
    var explanation: String {
        switch self {
        case .exact: return "Precies op de ingestelde tijd."
        case .sleepGoal: return "Eerder, zodra je je slaapdoel hebt gehaald (hooguit 1,5 uur eerder)."
        case .recovered: return "Eerder, zodra je herstel groen is (≥ 67 %, hooguit 1,5 uur eerder)."
        }
    }
    var icon: String {
        switch self { case .exact: return "alarm"; case .sleepGoal: return "bed.double"; case .recovered: return "leaf" }
    }
}

extension SleepGoal {
    var title: String {
        switch self { case .full: return "Volledig uitrusten"; case .perform: return "Goed presteren"; case .minimum: return "Erdoorheen komen" }
    }
    var short: String {
        switch self { case .full: return "Volledig"; case .perform: return "Presteren"; case .minimum: return "Minimaal" }
    }
}
