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
        if a.isOngoing && a.gps == true { route.start(a.id) }
        Task { await self.enrich(a.id, store: store) }
    }

    func update(_ a: Activity, store: DayStore) {
        guard let i = items.firstIndex(where: { $0.id == a.id }) else { return }
        var a = a
        if a.start != items[i].start || a.end != items[i].end { a.summary = nil; a.steps = nil }
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
        Task { await self.enrich(id, store: store) }
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
        let raw: [Sample] = (0..<7).reversed().flatMap { k in
            store.samples(day: cal.date(byAdding: .day, value: -k, to: today)!).map(ScoreModel.convert)
        }
        let known = items.map { (start: $0.start.timeIntervalSince1970 - 120, end: $0.effectiveEnd.timeIntervalSince1970 + 120) }
        let exclude = sleep + known + dismissed.map { (start: $0.lowerBound, end: $0.upperBound) }
        let toSummarize = items.filter { !$0.isOngoing }.map { (id: $0.id, s: $0.start.timeIntervalSince1970, e: $0.effectiveEnd.timeIntervalSince1970) }
        let ongoing = items.filter(\.isOngoing).map { (id: $0.id, s: $0.start.timeIntervalSince1970, e: Date().timeIntervalSince1970) }
        let c = UserProfile.calibration()
        Task {
            let (found, sums) = await Task.detached(priority: .utility) { () -> ([DetectedActivity], [UUID: ActivitySummary]) in
                let found = WhoopScores.detectActivities(raw, c, exclude: exclude)
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
            for f in found {
                var a = Activity(type: .other, start: Date(timeIntervalSince1970: f.start), end: Date(timeIntervalSince1970: f.end), auto: true)
                a.summary = WhoopScores.activitySummary(raw, start: f.start, end: f.end, c)
                self.items.append(a); newIds.append(a.id)
            }
            self.save()
            self.busy = false
            for id in newIds { await self.enrich(id, store: store, guessType: true) }
            // Stappen ontbreken nog bij eerdere activiteiten (bv. toestemming net gegeven)
            for a in self.items where a.steps == nil && !a.isOngoing && a.start > Date().addingTimeInterval(-6.5 * 86400) {
                await self.enrich(a.id, store: store)
            }
        }
    }

    /// Statistieken, stappen (iPhone) en eventueel het type (iPhone-bewegingsherkenning) aanvullen.
    private func enrich(_ id: UUID, store: DayStore, guessType: Bool = false) async {
        guard let a = items.first(where: { $0.id == id }) else { return }
        let s = a.start, e = a.effectiveEnd
        if a.summary == nil || a.isOngoing {
            let raw = store.samples(day: s).map(ScoreModel.convert) +
                (Calendar.current.isDate(s, inSameDayAs: e) ? [] : store.samples(day: e).map(ScoreModel.convert))
            let sum = WhoopScores.activitySummary(raw, start: s.timeIntervalSince1970, end: e.timeIntervalSince1970, UserProfile.calibration())
            if sum.measuredSec > 0 { set(id) { $0.summary = sum } }
        }
        guard !a.isOngoing else { return }
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
