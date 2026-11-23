import Foundation

/// Tekst voor het ochtendoverzicht: één hoofdregel, per kaart één waarde en één zin in gewone taal,
/// altijd vergeleken met je eigen gemiddelde. Geen decimalen.
struct MorningSummary: Equatable {
    struct Card: Equatable { var title: String; var value: String; var sentence: String }

    var headline: String
    var sentence: String
    var recovery: Int?
    var cards: [Card]
    var advice: String

    /// Waarden van afgelopen nacht en je eigen gemiddelden (nil = nog niet genoeg nachten).
    struct Input {
        var recovery: Int?
        var asleepMin: Int
        var debtMin = 0
        var hrv: Double?, rhr: Double?
        var disturbances = 0
        var hrvBase: Double?, rhrBase: Double?, sleepBase: Double?
        var baseNights = 0
    }

    static func hm(_ m: Int) -> String { "\(m / 60):" + String(format: "%02d", abs(m % 60)) }

    static func make(_ i: Input) -> MorningSummary {
        let rec = i.recovery
        let headline: String
        switch rec {
        case let r? where r >= 67: headline = "Goed hersteld"
        case let r? where r >= 34: headline = "Redelijk hersteld"
        case .some: headline = "Weinig hersteld"
        case nil: headline = "Herstel nog onbekend"
        }

        // Hoofdzin: wat bepaalt het herstel het meest, vergeleken met jezelf.
        var sentence = "Nog te weinig nachten om met je eigen gemiddelde te vergelijken."
        if let hrv = i.hrv, let base = i.hrvBase, base > 0 {
            let pct = Int(((hrv / base - 1) * 100).rounded())
            if abs(pct) < 5 { sentence = "Je hartslagvariatie is normaal voor jou." }
            else { sentence = "Je hartslagvariatie is \(abs(pct))% \(pct > 0 ? "hoger" : "lager") dan normaal voor jou." }
        }

        var cards: [Card] = []
        // Slaap
        var sleepLine: String
        if let base = i.sleepBase {
            let d = i.asleepMin - Int(base.rounded())
            sleepLine = abs(d) < 10 ? "Net zo lang als je gemiddelde (\(hm(Int(base.rounded()))))."
                : "\(hm(abs(d))) \(d > 0 ? "langer" : "korter") dan je gemiddelde (\(hm(Int(base.rounded()))))."
        } else {
            sleepLine = "Na een paar nachten zie je hier je gemiddelde."
        }
        if i.debtMin >= 30 { sleepLine += " Slaapschuld: \(hm(i.debtMin))." }
        cards.append(Card(title: "Slaap", value: hm(i.asleepMin), sentence: sleepLine))

        // Hart in rust
        if let rhr = i.rhr {
            let r = Int(rhr.rounded())
            var line = "Je hart in rust, gemeten tijdens je slaap."
            if let b = i.rhrBase {
                let d = r - Int(b.rounded())
                line = d == 0 ? "Precies je gemiddelde." : d < 0 ? "\(-d) slagen lager dan normaal: goed teken."
                    : d >= 3 ? "\(d) slagen hoger dan normaal: je lichaam werkt nog hard." : "\(d) slagen hoger dan normaal."
            }
            cards.append(Card(title: "Rusthartslag", value: "\(r)", sentence: line))
        }

        // Wakker geworden
        let w = i.disturbances
        cards.append(Card(title: "Wakker geworden", value: "\(w)×",
                          sentence: w <= 2 ? "Rustige nacht." : w <= 6 ? "Een paar keer kort wakker, dat is normaal." : "Onrustige nacht."))

        // Eén advies
        let advice: String
        if i.debtMin >= 60 {
            advice = "Ga vanavond eerder naar bed om je slaapschuld van \(hm(i.debtMin)) in te halen."
        } else {
            switch rec {
            case let r? where r >= 67: advice = "Je lichaam kan vandaag een zware training aan."
            case let r? where r >= 34: advice = "Rustig tot gemiddeld bewegen gaat prima; zware training kan beter morgen."
            case .some: advice = "Neem het vandaag rustig aan en ga op tijd naar bed."
            case nil: advice = "Draag de band elke nacht; na een paar nachten krijg je een herstelscore."
            }
        }
        return MorningSummary(headline: headline, sentence: sentence, recovery: rec, cards: cards, advice: advice)
    }
}
