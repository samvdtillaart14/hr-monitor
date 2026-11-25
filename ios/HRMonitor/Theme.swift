import SwiftUI
import UIKit
import WhoopScores

/// Centrale stijl (donker, sportief). Waarden volgen het webdashboard; pas ze hier aan en alles volgt.
enum Theme {
    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
    }
    /// Kleur die meegaat met licht/donker.
    static func dyn(_ light: UInt32, _ dark: UInt32, la: Double = 1, da: Double = 1) -> Color {
        func ui(_ v: UInt32, _ a: Double) -> UIColor {
            UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark, da) : ui(light, la) })
    }
    // Tokens uit docs/DESIGN.md (webdashboard); lichte varianten voor de lichte modus.
    static let bg = dyn(0xF2F3F5, 0x050607)
    static let card = dyn(0xFFFFFF, 0x14171B, la: 0.9, da: 0.72)
    static let cardHi = dyn(0xE6E8EC, 0x1E2228)
    static let line = dyn(0x000000, 0xFFFFFF, la: 0.08, da: 0.08)
    static let text = dyn(0x111418, 0xF2F4F6)
    static let muted = dyn(0x5F6873, 0x8A939E)
    static let accent = dyn(0x00A86B, 0x00F19F)
    static let hr = dyn(0xE5354A, 0xFF4D5E)
    /// Voor subtiele vlakken (was wit met lage dekking).
    static func faint(_ a: Double) -> Color { dyn(0x000000, 0xFFFFFF, la: a, da: a) }
    static let radius: CGFloat = 20
    static let gap: CGFloat = 14
    static let spring = Animation.easeOut(duration: 0.6)
    static let ringAnim = Animation.easeOut(duration: 0.9)

    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy) }
    static let label = Font.system(size: 11, weight: .semibold)

    static let zones: [(name: String, color: Color, upTo: Double)] = [
        ("Rust", hex(0x6B7280), 0.5), ("Zone 1", hex(0x3B82F6), 0.6), ("Zone 2", hex(0x00F19F), 0.7),
        ("Zone 3", hex(0xFACC15), 0.8), ("Zone 4", hex(0xFB923C), 0.9), ("Zone 5", hex(0xFF4D5E), 9)
    ]
    /// Zone 0–5 op basis van de hartslagreserve, met max- en rust-HR uit je profiel (zelfde zones als de belasting).
    static func zoneIndex(_ bpm: Int, profile: Calibration.Profile = UserProfile.current) -> Int {
        WhoopScores.hrZone(Double(bpm), profile)
    }
    static func zone(_ bpm: Int, profile: Calibration.Profile = UserProfile.current) -> (name: String, color: Color, frac: Double) {
        let z = zones[zoneIndex(bpm, profile: profile)]
        return (z.name, z.color, Double(bpm) / profile.maxHr)
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    var index = 0
    var info: String? = nil
    var content: Content
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String? = nil, index: Int = 0, info: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.index = index
        self.info = info ?? title.flatMap { CardInfo.text[$0] }
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(L(title).uppercased()).font(Theme.label).foregroundStyle(Theme.muted).tracking(2) }
            content
            if let info {
                Text(info).font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line))
        .opacity(shown || reduceMotion ? 1 : 0).offset(y: shown || reduceMotion ? 0 : 40)
        .onAppear { withAnimation(.easeOut(duration: 0.9).delay(0.08 * Double(index))) { shown = true } }
    }
}

/// Eén zin uitleg in gewone taal per kaart, op kaarttitel. Kaarten zonder titel geven `info:` zelf mee.
enum CardInfo {
    static let text: [String: String] = [
        "Afgelopen nacht": "Hoe lang je sliep en hoe dat zich verhoudt tot wat je lichaam nodig had.",
        "Slaapfases": "Hoeveel tijd je in lichte, diepe en droomslaap doorbracht.",
        "Uren vs. nodig": "Hoeveel procent van je slaapbehoefte je echt hebt geslapen.",
        "Regelmaat": "Hoe gelijk je bedtijd en opstaantijd zijn aan die van de dagen ervoor.",
        "Slaapefficiëntie": "Welk deel van je tijd in bed je echt sliep.",
        "Slaapstress": "Hoeveel van de nacht je lichaam nog in de stressstand stond.",
        "Slaapprestatie": "Je totale slaapscore: lengte, regelmaat en efficiëntie samen.",
        "Herstellende slaap": "Diepe slaap plus droomslaap: de slaap waarin je lichaam echt herstelt.",
        "Tijd in bed": "Van naar bed gaan tot opstaan, per nacht.",
        "Efficiëntie": "Welk deel van je tijd in bed je echt sliep.",
        "Slaaptekort": "Slaap die je de afgelopen nachten tekort bent gekomen.",
        "Hoge slaapstress": "Deel van de nacht waarin je lichaam niet tot rust kwam.",
        "Herstel": "Hoe klaar je lichaam is voor inspanning, vergeleken met je eigen normaal.",
        "Hartslagvariabiliteit": "Hogere HRV dan normaal betekent meestal dat je goed hersteld bent.",
        "Rusthartslag": "Een rust-HR hoger dan normaal wijst vaak op vermoeidheid of ziekte.",
        "Ademfrequentie": "Ademhalingen per minuut in je slaap; een stijging kan op ziekte wijzen.",
        "Belasting": "Hoe zwaar je hart en lichaam vandaag hebben gewerkt (0 tot 21).",
        "Hartslagzones 1–3": "Rustige inspanning zoals wandelen en licht sporten.",
        "Hartslagzones 4–5": "Zware inspanning waarbij je hart hard werkt.",
        "Energie (geschat, kcal)": "Een schatting van wat je vandaag verbrandde.",
        "Hartslag": "Je hartslag op dit moment, live van de band.",
        "Tijd per zone": "Hoe lang je vandaag in elke hartslagzone zat.",
        "Hartslag · laatste 5 min": "Het verloop van je hartslag in de laatste vijf minuten.",
        "Verouderingstempo": "Hoe snel je lichaam veroudert; 100% is precies even snel als de kalender.",
        "Leeftijd per week": "Je geschatte lichaamsleeftijd per week.",
        "Verbeterpunten": "Wat je het meest helpt om beter te slapen en te herstellen.",
        "Planning": "Je bedtijd en wekker voor de komende nachten.",
        "Slaapbehoefte vannacht": "Hoeveel slaap je vannacht nodig hebt, inclusief inhalen van tekort.",
        "Bandwekker": "De band trilt je wakker op de ingestelde tijd.",
        "Band": "Verbinding en batterij van je band.",
        "Je ritme": "Je gewone bed- en opstaantijden, waar de planning op rekent.",
        "Laatste 24 uur": "Je stressniveau over de afgelopen dag.",
        "Vitale waarden": "Je nachtwaarden vergeleken met je eigen normaal.",
        "Stress vandaag": "Je stressniveau door de dag; het grijze vlak is je slaap.",
        "Belasting & herstel · 7 dagen": "Of je inspanning en je herstel deze week in balans waren.",
        "Dashboard": "Vandaag naast je eigen normaal (gemiddelde van je eerdere dagen).",
        "Route": "De route die je hebt afgelegd.",
        "Per kilometer": "Je tempo en hartslag per kilometer.",
    ]
}

/// Grote hartslagring met zonekleur, vloeiend geanimeerd, en een kloppend hart op het ritme van de HR.
struct HeartRing: View {
    let bpm: Int?
    @State private var beat = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let z = Theme.zone(bpm ?? 0)
        ZStack {
            Circle().stroke(Theme.line, lineWidth: 18)
            Circle()
                .trim(from: 0, to: bpm == nil ? 0 : min(1, max(0.04, z.frac)))
                .stroke(AngularGradient(colors: [z.color.opacity(0.4), z.color], center: .center),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: z.color.opacity(0.6), radius: 12)
                .animation(Theme.ringAnim, value: bpm)
            VStack(spacing: 2) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 22)).foregroundStyle(bpm == nil ? Theme.muted : z.color)
                    .scaleEffect(beat ? 1.18 : 1)
                Text(bpm.map(String.init) ?? "--")
                    .font(Theme.number(84)).foregroundStyle(Theme.text)
                    .monospacedDigit().contentTransition(.numericText())
                    .animation(Theme.spring, value: bpm)
                Text(bpm == nil ? "BPM" : "BPM · \(z.name.uppercased())")
                    .font(Theme.label).foregroundStyle(bpm == nil ? Theme.muted : z.color).tracking(2)
            }
        }
        .frame(width: 270, height: 270)
        .task(id: bpm) {
            // Hartslag-animatie op het ritme van de gemeten HR.
            guard let bpm, bpm > 0, !reduceMotion else { return }
            let period = 60.0 / Double(bpm)
            while !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.12)) { beat = true }
                try? await Task.sleep(nanoseconds: 120_000_000)
                withAnimation(.easeIn(duration: 0.25)) { beat = false }
                try? await Task.sleep(nanoseconds: UInt64(max(0.15, period - 0.12) * 1e9))
            }
        }
    }
}

