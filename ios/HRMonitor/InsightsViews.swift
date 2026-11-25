import SwiftUI
import UserNotifications
import WhoopScores

// MARK: instellingen

enum InsightSettings {
    static let journalKey = "insights.journal"
    static let weeklyKey = "insights.weekly", illnessKey = "insights.illness"
    static let lastWeeklyKey = "insights.lastWeekly", lastIllnessKey = "insights.lastIllness"
    static func on(_ k: String) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? true }
}

/// Opent een scherm na een tik op een melding.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    enum Sheet: String, Identifiable { case journal, week; var id: String { rawValue } }
    @Published var sheet: Sheet?
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
                Card(title: "Afgelopen 7 dagen · \(a.nights) nachten") {
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

// MARK: meldingen

@MainActor
enum InsightNotifications {
    static func post(_ id: String, _ title: String, _ body: String, sheet: AppRouter.Sheet? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
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
            case "rhr": return String(format: "rust-HR +%.0f bpm", x.delta)
            case "hrv": return String(format: "HRV %.0f%% lager", 100 * -x.delta / max(1, x.baseline))
            case "skin": return String(format: "huidtemp +%.1f °C", x.delta)
            case "spo2": return String(format: "SpO2 %.0f%% lager", -x.delta)
            default: return String(format: "ademhaling +%.1f/min", x.delta)
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

    var body: some View {
        Section {
            Toggle("Dagboekherinnering ('s ochtends)", isOn: $journal)
            Toggle("Weekrapport (zondag 19:00)", isOn: $weekly)
            Toggle("Ziekte-waarschuwing", isOn: $illness)
        } header: { Text("Inzichten") } footer: {
            Text("De ziekte-waarschuwing komt 's ochtends als minstens twee van rust-HR, HRV, huidtemperatuur, ademhaling en SpO2 tegelijk duidelijk afwijken van je eigen basislijn, of één ervan twee nachten op rij (na 5 gemeten nachten). Geen medisch advies.")
        }
        .tint(Theme.accent)
        .onChange(of: journal) { _, _ in InsightNotifications.scheduleJournal() }
    }
}
