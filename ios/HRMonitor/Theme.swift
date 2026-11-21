import SwiftUI

/// Centrale stijl (donker, sportief). Waarden volgen het webdashboard; pas ze hier aan en alles volgt.
enum Theme {
    static let bg = Color(red: 0.02, green: 0.03, blue: 0.04)
    static let card = Color(red: 0.07, green: 0.08, blue: 0.10)
    static let cardHi = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let line = Color.white.opacity(0.08)
    static let text = Color.white
    static let muted = Color.white.opacity(0.55)
    static let accent = Color(red: 0.16, green: 0.86, blue: 0.55)   // groen
    static let hr = Color(red: 1.0, green: 0.27, blue: 0.33)        // rood
    static let blue = Color(red: 0.27, green: 0.62, blue: 1.0)
    static let radius: CGFloat = 20
    static let spring = Animation.spring(response: 0.55, dampingFraction: 0.82)

    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static let label = Font.system(size: 11, weight: .semibold).width(.expanded)

    /// Hartslagzones op basis van HRmax (standaard 190).
    static func zone(_ bpm: Int, max: Int = 190) -> (name: String, color: Color, frac: Double) {
        let f = Double(bpm) / Double(max)
        switch f {
        case ..<0.5: return ("Rust", blue, f)
        case ..<0.6: return ("Zone 1", Color(red: 0.55, green: 0.75, blue: 1), f)
        case ..<0.7: return ("Zone 2", accent, f)
        case ..<0.8: return ("Zone 3", Color(red: 1, green: 0.82, blue: 0.2), f)
        case ..<0.9: return ("Zone 4", Color(red: 1, green: 0.55, blue: 0.2), f)
        default:     return ("Zone 5", hr, f)
        }
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    var content: Content
    @State private var shown = false

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title.uppercased()).font(Theme.label).foregroundStyle(Theme.muted).tracking(1) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line))
        .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 16)
        .onAppear { withAnimation(Theme.spring.delay(0.05)) { shown = true } }
    }
}

/// Grote hartslagring met zonekleur, vloeiend geanimeerd, en een kloppend hart op het ritme van de HR.
struct HeartRing: View {
    let bpm: Int?
    @State private var beat = false
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
                .animation(Theme.spring, value: bpm)
            VStack(spacing: 2) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 22)).foregroundStyle(Theme.hr)
                    .scaleEffect(beat ? 1.18 : 1)
                Text(bpm.map(String.init) ?? "--")
                    .font(Theme.number(72)).foregroundStyle(Theme.text)
                    .monospacedDigit().contentTransition(.numericText())
                    .animation(Theme.spring, value: bpm)
                Text(bpm == nil ? "BPM" : "BPM · \(z.name.uppercased())")
                    .font(Theme.label).foregroundStyle(bpm == nil ? Theme.muted : z.color).tracking(1)
            }
        }
        .frame(width: 250, height: 250)
        .task(id: bpm) {
            // Hartslag-animatie op het ritme van de gemeten HR.
            guard let bpm, bpm > 0 else { return }
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
