import SwiftUI
import UserNotifications
import WhoopScores

// MARK: instellingen

enum InsightSettings {
    static let journalKey = "insights.journal"
    static let weeklyKey = "insights.weekly", illnessKey = "insights.illness"
    static let lastWeeklyKey = "insights.lastWeekly", lastIllnessKey = "insights.lastIllness"
    static let abnormalKey = "insights.abnormal", lastAbnormalKey = "insights.lastAbnormal"
    static let monthlyKey = "insights.monthly", lastMonthlyKey = "insights.lastMonthly"
    static func on(_ k: String) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? true }
}

/// Opent een scherm na een tik op een melding.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    enum Sheet: String, Identifiable { case journal, week, month; var id: String { rawValue } }
    @Published var sheet: Sheet?
    /// Samenvatting van een net afgelopen activiteit.
    struct ActivityRef: Identifiable { let id: UUID }
    @Published var activity: ActivityRef?
    /// Geselecteerde tab (een tik op een melding springt naar het juiste tabblad).
    enum Tab: Hashable { case today, live, health }
    @Published var tab: Tab = .today
}

// MARK: dagboek

/// Dagboek per avond (Documenten/journal.json): jjjj-mm-dd → aangetikte factoren.
@MainActor
final class Journal: ObservableObject {
    static let shared = Journal()
    static let defaultTags = ["Alcohol", "Laat gegeten", "Sport", "Laat scherm", "Cafeïne na 14:00", "Stress"]
    private static let customKey = "journal.customTags"
    @Published private(set) var entries: [String: Set<String>] = [:]
    @Published var customTags: [String] = UserDefaults.standard.stringArray(forKey: Journal.customKey) ?? [] {
        didSet { UserDefaults.standard.set(customTags, forKey: Self.customKey) }
    }
    var tags: [String] { Self.defaultTags + customTags }
    private static var url: URL { Recorder.folder.appendingPathComponent("journal.json") }

    private init() {
        if let d = try? Data(contentsOf: Self.url), let v = try? JSONDecoder().decode([String: [String]].self, from: d) {
            entries = v.mapValues(Set.init)
        }
    }

    /// Dag van het dagboek. Je vult 's ochtends in over gisteren: vóór 14:00 hoort bij de dag ervoor.
    nonisolated static func key(_ d: Date = Date()) -> String { DayStore.dayFmt.string(from: d.addingTimeInterval(-14 * 3600)) }
    /// "gisteren" of "vandaag", voor teksten.
    nonisolated static func dayWord(_ d: Date = Date()) -> String {
        key(d) == DayStore.dayFmt.string(from: d) ? "vandaag" : "gisteren"
    }

    func toggle(_ tag: String, day: String = Journal.key()) {
        var s = entries[day] ?? []
        if s.contains(tag) { s.remove(tag) } else { s.insert(tag) }
        entries[day] = s
        save()
    }
    /// Dag vastleggen zonder factoren ("niets bijzonders"), zodat hij als vergelijking meetelt.
    func markEmpty(day: String = Journal.key()) { if entries[day] == nil { entries[day] = []; save() } }

    private func save() {
        if let d = try? JSONEncoder().encode(entries.mapValues { Array($0).sorted() }) { try? d.write(to: Self.url, options: .atomic) }
    }

    func effects() -> [Insights.Effect] {
        Insights.effects(entries: entries, nights: NightArchive.shared.all, tags: tags) { k in
            guard let d = DayStore.dayFmt.date(from: k) else { return k }
            return DayStore.dayFmt.string(from: Calendar.current.date(byAdding: .day, value: 1, to: d) ?? d)
        }
    }
}

struct JournalView: View {
    @ObservedObject private var j = Journal.shared
    @State private var newTag = ""
    @Environment(\.dismiss) private var dismiss
    private let day = Journal.key()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(j.tags, id: \.self) { t in
                        Button { j.toggle(t, day: day) } label: {
                            HStack {
                                Text(t).foregroundStyle(Theme.text)
                                Spacer()
                                if j.entries[day]?.contains(t) == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                                else { Image(systemName: "circle").foregroundStyle(Theme.muted) }
                            }
                        }
                    }
                    HStack {
                        TextField("Eigen factor toevoegen", text: $newTag)
                        Button("Voeg toe") {
                            let t = newTag.trimmingCharacters(in: .whitespaces)
                            if !t.isEmpty && !j.tags.contains(t) { j.customTags.append(t) }
                            newTag = ""
                        }.disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: { Text("Vandaag") } footer: {
                    Text("Tik aan wat \(Journal.dayWord()) gold. Niets aangetikt telt ook: dat is je vergelijking.")
                }
                Section {
                    let e = j.effects()
                    if e.isEmpty {
                        Text("Na minstens 5 avonden mét en 5 zónder een factor (met een gemeten nacht erna) zie je hier het effect.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                    ForEach(e, id: \.tag) { EffectRow(e: $0) }
                } header: { Text("Wat beïnvloedt je herstel") } footer: {
                    Text("Verschil in de nacht erna, mét vergeleken met zónder. Een verband, geen bewijs: dagen met sport hebben vaak ook andere verschillen.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(Journal.dayWord() == "gisteren" ? "Hoe was gisteren?" : "Dagboek")
            .toolbar { Button("Klaar") { j.markEmpty(day: day); dismiss() } }
        }
    }
}

private struct EffectRow: View {
    let e: Insights.Effect
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(e.tag).font(.headline)
            HStack(spacing: 12) {
                part("Herstel", e.recovery, "%", higherIsBetter: true)
                part("HRV", e.hrv, " ms", higherIsBetter: true)
                part("Rust-HR", e.rhr, "", higherIsBetter: false)
            }.font(.subheadline)
            Text("\(e.withCount)× mét, \(e.withoutCount)× zonder").font(.caption).foregroundStyle(Theme.muted)
        }
    }
    @ViewBuilder private func part(_ t: String, _ v: Double?, _ unit: String, higherIsBetter: Bool) -> some View {
        if let v {
            let good = higherIsBetter ? v >= 0 : v <= 0
            Text("\(t) \(String(format: "%+.0f", v))\(unit)").foregroundStyle(abs(v) < 1 ? Theme.muted : good ? Theme.accent : Theme.hr)
        }
    }
}

// MARK: weekrapport

enum WeekReport {
    /// Nachten van de laatste 7 dagen t/m `end` en de 7 dagen daarvoor.
    @MainActor static func weeks(end: Date = Date()) -> (this: [NightMetrics], prev: [NightMetrics]) {
        let all = NightArchive.shared.all
        let cal = Calendar.current
        func range(_ from: Int, _ to: Int) -> [NightMetrics] {
            (from..<to).compactMap { i in
                cal.date(byAdding: .day, value: -i, to: end).flatMap { all[DayStore.dayFmt.string(from: $0)] }
            }
        }
        return (range(0, 7), range(7, 14))
    }
}

struct WeekReportView: View {
    var body: some View {
        let w = WeekReport.weeks()
        let a = Insights.summary(w.this), b = Insights.summary(w.prev)
        let adv = Insights.advice(this: a, prev: b)
        ScrollView {
            VStack(spacing: Theme.gap) {
                Card(title: "Advies voor komende week") { Text(adv.text).font(.body) }
                Card(title: String(format: L("Afgelopen 7 dagen · %d nachten"), a.nights)) {
                    row("Herstel", a.recovery, b.recovery, "%.0f%%", higherIsBetter: true)
                    row("Slaap", a.sleepMin, b.sleepMin, nil, higherIsBetter: true)
                    row("Slaapprestatie", a.sleepPerf, b.sleepPerf, "%.0f%%", higherIsBetter: true)
                    row("HRV", a.hrv, b.hrv, "%.0f ms", higherIsBetter: true)
                    row("Rust-HR", a.rhr, b.rhr, "%.0f bpm", higherIsBetter: false)
                    row("Regelmaat", a.consistency, b.consistency, "%.0f%%", higherIsBetter: true)
                }
                Text("Vergeleken met de 7 dagen daarvoor. Alleen nachten die Pulse heeft gemeten.").font(.caption).foregroundStyle(Theme.muted)
            }.padding()
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Weekrapport")
    }

    private func fmt(_ v: Double?, _ f: String?) -> String {
        guard let v else { return "--" }
        guard let f else { return DV.hm(v) }
        return String(format: f, v)
    }

    @ViewBuilder private func row(_ t: String, _ a: Double?, _ b: Double?, _ f: String?, higherIsBetter: Bool) -> some View {
        HStack {
            Text(t)
            Spacer()
            Text(fmt(a, f)).monospacedDigit()
            if let a, let b {
                let d = a - b
                let good = higherIsBetter ? d >= 0 : d <= 0
                Image(systemName: d >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .foregroundStyle(abs(d) < 0.5 ? Theme.muted : good ? Theme.accent : Theme.hr)
            }
        }.font(.subheadline)
    }
}

/// Sheet met NavigationStack voor het weekrapport vanuit een melding.
struct WeekReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack { WeekReportView().toolbar { Button("Klaar") { dismiss() } } }
    }
}

// MARK: maandrapport

enum MonthReport {
    struct Summary {
        var nights = 0, days = 0
        var week = Insights.WeekSummary()
        var strain: Double?, steps: Double?, inactiveMin: Double?, vo2: Double?, resp: Double?, skin: Double?
    }

    /// Maand `offset` terug t.o.v. `now` (1 = vorige maand): eerste dag van die maand.
    static func monthStart(_ offset: Int, now: Date = Date()) -> Date {
        let cal = Calendar.current
        let first = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        return cal.date(byAdding: .month, value: -offset, to: first) ?? first
    }

    static func name(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = DV.nl; f.dateFormat = "LLLL"
        return f.string(from: d)
    }

    @MainActor static func summary(_ start: Date) -> Summary {
        let cal = Calendar.current
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? start
        let lo = DayStore.dayFmt.string(from: start), hi = DayStore.dayFmt.string(from: end)
        let ns = NightArchive.shared.all.filter { $0.key >= lo && $0.key < hi }.map(\.value)
        let ds = DayArchive.shared.all.filter { $0.key >= lo && $0.key < hi }.map(\.value)
        var s = Summary()
        s.nights = ns.count; s.days = ds.count
        s.week = Insights.summary(ns)
        s.strain = avg(ds.map(\.strain))
        s.steps = avg(ds.compactMap(\.steps).map(Double.init))
        s.inactiveMin = avg(ds.compactMap(\.inactiveMin).map(Double.init))
        s.resp = avg(ns.compactMap(\.resp))
        s.skin = avg(ns.compactMap(\.skinTemp))
        let rhr = ns.compactMap(\.rhr).sorted()
        if rhr.count >= 5 { s.vo2 = 15.3 * UserProfile.maxHr / rhr[rhr.count / 2] }
        return s
    }

    private static func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
}

struct MonthReportView: View {
    var body: some View {
        let m0 = MonthReport.monthStart(1), m1 = MonthReport.monthStart(2)
        let a = MonthReport.summary(m0), b = MonthReport.summary(m1)
        ScrollView {
            VStack(spacing: Theme.gap) {
                Card(title: String(format: L("%@ · %d nachten"), MonthReport.name(m0).capitalized, a.nights)) {
                    row("Herstel", a.week.recovery, b.week.recovery, "%.0f%%", up: true)
                    row("Slaap", a.week.sleepMin, b.week.sleepMin, nil, up: true)
                    row("Slaapprestatie", a.week.sleepPerf, b.week.sleepPerf, "%.0f%%", up: true)
                    row("Regelmaat", a.week.consistency, b.week.consistency, "%.0f%%", up: true)
                    row("HRV", a.week.hrv, b.week.hrv, "%.0f ms", up: true)
                    row("Rust-HR", a.week.rhr, b.week.rhr, "%.0f bpm", up: false)
                    row("Ademfrequentie", a.resp, b.resp, "%.1f /min", up: nil)
                    row("VO2max (schatting)", a.vo2, b.vo2, "%.0f", up: true)
                }
                Card(title: "Overdag · \(a.days) dagen") {
                    row("Belasting", a.strain, b.strain, "%.1f", up: nil)
                    row("Stappen per dag", a.steps, b.steps, "%.0f", up: true)
                    row("Inactief per dag", a.inactiveMin, b.inactiveMin, nil, up: false)
                }
                Text("Gemiddelden per nacht of dag, vergeleken met \(MonthReport.name(m1)). Alleen wat Pulse heeft gemeten.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }.padding()
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Maandrapport")
    }

    private func fmt(_ v: Double?, _ f: String?) -> String {
        guard let v else { return "--" }
        guard let f else { return DV.hm(v) }
        return String(format: f, v)
    }

    /// up: true = hoger is beter, false = lager is beter, nil = neutraal.
    @ViewBuilder private func row(_ t: String, _ a: Double?, _ b: Double?, _ f: String?, up: Bool?) -> some View {
        HStack {
            Text(t)
            Spacer()
            Text(fmt(a, f)).monospacedDigit()
            if let a, let b {
                let d = a - b
                let small = abs(d) < 0.02 * max(abs(b), 1)
                let color: Color = small ? Theme.muted : up.map { $0 == (d >= 0) ? Theme.accent : Theme.hr } ?? Theme.muted
                Text((d >= 0 ? "+" : "−") + fmt(abs(d), f))
                    .font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                Image(systemName: d >= 0 ? "arrow.up.right" : "arrow.down.right").foregroundStyle(color)
            }
        }.font(.subheadline)
    }
}

struct MonthReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack { MonthReportView().toolbar { Button("Klaar") { dismiss() } } }
    }
}

// MARK: meldingen

@MainActor
enum InsightNotifications {
    static func post(_ id: String, _ title: String, _ body: String, sheet: AppRouter.Sheet? = nil) {
        let c = UNMutableNotificationContent()
        c.title = L(title); c.body = L(body); c.sound = .default
        if let sheet { c.userInfo = ["sheet": sheet.rawValue] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    /// De dagboekherinnering komt 's ochtends met de ochtendmelding (zie `morningJournal`);
    /// een oude vaste avondherinnering wordt hier opgeruimd.
    static func scheduleJournal() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["dagboek"])
    }

    /// 's Ochtends, samen met de ochtendmelding: vraag naar gisteren als dat nog niet is ingevuld.
    static func morningJournal() {
        guard InsightSettings.on(InsightSettings.journalKey), Journal.shared.entries[Journal.key()] == nil else { return }
        post("dagboek", "Dagboek", "Hoe was gisteren? Tik aan wat gold (alcohol, laat eten, sport…).", sheet: .journal)
    }

    /// Weekrapport op zondag vanaf 19:00, één keer per week (loopt mee op de hartslag, dus ook op de achtergrond).
    static func checkWeekly(now: Date = Date()) {
        guard InsightSettings.on(InsightSettings.weeklyKey) else { return }
        let cal = Calendar.current
        guard cal.component(.weekday, from: now) == 1, cal.component(.hour, from: now) >= 19 else { return }
        let key = DayStore.dayFmt.string(from: now)
        guard UserDefaults.standard.string(forKey: InsightSettings.lastWeeklyKey) != key else { return }
        UserDefaults.standard.set(key, forKey: InsightSettings.lastWeeklyKey)
        let w = WeekReport.weeks(end: now)
        let a = Insights.summary(w.this)
        var head: [String] = []
        if let r = a.recovery { head.append("herstel \(Int(r.rounded()))%") }
        if let s = a.sleepMin { head.append("slaap \(DV.hm(s))") }
        let adv = Insights.advice(this: a, prev: Insights.summary(w.prev)).text
        post("week", "Je weekrapport", (head.isEmpty ? "" : "Gemiddeld " + head.joined(separator: ", ") + ". ") + adv, sheet: .week)
    }

    /// Maandrapport op de 1e van de maand vanaf 09:00, één keer per maand.
    static func checkMonthly(now: Date = Date()) {
        guard InsightSettings.on(InsightSettings.monthlyKey) else { return }
        let cal = Calendar.current
        guard cal.component(.day, from: now) == 1, cal.component(.hour, from: now) >= 9 else { return }
        let m0 = MonthReport.monthStart(1, now: now)
        let key = DayStore.dayFmt.string(from: m0)
        guard UserDefaults.standard.string(forKey: InsightSettings.lastMonthlyKey) != key else { return }
        UserDefaults.standard.set(key, forKey: InsightSettings.lastMonthlyKey)
        let a = MonthReport.summary(m0), b = MonthReport.summary(MonthReport.monthStart(2, now: now))
        guard a.nights + a.days > 0 else { return }
        var parts: [String] = []
        func add(_ name: String, _ x: Double?, _ y: Double?, _ f: String, unit: String = "") {
            guard let x else { return }
            var t = "\(name) " + String(format: f, x) + unit
            if let y { let d = x - y; t += " (" + (d >= 0 ? "+" : "−") + String(format: f, abs(d)) + ")" }
            parts.append(t)
        }
        add("herstel", a.week.recovery, b.week.recovery, "%.0f", unit: "%")
        if let s = a.week.sleepMin {
            var t = "slaap \(DV.hm(s))"
            if let p = b.week.sleepMin { let d = s - p; t += " (" + (d >= 0 ? "+" : "−") + DV.hm(abs(d)) + ")" }
            parts.append(t)
        }
        add("HRV", a.week.hrv, b.week.hrv, "%.0f", unit: " ms")
        add("rust-HR", a.week.rhr, b.week.rhr, "%.0f", unit: " bpm")
        add("stappen", a.steps, b.steps, "%.0f")
        let month = MonthReport.name(m0)
        post("maand", String(format: L("Je maandrapport %@"), month), parts.joined(separator: ", ").capitalizedFirst + ". Tik voor alles, vergeleken met \(MonthReport.name(MonthReport.monthStart(2, now: now))).", sheet: .month)
    }

    /// Na de ochtendberekening: één melding als een waarde duidelijk afwijkt van je eigen normaal
    /// (rust-HR, HRV, huidtemperatuur, ademhaling, SpO2). Niet als de ziekte-waarschuwing deze nacht al kwam.
    static func checkAbnormal(_ n: Night?) {
        guard InsightSettings.on(InsightSettings.abnormalKey), let n else { return }
        let key = DayStore.dayFmt.string(from: n.date)
        let d = UserDefaults.standard
        guard d.string(forKey: InsightSettings.lastAbnormalKey) != key, d.string(forKey: InsightSettings.lastIllnessKey) != key else { return }
        let hist = NightArchive.shared.metrics(before: key, limit: 30)
        let devs = Insights.signals(n.metrics, history: hist).filter(\.deviates).map(\.deviation)
        guard !devs.isEmpty else { return }
        d.set(key, forKey: InsightSettings.lastAbnormalKey)
        post("afwijking", "Afwijkende waarde vannacht", text(devs) + " Vergeleken met je eigen normaal van de laatste weken.")
    }

    /// Na de ochtendberekening: waarschuwen als meerdere waarden tegelijk afwijken.
    static func checkIllness(_ n: Night?) {
        guard InsightSettings.on(InsightSettings.illnessKey), let n else { return }
        let key = DayStore.dayFmt.string(from: n.date)
        guard UserDefaults.standard.string(forKey: InsightSettings.lastIllnessKey) != key else { return }
        let hist = NightArchive.shared.metrics(before: key, limit: 30)
        guard let devs = Insights.illnessWarning(n.metrics, history: hist) else { return }
        UserDefaults.standard.set(key, forKey: InsightSettings.lastIllnessKey)
        post("ziekte", "Let op: je lichaam reageert anders", text(devs) + " Dit gaat vaak vooraf aan ziek worden. Doe het rustig aan en slaap extra.")
    }

    static func text(_ d: [Insights.Deviation]) -> String {
        d.map { x in
            switch x.metric {
            case "rhr": return String(format: L("rust-HR +%.0f bpm"), x.delta)
            case "hrv": return String(format: L("HRV %.0f%% lager"), 100 * -x.delta / max(1, x.baseline))
            case "skin": return String(format: L("huidtemp +%.1f °C"), x.delta)
            case "spo2": return String(format: L("SpO2 %.0f%% lager"), -x.delta)
            default: return String(format: L("ademhaling +%.1f/min"), x.delta)
            }
        }.joined(separator: ", ").capitalizedFirst + "."
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct InsightSettingsSection: View {
    @AppStorage(InsightSettings.journalKey) private var journal = true
    @AppStorage(InsightSettings.weeklyKey) private var weekly = true
    @AppStorage(InsightSettings.illnessKey) private var illness = true
    @AppStorage(InsightSettings.abnormalKey) private var abnormal = true
    @AppStorage(InsightSettings.monthlyKey) private var monthly = true

    var body: some View {
        Section {
            Toggle("Dagboekherinnering ('s ochtends)", isOn: $journal)
            Toggle("Weekrapport (zondag 19:00)", isOn: $weekly)
            Toggle("Maandrapport (1e van de maand)", isOn: $monthly)
            Toggle("Ziekte-waarschuwing", isOn: $illness)
            Toggle("Melding bij afwijkende waarden", isOn: $abnormal)
        } header: { Text("Inzichten") } footer: {
            Text("De ziekte-waarschuwing komt 's ochtends als minstens twee van rust-HR, HRV, huidtemperatuur, ademhaling en SpO2 tegelijk duidelijk afwijken van je eigen basislijn, of één ervan twee nachten op rij (na 5 gemeten nachten). De melding bij afwijkende waarden komt al bij één waarde die vannacht duidelijk afwijkt, hooguit één per ochtend. Geen medisch advies.")
        }
        .tint(Theme.accent)
        .onChange(of: journal) { _, _ in InsightNotifications.scheduleJournal() }
    }
}
