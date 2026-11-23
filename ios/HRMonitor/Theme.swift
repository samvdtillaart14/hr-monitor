import SwiftUI
import WhoopScores

/// Centrale stijl (donker, sportief). Waarden volgen het webdashboard; pas ze hier aan en alles volgt.
enum Theme {
    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
    }
    // Tokens uit docs/DESIGN.md (webdashboard).
    static let bg = hex(0x050607)
    static let card = hex(0x14171B, 0.72)
    static let cardHi = hex(0x1E2228)
    static let line = Color.white.opacity(0.08)
    static let text = hex(0xF2F4F6)
    static let muted = hex(0x8A939E)
    static let accent = hex(0x00F19F)
    static let hr = hex(0xFF4D5E)
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
    var content: Content
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String? = nil, index: Int = 0, @ViewBuilder content: () -> Content) {
        self.title = title
        self.index = index
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title.uppercased()).font(Theme.label).foregroundStyle(Theme.muted).tracking(2) }
            content
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

/// Tijd per hartslagzone in deze sessie, als gestapelde balk + legenda.
struct ZoneTime: View {
    let samples: [BLEManager.Sample]
    private var secs: [Int] {
        var s = Array(repeating: 0, count: Theme.zones.count)
        let p = UserProfile.current
        for x in samples { s[Theme.zoneIndex(x.bpm, profile: p)] += 1 }
        return s
    }
    var body: some View {
        let secs = self.secs
        let total = max(1, secs.reduce(0, +))
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(secs.indices, id: \.self) { i in
                        if secs[i] > 0 {
                            RoundedRectangle(cornerRadius: 4).fill(Theme.zones[i].color)
                                .frame(width: max(4, g.size.width * CGFloat(secs[i]) / CGFloat(total)))
                        }
                    }
                }
            }
            .frame(height: 12)
            .animation(Theme.spring, value: total)
            ForEach(secs.indices, id: \.self) { i in
                if secs[i] > 0 {
                    HStack {
                        Circle().fill(Theme.zones[i].color).frame(width: 8, height: 8)
                        Text(Theme.zones[i].name).font(.subheadline)
                        Spacer()
                        Text("\(secs[i] / 60):\(String(format: "%02d", secs[i] % 60))").font(.subheadline).monospacedDigit().foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }
}

/// Klein Pulse-logo linksboven op de tabbladen.
extension View {
    func pulseLogo() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Image("PulseLogo").resizable().scaledToFit().frame(height: 24)
                    .foregroundStyle(.white).accessibilityLabel("Pulse")
            }
        }
    }
}
