import SwiftUI
import Charts
import WhoopScores

// MARK: gedeelde bouwstenen

enum DV {
    static let sleep = Theme.hex(0x8FA8C8)
    static let poor = Theme.hex(0xF5A742), fair = Theme.hex(0x9AA1A9), good = Theme.hex(0x6BEAA3)
    static let wakeC = Theme.hex(0xD6D9DD), lightC = Theme.hex(0xA5A0EA), deepC = Theme.hex(0xEE9BEF), remC = Theme.hex(0xA45CE0)
    static let strainC = Theme.zones[1].color

    static func hm(_ min: Double) -> String {
        guard min.isFinite else { return "--" }
        let m = Int(min.rounded()); return "\(m / 60):\(String(format: "%02d", abs(m % 60)))"
    }
    /// Datums altijd in het Nederlands, ook als de iPhone op Engels staat.
    static let nl = Locale(identifier: "nl_NL")
    static func clock(_ d: Date) -> String { d.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: nl)) }
    static func recoveryColor(_ r: Int?) -> Color {
        guard let r else { return Theme.muted }
        return r >= 67 ? Theme.accent : r >= 34 ? Theme.zones[3].color : Theme.hr
    }
    static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
    static func sd(_ v: [Double]) -> Double? {
        guard v.count >= 2, let m = mean(v) else { return nil }
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - 1)).squareRoot()
    }
}

enum Rating: Int { case poor, fair, optimal
    var color: Color { [DV.poor, DV.fair, DV.good][rawValue] }
    var name: String { ["Matig", "Voldoende", "Optimaal"][rawValue] }
    static func of(_ v: Double?, optimal: Double, fair: Double, higherIsBetter: Bool = true) -> Rating? {
        guard let v, v.isFinite else { return nil }
        if higherIsBetter { return v >= optimal ? .optimal : v >= fair ? .fair : .poor }
        return v <= optimal ? .optimal : v <= fair ? .fair : .poor
    }
}

struct RatingBar: View {
    let r: Rating?
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(r?.rawValue == i ? r!.color : Theme.line).frame(width: 22, height: 4)
            }
        }
    }
}

struct BigRing: View {
    let value: Double?
    let text: String
    let label: String
    let color: Color
    @State private var shown = false
    var body: some View {
        ZStack {
            Circle().stroke(Theme.line, lineWidth: 14)
            Circle().trim(from: 0, to: shown ? min(1, max(0, value ?? 0)) : 0)
                .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90)).shadow(color: color.opacity(0.45), radius: 10)
            VStack(spacing: 4) {
                Text(text).font(Theme.number(64)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                Text(label.uppercased()).font(Theme.label).tracking(2.5).multilineTextAlignment(.center)
            }.padding(30)
        }
        .frame(width: 230, height: 230).frame(maxWidth: .infinity).padding(.vertical, 8)
        .onAppear { withAnimation(Theme.ringAnim.delay(0.1)) { shown = true } }
    }
}

/// Rij "vandaag vs. eerdere dagen" met pijl; groen als de verandering gunstig is.
struct CompareRow: View {
    let icon: String, title: String, value: String
    var baseline: String? = nil
    var delta: Double? = nil
    var higherIsBetter: Bool? = true
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.muted).frame(width: 24)
            Text(title.uppercased()).font(Theme.label).tracking(1.5)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).font(Theme.number(24)).monospacedDigit()
                if let baseline { Text(baseline).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted).monospacedDigit() }
            }
            arrow.frame(width: 14)
        }
        .padding(.vertical, 6)
    }
    @ViewBuilder private var arrow: some View {
        if let delta, abs(delta) > 1e-6 {
            let up = delta > 0
            let good = higherIsBetter.map { $0 == up }
            Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.caption2)
                .foregroundStyle(good == nil ? Theme.muted : good! ? DV.good : DV.poor)
        } else {
            Circle().fill(Theme.muted).frame(width: 6, height: 6)
        }
    }
}

/// Weektrend als staafdiagram (of lijn), met waarde boven elke dag; vandaag gemarkeerd.
struct TrendCard: View {
    let title: String
    let points: [(Date, Double?)]
    var line = false
    var domain: ClosedRange<Double>? = nil
    var color: (Double) -> Color = { _ in DV.sleep }
    var label: (Double) -> String = { "\(Int($0.rounded()))" }
    var index = 0
    var body: some View {
        Card(title: title, index: index) {
            let pts = points.compactMap { p in p.1.map { (p.0, $0) } }
            if pts.isEmpty {
                Text("Nog geen data").font(.subheadline).foregroundStyle(Theme.muted)
            } else {
                Chart {
                    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                        if line {
                            LineMark(x: .value("Dag", p.0, unit: .day), y: .value("v", p.1))
                                .foregroundStyle(DV.sleep).symbol(.circle)
                                .annotation(position: .top) { Text(label(p.1)).font(.caption2.weight(.semibold)).foregroundStyle(DV.sleep) }
                        } else {
                            BarMark(x: .value("Dag", p.0, unit: .day), y: .value("v", p.1), width: 18)
                                .foregroundStyle(color(p.1)).cornerRadius(3)
                                .annotation(position: .top) { Text(label(p.1)).font(.caption2.weight(.semibold)).foregroundStyle(color(p.1)) }
                        }
                    }
                }
                .chartXScale(domain: weekDomain)
                .chartYScale(domain: domain ?? 0...((pts.map(\.1).max() ?? 1) * 1.25 + 0.001))
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: true) } }
                .frame(height: 170)
            }
        }
    }
    private var weekDomain: ClosedRange<Date> {
        let cal = Calendar.current, t = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: -6, to: t)!...cal.date(byAdding: .day, value: 1, to: t)!
    }
}

struct StatusPill: View {
    let text: String
    let ok: Bool?
    var body: some View {
        let c = ok == nil ? Theme.muted : ok! ? DV.good : DV.poor
        Label(text, systemImage: ok == false ? "exclamationmark" : "checkmark")
            .font(.caption.weight(.semibold)).foregroundStyle(c)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(c.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}

private func detailScroll<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
    ScrollView { VStack(spacing: Theme.gap) { c() }.padding() }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
}

// MARK: Slaap

struct SleepDetailView: View {
    @ObservedObject var model: ScoreModel

    @AppStorage("ui.sleepDetails") private var showDetails = false
    @AppStorage(Display.sleepStages) private var showStages = true
    @AppStorage("ui.sleepTrends") private var showTrends = false
    private var n: Night? { model.lastNight ?? model.nights.last }
    private var prev: [Night] { Array(model.nights.dropLast()) }

    var body: some View {
        detailScroll("Slaap") {
            if let n {
                BigRing(value: n.performance.map { $0 / 100 }, text: n.performance.map { "\(Int($0.rounded()))%" } ?? "--",
                        label: "Slaap\nprestatie", color: DV.sleep)
                contributors(n)
                lastNight(n)
                if showStages { stages(n) }
                Collapsible(title: "Details", open: $showDetails) {
                    needed(n)
                    consistency(n)
                    efficiency(n)
                    stress(n)
                }
                Collapsible(title: "Weektrends", open: $showTrends) { trends }
                Text("Eigen berekeningen (scores-module), geen officiële Whoop-scores. Slaapfases worden geschat uit hartslag, HRV en beweging; vergelijkingen gebruiken de nachten die deze app heeft opgeslagen (max. 7).")
                    .font(.caption).foregroundStyle(Theme.muted)
            } else {
                Text("Nog geen nacht gemeten. Laat de app 's nachts verbonden met de band (of laat de Whoop-app synchroniseren terwijl Pulse meeluistert).")
                    .foregroundStyle(Theme.muted).padding(.top, 40)
            }
        }
    }

    private func contributors(_ n: Night) -> some View {
        Card(index: 1) {
            row("moon.zzz", "Uren vs. nodig", n.sufficiency, Rating.of(n.sufficiency, optimal: 85, fair: 70))
            Divider().overlay(Theme.line)
            row("calendar", "Regelmaat", n.consistency, Rating.of(n.consistency, optimal: 80, fair: 70))
            Divider().overlay(Theme.line)
            row("bed.double", "Efficiëntie", n.efficiency, Rating.of(n.efficiency, optimal: 90, fair: 80))
            Divider().overlay(Theme.line)
            row("gauge.with.needle", "Hoge slaapstress", n.highStressPct, Rating.of(n.highStressPct, optimal: 5, fair: 15, higherIsBetter: false))
            HStack(spacing: 14) {
                ForEach([Rating.poor, .fair, .optimal], id: \.rawValue) { r in
                    HStack(spacing: 6) { Capsule().fill(r.color).frame(width: 14, height: 4); Text(r.name) }
                }
            }.font(.caption).foregroundStyle(Theme.muted).padding(.top, 4)
        }
    }

    private func row(_ icon: String, _ t: String, _ v: Double?, _ r: Rating?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.muted).frame(width: 24)
            Text(t.uppercased()).font(Theme.label).tracking(1.5)
            Spacer()
            RatingBar(r: r)
            Text(v.map { "\(Int($0.rounded()))%" } ?? "--").font(Theme.number(22)).monospacedDigit().frame(width: 70, alignment: .trailing)
        }.padding(.vertical, 6)
    }

    private func lastNight(_ n: Night) -> some View {
        let typical = DV.mean(prev.map { Double($0.r.asleepMin) })
        return Card(title: "Afgelopen nacht", index: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(DV.hm(Double(n.r.asleepMin))).font(Theme.number(34))
                if let typical { Text("gem. \(DV.hm(typical))").font(.subheadline).foregroundStyle(Theme.muted) }
            }
            Text("Geslapen · \(DV.clock(n.onset)) – \(DV.clock(n.wake))").font(.caption).foregroundStyle(Theme.muted)
            Chart {
                ForEach(Array(n.hr.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("t", p.0), y: .value("HR", p.1)).foregroundStyle(DV.sleep).lineStyle(StrokeStyle(lineWidth: 1.2))
                }
                RuleMark(x: .value("in", n.onset)).foregroundStyle(Theme.muted).lineStyle(StrokeStyle(dash: [3, 3]))
                RuleMark(x: .value("uit", n.wake)).foregroundStyle(Theme.muted).lineStyle(StrokeStyle(dash: [3, 3]))
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 2)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
            .frame(height: 140)
            // Hypnogram
            Chart {
                ForEach(Array(n.r.stages.enumerated()), id: \.offset) { k, s in
                    RectangleMark(xStart: .value("a", n.stageTime(k)), xEnd: .value("b", n.stageTime(k + 1)),
                                  yStart: .value("y0", Double(stageRow(s)) - 0.4), yEnd: .value("y1", Double(stageRow(s)) + 0.4))
                        .foregroundStyle(stageColor(s))
                }
            }
            .chartYScale(domain: -0.6...3.6)
            .chartYAxis { AxisMarks(values: [0, 1, 2, 3]) { v in AxisValueLabel { Text(["Diep", "Licht", "REM", "Wakker"][v.as(Int.self) ?? 0]).font(.caption2) } } }
            .chartXAxis(.hidden)
            .frame(height: 110)
        }
    }

    private func stageRow(_ s: Stage) -> Int { switch s { case .deep: 0; case .light: 1; case .rem: 2; case .wake: 3 } }
    private func stageColor(_ s: Stage) -> Color { switch s { case .deep: DV.deepC; case .light: DV.lightC; case .rem: DV.remC; case .wake: DV.wakeC } }

    private func stages(_ n: Night) -> some View {
        let total = max(1, Double(n.r.inBedMin))
        let rows: [(String, Int, Color, (Night) -> Int)] = [
            ("Wakker", n.r.awakeMin, DV.wakeC, { $0.r.awakeMin }), ("Licht", n.r.lightMin, DV.lightC, { $0.r.lightMin }),
            ("Diep", n.r.deepMin, DV.deepC, { $0.r.deepMin }), ("REM", n.r.remMin, DV.remC, { $0.r.remMin })
        ]
        return Card(title: "Slaapfases", index: 3) {
            HStack { Text("▯ gebruikelijk bereik").font(.caption).foregroundStyle(Theme.muted); Spacer()
                Text("In bed \(DV.hm(total))").font(.subheadline.weight(.semibold)) }
            ForEach(rows, id: \.0) { r in
                let frac = Double(r.1) / total
                let typ = prev.map { Double(r.3($0)) / max(1, Double($0.r.inBedMin)) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(r.0.uppercased()).font(Theme.label).tracking(1.5)
                        Text("\(Int((frac * 100).rounded()))%").font(.caption.weight(.semibold)).foregroundStyle(r.2)
                        Spacer()
                        Text(DV.hm(Double(r.1))).font(.headline).monospacedDigit()
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.line)
                            if let lo = typ.min(), let hi = typ.max(), typ.count >= 2 {
                                Rectangle().fill(Color.white.opacity(0.14))
                                    .frame(width: max(3, g.size.width * (hi - lo))).offset(x: g.size.width * lo)
                            }
                            Capsule().fill(r.2).frame(width: max(6, g.size.width * frac))
                        }
                    }.frame(height: 12)
                }
            }
            Divider().overlay(Theme.line)
            HStack {
                Label("Herstellende slaap (diep + REM)", systemImage: "square.fill").font(.subheadline).foregroundStyle(DV.remC)
                Spacer()
                Text(DV.hm(Double(n.restorativeMin))).font(.headline).monospacedDigit()
            }
        }
    }

    private func needed(_ n: Night) -> some View {
        let mx = max(n.needMin, Double(n.r.asleepMin), 1)
        return Card(title: "Uren vs. nodig", index: 4) {
            Text("\(Int(n.sufficiency.rounded()))%").font(Theme.number(34))
            bar("Geslapen", Double(n.r.asleepMin), mx, DV.sleep)
            bar("Nodig", n.needMin, mx, Theme.cardHi)
            VStack(spacing: 8) {
                line("Gezond minimum", DV.hm(n.needBase), Theme.muted)
                line("Belasting gisteren", "+" + DV.hm(n.needStrain), DV.strainC)
                line("Slaaptekort", "+" + DV.hm(n.needDebt), DV.wakeC)
            }.padding(12).background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private func bar(_ t: String, _ v: Double, _ mx: Double, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(t.uppercased()).font(Theme.label).tracking(1.5).foregroundStyle(Theme.muted); Spacer(); Text(DV.hm(v)).font(.headline).monospacedDigit() }
            GeometryReader { g in Capsule().fill(c).frame(width: max(6, g.size.width * v / mx)) }.frame(height: 12)
        }
    }
    private func line(_ t: String, _ v: String, _ c: Color) -> some View {
        HStack { RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 14, height: 14); Text(t); Spacer(); Text(v).monospacedDigit().fontWeight(.semibold) }.font(.subheadline)
    }

    /// Uren sinds 18:00 van de vorige avond, zodat de nacht een doorlopende as heeft.
    private func hourOfNight(_ d: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let h = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        return h >= 18 ? h - 18 : h + 6
    }

    private func consistency(_ n: Night) -> some View {
        let last = Array(model.nights.suffix(5))
        let earlier = Array(last.dropLast())
        let optWake = DV.mean(earlier.map { hourOfNight($0.wake) })
        let optBed = optWake.map { $0 - n.needMin / 60 }
        return Card(title: "Regelmaat", index: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(n.consistency.map { "\(Int($0.rounded()))%" } ?? "--").font(Theme.number(34))
                Spacer()
                Text("- - optimale bed-/wektijd").font(.caption).foregroundStyle(Theme.muted)
            }
            Chart {
                ForEach(Array(last.enumerated()), id: \.offset) { i, x in
                    BarMark(x: .value("Dag", x.date, unit: .day), yStart: .value("in", hourOfNight(x.onset)), yEnd: .value("uit", hourOfNight(x.wake)), width: 16)
                        .foregroundStyle(i == last.count - 1 ? DV.sleep : Theme.muted.opacity(0.6)).cornerRadius(3)
                }
                if let optBed { RuleMark(y: .value("bed", optBed)).foregroundStyle(Theme.muted).lineStyle(StrokeStyle(dash: [4, 4])) }
                if let optWake { RuleMark(y: .value("wek", optWake)).foregroundStyle(Theme.muted).lineStyle(StrokeStyle(dash: [4, 4])) }
            }
            .chartYScale(domain: .automatic(includesZero: false, reversed: true))
            .chartYAxis { AxisMarks(values: [1, 5, 9, 13, 17]) { v in AxisGridLine(); AxisValueLabel { Text(String(format: "%02d:00", ((v.as(Int.self) ?? 0) + 18) % 24)).font(.caption2) } } }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true) } }
            .frame(height: 200)
        }
    }

    private func efficiency(_ n: Night) -> some View {
        Card(title: "Slaapefficiëntie", index: 6) {
            Text("\(Int(n.efficiency.rounded()))%").font(Theme.number(34))
            HStack { Text("IN SLAAP").font(Theme.label).tracking(1.5).foregroundStyle(Theme.muted); Spacer(); Text(DV.hm(Double(n.r.asleepMin))).font(.headline) }
            timeline(n) { $0 != .wake }.foregroundStyle(DV.sleep)
            timeline(n) { $0 == .wake }.foregroundStyle(DV.wakeC)
            HStack { Text("WAKKER").font(Theme.label).tracking(1.5).foregroundStyle(Theme.muted); Spacer(); Text(DV.hm(Double(n.r.awakeMin))).font(.headline) }
            Divider().overlay(Theme.line)
            HStack { Text("Keren wakker").font(.subheadline); Spacer(); Text("\(n.r.disturbances)").font(Theme.number(22)) }
            if n.phoneMin > 0 {
                HStack { Text("Telefoon gebruikt (telt als wakker)").font(.subheadline); Spacer(); Text(DV.hm(Double(n.phoneMin))).font(.headline) }
            }
        }
    }
    private func timeline(_ n: Night, _ on: @escaping (Stage) -> Bool) -> some View {
        Canvas { ctx, size in
            let N = max(1, n.r.stages.count), w = size.width / CGFloat(N)
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(.white.opacity(0.06)))
            for (k, s) in n.r.stages.enumerated() where on(s) {
                ctx.fill(Path(CGRect(x: CGFloat(k) * w, y: 0, width: w + 0.5, height: size.height)), with: .foreground)
            }
        }.frame(height: 18)
    }

    private func stress(_ n: Night) -> some View {
        let tot = max(1, n.stressMin.reduce(0, +))
        return Card(title: "Slaapstress", index: 7) {
            Text("\(Int(n.highStressPct.rounded()))% hoog").font(Theme.number(28))
            Chart {
                RectangleMark(xStart: .value("a", n.onset), xEnd: .value("b", n.wake)).foregroundStyle(DV.sleep.opacity(0.10))
                ForEach(Array(n.stress.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("t", p.0), y: .value("s", p.1))
                        .foregroundStyle(LinearGradient(colors: [DV.good, Theme.zones[3].color], startPoint: .bottom, endPoint: .top))
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: 0...3)
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
            .frame(height: 160)
            ForEach([(2, "Hoog", DV.poor), (1, "Middel", DV.good), (0, "Laag", DV.fair)], id: \.0) { i, t, c in
                let m = n.stressMin[i]
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(t.uppercased()).font(Theme.label).tracking(1.5)
                        Text("\(100 * m / tot)%").font(.caption.weight(.semibold)).foregroundStyle(c)
                        Spacer(); Text(DV.hm(Double(m))).font(.headline).monospacedDigit() }
                    GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(Theme.line); Capsule().fill(c).frame(width: max(6, g.size.width * Double(m) / Double(tot))) } }.frame(height: 10)
                }
            }
            Text("Slaapstress uit de scores-module: hartslag en HRV per minuut t.o.v. je eigen basislijn.").font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private var trends: some View {
        let ns = model.nights
        return Group {
            TrendCard(title: "Slaapprestatie", points: ns.map { ($0.date, $0.performance) }, domain: 0...125, label: { "\(Int($0))%" })
            TrendCard(title: "Uren vs. nodig", points: ns.map { ($0.date, $0.sufficiency) }, domain: 0...125, label: { "\(Int($0))%" })
            TrendCard(title: "Herstellende slaap", points: ns.map { ($0.date, Double($0.restorativeMin)) }, color: { _ in DV.remC }, label: { DV.hm($0) })
            TrendCard(title: "Regelmaat", points: ns.map { ($0.date, $0.consistency) }, domain: 0...125, label: { "\(Int($0))%" })
            Card(title: "Tijd in bed") {
                Chart {
                    ForEach(Array(ns.enumerated()), id: \.offset) { _, x in
                        BarMark(x: .value("Dag", x.date, unit: .day), yStart: .value("in", hourOfNight(x.onset)), yEnd: .value("uit", hourOfNight(x.wake)), width: 16)
                            .foregroundStyle(DV.sleep).cornerRadius(3)
                            .annotation(position: .top) { Text(DV.clock(x.onset)).font(.caption2).foregroundStyle(DV.sleep) }
                            .annotation(position: .bottom) { Text(DV.clock(x.wake)).font(.caption2).foregroundStyle(DV.sleep) }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false, reversed: true))
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true) } }
                .frame(height: 200)
            }
            TrendCard(title: "Efficiëntie", points: ns.map { ($0.date, $0.efficiency) }, domain: 0...125, label: { "\(Int($0))%" })
            TrendCard(title: "Slaaptekort", points: ns.map { ($0.date, $0.debtMin) }, color: { _ in DV.wakeC }, label: { DV.hm($0) })
            TrendCard(title: "Hoge slaapstress", points: ns.map { ($0.date, $0.highStressPct) }, color: { _ in DV.poor }, label: { "\(Int($0))%" })
        }
    }
}

// MARK: Herstel

struct RecoveryDetailView: View {
    @ObservedObject var model: ScoreModel
    private var n: Night? { model.lastNight ?? model.nights.last }
    private var prev: [Night] { Array(model.nights.dropLast()) }

    var body: some View {
        detailScroll("Herstel") {
            if let n {
                BigRing(value: n.recovery.map { Double($0) / 100 }, text: n.recovery.map { "\($0)%" } ?? "--",
                        label: "Herstel", color: DV.recoveryColor(n.recovery))
                if n.recovery == nil && n.recoveryNeedsNights > 0 {
                    Text("Te weinig data voor herstel: nog \(n.recoveryNeedsNights) \(n.recoveryNeedsNights == 1 ? "nacht" : "nachten") meten, of vul je normale HRV en rust-hartslag in (Gezondheid → profiel). Herstel vergelijkt met je eigen basislijn; een standaardbasislijn gaf onzin.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                }
                Card(index: 1) {
                    cmp("waveform.path.ecg", "Hartslagvariabiliteit", n.metrics.hrv, prev.compactMap(\.metrics.hrv), "%.0f", true)
                    Divider().overlay(Theme.line)
                    cmp("heart", "Rusthartslag", n.metrics.rhr, prev.compactMap(\.metrics.rhr), "%.0f", false)
                    Divider().overlay(Theme.line)
                    cmp("lungs", "Ademfrequentie", n.metrics.resp, prev.compactMap(\.metrics.resp), "%.1f", nil)
                    Divider().overlay(Theme.line)
                    cmp("moon", "Slaapprestatie", n.performance, prev.compactMap(\.performance), "%.0f%%", true)
                    Label("Vandaag vs. eerdere nachten (gemiddelde eronder)", systemImage: "arrow.up.arrow.down").font(.caption).foregroundStyle(Theme.muted)
                }
                Text("Weektrends").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                TrendCard(title: "Herstel", points: model.nights.map { ($0.date, $0.recovery.map(Double.init)) }, domain: 0...125,
                          color: { DV.recoveryColor(Int($0)) }, label: { "\(Int($0))%" })
                TrendCard(title: "Hartslagvariabiliteit", points: model.nights.map { ($0.date, $0.metrics.hrv) }, line: true)
                TrendCard(title: "Rusthartslag", points: model.nights.map { ($0.date, $0.metrics.rhr) }, line: true)
                TrendCard(title: "Ademfrequentie", points: model.nights.map { ($0.date, $0.metrics.resp) }, line: true, label: { String(format: "%.1f", $0) })
                TrendCard(title: "Slaapprestatie", points: model.nights.map { ($0.date, $0.performance) }, line: true, label: { "\(Int($0))%" })
                Text("Eigen berekening (scores-module): HRV, rust-HR, ademfrequentie en slaap t.o.v. je eigen basislijn. Basislijn: je Whoop-kalibratie, of anders je eigen nachten (vanaf 4).")
                    .font(.caption).foregroundStyle(Theme.muted)
            } else {
                Text("Nog geen nacht gemeten.").foregroundStyle(Theme.muted).padding(.top, 40)
            }
        }
    }

    private func cmp(_ icon: String, _ t: String, _ v: Double?, _ hist: [Double], _ f: String, _ hib: Bool?) -> some View {
        let base = DV.mean(hist)
        return CompareRow(icon: icon, title: t, value: v.map { String(format: f, $0) } ?? "--",
                          baseline: base.map { String(format: f, $0) }, delta: v.flatMap { a in base.map { a - $0 } }, higherIsBetter: hib)
    }
}

// MARK: Belasting

struct StrainDetailView: View {
    @ObservedObject var model: ScoreModel
    private var d: DayLoad? { model.today ?? model.days.last }
    private var prev: [DayLoad] { Array(model.days.dropLast()) }

    var body: some View {
        detailScroll("Belasting") {
            if let d {
                BigRing(value: d.strain / 21, text: String(format: "%.1f", d.strain), label: "Belasting", color: DV.strainC)
                Card(index: 1) {
                    cmp("heart", "Hartslagzones 1–3", d.zones13, prev.map(\.zones13))
                    Divider().overlay(Theme.line)
                    cmp("bolt.heart", "Hartslagzones 4–5", d.zones45, prev.map(\.zones45))
                    Text("Nog niet gemeten: stappen en krachttraining (bewegingssensor nog niet ontcijferd).")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                Text("Weektrends").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                TrendCard(title: "Belasting", points: model.days.map { ($0.date, $0.strain) }, domain: 0...24,
                          color: { _ in DV.strainC }, label: { String(format: "%.1f", $0) })
                zoneStack
                TrendCard(title: "Hartslagzones 4–5", points: model.days.map { ($0.date, $0.zones45) },
                          color: { _ in Theme.zones[4].color }, label: { DV.hm($0) })
                TrendCard(title: "Energie (geschat, kcal)", points: model.days.map { ($0.date, $0.kcal) },
                          color: { _ in Theme.zones[3].color }, label: { "\(Int($0))" })
                Text("Belasting en zones: scores-module (hartslagreserve met max- en rust-HR uit je profiel). Energie: Mifflin (rust) plus Keytel (hartslag) met je leeftijd, geslacht, gewicht en lengte uit het profiel (standaard 75 kg / 180 cm); tijd zonder metingen telt als rustverbruik. Een schatting.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    private func cmp(_ icon: String, _ t: String, _ v: Double, _ hist: [Double]) -> some View {
        let base = DV.mean(hist)
        return CompareRow(icon: icon, title: t, value: DV.hm(v), baseline: base.map(DV.hm), delta: base.map { v - $0 }, higherIsBetter: true)
    }

    private var zoneStack: some View {
        Card(title: "Hartslagzones 1–3") {
            Chart {
                ForEach(model.days) { x in
                    ForEach(1...3, id: \.self) { z in
                        BarMark(x: .value("Dag", x.date, unit: .day), y: .value("min", x.zoneMin[z]), width: 18)
                            .foregroundStyle(by: .value("Zone", "Zone \(z)"))
                    }
                }
            }
            .chartForegroundStyleScale(["Zone 1": Theme.zones[1].color, "Zone 2": Theme.zones[2].color, "Zone 3": Theme.zones[3].color])
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true) } }
            .frame(height: 190)
        }
    }
}

// MARK: Gezondheidsmonitor

struct HealthMonitorView: View {
    @ObservedObject var model: ScoreModel
    @EnvironmentObject var ble: BLEManager
    private var n: Night? { model.lastNight ?? model.nights.last }
    private var prev: [Night] { Array(model.nights.dropLast()) }

    var body: some View {
        detailScroll("Vitale waarden") {
            hrCard
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.gap), GridItem(.flexible())], spacing: Theme.gap) {
                tile("lungs", "Ademfrequentie", n?.metrics.resp, "/min", "%.1f", prev.compactMap(\.metrics.resp), higherIsBad: true)
                tile("heart", "Rust-HR", n?.metrics.rhr, "bpm", "%.0f", prev.compactMap(\.metrics.rhr), higherIsBad: true)
                tile("waveform.path.ecg", "HRV", n?.metrics.hrv, "ms", "%.0f", prev.compactMap(\.metrics.hrv), higherIsBad: false)
                skinTile
            }
            Text("Bereik = gemiddelde ± 1 standaardafwijking van je eerdere nachten (min. 2 nachten nodig). Huidtemp Δ = verschil met je gemiddelde. Nog niet gemeten: bloedzuurstof.")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private var hrCard: some View {
        let z = ble.bpm.map { Theme.zone($0) }
        return Card(title: "Hartslag") {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "heart.fill").foregroundStyle(z?.color ?? Theme.muted).font(.title2)
                    Text(ble.bpm.map(String.init) ?? "--").font(Theme.number(44)).monospacedDigit()
                    Text("BPM · \(z?.name ?? "geen verbinding")").font(Theme.label).tracking(1.5).foregroundStyle(Theme.muted)
                }
                Chart(ble.samples) {
                    LineMark(x: .value("t", $0.time), y: .value("bpm", $0.bpm)).foregroundStyle(z?.color ?? DV.sleep)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 100)
            }
        }
    }

    private func tile(_ icon: String, _ t: String, _ v: Double?, _ unit: String, _ f: String, _ hist: [Double], higherIsBad: Bool) -> some View {
        Card {
            Label(t.uppercased(), systemImage: icon).font(Theme.label).tracking(1.2).foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(v.map { String(format: f, $0) } ?? "--").font(Theme.number(30)).monospacedDigit()
                Text(unit).font(.footnote).foregroundStyle(Theme.muted)
            }
            pill(v, hist, f, higherIsBad)
        }
    }

    @ViewBuilder private func pill(_ v: Double?, _ hist: [Double], _ f: String, _ higherIsBad: Bool) -> some View {
        if let v, let m = DV.mean(hist), let s = DV.sd(hist) {
            let lo = m - s, hi = m + s
            if v > hi { StatusPill(text: "↑ > " + String(format: f, hi) + (higherIsBad ? " · let op" : " · gunstig"), ok: !higherIsBad) }
            else if v < lo { StatusPill(text: "↓ < " + String(format: f, lo) + (higherIsBad ? " · gunstig" : " · let op"), ok: higherIsBad) }
            else { StatusPill(text: "binnen " + String(format: f, lo) + "–" + String(format: f, hi), ok: true) }
        } else {
            StatusPill(text: "basislijn volgt", ok: nil)
        }
    }

    private var skinTile: some View {
        let hist = prev.compactMap(\.metrics.skinTemp)
        let base = DV.mean(hist)
        let delta = n?.metrics.skinTemp.flatMap { v in base.map { v - $0 } }
        return Card {
            Label("HUIDTEMP Δ", systemImage: "thermometer.medium").font(Theme.label).tracking(1.2).foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(delta.map { String(format: "%+.1f", $0) } ?? "--").font(Theme.number(30)).monospacedDigit()
                Text("°C").font(.footnote).foregroundStyle(Theme.muted)
            }
            if let delta, let s = DV.sd(hist) {
                abs(delta) <= max(0.2, s) ? StatusPill(text: String(format: "binnen ±%.1f", max(0.2, s)), ok: true)
                    : StatusPill(text: delta > 0 ? "↑ hoger · let op" : "↓ lager · let op", ok: false)
            } else { StatusPill(text: "basislijn volgt", ok: nil) }
        }
    }
}


/// Inklapbaar blok met een kop ("Details", "Weektrends"); de keuze blijft bewaard.
struct Collapsible<Content: View>: View {
    let title: String
    @Binding var open: Bool
    @ViewBuilder var content: Content

    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { open.toggle() } } label: {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 0 : -90)).foregroundStyle(Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.top, 8)
        if open { content }
    }
}
