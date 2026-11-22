import SwiftUI
import CoreMotion
import WhoopScores

/// Verbeterpunten: concrete stappen op basis van je eigen slaap, belasting, activiteiten en stappen.
/// De regels zitten in de scores-module (Improvements); hier alleen de invoer verzamelen en tonen.
@MainActor
enum ImprovementData {
    /// Gemiddelde stappen per dag over de laatste 7 hele dagen, uit de iPhone (CoreMotion).
    /// nil zonder toestemming of met minder dan 3 dagen met stappen.
    static func phoneSteps() async -> Double? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        let st = CMPedometer.authorizationStatus()
        guard st != .denied && st != .restricted else { return nil }
        let p = CMPedometer()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var perDay: [Double] = []
        for k in 1...7 {
            guard let s = cal.date(byAdding: .day, value: -k, to: today), let e = cal.date(byAdding: .day, value: 1, to: s) else { continue }
            let n: Int? = await withCheckedContinuation { c in
                p.queryPedometerData(from: s, to: e) { d, _ in c.resume(returning: d.map { $0.numberOfSteps.intValue }) }
            }
            // 0 stappen = telefoon niet bij je of geen data; telt niet mee.
            if let n, n > 0 { perDay.append(Double(n)) }
        }
        return perDay.count >= 3 ? perDay.reduce(0, +) / Double(perDay.count) : nil
    }

    static func input(model: ScoreModel, acts: ActivityStore, age: Double?, male: Bool,
                      profileStrength: Double?, profileSteps: Double?, phoneSteps: Double?) -> ImprovementInput {
        let nights = model.nights.map { n in
            ImprovementInput.NightInfo(onset: n.r.onset, wake: n.r.wake, asleepMin: Double(n.r.asleepMin), needMin: n.needMin,
                                       debtMin: n.debtMin, efficiency: n.efficiency, awakeMin: Double(n.r.awakeMin),
                                       rhr: n.metrics.rhr, consistency: n.consistency, recovery: n.recovery)
        }
        let days = model.days.map { ImprovementInput.DayInfo(strain: $0.strain, zones13: $0.zones13, zones45: $0.zones45, measuredMin: $0.measuredMin) }
        var i = ImprovementInput(nights: nights, days: days, maxHr: UserProfile.maxHr, restHr: UserProfile.restHr,
                                 tzOffsetSec: TimeZone.current.secondsFromGMT())

        // Krachttraining: gelogde activiteiten van de laatste 7 dagen, anders wat je in je profiel invulde.
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let logged = acts.items.filter { $0.type == .strength && !$0.isOngoing && $0.start >= weekAgo }
            .map(\.duration).reduce(0, +) / 60
        if logged > 0 { i.strengthMinWeek = logged; i.strengthFromActivities = true }
        else { i.strengthMinWeek = profileStrength }
        // Stappen: iPhone eerst, anders profiel.
        if let phoneSteps { i.stepsPerDay = phoneSteps; i.stepsMeasured = true } else { i.stepsPerDay = profileSteps }

        // Normale rust-HR: mediaan van de laatste 30 nachten (vanaf 5 nachten).
        let rhr = NightArchive.shared.recentRhr(30).filter(\.isFinite).sorted()
        if rhr.count >= 5 { i.rhrBaseline = rhr[rhr.count / 2] }

        // Impact: dezelfde jaren-schaal als Levensduur.
        let f = AgeModel.factors(age: age ?? 30, male: male, nights: model.nights, days: model.days,
                                 strengthMin: i.strengthMinWeek, steps: i.stepsPerDay)
        let names: [String: ImprovementInput.Factor] = [
            "Slaapregelmaat": .consistency, "Uren slaap": .sleepHours, "Zones 1–3 per week": .zones13,
            "Zones 4–5 per week": .zones45, "Krachttraining per week": .strength, "Stappen per dag": .steps,
            "VO₂max (geschat)": .vo2max, "Rusthartslag": .rhr,
        ]
        for x in f { if let k = names[x.name], x.value != nil { i.factorYears[k] = x.years } }
        i.vo2max = f.first { $0.name == "VO₂max (geschat)" }?.value
        return i
    }
}

/// Afgevinkte stappen, per week (maandag begint opnieuw).
enum ImprovementChecks {
    private static let key = "improvements.done"
    private static var week: Int {
        Int(Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start.timeIntervalSince1970 ?? 0)
    }
    static func load() -> Set<String> {
        let all = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(all.filter { $0.hasPrefix("\(week)|") })
    }
    static func id(_ tip: String, _ step: Int) -> String { "\(week)|\(tip)|\(step)" }
    static func save(_ s: Set<String>) { UserDefaults.standard.set(Array(s), forKey: key) }
}

extension ImprovementArea {
    var name: String { switch self { case .sleep: "Slaap"; case .movement: "Beweging"; case .recovery: "Herstel" } }
    var icon: String { switch self { case .sleep: "moon.zzz.fill"; case .movement: "figure.walk"; case .recovery: "heart.circle.fill" } }
    var color: Color { switch self { case .sleep: DV.sleep; case .movement: Theme.accent; case .recovery: Theme.zones[3].color } }
}

struct ImpactDots: View {
    let impact: Double
    var body: some View {
        let lvl = Improvements.impactLevel(impact)
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { k in
                Circle().fill(k < lvl ? DV.poor : Theme.line).frame(width: 6, height: 6)
            }
        }.accessibilityLabel(Improvements.impactLabel(impact))
    }
}

/// Kaart op Gezondheid: de drie belangrijkste verbeterpunten.
struct ImprovementsCard: View {
    let tips: [Improvement]
    let loading: Bool
    var body: some View {
        Card(title: "Verbeterpunten") {
            if loading && tips.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if tips.isEmpty {
                Text("Niets dringends: je zit op alle punten goed. Houd je huidige ritme vast.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
            } else {
                ForEach(Array(tips.prefix(3).enumerated()), id: \.element.id) { k, t in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(k + 1)").font(Theme.number(18)).foregroundStyle(Theme.muted).frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 6) {
                                ImpactDots(impact: t.impact)
                                Text(t.area.name).font(.caption).foregroundStyle(Theme.muted)
                                if t.generic { Text("· algemeen").font(.caption).foregroundStyle(Theme.muted) }
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 2)
                }
                HStack {
                    Text(tips.count > 3 ? "Alle \(tips.count) verbeterpunten en stappen" : "Bekijk de stappen")
                    Spacer()
                    Image(systemName: "chevron.right")
                }.font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent).padding(.top, 4)
            }
        }
    }
}

/// Detailscherm: alle verbeterpunten, belangrijkste eerst, met afvinkbare stappen.
struct ImprovementsView: View {
    let tips: [Improvement]
    @State private var done = ImprovementChecks.load()

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.gap) {
                Text("Belangrijkste eerst. Begin met de bovenste en pak per week één of twee punten op; vink stappen af zodra ze lukken. Afvinken begint elke maandag opnieuw.")
                    .font(.subheadline).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                if tips.isEmpty {
                    Card { Text("Niets dringends: je zit op alle punten goed.").font(.subheadline) }
                }
                ForEach(Array(tips.enumerated()), id: \.element.id) { k, t in tipCard(k, t) }
                Text("Volgorde: geschatte winst op dezelfde schaal als Levensduur, plus herstel en slaapschuld. Eigen vuistregels; geen medisch advies. Punten met 'algemeen' worden persoonlijk zodra er genoeg nachten en dagen zijn gemeten.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }.padding()
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Verbeterpunten").navigationBarTitleDisplayMode(.inline)
    }

    private func tipCard(_ k: Int, _ t: Improvement) -> some View {
        Card(index: k) {
            HStack(spacing: 6) {
                Image(systemName: t.area.icon).foregroundStyle(t.area.color)
                Text(t.area.name.uppercased()).font(Theme.label).tracking(1.5).foregroundStyle(Theme.muted)
                if t.generic {
                    Text("ALGEMEEN").font(Theme.label).tracking(1).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.line, in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                ImpactDots(impact: t.impact)
                Text(Improvements.impactLabel(t.impact)).font(.caption).foregroundStyle(Theme.muted)
            }
            Text("\(k + 1). \(t.title)").font(.headline).foregroundStyle(Theme.text)
            Text(t.why).font(.subheadline).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(t.steps.enumerated()), id: \.offset) { s, text in
                    let id = ImprovementChecks.id(t.id, s)
                    Button {
                        if done.contains(id) { done.remove(id) } else { done.insert(id) }
                        ImprovementChecks.save(done)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: done.contains(id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(done.contains(id) ? Theme.accent : Theme.muted)
                            Text(text).font(.subheadline).foregroundStyle(done.contains(id) ? Theme.muted : Theme.text)
                                .strikethrough(done.contains(id), color: Theme.muted)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 4)
        }
    }
}
