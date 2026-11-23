import Foundation
import CoreMotion
import WhoopScores

enum ActivityType: String, Codable, CaseIterable, Identifiable {
    case running, tennis, padel, cycling, walking, strength, football, hiit, other
    var id: String { rawValue }
    /// buitenactiviteit: standaard GPS-route opnemen
    var outdoor: Bool { [.running, .cycling, .walking].contains(self) }
    var name: String {
        switch self {
        case .running: "Hardlopen"; case .tennis: "Tennis"; case .padel: "Padel"; case .cycling: "Fietsen"
        case .walking: "Wandelen"; case .strength: "Krachttraining"; case .football: "Voetbal"; case .hiit: "HIIT"
        case .other: "Activiteit"
        }
    }
    var icon: String {
        switch self {
        case .running: "figure.run"; case .tennis: "figure.tennis"; case .padel: "figure.racquetball"
        case .cycling: "figure.outdoor.cycle"; case .walking: "figure.walk"; case .strength: "figure.strengthtraining.traditional"
        case .football: "figure.soccer"; case .hiit: "figure.highintensity.intervaltraining"; case .other: "figure.mixed.cardio"
        }
    }
}

struct Activity: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: ActivityType
    var start: Date
    /// nil = loopt nog (handmatig gestart)
    var end: Date?
    /// automatisch herkend op hartslag
    var auto = false
    var summary: ActivitySummary?
    var steps: Int?
    /// GPS-route opnemen (alleen bij "Nu starten")
    var gps: Bool?
    /// afstand uit de GPS-route (m)
    var distanceM: Double?

    var effectiveEnd: Date { end ?? Date() }
    var duration: TimeInterval { effectiveEnd.timeIntervalSince(start) }
    var isOngoing: Bool { end == nil }
}

/// Activiteiten: handmatig toegevoegd of automatisch herkend op hartslag. Opslag in Documenten/activities.json.
@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var items: [Activity] = []
    /// verwijderde automatische activiteiten: niet opnieuw herkennen
    private var dismissed: [ClosedRange<Double>] = []
    private var busy = false
    private var stepsTried = Set<UUID>()
    private let pedometer = CMPedometer()
    private let motion = CMMotionActivityManager()
    let route: RouteRecorder

    private struct File: Codable { var items: [Activity]; var dismissed: [[Double]] }
    nonisolated static var url: URL { Recorder.folder.appendingPathComponent("activities.json") }

    init() {
        route = RouteRecorder()
        if let d = try? Data(contentsOf: Self.url), let f = try? JSONDecoder().decode(File.self, from: d) {
            items = f.items.sorted { $0.start < $1.start }
            dismissed = f.dismissed.compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
        }
        // App herstart tijdens een activiteit met GPS: opname hervatten.
        if let o = ongoing, o.gps == true { route.start(o.id) }
        pending = (UserDefaults.standard.array(forKey: Self.pendingKey) as? [[String]] ?? []).compactMap { r in
            guard r.count == 3, let id = UUID(uuidString: r[0]), let s = Double(r[1]), let e = Double(r[2]) else { return nil }
            return (id, s, e)
        }
        // App afgesloten tijdens een automatische GPS-opname: die opname alsnog laten koppelen.
        if let r = UserDefaults.standard.array(forKey: Self.autoSessionKey) as? [String], r.count == 2,
           let id = UUID(uuidString: r[0]), let st = Double(r[1]) {
            let end = Route.load(id).last?.t ?? st
            pending.append((id, st, max(st, end)))
            UserDefaults.standard.removeObject(forKey: Self.autoSessionKey)
            savePending()
        }
        autoGps = UserDefaults.standard.bool(forKey: Self.autoGpsKey)
        if autoGps { startMotion(); route.requestAlways() }
    }

    private func save() {
        items.sort { $0.start < $1.start }
        let f = File(items: items, dismissed: dismissed.map { [$0.lowerBound, $0.upperBound] })
        if let d = try? JSONEncoder().encode(f) { try? d.write(to: Self.url, options: .atomic) }
    }

    var ongoing: Activity? { items.first { $0.isOngoing } }

    func on(day: Date) -> [Activity] {
        items.filter { Calendar.current.isDate($0.start, inSameDayAs: day) || ($0.isOngoing && Calendar.current.isDateInToday(day)) }
    }

    /// Vorige activiteiten van hetzelfde type in de 30 dagen ervoor (voor de vergelijking).
    func previous(_ a: Activity) -> [Activity] {
        let from = a.start.addingTimeInterval(-30 * 86400)
        return items.filter { $0.id != a.id && $0.type == a.type && $0.start < a.start && $0.start >= from && $0.summary != nil && !$0.isOngoing }
    }

    // MARK: wijzigen

    func add(_ a: Activity, store: DayStore) {
        items.append(a); save()
        if a.isOngoing && a.gps == true {
            if autoSession != nil { stopAuto() }
            route.start(a.id)
        }
        Task { await self.enrich(a.id, store: store) }
    }

    func update(_ a: Activity, store: DayStore) {
        guard let i = items.firstIndex(where: { $0.id == a.id }) else { return }
        var a = a
        let old = items[i]
        if a.start != old.start || a.end != old.end {
            a.summary = nil; a.steps = nil
            // Herkende activiteit ingekort: het oude stuk niet opnieuw als nieuwe activiteit herkennen.
            if old.auto { dismissed.append(old.start.timeIntervalSince1970...old.effectiveEnd.timeIntervalSince1970) }
        }
        items[i] = a; save()
        Task { await self.enrich(a.id, store: store) }
    }

    func stop(_ id: UUID, store: DayStore) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].end = Date()
        if route.activityId == id {
            route.stop()
            let pts = Route.load(id)
            if pts.count > 1 { items[i].distanceM = Route.distance(pts) }
        }
        save()
        Task { await self.enrich(id, store: store, forceSummary: true) }
    }

    func delete(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let a = items.remove(at: i)
        if route.activityId == id { route.stop() }
        Route.delete(id)
        if a.auto { dismissed.append(a.start.timeIntervalSince1970...a.effectiveEnd.timeIntervalSince1970) }
        save()
    }

    // MARK: herkennen en berekenen

    /// Herkent nieuwe activiteiten in de geladen dagen en werkt de statistieken bij.
    /// `sleep`: slaapperioden (die tellen nooit als activiteit).
    func refresh(store: DayStore, sleep: [(start: Double, end: Double)]) {
        guard !busy else { return }
        busy = true
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        let rawStore: [DayStore.Sample] = (0..<7).reversed().flatMap { k in
            store.samples(day: cal.date(byAdding: .day, value: -k, to: today)!)
        }
        let known = items.map { (start: $0.start.timeIntervalSince1970 - 120, end: $0.effectiveEnd.timeIntervalSince1970 + 120) }
        let exclude = sleep + known + dismissed.map { (start: $0.lowerBound, end: $0.upperBound) }
        let toSummarize = items.filter { !$0.isOngoing }.map { (id: $0.id, s: $0.start.timeIntervalSince1970, e: $0.effectiveEnd.timeIntervalSince1970) }
        let ongoing = items.filter(\.isOngoing).map { (id: $0.id, s: $0.start.timeIntervalSince1970, e: Date().timeIntervalSince1970) }
        let c = UserProfile.calibration()
        Task {
            let (found, sums) = await Task.detached(priority: .utility) { () -> ([(DetectedActivity, ActivitySummary)], [UUID: ActivitySummary]) in
                let raw = rawStore.map(ScoreModel.convert)
                let found = WhoopScores.detectActivities(raw, c, exclude: exclude).map {
                    ($0, WhoopScores.activitySummary(raw, start: $0.start, end: $0.end, c))
                }
                var sums: [UUID: ActivitySummary] = [:]
                for x in toSummarize + ongoing {
                    let s = WhoopScores.activitySummary(raw, start: x.s, end: x.e, c)
                    if s.measuredSec > 0 { sums[x.id] = s }
                }
                return (found, sums)
            }.value
            for i in self.items.indices {
                // Alleen bijwerken als er nu minstens zoveel data is als eerder (oude dagen zijn niet meer geladen).
                if let s = sums[self.items[i].id], s.measuredSec >= (self.items[i].summary?.measuredSec ?? 0) {
                    self.items[i].summary = s
                }
            }
            var newIds: [UUID] = []
            for (f, sum) in found {
                var a = Activity(type: .other, start: Date(timeIntervalSince1970: f.start), end: Date(timeIntervalSince1970: f.end), auto: true)
                self.attachRoute(&a)
                a.summary = sum
                self.items.append(a); newIds.append(a.id)
            }
            self.prunePending()
            self.save()
            self.busy = false
            for id in newIds { await self.enrich(id, store: store, guessType: true) }
            // Stappen ontbreken nog bij eerdere activiteiten (bv. toestemming net gegeven)
            // (één poging per activiteit per app-start, anders elke 30 s opnieuw zonder toestemming)
            for a in self.items where a.steps == nil && !a.isOngoing && !self.stepsTried.contains(a.id)
                && a.start > Date().addingTimeInterval(-6.5 * 86400) {
                await self.enrich(a.id, store: store)
            }
        }
    }

    /// Statistieken, stappen (iPhone) en eventueel het type (iPhone-bewegingsherkenning) aanvullen.
    private func enrich(_ id: UUID, store: DayStore, guessType: Bool = false, forceSummary: Bool = false) async {
        guard let a = items.first(where: { $0.id == id }) else { return }
        let s = a.start, e = a.effectiveEnd
        if a.summary == nil || a.isOngoing || forceSummary {
            let raw = store.samples(day: s).map(ScoreModel.convert) +
                (Calendar.current.isDate(s, inSameDayAs: e) ? [] : store.samples(day: e).map(ScoreModel.convert))
            let sum = WhoopScores.activitySummary(raw, start: s.timeIntervalSince1970, end: e.timeIntervalSince1970, UserProfile.calibration())
            if sum.measuredSec > 0 { set(id) { $0.summary = sum } }
        }
        guard !a.isOngoing else { return }
        stepsTried.insert(id)
        if let steps = await Self.steps(pedometer, s, e) { set(id) { $0.steps = steps } }
        if guessType, let t = await Self.guessType(motion, s, e, steps: items.first { $0.id == id }?.steps) {
            set(id) { if $0.type == .other { $0.type = t } }
        }
        save()
    }

    private func set(_ id: UUID, _ f: (inout Activity) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        f(&items[i])
    }

    // MARK: automatisch GPS tijdens een activiteit

    static let autoGpsKey = "activity.autoGps"
    private static let pendingKey = "activity.autoRoutes"
    private static let autoSessionKey = "activity.autoSession"
    /// controleert elke 30 s of een automatische opname moet stoppen (ook zonder hartslag of bewegingsmelding)
    private var autoTimer: Timer?
    /// GPS automatisch aanzetten zodra je hartslag verhoogd is of de iPhone hardlopen/fietsen ziet.
    @Published var autoGps = false {
        didSet {
            guard autoGps != oldValue else { return }
            UserDefaults.standard.set(autoGps, forKey: Self.autoGpsKey)
            if autoGps { route.requestAlways(); startMotion() } else { motion.stopActivityUpdates(); if autoSession != nil { stopAuto() } }
        }
    }
    /// lopende automatische GPS-opname (nog niet aan een activiteit gekoppeld)
    @Published private(set) var autoSession: (id: UUID, start: Double)?
    /// afgeronde automatische opnamen die nog aan een herkende activiteit gekoppeld moeten worden
    private var pending: [(id: UUID, start: Double, end: Double)] = []
    private var liveHr: [(t: Double, hr: Double)] = []
    private var lastActive = 0.0
    private var moving = false

    /// Live hartslag (per seconde). Start GPS na 2 min verhoogde hartslag, stopt na 5 min rust.
    func live(hr: Int) {
        guard autoGps else { return }
        let now = Date().timeIntervalSince1970
        liveHr.append((now, Double(hr)))
        liveHr.removeAll { $0.t < now - 120 }
        let p = UserProfile.current
        let v = liveHr.map(\.hr).sorted()
        let active = v.count >= 60 && (v[v.count / 2] - p.restingHr) / max(1, p.maxHr - p.restingHr) >= ActivityDetectionParams().activeReserve
        tick(now, active: active)
    }

    private func tick(_ now: Double, active: Bool) {
        if active || moving { lastActive = now }
        if autoSession == nil {
            if (active || moving) && ongoing == nil && route.activityId == nil { startAuto(now) }
        } else if now - lastActive > 300 {
            stopAuto()
        }
    }

    private func startMotion() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motion.startActivityUpdates(to: .main) { [weak self] a in
            guard let self, let a else { return }
            MainActor.assumeIsolated {
                self.moving = (a.running || a.cycling) && a.confidence != .low
                if self.autoGps { self.tick(Date().timeIntervalSince1970, active: false) }
            }
        }
    }

    private func startAuto(_ now: Double) {
        let id = UUID()
        autoSession = (id, now)
        UserDefaults.standard.set([id.uuidString, String(now)], forKey: Self.autoSessionKey)
        route.start(id)
        autoTimer?.invalidate()
        autoTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(Date().timeIntervalSince1970, active: false) }
        }
    }

    private func stopAuto() {
        guard let s = autoSession else { return }
        autoTimer?.invalidate(); autoTimer = nil
        if route.activityId == s.id { route.stop() }
        pending.append((s.id, s.start, Date().timeIntervalSince1970))
        autoSession = nil
        UserDefaults.standard.removeObject(forKey: Self.autoSessionKey)
        savePending()
        // Activiteit al herkend terwijl de opname nog liep: volledige route alsnog koppelen.
        for i in items.indices where items[i].auto && !items[i].isOngoing {
            let a = items[i]
            guard a.start.timeIntervalSince1970 < Date().timeIntervalSince1970, a.effectiveEnd.timeIntervalSince1970 > s.start else { continue }
            var b = a; attachRoute(&b); items[i] = b
        }
        save()
    }

    /// Koppelt een automatische GPS-opname aan een herkende activiteit (route ingekort tot de activiteit).
    private func attachRoute(_ a: inout Activity) {
        let s = a.start.timeIntervalSince1970, e = a.effectiveEnd.timeIntervalSince1970
        var pts: [RoutePoint] = []
        for p in pending where p.start < e && p.end > s { pts += Route.load(p.id) }
        // ook een opname die nog loopt (activiteit herkend terwijl je nog bezig bent)
        if let cur = autoSession, cur.start < e, route.activityId == cur.id { pts += route.points }
        pts = pts.filter { $0.t >= s - 60 && $0.t <= e + 60 }.sorted { $0.t < $1.t }
        guard pts.count > 1 else { return }
        Route.save(pts, a.id)
        a.gps = true
        a.distanceM = Route.distance(pts)
        // Snel en weinig stappen: waarschijnlijk fietsen (het type kan daarna nog door de iPhone worden bepaald)
        // Snelheid over de tijd dat de GPS liep (die start later dan de herkende activiteit, bv. na de aanloop).
        let kmh = a.distanceM! / max(1, min(e, pts[pts.count - 1].t) - max(s, pts[0].t)) * 3.6
        if a.type == .other { if kmh > 16 { a.type = .cycling } else if kmh > 7.5 { a.type = .running } }
    }

    /// Opnamen ouder dan een dag zonder herkende activiteit weggooien.
    private func prunePending() {
        let cutoff = Date().timeIntervalSince1970 - 86400
        for p in pending where p.end < cutoff { Route.delete(p.id) }
        pending.removeAll { $0.end < cutoff }
        savePending()
        // Losse routebestanden (bv. van een opname die werd afgebroken) opruimen.
        var keep = Set(items.map(\.id.uuidString) + pending.map(\.id.uuidString))
        if let id = route.activityId { keep.insert(id.uuidString) }
        if let s = autoSession { keep.insert(s.id.uuidString) }
        let files = (try? FileManager.default.contentsOfDirectory(at: Route.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where f.pathExtension == "json" && !keep.contains(f.deletingPathExtension().lastPathComponent) {
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if m.timeIntervalSince1970 < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }

    private func savePending() {
        UserDefaults.standard.set(pending.map { [$0.id.uuidString, String($0.start), String($0.end)] }, forKey: Self.pendingKey)
    }

    // MARK: iPhone-beweging (CoreMotion, laatste 7 dagen)

    nonisolated static func steps(_ p: CMPedometer, _ s: Date, _ e: Date) async -> Int? {
        guard CMPedometer.isStepCountingAvailable(), s > Date().addingTimeInterval(-7 * 86400 + 60) else { return nil }
        return await withCheckedContinuation { c in
            p.queryPedometerData(from: s, to: e) { d, _ in c.resume(returning: d.map { $0.numberOfSteps.intValue }) }
        }
    }

    /// Type uit de bewegingsherkenning van de iPhone; alleen als de telefoon is meegedragen.
    nonisolated static func guessType(_ m: CMMotionActivityManager, _ s: Date, _ e: Date, steps: Int?) async -> ActivityType? {
        let dur = e.timeIntervalSince(s)
        if let steps, dur > 0, Double(steps) / (dur / 60) >= 140 { return .running }
        guard CMMotionActivityManager.isActivityAvailable() else { return nil }
        let acts: [CMMotionActivity] = await withCheckedContinuation { c in
            m.queryActivityStarting(from: s, to: e, to: .main) { a, _ in c.resume(returning: a ?? []) }
        }
        var t: [String: Double] = [:]
        for (i, a) in acts.enumerated() where a.confidence != .low {
            let from = max(a.startDate, s), to = i + 1 < acts.count ? min(acts[i + 1].startDate, e) : e
            let d = max(0, to.timeIntervalSince(from))
            if a.running { t["run", default: 0] += d } else if a.cycling { t["bike", default: 0] += d }
            else if a.walking { t["walk", default: 0] += d }
        }
        if t["run", default: 0] > dur * 0.4 { return .running }
        if t["bike", default: 0] > dur * 0.5 { return .cycling }
        if t["walk", default: 0] > dur * 0.6 { return .walking }
        return nil
    }
}
