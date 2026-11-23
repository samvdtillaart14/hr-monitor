import SwiftUI
import WhoopScores
import Charts

/// Dagoverzicht: slaap, herstel en belasting als ringen, gezondheid/stress, stressverloop, 7 dagen en metrieken.
/// Alles komt uit de scores-module (ScoreModel), dezelfde bron als de detailschermen.
struct TodayView: View {
    @EnvironmentObject var store: DayStore
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var acts: ActivityStore
    @Environment(\.scenePhase) private var phase
    @EnvironmentObject var scores: ScoreModel
    @State private var lastCompute = Date.distantPast
    @State private var stress: [StressDetailView.Pt] = []
    @State private var measuredMin = 0

    private var night: Night? { scores.lastNight }
    private var pastNights: [Night] { scores.nights.filter { !Calendar.current.isDateInToday($0.date) } }
    private var pastDays: [DayLoad] { scores.days.filter { !Calendar.current.isDateInToday($0.date) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.gap) {
                    header
                    rings.padding(.vertical, 8)
                    if night == nil {
                        Text("Geen nachtdata: vannacht is geen slaap gemeten.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                    ActivitiesCard(scores: scores)
                    TonightCard()
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
        // Stress hangt af van de rust-HR van de laatste nacht: opnieuw zodra de nachten klaar zijn.
        // dropFirst: de beginwaarde (nog lege lijst) zou activiteiten herkennen zonder slaap uit te sluiten.
        .onReceive(scores.$nights.dropFirst()) { n in
            updateStress()
            // Activiteiten herkennen zodra de slaap bekend is (slaap telt nooit als activiteit).
            acts.refresh(store: store, sleep: n.map { (start: $0.r.onset - 600, end: $0.r.wake + 600) })
        }
    }

    private func recompute() {
        lastCompute = Date()
        scores.refresh(store: store)
        updateStress()
    }

    /// Zelfde berekening als het stressscherm.
    private func updateStress() {
        let s = store.samples(day: Date())
        measuredMin = Set(s.map { $0.t / 60 }).count
        stress = StressDetailView.buckets(s, rhr: night?.metrics.rhr ?? 60, sleep: night.map { ($0.r.onset, $0.r.wake) })
    }

    private var sleepPerf: Int? { night?.performance.map { Int($0.rounded()) } }
    private var recoveryNow: Int? { night?.recovery }
    private var strainNow: Double? { scores.today?.strain }

    private var header: some View {
        HStack {
            Text(Date.now.formatted(.dateTime.locale(DV.nl).weekday(.wide).day().month(.wide))).font(.headline)
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
                          text: recoveryNow.map { "\($0)%" } ?? "--", color: DV.recoveryColor(recoveryNow))
            }
            NavigationLink { StrainDetailView(model: scores) } label: {
                ScoreRing(label: "Belasting", value: strainNow.map { $0 / 21 },
                          text: strainNow.map { String(format: "%.1f", $0) } ?? "--", color: Theme.zones[1].color)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: tegels

    private var baselineRHR: Double? { DV.mean(pastNights.compactMap(\.metrics.rhr)) }

    private var healthTile: some View {
        let rhr = night?.metrics.rhr
        let delta = rhr.flatMap { r in baselineRHR.map { r - $0 } }
        let elevated = (delta ?? 0) > 3
        return Card(title: "Vitale waarden", index: 1) {
            HStack(spacing: 10) {
                Image(systemName: elevated ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(elevated ? Theme.zones[4].color : Theme.accent).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rhr == nil ? "GEEN DATA" : elevated ? "VERHOOGD" : "NORMAAL")
                        .font(Theme.label).tracking(1.5).foregroundStyle(elevated ? Theme.zones[4].color : Theme.accent)
                    Text(rhr.map { "Rust-HR \(Int($0.rounded()))" } ?? "Rust-HR").font(.subheadline).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var stressTile: some View {
        let s = stress.last?.v
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
                    Text(stress.last.map { DV.clock($0.t) } ?? "").font(.subheadline).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    // MARK: grafieken

    private var stressChart: some View {
        Card(title: "Stress vandaag", index: 3) {
            if stress.count > 1 {
                Chart {
                    if let n = night {
                        RectangleMark(xStart: .value("", max(n.onset, Calendar.current.startOfDay(for: Date()))), xEnd: .value("", n.wake))
                            .foregroundStyle(Theme.hex(0x8FA8C8).opacity(0.12))
                    }
                    ForEach(stress.indices, id: \.self) { i in
                        LineMark(x: .value("Tijd", stress[i].t), y: .value("Stress", stress[i].v))
                            .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.zones[3].color], startPoint: .bottom, endPoint: .top))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: 0...3)
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                .frame(height: 170)
            } else {
                Text("Nog te weinig metingen vandaag.").font(.subheadline).foregroundStyle(Theme.muted)
            }
        }
    }

    private var weekChart: some View {
        let cal = Calendar.current
        return Card(title: "Belasting & herstel · 7 dagen", index: 4) {
            Chart {
                ForEach(scores.days) { d in
                    LineMark(x: .value("Dag", d.date, unit: .day), y: .value("Belasting", d.strain), series: .value("s", "Belasting"))
                        .foregroundStyle(Theme.zones[1].color).symbol(.circle)
                }
                ForEach(scores.nights.filter { $0.recovery != nil }) { n in
                    let r = n.recovery ?? 0
                    LineMark(x: .value("Dag", cal.startOfDay(for: n.date), unit: .day), y: .value("Herstel", Double(r) / 100 * 21), series: .value("s", "Herstel"))
                        .foregroundStyle(Theme.accent).symbol(.circle)
                        .annotation(position: .top) { Text("\(r)%").font(.caption2).foregroundStyle(DV.recoveryColor(r)) }
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
        let fmtMin = { (m: Double) in DV.hm(m) }
        let z13 = scores.today?.zones13, z45 = scores.today?.zones45
        let rows: [(String, String, String)] = [
            ("HRV", night?.metrics.hrv.map { "\(Int($0.rounded())) ms" } ?? "--",
             DV.mean(pastNights.compactMap(\.metrics.hrv)).map { "\(Int($0.rounded())) ms" } ?? "–"),
            ("Rust-HR", night?.metrics.rhr.map { "\(Int($0.rounded())) bpm" } ?? "--",
             baselineRHR.map { "\(Int($0.rounded())) bpm" } ?? "–"),
            ("Slaap", night.map { fmtMin(Double($0.r.asleepMin)) } ?? "--",
             DV.mean(pastNights.map { Double($0.r.asleepMin) }).map(fmtMin) ?? "–"),
            ("Zone 1–3", z13.map { "\(Int($0.rounded())) min" } ?? "--",
             DV.mean(pastDays.map(\.zones13)).map { "\(Int($0.rounded())) min" } ?? "–"),
            ("Zone 4–5", z45.map { "\(Int($0.rounded())) min" } ?? "--",
             DV.mean(pastDays.map(\.zones45)).map { "\(Int($0.rounded())) min" } ?? "–"),
            ("Huidtemp (nacht)", night?.metrics.skinTemp.map { String(format: "%.1f °C", $0) } ?? "--",
             DV.mean(pastNights.compactMap(\.metrics.skinTemp)).map { String(format: "%.1f °C", $0) } ?? "–"),
            ("Gemeten", fmtMin(Double(measuredMin)), "")
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
