import SwiftUI
import Charts

/// Dagoverzicht: slaap, herstel en belasting als ringen, gezondheid/stress, stressverloop, 7 dagen en metrieken.
struct TodayView: View {
    @EnvironmentObject var store: DayStore
    @EnvironmentObject var ble: BLEManager
    @Environment(\.scenePhase) private var phase
    @State private var week: [Analytics.Day] = []
    @StateObject private var scores = ScoreModel()
    @State private var lastCompute = Date.distantPast

    private var today: Analytics.Day? { week.last }
    private var past: [Analytics.Day] { Array(week.dropLast()) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.gap) {
                    header
                    rings.padding(.vertical, 8)
                    HStack(spacing: Theme.gap) {
                        NavigationLink { HealthMonitorView(model: scores) } label: { healthTile }
                        NavigationLink { StressDetailView(model: scores) } label: { stressTile }
                    }.buttonStyle(.plain)
                    stressChart
                    weekChart
                    metrics
                    Text("Eigen berekeningen op basis van je banddata; geen officiële Whoop-scores. Scores worden beter naarmate er meer dagen (en nachten) zijn gemeten.")
                        .font(.caption).foregroundStyle(Theme.muted).padding(.top, 4)
                }
                .padding()
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Vandaag")
            .refreshable { recompute() }
        }
        .onAppear(perform: recompute)
        // Alleen herberekenen als de app zichtbaar is, hooguit 1× per 30 s: spaart CPU op de achtergrond,
        // anders kan iOS de app 's nachts afsluiten.
        .onChange(of: store.revision) { _, _ in
            if phase == .active && Date().timeIntervalSince(lastCompute) > 30 { recompute() }
        }
        .onChange(of: phase) { _, p in if p == .active { recompute() } }
    }

    private func recompute() { lastCompute = Date(); week = Analytics.week(store: store); scores.refresh(store: store) }

    private var sleepPerf: Int? { scores.lastNight?.performance.map { Int($0.rounded()) } ?? today?.sleepScore }
    private var recoveryNow: Int? { scores.lastNight?.recovery ?? today?.recovery }
    private var strainNow: Double? { scores.today?.strain ?? today?.strain }

    private var header: some View {
        HStack {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.headline)
            Spacer()
            if let b = ble.battery {
                Label("\(b)%", systemImage: "battery.75percent").font(.subheadline).foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: ringen

    private var rings: some View {
        HStack(spacing: 10) {
            NavigationLink { SleepDetailView(model: scores) } label: {
                ScoreRing(label: "Slaap", value: sleepPerf.map { Double($0) / 100 },
                          text: sleepPerf.map { "\($0)%" } ?? "--", color: Theme.hex(0x8FA8C8))
            }
            NavigationLink { RecoveryDetailView(model: scores) } label: {
                ScoreRing(label: "Herstel", value: recoveryNow.map { Double($0) / 100 },
                          text: recoveryNow.map { "\($0)%" } ?? "--", color: recoveryColor(recoveryNow))
            }
            NavigationLink { StrainDetailView(model: scores) } label: {
                ScoreRing(label: "Belasting", value: strainNow.map { $0 / 21 },
                          text: strainNow.map { String(format: "%.1f", $0) } ?? "--", color: Theme.zones[1].color)
            }
        }
        .buttonStyle(.plain)
    }

    private func recoveryColor(_ r: Int?) -> Color {
        guard let r else { return Theme.muted }
        return r >= 67 ? Theme.accent : r >= 34 ? Theme.zones[3].color : Theme.hr
    }

    // MARK: tegels

    private var baselineRHR: Double? {
        let v = past.compactMap(\.rhr); return v.isEmpty ? nil : Double(v.reduce(0, +)) / Double(v.count)
    }

    private var healthTile: some View {
        let rhr = today?.rhr
        let delta = rhr.flatMap { r in baselineRHR.map { Double(r) - $0 } }
        let elevated = (delta ?? 0) > 3
        return Card(title: "Gezondheid", index: 1) {
            HStack(spacing: 10) {
                Image(systemName: elevated ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(elevated ? Theme.zones[4].color : Theme.accent).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rhr == nil ? "GEEN DATA" : elevated ? "VERHOOGD" : "NORMAAL")
                        .font(Theme.label).tracking(1.5).foregroundStyle(elevated ? Theme.zones[4].color : Theme.accent)
                    Text(rhr.map { "Rust-HR \($0)" } ?? "Rust-HR").font(.subheadline).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var stressTile: some View {
        let s = today?.currentStress
        let (txt, col): (String, Color) = {
            guard let s else { return ("GEEN DATA", Theme.muted) }
            return s < 1 ? ("LAAG", Theme.accent) : s < 2 ? ("MIDDEL", Theme.zones[3].color) : ("HOOG", Theme.hr)
        }()
        return Card(title: "Stress", index: 2) {
            HStack(spacing: 10) {
                Text(s.map { String(format: "%.1f", $0) } ?? "–").font(Theme.number(20)).foregroundStyle(col)
                    .padding(6).background(col.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(txt).font(Theme.label).tracking(1.5).foregroundStyle(col)
                    Text(today?.stress.last.map { $0.0.formatted(date: .omitted, time: .shortened) } ?? "").font(.subheadline).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    // MARK: grafieken

    private var stressChart: some View {
        Card(title: "Stress vandaag", index: 3) {
            if let pts = today?.stress, pts.count > 1 {
                Chart {
                    if let a = today?.sleepStart, let b = today?.sleepEnd {
                        RectangleMark(xStart: .value("", a), xEnd: .value("", b))
                            .foregroundStyle(Theme.hex(0x8FA8C8).opacity(0.12))
                    }
                    ForEach(pts.indices, id: \.self) { i in
                        LineMark(x: .value("Tijd", pts[i].0), y: .value("Stress", pts[i].1))
                            .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.zones[3].color], startPoint: .bottom, endPoint: .top))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: 0...3)
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                .frame(height: 170)
            } else {
                Text("Nog te weinig rustige metingen vandaag.").font(.subheadline).foregroundStyle(Theme.muted)
            }
        }
    }

    private var weekChart: some View {
        Card(title: "Belasting & herstel · 7 dagen", index: 4) {
            Chart {
                ForEach(week.indices, id: \.self) { i in
                    let d = week[i]
                    LineMark(x: .value("Dag", d.date, unit: .day), y: .value("Belasting", d.strain), series: .value("s", "Belasting"))
                        .foregroundStyle(Theme.zones[1].color).symbol(.circle)
                    if let r = d.recovery {
                        LineMark(x: .value("Dag", d.date, unit: .day), y: .value("Herstel", Double(r) / 100 * 21), series: .value("s", "Herstel"))
                            .foregroundStyle(recoveryColor(r)).symbol(.circle)
                            .annotation(position: .top) { Text("\(r)%").font(.caption2).foregroundStyle(recoveryColor(r)) }
                    }
                }
            }
            .chartYScale(domain: 0...21)
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
            .frame(height: 200)
            HStack(spacing: 16) {
                Label("Belasting (0–21)", systemImage: "circle.fill").foregroundStyle(Theme.zones[1].color)
                Label("Herstel (%)", systemImage: "circle.fill").foregroundStyle(Theme.accent)
            }.font(.caption)
        }
    }

    // MARK: metrieken met baseline

    private var metrics: some View {
        let hrvB = past.compactMap(\.hrv), sleepB = past.map(\.sleepMinutes).filter { $0 > 0 }
        let avg = { (v: [Double]) -> Double? in v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        let fmtMin = { (m: Int) in "\(m / 60):\(String(format: "%02d", m % 60))" }
        let rows: [(String, String, String)] = [
            ("HRV", today?.hrv.map { "\(Int($0)) ms" } ?? "--", avg(hrvB).map { "\(Int($0)) ms" } ?? "–"),
            ("Rust-HR", today?.rhr.map { "\($0) bpm" } ?? "--", baselineRHR.map { "\(Int($0)) bpm" } ?? "–"),
            ("Slaap", today.map { $0.sleepMinutes > 0 ? fmtMin($0.sleepMinutes) : "--" } ?? "--", avg(sleepB.map { Double($0) }).map { fmtMin(Int($0)) } ?? "–"),
            ("Zone 1–3", today.map { "\($0.zoneMinutes[1...3].reduce(0, +)) min" } ?? "--", "–"),
            ("Zone 4–5", today.map { "\($0.zoneMinutes[4...5].reduce(0, +)) min" } ?? "--", "–"),
            ("Huidtemp", today?.skin.map { String(format: "%.1f °C", $0) } ?? "--", avg(past.compactMap(\.skin)).map { String(format: "%.1f °C", $0) } ?? "–"),
            ("Gemeten", today.map { fmtMin($0.measuredMinutes) } ?? "--", "")
        ]
        return Card(title: "Dashboard", index: 5) {
            HStack { Spacer(); Text("VANDAAG").frame(width: 90, alignment: .trailing); Text("BASELINE").frame(width: 90, alignment: .trailing) }
                .font(Theme.label).foregroundStyle(Theme.muted)
            ForEach(rows, id: \.0) { r in
                HStack {
                    Text(r.0).font(.subheadline)
                    Spacer()
                    Text(r.1).font(.subheadline.weight(.semibold)).monospacedDigit().frame(width: 90, alignment: .trailing)
                    Text(r.2).font(.subheadline).foregroundStyle(Theme.muted).monospacedDigit().frame(width: 90, alignment: .trailing)
                }
                Divider().overlay(Theme.line)
            }
        }
    }
}

struct ScoreRing: View {
    let label: String
    let value: Double?
    let text: String
    let color: Color
    @State private var shown = false
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Theme.line, lineWidth: 9)
                Circle().trim(from: 0, to: shown ? min(1, max(0, value ?? 0)) : 0)
                    .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.4), radius: 6)
                Text(text).font(Theme.number(24)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1).padding(8)
            }
            .frame(width: 100, height: 100)
            Text(label.uppercased()).font(Theme.label).tracking(2)
        }
        .frame(maxWidth: .infinity)
        .onAppear { withAnimation(Theme.ringAnim.delay(0.1)) { shown = true } }
        .animation(Theme.ringAnim, value: value)
    }
}
