import Foundation
import SwiftUI
import UserNotifications
import WhoopScores
#if canImport(AlarmKit)
import AlarmKit
#endif

/// Slaapplanner en wekker. Rekent de planning voor vannacht uit (SleepPlanner in de scores-module),
/// zet de wekker op de iPhone en, als je dat aanzet, ook op de band.
///
/// Hoe de wekker afgaat:
/// - iPhone: met AlarmKit (iOS 26+) een echte wekker die ook in stille modus klinkt; anders een melding met geluid.
/// - Band (experimenteel): cmd 0x42, bekend van de Whoop 4.0. De band zelf trilt dan op de ingestelde tijd,
///   ook als de app slaapt. Of de 5.0 dit commando kent, laat het antwoord van de band zien.
/// - Slimme modi (slaapdoel, groen herstel): de app rekent in het laatste anderhalf uur elke 5 minuten
///   op de binnenkomende hartslag en laat de wekker eerder afgaan zodra het doel is gehaald.
@MainActor
final class SleepAlarm: ObservableObject {
    private static let scheduleKey = "alarm.schedule", goalKey = "alarm.goal", bandKey = "alarm.band",
                       armedKey = "alarm.armed", usualBedKey = "alarm.usualBed", usualWakeKey = "alarm.usualWake",
                       workStartKey = "alarm.workStart", bandSetKey = "alarm.bandSet"

    struct Armed: Codable, Equatable {
        var wake: Date
        var mode: AlarmMode
        var goalSleepMin: Double
        var fired = false
    }

    @Published var schedule: AlarmSchedule { didSet { saveSchedule(); rearm() } }
    @Published var goal: SleepGoal { didSet { d.set(goal.rawValue, forKey: Self.goalKey); rearm() } }
    @Published var bandHaptics: Bool { didSet { d.set(bandHaptics, forKey: Self.bandKey); bandChanged() } }
    /// Gebruikelijke bedtijd en opstaantijd (minuten na middernacht) zolang er te weinig nachten zijn.
    @Published var usualBed: Int { didSet { d.set(usualBed, forKey: Self.usualBedKey) } }
    @Published var usualWake: Int { didSet { d.set(usualWake, forKey: Self.usualWakeKey) } }
    /// Begintijd werk op werkdagen (minuten na middernacht), alleen ter controle van de wektijd.
    @Published var workStart: Int { didSet { d.set(workStart, forKey: Self.workStartKey) } }

    @Published private(set) var armed: Armed?
    @Published private(set) var phoneStatus: String?
    @Published private(set) var bandStatus: String?
    /// Tussenstand tijdens het slimme venster, bv. "Geslapen 6:40 van 7:10".
    @Published private(set) var progress: String?

    private let d = UserDefaults.standard
    private let ble: BLEManager, store: DayStore, scores: ScoreModel
    private var lastCheck = Date.distantPast
    private var estimating = false
    private var bandSentFor: Date?

    init(ble: BLEManager, store: DayStore, scores: ScoreModel) {
        self.ble = ble; self.store = store; self.scores = scores
        var s = (d.data(forKey: Self.scheduleKey)).flatMap { try? JSONDecoder().decode(AlarmSchedule.self, from: $0) } ?? .standard
        s.dropExpiredOverride(now: Date())
        schedule = s
        goal = d.string(forKey: Self.goalKey).flatMap(SleepGoal.init(rawValue:)) ?? .perform
        bandHaptics = d.bool(forKey: Self.bandKey)
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
        Task { await schedulePhone(at: a.wake, smart: false) }
        sendBandIfWanted()
    }

    private func disarm() {
        guard armed != nil || phoneStatus != nil else { return }
        armed = nil; saveArmed(); progress = nil
        cancelPhone()
        phoneStatus = nil
        parkBand()
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

    /// Wekker nu laten afgaan (slim doel gehaald).
    private func fire() {
        guard var a = armed else { return }
        a.fired = true; armed = a; saveArmed()
        let at = Date().addingTimeInterval(3)
        if bandHaptics, ble.state == .connected, ble.sendBandAlarm(at: at) == nil {
            bandSentFor = at
            d.set(true, forKey: Self.bandSetKey)
            bandStatus = "Slim wekken: band gevraagd te trillen om \(Self.clock(at, seconds: true))"
        }
        Task { await schedulePhone(at: at, smart: true) }
    }

    // MARK: iPhone

    private static let noteIDs = (0..<3).map { "alarm.wake.\($0)" }

    private func schedulePhone(at date: Date, smart: Bool) async {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            if await PhoneAlarm.schedule(at: date) {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Self.noteIDs)
                phoneStatus = smart ? "iPhone-wekker gaat nu af (doel gehaald)" : "iPhone-wekker staat op \(Self.clock(date))"
                return
            }
        }
        #endif
        await notify(at: date, smart: smart)
    }

    /// Zonder AlarmKit: drie meldingen met geluid, 2 minuten na elkaar. Een melding klinkt niet in stille modus
    /// en niet met een focus aan; daarom staat dat erbij.
    private func notify(at date: Date, smart: Bool) async {
        let center = UNUserNotificationCenter.current()
        let ok = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        center.removePendingNotificationRequests(withIdentifiers: Self.noteIDs)
        guard ok else { phoneStatus = "Geen toestemming voor meldingen: zet ze aan in iOS-instellingen."; return }
        for (i, id) in Self.noteIDs.enumerated() {
            let c = UNMutableNotificationContent()
            c.title = smart ? "Goedemorgen, doel gehaald" : "Tijd om op te staan"
            c.body = "Je wekker van \(Self.clock(armed?.wake ?? date))."
            c.sound = .default
            c.interruptionLevel = .timeSensitive
            let t = max(1, date.timeIntervalSinceNow + Double(i) * 120)
            try? await center.add(UNNotificationRequest(identifier: id, content: c,
                                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: t, repeats: false)))
        }
        phoneStatus = "Melding om \(Self.clock(date)) (geen echte wekker: klinkt niet in stille modus)"
    }

    private func cancelPhone() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Self.noteIDs)
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { PhoneAlarm.cancel() }
        #endif
    }

    /// true als de iPhone een echte wekker (AlarmKit) kan zetten.
    static var hasSystemAlarm: Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    // MARK: band (experimenteel)

    private func sendBandIfWanted() {
        guard bandHaptics, let a = armed, bandSentFor != a.wake else { return }
        guard ble.state == .connected else { bandStatus = "Band niet verbonden; wordt verstuurd zodra hij verbindt."; return }
        if let e = ble.sendBandAlarm(at: a.wake) { bandStatus = e; return }
        bandSentFor = a.wake
        d.set(true, forKey: Self.bandSetKey)
        bandStatus = "Wekker \(Self.clock(a.wake)) naar de band gestuurd, wacht op antwoord…"
    }

    /// Na (her)verbinden opnieuw versturen: de band kan een herstart of een Whoop-sync gehad hebben.
    func bandResend() {
        bandSentFor = nil
        if bandHaptics, armed != nil { sendBandIfWanted() }
    }

    func bandResult(_ code: UInt8) {
        switch code {
        case 1: bandStatus = "Band bevestigde het commando" + (bandSentFor.map { " (\(Self.clock($0, seconds: true)))" } ?? "") + "."
        case 3: bandStatus = "Band kent dit wekkercommando niet (niet ondersteund). De iPhone-wekker blijft werken."
        default: bandStatus = "Band weigerde het wekkercommando (code \(code))."
        }
    }

    private func bandChanged() {
        if bandHaptics { bandSentFor = nil; sendBandIfWanted() } else { parkBand(); bandStatus = nil }
    }

    /// Een wis-commando kennen we niet: zet de bandwekker een jaar vooruit.
    private func parkBand() {
        guard d.bool(forKey: Self.bandSetKey), ble.state == .connected else { return }
        let t = Date(timeIntervalSince1970: Double(SleepPlanner.bandAlarmParkedTime(now: Date())))
        if ble.sendBandAlarm(at: t) == nil { bandSentFor = nil; d.set(false, forKey: Self.bandSetKey) }
    }

    /// Test: laat de band over 30 seconden trillen.
    func testBand() {
        let at = Date().addingTimeInterval(30)
        if let e = ble.sendBandAlarm(at: at) { bandStatus = e; return }
        bandSentFor = at
        d.set(true, forKey: Self.bandSetKey)
        bandStatus = "Test verstuurd: de band zou om \(Self.clock(at, seconds: true)) moeten trillen."
    }

    // MARK: opslag en opmaak

    private func saveSchedule() {
        if let v = try? JSONEncoder().encode(schedule) { d.set(v, forKey: Self.scheduleKey) }
    }

    private func saveArmed() {
        if let a = armed, let v = try? JSONEncoder().encode(a) { d.set(v, forKey: Self.armedKey) }
        else { d.removeObject(forKey: Self.armedKey) }
    }

    static func clock(_ d: Date, seconds: Bool = false) -> String {
        let f = DateFormatter(); f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        return f.string(from: d)
    }
    static func clock(minutes m: Int) -> String {
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

#if canImport(AlarmKit)
/// Echte wekker via AlarmKit (iOS 26+): klinkt ook in stille modus en met een focus aan.
@available(iOS 26.0, *)
enum PhoneAlarm {
    struct Meta: AlarmMetadata {}
    private static let idKey = "alarm.kitID"

    static func authorized() async -> Bool {
        let m = AlarmManager.shared
        switch m.authorizationState {
        case .authorized: return true
        case .denied: return false
        default: return ((try? await m.requestAuthorization()) ?? .denied) == .authorized
        }
    }

    static func cancel() {
        if let s = UserDefaults.standard.string(forKey: idKey), let id = UUID(uuidString: s) {
            try? AlarmManager.shared.cancel(id: id)
        }
        UserDefaults.standard.removeObject(forKey: idKey)
    }

    @MainActor
    static func schedule(at date: Date) async -> Bool {
        guard await authorized() else { return false }
        cancel()
        let stop = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
        let alert = AlarmPresentation.Alert(title: "Tijd om op te staan", stopButton: stop)
        let attrs = AlarmAttributes<Meta>(presentation: AlarmPresentation(alert: alert), metadata: Meta(), tintColor: Theme.accent)
        let id = UUID()
        do {
            _ = try await AlarmManager.shared.schedule(id: id, configuration: .alarm(schedule: .fixed(date), attributes: attrs))
            UserDefaults.standard.set(id.uuidString, forKey: idKey)
            return true
        } catch {
            return false
        }
    }
}
#endif
