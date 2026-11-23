import SwiftUI
import WhoopScores

/// Slaapgewoontes: slaapschuld, regelmaat, tijd tot inslapen en keren wakker.
/// Hele getallen, steeds vergeleken met je eigen gemiddelde van de vorige nachten, één zin uitleg per regel.
struct SleepHabitsCard: View {
    let n: Night
    let prev: [Night]

    var body: some View {
        Card(title: "Slaapgewoontes", index: 2) {
            item("Slaapschuld (7 nachten)", value: n.weekDebtMin, typical: avg(prev.map(\.weekDebtMin)),
                 text: dur, lowerIsBetter: true,
                 uitleg: "Hoeveel slaap je deze week tekortkwam ten opzichte van wat je lichaam nodig had.")
            Divider().overlay(Theme.line)
            item("Regelmaat", value: n.consistency, typical: avg(prev.compactMap(\.consistency)),
                 text: { "\(Int($0.rounded()))%" }, lowerIsBetter: false,
                 uitleg: "Hoe goed je bed- en opstatijd overeenkomen met de nachten ervoor.")
            Divider().overlay(Theme.line)
            item("Tijd tot inslapen", value: n.latencyMin.map(Double.init),
                 typical: avg(prev.compactMap { $0.latencyMin.map(Double.init) }),
                 text: { "\(Int($0.rounded())) min" }, lowerIsBetter: true,
                 uitleg: n.latencyMin == nil
                    ? "Onbekend: je telefoon was niet aan in de twee uur voor het slapen."
                    : "Van het moment dat je scherm uitging tot de band zag dat je sliep.")
            Divider().overlay(Theme.line)
            item("Keren wakker", value: Double(n.r.disturbances), typical: avg(prev.map { Double($0.r.disturbances) }),
                 text: { "\(Int($0.rounded()))×" }, lowerIsBetter: true,
                 uitleg: "Hoe vaak je 's nachts wakker werd, ook kort.")
        }
    }

    private func avg(_ v: [Double]) -> Double? { DV.mean(v.filter(\.isFinite)) }

    private func dur(_ m: Double) -> String {
        let t = max(0, Int(m.rounded()))
        return t >= 60 ? "\(t / 60) u \(t % 60) min" : "\(t) min"
    }

    @ViewBuilder
    private func item(_ title: String, value: Double?, typical: Double?, text: @escaping (Double) -> String,
                      lowerIsBetter: Bool, uitleg: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased()).font(Theme.label).tracking(1.5)
                Spacer()
                Text(value.map(text) ?? "--").font(Theme.number(22)).monospacedDigit()
            }
            if let value, let typical {
                let better = lowerIsBetter ? value < typical : value > typical
                let same = text(value) == text(typical)
                Text(same ? "Gelijk aan je gemiddelde" : "Jouw gemiddelde: \(text(typical))")
                    .font(.caption).foregroundStyle(same ? Theme.muted : (better ? DV.good : DV.poor))
            }
            Text(uitleg).font(.caption).foregroundStyle(Theme.muted)
        }.padding(.vertical, 4)
    }
}
