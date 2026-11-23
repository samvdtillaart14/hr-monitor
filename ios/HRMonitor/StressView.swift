import SwiftUI
import Charts

/// Stressmonitor: eigen maat (hartslag boven rust-HR, 12 bpm = 1 punt, 0–3) per 5 minuten.
struct StressDetailView: View {
    @EnvironmentObject var store: DayStore
    @ObservedObject var model: ScoreModel

    struct Pt { let t: Date; let v: Double; let active: Bool; let asleep: Bool }
    @State private var pts: [Pt] = []
    @State private var today: [[Int]] = []     // [dag, niet-actief, slaap] × [laag, middel, hoog] in min
    @State private var typical: [[Int]]? = nil

    private static let colors = [Theme.hex(0x6FA6E8), DV.good, DV.poor]
    private static let names = ["Laag", "Middel", "Hoog"]

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.gap) {
                gauge
                chart
                if today.count == 3 {
                    breakdown("Hele dag", "Stress over de hele dag, inclusief slaap en activiteit.", 0, 1)
                    breakdown("Buiten activiteit", "Zonder momenten met beweging of hartslag in zone 1+.", 1, 2)
                    breakdown("Slaap", "Alleen tijdens je slaap.", 2, 3)
                }
                Text("Eigen maat: hartslag boven je rust-HR (12 bpm = 1 punt), per 5 minuten. Vergelijking met dezelfde weekdag vorige week, zodra die is gemeten.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }.padding()
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Stressmonitor").navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: compute)
    }

    private var current: Double? { pts.last?.v }
    static func level(_ v: Double) -> Int { v >= 2 ? 2 : v >= 1 ? 1 : 0 }

    private var gauge: some View {
        let v = current ?? 0
        return ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(AngularGradient(colors: [Self.colors[0], DV.good, Theme.zones[3].color, DV.poor], center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(135))
            Capsule().fill(.white).frame(width: 5, height: 26).offset(y: -112)
                .rotationEffect(.degrees(-135 + 270 * v / 3))
            // Schaal: 0 links onder, 3 rechts onder.
            HStack {
                Text("0"); Spacer(); Text("3")
            }
            .font(.caption.bold()).foregroundStyle(Theme.muted).frame(width: 170).offset(y: 100)
            VStack(spacing: 4) {
                Text(current.map { String(format: "%.0f", $0) } ?? "--").font(Theme.number(60)).monospacedDigit()
                Text(current.map { Self.names[Self.level($0)].uppercased() } ?? "GEEN DATA").font(Theme.label).tracking(2)
                    .foregroundStyle(current.map { Self.colors[Self.level($0)] } ?? Theme.muted)
                if let t = pts.last?.t { Text(DV.clock(t)).font(.caption).foregroundStyle(Theme.muted) }
            }
        }
        .frame(width: 240, height: 240).frame(maxWidth: .infinity).padding(.top, 10)
    }

    private var chart: some View {
        Card(title: "Laatste 24 uur") {
            Chart {
                if let n = model.lastNight {
                    RectangleMark(xStart: .value("a", n.onset), xEnd: .value("b", n.wake)).foregroundStyle(DV.sleep.opacity(0.12))
                }
                ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("t", p.t), y: .value("s", p.v))
                        .foregroundStyle(LinearGradient(colors: [DV.good, Theme.zones[3].color], startPoint: .bottom, endPoint: .top))
                }
            }
            .chartYScale(domain: 0...3)
            .chartXScale(domain: Date().addingTimeInterval(-86400)...Date())
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
            .frame(height: 180)
        }
    }

    private func breakdown(_ title: String, _ sub: String, _ i: Int, _ idx: Int) -> some View {
        let cur = today[i], tot = max(1, cur.reduce(0, +))
        let typ = typical?[i]
        return Card(title: title, index: idx) {
            GeometryReader { g in
                VStack(spacing: 4) {
                    stack(cur, g.size.width, 12, 1)
                    if let typ, typ.reduce(0, +) > 0 { stack(typ, g.size.width, 6, 0.55) }
                }
            }.frame(height: typ == nil ? 12 : 22)
            HStack(alignment: .top) {
                ForEach(0..<3, id: \.self) { k in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(DV.hm(Double(cur[k]))).font(Theme.number(20)).monospacedDigit()
                        if let typ, typ[k] > 0 {
                            let pct = Int((100 * Double(cur[k] - typ[k]) / Double(typ[k])).rounded())
                            Label("\(abs(pct))%", systemImage: pct >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                                .font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.line, in: RoundedRectangle(cornerRadius: 5))
                        }
                        Label(Self.names[k].uppercased(), systemImage: "square.fill").font(Theme.label).foregroundStyle(Self.colors[k])
                        Text("\(100 * cur[k] / tot)%").font(.caption).foregroundStyle(Theme.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(sub + (typ == nil ? " Vergelijking volgt na een week meten." : " Onderste balk: zelfde weekdag vorige week."))
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private func stack(_ m: [Int], _ w: CGFloat, _ h: CGFloat, _ a: Double) -> some View {
        let tot = CGFloat(max(1, m.reduce(0, +)))
        return HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { k in
                if m[k] > 0 { Rectangle().fill(Self.colors[k].opacity(a)).frame(width: max(2, (w - 4) * CGFloat(m[k]) / tot), height: h) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: berekening

    private func compute() {
        let now = Date(), from = now.addingTimeInterval(-86400)
        let cal = Calendar.current
        let raw = (store.samples(day: cal.date(byAdding: .day, value: -1, to: now)!) + store.samples(day: now))
            .filter { Double($0.t) >= from.timeIntervalSince1970 }
        let rhr = model.lastNight?.metrics.rhr ?? 60
        pts = Self.buckets(raw, rhr: rhr, sleep: model.lastNight.map { ($0.r.onset, $0.r.wake) })
        today = split(Self.buckets(store.samples(day: now), rhr: rhr, sleep: model.lastNight.map { ($0.r.onset, $0.r.wake) }))
        let lastWeek = cal.date(byAdding: .day, value: -7, to: now)!
        let lw = store.samples(day: lastWeek)
        let lwNight = model.nights.first { cal.isDate($0.date, inSameDayAs: lastWeek) }
        typical = lw.count > 3600 ? split(Self.buckets(lw, rhr: lwNight?.metrics.rhr ?? rhr, sleep: lwNight.map { ($0.r.onset, $0.r.wake) })) : nil
    }

    /// Stress per 5 minuten (0–3). Ook gebruikt door het tabblad Vandaag, zodat beide schermen hetzelfde tonen.
    static func buckets(_ s: [DayStore.Sample], rhr: Double, sleep: (Double, Double)?) -> [Pt] {
        var b: [UInt32: (sum: Double, n: Int, act: Int)] = [:]
        let profile = UserProfile.current
        for x in s where x.hr > 0 {
            let k = x.t / 300 * 300
            let active = (x.motion ?? 0) >= 0.05 || Theme.zoneIndex(x.hr, profile: profile) >= 1
            b[k, default: (0, 0, 0)].sum += max(0, min(3, (Double(x.hr) - rhr) / 12))
            b[k, default: (0, 0, 0)].n += 1
            if active { b[k, default: (0, 0, 0)].act += 1 }
        }
        return b.keys.sorted().compactMap { k in
            let e = b[k]!
            guard e.n >= 30 else { return nil }
            let t = Double(k)
            let asleep = sleep.map { t >= $0.0 && t < $0.1 } ?? false
            return Pt(t: Date(timeIntervalSince1970: t), v: e.sum / Double(e.n), active: e.act * 2 > e.n, asleep: asleep)
        }
    }

    private func split(_ p: [Pt]) -> [[Int]] {
        var r = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
        for x in p {
            let l = Self.level(x.v)
            r[0][l] += 5
            if !x.active { r[1][l] += 5 }
            if x.asleep { r[2][l] += 5 }
        }
        return r
    }
}
