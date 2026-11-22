import Foundation

/// Verbeterpunten: concrete, kleine stappen op basis van je eigen nachten, dagen en activiteiten.
/// Alleen data die de app echt heeft; ontbreekt die, dan een algemene maar concrete startstap (`generic`).
public enum ImprovementArea: String, Sendable { case sleep, movement, recovery }

public struct Improvement: Identifiable, Sendable {
    public var id: String
    public var area: ImprovementArea
    /// De actie zelf, zo specifiek mogelijk ("Ga deze week uiterlijk om 00:30 naar bed").
    public var title: String
    /// Waarom, met je eigen cijfers.
    public var why: String
    /// Kleine stappen, de makkelijkste eerst.
    public var steps: [String]
    /// Geschatte winst, ongeveer in jaren biologische leeftijd (zelfde schaal als Levensduur). Bepaalt de volgorde.
    public var impact: Double
    /// true: te weinig eigen data, algemene startstap.
    public var generic: Bool
}

public struct ImprovementInput: Sendable {
    public struct NightInfo: Sendable {
        public var onset: Double, wake: Double          // epoch-seconden
        public var asleepMin: Double, needMin: Double, debtMin: Double
        public var efficiency: Double                    // %
        public var awakeMin: Double
        public var rhr: Double?
        public var consistency: Double?                  // %
        public var recovery: Int?
        public init(onset: Double, wake: Double, asleepMin: Double, needMin: Double, debtMin: Double = 0,
                    efficiency: Double, awakeMin: Double = 0, rhr: Double? = nil, consistency: Double? = nil, recovery: Int? = nil) {
            self.onset = onset; self.wake = wake; self.asleepMin = asleepMin; self.needMin = needMin; self.debtMin = debtMin
            self.efficiency = efficiency; self.awakeMin = awakeMin; self.rhr = rhr; self.consistency = consistency; self.recovery = recovery
        }
    }
    public struct DayInfo: Sendable {
        public var strain: Double, zones13: Double, zones45: Double, measuredMin: Double
        public init(strain: Double, zones13: Double, zones45: Double, measuredMin: Double) {
            self.strain = strain; self.zones13 = zones13; self.zones45 = zones45; self.measuredMin = measuredMin
        }
    }
    /// Bijdrage (jaren) per Levensduur-factor; > 0 = ruimte om te verbeteren.
    public enum Factor: String, Sendable { case consistency, sleepHours, zones13, zones45, strength, steps, vo2max, rhr }

    public var nights: [NightInfo]                   // oudste eerst
    public var days: [DayInfo]                       // oudste eerst, inclusief vandaag
    public var factorYears: [Factor: Double] = [:]
    /// Krachttraining (min/week) en of dat uit gelogde activiteiten komt (anders zelf ingevuld).
    public var strengthMinWeek: Double?
    public var strengthFromActivities = false
    /// Stappen per dag en of de iPhone ze telde (anders zelf ingevuld).
    public var stepsPerDay: Double?
    public var stepsMeasured = false
    /// Normale rust-HR (mediaan over ~30 nachten), voor uitschieters.
    public var rhrBaseline: Double?
    public var vo2max: Double?
    public var maxHr: Double, restHr: Double
    /// Verschil met UTC in seconden, voor klokttijden.
    public var tzOffsetSec: Int

    public init(nights: [NightInfo], days: [DayInfo], maxHr: Double, restHr: Double, tzOffsetSec: Int) {
        self.nights = nights; self.days = days; self.maxHr = maxHr; self.restHr = restHr; self.tzOffsetSec = tzOffsetSec
    }
}

public enum Improvements {
    public static let minNights = 3, minDays = 3
    static let fullDayMin = 16.0 * 60

    // MARK: hulpfuncties

    /// Kloktijd in minuten (0–1439).
    static func clock(_ t: Double, _ tz: Int) -> Int {
        let m = Int(((t + Double(tz)) / 60).rounded(.down)) % 1440
        return m < 0 ? m + 1440 : m
    }
    /// Inslaaptijd op een schaal vanaf 12:00, zodat 23:30 en 01:30 dicht bij elkaar liggen.
    static func bedScale(_ t: Double, _ tz: Int) -> Double { Double((clock(t, tz) - 720 + 1440) % 1440) }
    /// Opsta-tijd op een schaal vanaf 18:00.
    static func wakeScale(_ t: Double, _ tz: Int) -> Double { Double((clock(t, tz) - 1080 + 1440) % 1440) }
    static func fromBed(_ v: Double) -> Int { (Int(v.rounded()) + 720) % 1440 }
    static func fromWake(_ v: Double) -> Int { (Int(v.rounded()) + 1080) % 1440 }

    public static func hhmm(_ m: Int) -> String {
        let x = ((m % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", x / 60, x % 60)
    }
    /// Duur als "1 u 20 min" / "45 min".
    public static func dur(_ min: Double) -> String {
        let m = max(0, Int(min.rounded()))
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) u" : "\(m / 60) u \(m % 60) min"
    }
    static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
    static func sd(_ v: [Double]) -> Double? {
        guard v.count >= 2, let m = mean(v) else { return nil }
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - 1)).squareRoot()
    }
    static func round5(_ v: Double) -> Int { Int((v / 5).rounded()) * 5 }
    static func thousands(_ v: Int) -> String {
        let s = String(v)
        guard s.count > 3 else { return s }
        var out = ""
        for (i, ch) in s.reversed().enumerated() { if i > 0 && i % 3 == 0 { out.append(".") }; out.append(ch) }
        return String(out.reversed())
    }

    /// Hartslag bij een fractie van de hartslagreserve (zelfde zones als de belasting).
    static func hrAt(_ frac: Double, _ i: ImprovementInput) -> Int { Int((i.restHr + frac * (i.maxHr - i.restHr)).rounded()) }

    /// Doelbedtijd (minuten vanaf middernacht) voor deze week: richting "opstaan − slaapbehoefte",
    /// maar hooguit 45 min eerder dan je huidige gemiddelde, afgerond op een kwartier.
    public struct SleepPlan: Sendable {
        public var bedMean: Int, bedEarliest: Int, bedLatest: Int, bedSdMin: Double
        public var wakeMean: Int, asleepMean: Double, needMean: Double
        public var target: Int
        /// doel ligt nog later dan ideaal: volgende week verder schuiven
        public var moreLater: Bool
    }

    public static func sleepPlan(_ i: ImprovementInput) -> SleepPlan? {
        let n = i.nights
        guard n.count >= minNights else { return nil }
        let beds = n.map { bedScale($0.onset, i.tzOffsetSec) }
        let wakes = n.map { wakeScale($0.wake, i.tzOffsetSec) }
        guard let bm = mean(beds), let wm = mean(wakes), let am = mean(n.map(\.asleepMin)) else { return nil }
        let need = mean(n.map(\.needMin).filter { $0 > 0 }) ?? 480
        // Ideaal: opstaan − (slaapbehoefte + 15 min inslapen), op de bedschaal (wake-schaal begint 6 uur later).
        let ideal = wm + 360 - need - 15
        var target = max(ideal, bm - 45)
        target = (target / 15).rounded(.down) * 15
        // Niet later dan je huidige gemiddelde.
        if target > bm { target = (bm / 15).rounded(.down) * 15 }
        return SleepPlan(bedMean: fromBed(bm), bedEarliest: fromBed(beds.min()!), bedLatest: fromBed(beds.max()!),
                         bedSdMin: sd(beds) ?? 0, wakeMean: fromWake(wm), asleepMean: am, needMean: need,
                         target: fromBed(target), moreLater: ideal < target - 10)
    }

    // MARK: regels

    public static func build(_ i: ImprovementInput) -> [Improvement] {
        var out: [Improvement] = []
        let y = { (f: ImprovementInput.Factor) in max(0, i.factorYears[f] ?? 0) }
        let plan = sleepPlan(i)
        let n = i.nights
        let bedText = plan.map { hhmm($0.target) } ?? "23:30"

        // 1. Slaapregelmaat
        if let p = plan {
            let cons = mean(n.compactMap(\.consistency))
            if (cons ?? 100) < 80 || p.bedSdMin > 45 {
                var why = "De afgelopen \(n.count) nachten viel je gemiddeld om \(hhmm(p.bedMean)) in slaap, maar tussen \(hhmm(p.bedEarliest)) en \(hhmm(p.bedLatest))."
                if let cons { why += " Je slaapregelmaat is \(Int(cons.rounded()))%; boven 80% is goed." }
                var steps = [
                    "Zet vandaag een dagelijkse herinnering om \(hhmm(p.target - 45)): telefoon aan de lader, buiten bereik van je bed.",
                    "Sta elke dag op rond \(hhmm(p.wakeMean)), ook in het weekend (hooguit 30 min later).",
                ]
                steps.append(p.moreLater ? "Lukt het 5 van de 7 avonden? Schuif volgende week een kwartier eerder."
                                         : "Lukt het 5 van de 7 avonden? Houd deze tijd dan vast; dat is je nieuwe ritme.")
                out.append(Improvement(id: "sleep.regular", area: .sleep,
                                       title: "Ga deze week elke avond uiterlijk om \(hhmm(p.target)) naar bed",
                                       why: why, steps: steps,
                                       impact: y(.consistency) + (p.bedSdMin > 60 ? 0.4 : 0.2), generic: false))
            }
        } else {
            out.append(Improvement(id: "sleep.regular", area: .sleep,
                                   title: "Kies één bedtijd voor deze week en houd die 5 avonden aan",
                                   why: "Nog te weinig nachten gemeten (\(n.count) van \(minNights)) voor een persoonlijk doel. Vaste tijden zijn de snelste winst voor slaap en herstel.",
                                   steps: ["Draag de band 3 nachten achter elkaar; daarna rekent de app een doeltijd voor je uit.",
                                           "Kies nu een tijd, bijvoorbeeld 23:30, en zet 45 minuten eerder een herinnering: telefoon weg.",
                                           "Sta elke dag op dezelfde tijd op, ook in het weekend."],
                                   impact: 0.6, generic: true))
        }

        // 2. Uren slaap
        if let p = plan {
            let lastDebt = n.last?.debtMin ?? 0
            let short = p.needMean - p.asleepMean
            if short > 30 || p.asleepMean < 420 {
                let gap = max(short, 420 - p.asleepMean)
                let extra = Double(min(60, max(15, Int((gap / 15).rounded(.up)) * 15)))
                // Eerdere van "doelbedtijd" en "gemiddelde − extra" (op de bedschaal vergelijken i.v.m. middernacht).
                let s = { (m: Int) in (m - 720 + 1440) % 1440 }
                let bed = hhmm(min(s(p.target), s(p.bedMean) - Int(extra)) + 720)
                var why = "Je sliep gemiddeld \(dur(p.asleepMean)) per nacht, terwijl je \(dur(p.needMean)) nodig had."
                if lastDebt >= 30 { why += " Je slaaptekort is nu \(dur(lastDebt))." }
                out.append(Improvement(id: "sleep.hours", area: .sleep,
                                       title: "Slaap deze week \(Int(extra)) minuten langer per nacht",
                                       why: why,
                                       steps: ["Zet je wekker niet later, maar lig om \(bed) in bed.",
                                               "Geen cafeïne (koffie, cola, energiedrank) meer na 14:00.",
                                               "Te kort geslapen? Een dutje van hooguit 20–30 minuten vóór 15:00, niet uitslapen."],
                                       impact: y(.sleepHours) + min(0.5, lastDebt / 120), generic: false))
            }
        }

        // 3. Wakker liggen
        if n.count >= minNights, let eff = mean(n.map(\.efficiency)), eff < 85 {
            let awake = mean(n.map(\.awakeMin)) ?? 0
            out.append(Improvement(id: "sleep.efficiency", area: .sleep,
                                   title: "Lig korter wakker in bed (nu gemiddeld \(dur(awake)) per nacht)",
                                   why: "Je slaapefficiëntie is \(Int(eff.rounded()))%; boven 85–90% is goed.",
                                   steps: ["Lig je langer dan ongeveer 20 minuten wakker: sta op, lees iets bij gedimd licht en ga terug als je slaperig bent.",
                                           "Zet de slaapkamer koel (16–19 °C) en helemaal donker.",
                                           "Ga pas naar bed als je slaperig bent, rond \(bedText); niet een uur eerder om 'in te halen'."],
                                   impact: min(1.0, (85 - eff) / 10 + 0.2), generic: false))
        }

        // 4. Rust-HR-uitschieters (alcohol, laat eten, late training)
        if let base = i.rhrBaseline, n.count >= minNights {
            let high = n.compactMap(\.rhr).filter { $0 >= base + 5 }
            if !high.isEmpty, let avgHigh = mean(high) {
                out.append(Improvement(id: "recovery.rhr", area: .recovery,
                                       title: "Drink deze week geen alcohol van zondag tot en met donderdag",
                                       why: "Op \(high.count) van de laatste \(n.count) nachten lag je rust-HR rond \(Int(avgHigh.rounded())) bpm, \(Int((avgHigh - base).rounded())) boven je normaal (\(Int(base.rounded())) bpm). Alcohol, laat eten en late training zijn de bekendste oorzaken; de app kan niet zien welke het bij jou was.",
                                       steps: ["Drink je toch: hooguit 2 glazen en het laatste glas 3 uur voor bedtijd.",
                                               "Laatste maaltijd uiterlijk 3 uur voor \(bedText).",
                                               "Zware training (zone 4–5) niet later dan 3 uur voor het slapen.",
                                               "Kijk vrijdag in Gezondheidsmonitor of je rust-HR terug is op ~\(Int(base.rounded())) bpm."],
                                       impact: min(1.2, 0.3 * Double(high.count)), generic: false))
            }
        }

        // 5. Te zwaar belast bij slecht herstel
        if let r = n.last?.recovery, r < 34 {
            let recent = i.days.suffix(3).map(\.strain)
            if let s = mean(recent), s >= 12 {
                out.append(Improvement(id: "recovery.rest", area: .recovery,
                                       title: "Houd vandaag een rustige dag: belasting onder 10",
                                       why: "Je herstel is \(r)% en je belasting was de laatste dagen gemiddeld \(String(format: "%.1f", s)).",
                                       steps: ["Alleen wandelen of mobiliteit; geen zone 4–5 (boven \(hrAt(0.8, i)) bpm).",
                                               "Lig vanavond om \(bedText) in bed.",
                                               "Morgen weer groen of geel herstel? Dan kun je weer vol trainen."],
                                       impact: 0.8, generic: false))
            }
        }

        // 6. Matige inspanning (zones 1–3)
        let full = i.days.filter { $0.measuredMin >= fullDayMin }
        let z2lo = hrAt(0.6, i), z2hi = hrAt(0.7, i), z1lo = hrAt(0.5, i), z4lo = hrAt(0.8, i), z5lo = hrAt(0.9, i)
        if full.count >= minDays {
            let z13 = full.map(\.zones13).reduce(0, +) * 7 / Double(full.count)
            if z13 < 150 {
                let deficit = 150 - z13
                let sessions = max(1, min(4, Int((deficit / 30).rounded(.up))))
                let minutes = max(20, round5(deficit / Double(sessions)))
                let days = ["za", "di en za", "di, do en za", "ma, wo, vr en zo"][sessions - 1]
                out.append(Improvement(id: "move.zone2", area: .movement,
                                       title: "Voeg \(sessions)× \(minutes) minuten rustig cardio in zone 2 toe",
                                       why: "Je zat gemiddeld \(dur(z13)) per week in zone 1–3; het advies is minstens 2 u 30 min.",
                                       steps: ["Zone 2 is voor jou \(z2lo)–\(z2hi) bpm: je kunt nog in hele zinnen praten.",
                                               "Zet ze nu vast in je agenda, bijvoorbeeld \(days).",
                                               "Fietsen of stevig wandelen naar werk of boodschappen telt mee zodra je boven \(z1lo) bpm komt."],
                                       impact: y(.zones13), generic: false))
            }
            let z45 = full.map(\.zones45).reduce(0, +) * 7 / Double(full.count)
            if z45 < 25 {
                var why = "Je zat gemiddeld \(dur(z45)) per week in zone 4–5; rond 25 minuten of meer is goed voor je VO₂max"
                why += i.vo2max.map { " (nu geschat \(Int($0.rounded())))." } ?? "."
                out.append(Improvement(id: "move.intervals", area: .movement,
                                       title: "Doe 1× per week 4 × 4 minuten interval boven \(z4lo) bpm",
                                       why: why,
                                       steps: ["10 minuten inlopen, dan 4 × 4 minuten hard (\(z4lo)–\(z5lo) bpm) met 3 minuten rustig ertussen.",
                                               "Kies een dag na een goede nacht (groen of geel herstel).",
                                               "Gaat het 3 weken goed? Maak er 2× per week van."],
                                       impact: y(.zones45) + 0.5 * y(.vo2max) + 0.3 * y(.rhr), generic: false))
            }
        } else {
            out.append(Improvement(id: "move.zone2", area: .movement,
                                   title: "Wandel of fiets deze week 3× 30 minuten in zone 2",
                                   why: "Nog te weinig volledig gemeten dagen (\(full.count) van \(minDays), minstens 16 uur band om) voor een persoonlijk doel.",
                                   steps: ["Zone 2 is voor jou \(z2lo)–\(z2hi) bpm: je kunt nog in hele zinnen praten.",
                                           "Draag de band ook overdag 3 dagen volledig; dan rekent de app je weekminuten uit.",
                                           "Zet de drie momenten nu vast in je agenda."],
                                   impact: 0.5, generic: true))
        }

        // 7. Krachttraining
        if let s = i.strengthMinWeek {
            if s < 90 {
                let src = i.strengthFromActivities ? "Volgens je gelogde activiteiten deed je" : "Je hebt ingevuld dat je"
                out.append(Improvement(id: "move.strength", area: .movement,
                                       title: s < 20 ? "Begin met 2× per week 20 minuten krachttraining" : "Voeg 1 krachtsessie van 30 minuten per week toe",
                                       why: "\(src) \(dur(s)) krachttraining per week; rond 1 u 30 min is het doel.",
                                       steps: ["Basisrondje, 3 keer: 10 squats, 8 push-ups (eventueel op je knieën), 10 lunges per been en 30 seconden plank.",
                                               "Koppel het aan een vast moment, bijvoorbeeld maandag en donderdag direct na het opstaan.",
                                               "Log het in de app als activiteit 'Krachttraining', dan telt het automatisch mee."],
                                       impact: y(.strength), generic: false))
            }
        } else {
            out.append(Improvement(id: "move.strength", area: .movement,
                                   title: "Begin met 2× per week 20 minuten krachttraining",
                                   why: "De app weet nog niet hoeveel krachttraining je doet. Log het als activiteit 'Krachttraining' of vul het in bij je profiel.",
                                   steps: ["Basisrondje, 3 keer: 10 squats, 8 push-ups (eventueel op je knieën), 10 lunges per been en 30 seconden plank.",
                                           "Koppel het aan een vast moment, bijvoorbeeld maandag en donderdag direct na het opstaan.",
                                           "Log elke sessie in de app als activiteit 'Krachttraining'."],
                                   impact: 0.4, generic: true))
        }

        // 8. Stappen
        if let st = i.stepsPerDay {
            if st < 8000 {
                let extra = min(4000, max(1000, Int(((8000 - st) / 500).rounded(.up)) * 500))
                let src = i.stepsMeasured ? "Je iPhone telde de afgelopen dagen gemiddeld" : "Je hebt ingevuld dat je gemiddeld"
                out.append(Improvement(id: "move.steps", area: .movement,
                                       title: "Loop elke dag \(thousands(extra)) stappen extra (ongeveer \(extra / 100) minuten)",
                                       why: "\(src) \(thousands(Int(st.rounded()))) stappen per dag zet; rond 8.000 is het doel.",
                                       steps: ["Wandel 10 minuten direct na de lunch en 10 minuten na het avondeten.",
                                               "Neem de trap en loop rond tijdens telefoongesprekken.",
                                               "Haal je het 5 van de 7 dagen? Doe er volgende week 1.000 bij."],
                                       impact: y(.steps), generic: false))
            }
        } else {
            out.append(Improvement(id: "move.steps", area: .movement,
                                   title: "Wandel elke dag 10 minuten na de lunch en na het avondeten",
                                   why: "De app kan je stappen nog niet lezen. Geef toegang tot Beweging en fitness in de iOS-instellingen of vul je gemiddelde in bij je profiel.",
                                   steps: ["Zet een herinnering direct na lunch en avondeten.",
                                           "Neem de trap en loop rond tijdens telefoongesprekken."],
                                   impact: 0.3, generic: true))
        }

        return out.filter { $0.impact > 0.05 }.sorted { $0.impact > $1.impact }
    }

    public static func impactLabel(_ v: Double) -> String { v >= 1 ? "Grote impact" : v >= 0.4 ? "Middelgrote impact" : "Kleine impact" }
    /// 1–3 stippen
    public static func impactLevel(_ v: Double) -> Int { v >= 1 ? 3 : v >= 0.4 ? 2 : 1 }
}
