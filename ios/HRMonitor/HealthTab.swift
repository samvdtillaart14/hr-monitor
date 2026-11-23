import SwiftUI
import Charts
import WhoopScores
import UniformTypeIdentifiers

/// Geschatte biologische leeftijd: kalenderleeftijd + bijdragen (in jaren) van slaap, belasting en fitheid.
/// Eigen schatting met publieke vuistregels, afgesteld op één referentieweek; geen medische meting.
struct AgeFactor: Identifiable {
    var id: String { name }
    let group: String, name: String
    let value: Double?                 // gemiddelde over de opgeslagen dagen (max. ~30)
    let years: Double                  // bijdrage aan de leeftijd
    let lo: Double, hi: Double         // schaal van de balk (slecht → goed)
    let fmt: (Double) -> String
    let info: String
    /// Waarom er (nog) geen waarde is, bv. "Te weinig data: 1 van 3 nachten".
    var missing: String? = nil
}

enum AgeModel {
    static func clamp(_ v: Double, _ m: Double) -> Double { max(-m, min(m, v)) }

    /// Minimaal aantal nachten / volledig gemeten dagen voordat een factor meetelt. Eén nacht (bv. kort,
    /// met alcohol) of een halve dag zonder training gaf extreme jaren; daarom eerst genoeg data.
    static let minNights = 3, minDays = 3
    /// Een dag telt als gemeten bij minstens 16 uur aan metingen.
    static let fullDayMin = 16.0 * 60

    static func factors(age: Double, male: Bool, nights: [Night], days: [DayLoad], strengthMin: Double?, steps: Double?) -> [AgeFactor] {
        var f: [AgeFactor] = []
        let nightNote = nights.count < minNights ? "Te weinig data: \(nights.count) van \(minNights) nachten gemeten." : nil
        let enoughNights = nightNote == nil
        let pct = { (v: Double) in "\(Int(v.rounded()))%" }
        let hm = { (m: Double) in DV.hm(m) }
        // Slaap
        let consV = nights.compactMap(\.consistency)
        let cons = consV.count >= minNights ? DV.mean(consV) : nil
        f.append(AgeFactor(group: "Slaap", name: "Slaapregelmaat", value: cons,
                           years: cons.map { clamp((75 - $0) / 20, 1.5) } ?? 0, lo: 40, hi: 100, fmt: pct,
                           info: "Elke dag rond dezelfde tijd slapen en opstaan. Onder 75% telt het als extra jaren, daarboven als winst.",
                           missing: cons == nil ? "Te weinig data: regelmaat vergelijkt elke nacht met de nachten ervoor; nodig zijn \(minNights) nachten met een vorige nacht erbij (nu \(consV.count))." : nil))
        let hours = enoughNights ? DV.mean(nights.map { Double($0.r.asleepMin) }) : nil
        f.append(AgeFactor(group: "Slaap", name: "Uren slaap", value: hours,
                           years: hours.map { clamp(abs($0 / 60 - 7.5) * 0.85 - 0.4, 2) } ?? 0, lo: 300, hi: 480, fmt: hm,
                           info: "Advies is 7–8 uur. Hoe verder je ervan af zit, hoe meer het meetelt.", missing: nightNote))
        // Belasting (per week)
        // Alleen (bijna) volledig gemeten dagen tellen; een halve dag zonder training is geen weekgemiddelde.
        let fullDays = days.filter { $0.measuredMin >= fullDayMin }
        let n = Double(fullDays.count)
        let dayNote = fullDays.count < minDays ? "Te weinig data: \(fullDays.count) van \(minDays) volledig gemeten dagen (minstens 16 uur band om)." : nil
        let z13 = dayNote == nil ? fullDays.map(\.zones13).reduce(0, +) * 7 / n : nil
        let z45 = dayNote == nil ? fullDays.map(\.zones45).reduce(0, +) * 7 / n : nil
        f.append(AgeFactor(group: "Belasting", name: "Zones 1–3 per week", value: z13,
                           years: z13.map { clamp((150 - $0) / 67, 2) } ?? 0, lo: 0, hi: 300, fmt: hm,
                           info: "Matige inspanning. De WHO adviseert minstens 150 minuten per week.", missing: dayNote))
        f.append(AgeFactor(group: "Belasting", name: "Zones 4–5 per week", value: z45,
                           years: z45.map { clamp((25 - $0) / 50, 1.5) } ?? 0, lo: 0, hi: 90, fmt: hm,
                           info: "Zware inspanning; telt dubbel volgens de WHO-norm (75 min zwaar ≈ 150 min matig).", missing: dayNote))
        f.append(AgeFactor(group: "Belasting", name: "Krachttraining per week", value: strengthMin,
                           years: strengthMin.map { clamp((90 - $0) / 61, 1.5) } ?? 0, lo: 0, hi: 180, fmt: hm,
                           info: "Zelf invullen in je profiel: de band stuurt (nog) geen bewegingsdata die we kunnen herkennen.",
                           missing: strengthMin == nil ? "Nog niet ingevuld. Vul je minuten krachttraining per week in bij je profiel (rechtsboven op Gezondheid)." : nil))
        f.append(AgeFactor(group: "Belasting", name: "Stappen per dag", value: steps,
                           years: steps.map { clamp((8300 - $0) / 4000, 1.5) } ?? 0, lo: 2000, hi: 14000, fmt: { "\(Int($0))" },
                           info: "Zelf invullen in je profiel (bv. uit Apple Gezondheid). Rond 8.000 per dag is neutraal.",
                           missing: steps == nil ? "Nog niet ingevuld. De band telt geen stappen; vul je gemiddelde uit Apple Gezondheid in bij je profiel (rechtsboven op Gezondheid)." : nil))
        // Fitheid
        let rhrV = nights.compactMap(\.metrics.rhr)
        let rhr = rhrV.count >= minNights ? DV.mean(rhrV) : nil
        let vo2 = rhr.map { 15.3 * (208 - 0.7 * age) / $0 }       // Uth (2004) met HRmax volgens Tanaka (2001)
        let expected = (male ? 47 : 40) - 0.35 * (age - 25)
        f.append(AgeFactor(group: "Fitheid", name: "VO₂max (geschat)", value: vo2,
                           years: vo2.map { clamp((expected - $0) * 0.34, 3) } ?? 0, lo: 30, hi: 60, fmt: { "\(Int($0.rounded()))" },
                           info: "Geschat uit je rust-HR en leeftijd (15,3 × HRmax / HRrust). Sterkste losse voorspeller van levensduur.", missing: rhr == nil ? nightNote : nil))
        f.append(AgeFactor(group: "Fitheid", name: "Rusthartslag", value: rhr,
                           years: rhr.map { clamp(($0 - 60) * 0.1, 1.5) } ?? 0, lo: 80, hi: 45, fmt: { "\(Int($0.rounded()))" },
                           info: "Gemeten tijdens je slaap. Lager is meestal fitter; 60 bpm is neutraal.", missing: rhr == nil ? nightNote : nil))
        return f
    }

    static func pace(offset: Double) -> Double { max(-1, min(3, 1 + offset / 5)) }
}

/// Bewaart per week de leeftijdsschatting en factorwaarden, voor trends en het 6-maandsgemiddelde.
enum AgeHistory {
    struct Week: Codable { var start: Double; var bio: Double; var pace: Double; var values: [String: Double] }
    /// v2: weken van vóór de minimum-data-regel bevatten extreme waarden uit één nacht en tellen niet mee.
    private static let key = "age.history.v2"
    static func load() -> [Week] {
        guard let d = UserDefaults.standard.data(forKey: key), let w = try? JSONDecoder().decode([Week].self, from: d) else { return [] }
        return w
    }
    static func save(bio: Double, pace: Double, factors: [AgeFactor]) {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!.start.timeIntervalSince1970
        var w = load().filter { $0.start != start }
        var vals: [String: Double] = [:]
        for f in factors { if let v = f.value { vals[f.name] = v } }
        w.append(Week(start: start, bio: bio, pace: pace, values: vals))
        w.sort { $0.start < $1.start }
        if let d = try? JSONEncoder().encode(Array(w.suffix(26))) { UserDefaults.standard.set(d, forKey: key) }
    }
}

struct HealthTab: View {
    @EnvironmentObject var store: DayStore
    @EnvironmentObject var model: ScoreModel
    @EnvironmentObject var acts: ActivityStore
    @AppStorage("profile.birth") private var birth: Double = 0
    @AppStorage("profile.male") private var male = true
    @AppStorage("profile.strength") private var strength: Double = -1
    @AppStorage("profile.steps") private var steps: Double = -1
    @State private var showProfile = false
    @State private var phoneSteps: Double?
    @State private var stepsLoaded = false
    @AppStorage(Display.healthAge) private var showAge = true
    @AppStorage(Display.healthPace) private var showPace = true

    private var tips: [Improvement] {
        Improvements.build(ImprovementData.input(model: model, acts: acts, age: age, male: male,
                                                 profileStrength: strength >= 0 ? strength : nil,
                                                 profileSteps: steps >= 0 ? steps : nil, phoneSteps: phoneSteps))
    }

    private var age: Double? { birth > 0 ? (Date().timeIntervalSince1970 - birth) / 31_557_600 : nil }
    private var factors: [AgeFactor] {
        guard let age else { return [] }
        return AgeModel.factors(age: age, male: male, nights: model.nights, days: model.days,
                                strengthMin: strength >= 0 ? strength : nil, steps: steps >= 0 ? steps : nil)
    }
    /// Pas een leeftijd/tempo tonen als er genoeg gemeten slaap- of fitheidsdata is (zelf invullen alleen is te weinig).
    private var hasData: Bool { factors.contains { $0.value != nil && $0.group != "Belasting" } }
    private var offset: Double { factors.map(\.years).reduce(0, +) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.gap) {
                    if age == nil {
                        Card {
                            Text("Vul je geboortedatum in om je biologische leeftijd te schatten.").font(.subheadline)
                            Button("Profiel invullen") { showProfile = true }.buttonStyle(.borderedProminent)
                        }
                    }
                    if showAge { AgeOrb(bio: hasData ? age.map { $0 + offset } : nil, offset: offset, size: 250) }
                    if showPace { paceCard }
                    NavigationLink { WeekReportView() } label: {
                        Card(title: "Weekrapport") {
                            HStack {
                                Text("Slaap, herstel en trends van deze week, met één advies").font(.subheadline).foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                            }
                        }
                    }.buttonStyle(.plain)
                    let t = tips
                    NavigationLink { ImprovementsView(tips: t) } label: { ImprovementsCard(tips: t, loading: !stepsLoaded) }
                        .buttonStyle(.plain)
                    NavigationLink { HealthspanView(model: model, factors: factors, age: age ?? 0, offset: offset, hasData: hasData) } label: {
                        Text("NAAR LEVENSDUUR-DETAILS").font(Theme.label).tracking(2).frame(maxWidth: .infinity).padding()
                            .background(Theme.cardHi, in: RoundedRectangle(cornerRadius: 14))
                    }.disabled(age == nil)
                    Text("Schatting met eigen vuistregels; geen medische meting. Zie de details voor wat meetelt.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }.padding()
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Gezondheid")
            .toolbar { Button { showProfile = true } label: { Image(systemName: "person.crop.circle") } }
            .sheet(isPresented: $showProfile) { ProfileSheet(birth: $birth, male: $male, strength: $strength, steps: $steps) }
        }
        .onAppear { model.refresh(store: store) }
        .task { phoneSteps = await ImprovementData.phoneSteps(); stepsLoaded = true }
        .onChange(of: model.nights.count) { _, _ in snapshot() }
    }

    private func snapshot() {
        guard hasData, let age else { return }
        AgeHistory.save(bio: age + offset, pace: AgeModel.pace(offset: offset), factors: factors)
    }

    private var paceCard: some View {
        let hist = AgeHistory.load()
        let prev = hist.count >= 2 ? hist[hist.count - 2].pace : nil
        let p = AgeModel.pace(offset: offset)
        return Card(title: "Verouderingstempo") {
            HStack {
                Text("Langzaam").foregroundStyle(Theme.muted)
                Spacer()
                Text(hasData ? String(format: "%.1f×", p) : "--").font(Theme.number(28))
                Spacer()
                Text("Snel").foregroundStyle(Theme.muted)
            }.font(.subheadline)
            PaceScale(pace: hasData ? p : nil)
            if !hasData {
                Text("Te weinig data: het tempo verschijnt na \(AgeModel.minNights) gemeten nachten.").font(.caption).foregroundStyle(Theme.muted)
            } else if let prev {
                StatusPill(text: p > prev + 0.05 ? "sneller dan vorige week" : p < prev - 0.05 ? "langzamer dan vorige week" : "gelijk aan vorige week",
                           ok: p <= prev + 0.05)
            } else {
                Text("Vergelijking met vorige week volgt na twee weken meten.").font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct AgeOrb: View {
    let bio: Double?
    let offset: Double
    var size: CGFloat = 250
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [.black, Theme.hex(0x1D3B5C), Theme.hex(0x3E7FBF).opacity(0.8)], center: .center, startRadius: size * 0.16, endRadius: size * 0.52))
                .overlay(Circle().stroke(Theme.hex(0x6FA6E8).opacity(0.6), lineWidth: 2))
                .shadow(color: Theme.hex(0x3E7FBF).opacity(0.5), radius: 30)
            VStack(spacing: 6) {
                Text(bio.map { String(format: "%.1f", $0) } ?? "--").font(Theme.number(size * 0.22)).monospacedDigit()
                Text("BIOLOGISCHE LEEFTIJD").font(Theme.label).tracking(1.5)
                if bio == nil && size > 200 {
                    Text("Te weinig data").font(.headline).foregroundStyle(Theme.muted)
                }
                if bio != nil && size > 200 {
                    Text(String(format: "%.1f jaar %@", abs(offset), offset >= 0 ? "ouder" : "jonger"))
                        .font(.headline).foregroundStyle(offset > 0 ? DV.poor : Theme.hex(0x8EC5FF))
                }
            }
        }
        .frame(width: size, height: size).frame(maxWidth: .infinity).padding(.vertical, 12)
    }
}

struct PaceScale: View {
    let pace: Double?
    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<41, id: \.self) { i in
                            Capsule().fill(Color.white.opacity(i % 10 == 0 ? 0.6 : 0.25)).frame(width: 2, height: i % 10 == 0 ? 30 : 22)
                            if i < 40 { Spacer(minLength: 0) }
                        }
                    }
                    if let pace { Capsule().fill(.white).frame(width: 4, height: 38).offset(x: g.size.width * (pace + 1) / 4 - 2) }
                }
            }.frame(height: 38)
            HStack { Text("−1,0×"); Spacer(); Text("1,0×"); Spacer(); Text("3,0×") }.font(.caption).foregroundStyle(Theme.muted)
        }
    }
}

/// Detailscherm: weekoverzicht, trends en per factor een schaal met 30-dagen- en 6-maandsgemiddelde.
struct HealthspanView: View {
    @ObservedObject var model: ScoreModel
    let factors: [AgeFactor]
    let age: Double
    let offset: Double
    var hasData = true
    @State private var open: String? = nil
    @AppStorage(Display.healthWeekAge) private var showWeekAge = true

    private var hist: [AgeHistory.Week] { AgeHistory.load() }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.gap) {
                header
                if showWeekAge { trendCard }
                ForEach(["Slaap", "Belasting", "Fitheid"], id: \.self) { g in
                    HStack {
                        Text(g).font(.title2.bold())
                        Spacer()
                        Label("6 mnd", systemImage: "arrowtriangle.down.fill").font(.caption)
                        Label("30 dagen", systemImage: "arrowtriangle.up.fill").font(.caption)
                    }.foregroundStyle(Theme.text).padding(.top, 6)
                    ForEach(factors.filter { $0.group == g }) { f in row(f) }
                }
                Text("Waarden: gemiddelden over de dagen die de app heeft opgeslagen (30-dagenmarker) en over de wekelijkse momentopnames (6-maandenmarker, groeit vanzelf). Afgesteld zodat een referentieweek ongeveer dezelfde bijdragen geeft als de Whoop-app; blijft een schatting.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }.padding()
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Levensduur").navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!
        return VStack(spacing: 4) {
            Text("WEEKOVERZICHT · \(week.start.formatted(.dateTime.locale(DV.nl).day().month(.abbreviated))) – \(Date().formatted(.dateTime.locale(DV.nl).day().month(.abbreviated)))")
                .font(Theme.label).tracking(1.5).foregroundStyle(Theme.muted)
            HStack {
                VStack { Text(hasData ? String(format: "%.1f", abs(offset)) : "--").font(Theme.number(24)).foregroundStyle(hasData && offset > 0 ? DV.poor : Theme.hex(0x8EC5FF))
                    Text(offset >= 0 ? "JAAR OUDER" : "JAAR JONGER").font(Theme.label).tracking(1) }.frame(maxWidth: .infinity)
                AgeOrb(bio: hasData ? age + offset : nil, offset: offset, size: 140).frame(width: 150)
                VStack { Text(hasData ? String(format: "%.1f×", AgeModel.pace(offset: offset)) : "--").font(Theme.number(24))
                    Text("TEMPO").font(Theme.label).tracking(1) }.frame(maxWidth: .infinity)
            }
        }
    }

    private var trendCard: some View {
        Card(title: "Leeftijd per week") {
            if hist.count < 2 {
                Text("De trend verschijnt na twee weken meten (één punt per week).").font(.subheadline).foregroundStyle(Theme.muted)
            } else {
                Chart {
                    ForEach(hist, id: \.start) { w in
                        LineMark(x: .value("Week", Date(timeIntervalSince1970: w.start)), y: .value("Leeftijd", w.bio), series: .value("s", "Biologisch"))
                            .foregroundStyle(Theme.hex(0x8EC5FF)).symbol(.circle)
                        LineMark(x: .value("Week", Date(timeIntervalSince1970: w.start)), y: .value("Leeftijd", age - (Date().timeIntervalSince1970 - w.start) / 31_557_600), series: .value("s", "Kalender"))
                            .foregroundStyle(Theme.muted).lineStyle(StrokeStyle(dash: [4, 4]))
                    }
                }.chartYScale(domain: .automatic(includesZero: false)).frame(height: 160)
                Chart {
                    ForEach(hist, id: \.start) { w in
                        BarMark(x: .value("Week", Date(timeIntervalSince1970: w.start), unit: .weekOfYear), y: .value("Tempo", w.pace))
                            .foregroundStyle(w.pace > 1 ? DV.poor : DV.good)
                    }
                    RuleMark(y: .value("1×", 1)).foregroundStyle(Theme.muted).lineStyle(StrokeStyle(dash: [3, 3]))
                }.chartYScale(domain: -1...3).frame(height: 120)
            }
        }
    }

    private func row(_ f: AgeFactor) -> some View {
        let six = DV.mean(hist.compactMap { $0.values[f.name] })
        let isOpen = open == f.name
        return Card {
            Button { withAnimation { open = isOpen ? nil : f.name } } label: {
                HStack { Text(f.name.uppercased()).font(Theme.label).tracking(1.5); Spacer(); Image(systemName: isOpen ? "chevron.up" : "chevron.down") }
            }.buttonStyle(.plain)
            HStack(alignment: .center, spacing: 12) {
                ScaleBar(f: f, thirty: f.value, six: six)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(f.value == nil ? "–" : String(format: "%+.1f", f.years)).font(Theme.number(22))
                        .foregroundStyle(f.years > 0.05 ? DV.poor : f.years < -0.05 ? DV.good : Theme.muted)
                    Text("jaar").font(.caption).foregroundStyle(Theme.muted)
                }.frame(width: 64)
            }
            if f.value == nil, !isOpen, let m = f.missing {
                Text(m).font(.caption).foregroundStyle(Theme.muted)
            }
            if isOpen {
                Text(f.value == nil ? (f.missing ?? "Nog geen waarde.") :
                        (f.years > 0.05 ? "Kans om te verbeteren. " : f.years < -0.05 ? "Dit werkt in je voordeel. " : "Neutraal. ")
                        + String(format: "Deze factor telt nu %+.1f jaar mee. ", f.years) + f.info)
                    .font(.subheadline).foregroundStyle(Theme.muted)
            }
        }
    }
}

/// Gekleurde schaal (oranje = slecht, groen = goed) met markers voor 6 maanden (boven) en 30 dagen (onder).
struct ScaleBar: View {
    let f: AgeFactor
    let thirty: Double?
    let six: Double?
    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    if let six { marker(six, g.size.width, down: true) }
                }
            }.frame(height: 26)
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { i in
                    Rectangle().fill(i < 4 ? DV.poor : i < 6 ? DV.fair : DV.good).opacity(0.85).frame(height: 5)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    if let thirty { marker(thirty, g.size.width, down: false) }
                }
            }.frame(height: 26)
            HStack { Text(f.fmt(f.lo)).foregroundStyle(DV.poor); Spacer(); Text(f.fmt(f.hi)).foregroundStyle(DV.good) }.font(.caption2)
        }
    }
    private func pos(_ v: Double) -> Double { max(0, min(1, (v - f.lo) / (f.hi - f.lo))) }
    private func marker(_ v: Double, _ w: CGFloat, down: Bool) -> some View {
        VStack(spacing: 0) {
            if down { Text(f.fmt(v)).font(.caption2.weight(.semibold)); Image(systemName: "arrowtriangle.down.fill").font(.system(size: 8)) }
            else { Image(systemName: "arrowtriangle.up.fill").font(.system(size: 8)); Text(f.fmt(v)).font(.caption2.weight(.semibold)) }
        }
        .frame(width: 60)
        .offset(x: w * pos(v) - 30)
    }
}

struct ProfileSheet: View {
    @Binding var birth: Double
    @Binding var male: Bool
    @Binding var strength: Double
    @Binding var steps: Double
    @Environment(\.dismiss) private var dismiss
    @State private var date = Calendar.current.date(byAdding: .year, value: -25, to: Date())!
    @State private var strengthText = ""
    @State private var stepsText = ""
    @AppStorage(UserProfile.maxHrKey) private var maxHr: Double = 0
    @AppStorage(UserProfile.restHrAutoKey) private var restHrAuto: Double = 0
    @State private var maxHrText = ""
    @AppStorage(UserProfile.weightKey) private var weight: Double = 0
    @AppStorage(UserProfile.heightKey) private var height: Double = 0
    @AppStorage(UserProfile.baseHrvKey) private var baseHrv: Double = 0
    @AppStorage(UserProfile.baseRhrKey) private var baseRhr: Double = 0
    @State private var baseHrvText = ""
    @State private var baseRhrText = ""
    @State private var weightText = ""
    @State private var heightText = ""
    @State private var importing = false
    @State private var calStatus = UserProfile.importedCalibration == nil ? "Niet geladen (standaard)" : "Geladen"
    /// Schatting voor de max-HR met de geboortedatum die nu in het formulier staat.
    private var estimate: Int { Int((208 - 0.7 * Date().timeIntervalSince(date) / 31_557_600).rounded()) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Over jou") {
                    DatePicker("Geboortedatum", selection: $date, in: ...Date(), displayedComponents: .date)
                    Picker("Geslacht (VO₂max-norm)", selection: $male) { Text("Man").tag(true); Text("Vrouw").tag(false) }
                }
                Section {
                    LabeledContent("Max-hartslag") {
                        TextField("\(estimate) (schatting)", text: $maxHrText).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Rust-hartslag (berekend)",
                                   value: restHrAuto > 0 ? "\(Int(restHrAuto)) bpm" : "na 3 nachten · nu \(Int(UserProfile.restHr))")
                } header: { Text("Hartslag") } footer: {
                    Text("Bepaalt je hartslagzones, belasting en calorieën. De rust-hartslag rekent de app zelf uit: de mediaan van je rust-HR over de gemeten nachten (gemiddelde hartslag tijdens de slaap), vanaf 3 nachten. Vul je max-hartslag in: je hoogste gemeten hartslag in (bv. uit een maximale inspanningstest of de Whoop-app). Leeg = schatting 208 − 0,7 × leeftijd.")
                }
                Section {
                    LabeledContent("Gewicht (kg)") {
                        TextField("75", text: $weightText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Lengte (cm)") {
                        TextField("180", text: $heightText).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                } header: { Text("Lichaam") } footer: { Text("Voor het rustverbruik en de calorieën. Leeg = 75 kg / 180 cm.") }
                Section {
                    LabeledContent("HRV (ms)") {
                        TextField("bv. 30", text: $baseHrvText).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Rust-hartslag (bpm)") {
                        TextField("bv. 55", text: $baseRhrText).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                } header: { Text("Je normale waarden") } footer: {
                    Text("Startpunt voor herstel en slaapstress zolang de app nog geen 4 nachten van je heeft gemeten. Neem je gemiddelde uit de Whoop-app. Leeg = herstel verschijnt pas na 4 nachten.")
                }
                Section {
                    LabeledContent("Kalibratie", value: calStatus)
                    Button("Kalibratiebestand kiezen…") { importing = true }
                    if UserProfile.importedCalibration != nil {
                        Button("Kalibratie verwijderen", role: .destructive) {
                            UserProfile.removeCalibration(); calStatus = "Niet geladen (standaard)"
                        }
                    }
                } header: { Text("Afstemming op Whoop") } footer: {
                    Text("Kies whoop-calibration.json (gemaakt uit je Whoop-export) via de Bestanden-app. Dan rekenen belasting, slaap en herstel met jouw afgestemde formules. Het bestand blijft alleen op je iPhone.")
                }
                Section {
                    TextField("Krachttraining, minuten per week", text: $strengthText).keyboardType(.numberPad)
                    TextField("Stappen per dag (gemiddeld)", text: $stepsText).keyboardType(.numberPad)
                } header: { Text("Zelf invullen") } footer: { Text("De band stuurt dit (nog) niet. Leeg laten = telt niet mee.") }
            }
            .navigationTitle("Profiel")
            .toolbar {
                Button("Bewaar") {
                    birth = date.timeIntervalSince1970
                    strength = Double(strengthText) ?? -1
                    steps = Double(stepsText) ?? -1
                    maxHr = Double(maxHrText).flatMap { (100...240).contains($0) ? $0 : nil } ?? 0
                    weight = Double(weightText.replacingOccurrences(of: ",", with: ".")).flatMap { (30...250).contains($0) ? $0 : nil } ?? 0
                    height = Double(heightText).flatMap { (120...230).contains($0) ? $0 : nil } ?? 0
                    baseHrv = Double(baseHrvText.replacingOccurrences(of: ",", with: ".")).flatMap { (10...200).contains($0) ? $0 : nil } ?? 0
                    baseRhr = Double(baseRhrText.replacingOccurrences(of: ",", with: ".")).flatMap { (30...100).contains($0) ? $0 : nil } ?? 0
                    dismiss()
                }
            }
            .onAppear {
                if birth > 0 { date = Date(timeIntervalSince1970: birth) }
                if strength >= 0 { strengthText = String(Int(strength)) }
                if steps >= 0 { stepsText = String(Int(steps)) }
                if maxHr > 0 { maxHrText = String(Int(maxHr)) }
                if weight > 0 { weightText = String(format: "%g", weight) }
                if height > 0 { heightText = String(Int(height)) }
                if baseHrv > 0 { baseHrvText = String(Int(baseHrv)) }
                if baseRhr > 0 { baseRhrText = String(Int(baseRhr)) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    do { try UserProfile.importCalibration(from: url); calStatus = "Geladen" }
                    catch { calStatus = "Ongeldig bestand" }
                case .failure: calStatus = "Niet gelukt"
                }
            }
        }
    }
}
