import SwiftUI
import Charts
import WhoopScores

private let actBlue = Theme.zones[1].color

private func fmtDur(_ s: TimeInterval) -> String {
    let t = max(0, Int(s.rounded()))
    return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
}

// MARK: lijst op Vandaag

/// Kaart "Activiteiten": slaap van afgelopen nacht plus de activiteiten van vandaag, en toevoegen.
struct ActivitiesCard: View {
    @EnvironmentObject var acts: ActivityStore
    @ObservedObject var scores: ScoreModel
    @State private var adding = false

    var body: some View {
        Card(title: "Activiteiten", index: 1) {
            VStack(spacing: 10) {
                if let n = scores.lastNight {
                    NavigationLink { SleepDetailView(model: scores) } label: {
                        ActivityRowView(icon: "moon.fill", value: DV.hm(Double(n.r.asleepMin)), name: "Slaap",
                                        from: n.onset, to: n.wake, color: DV.sleep)
                    }
                }
                ForEach(acts.on(day: Date())) { a in
                    NavigationLink { ActivityDetailView(id: a.id) } label: {
                        ActivityRowView(icon: a.type.icon, value: a.summary.map { String(format: "%.1f", $0.strain) } ?? "–",
                                        name: a.type.name, from: a.start, to: a.end, color: actBlue, auto: a.auto)
                    }
                }
                Button { adding = true } label: {
                    Label(acts.ongoing == nil ? "Activiteit toevoegen" : "Activiteit loopt…", systemImage: "plus")
                        .font(.subheadline.weight(.semibold)).tracking(1)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Theme.cardHi, in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(acts.ongoing != nil)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $adding) { ActivityEditSheet(existing: nil) }
    }
}

struct ActivityRowView: View {
    let icon: String, value: String, name: String
    let from: Date, to: Date?
    let color: Color
    var auto = false

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.title3)
                Text(value).font(Theme.number(20)).monospacedDigit()
            }
            .foregroundStyle(.white)
            .frame(width: 104, height: 44)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(name.uppercased()).font(.subheadline.weight(.bold)).tracking(1.5)
                if auto { Text("automatisch herkend").font(.caption2).foregroundStyle(Theme.muted) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(timeLabel(from)).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                if let to { Text(DV.clock(to)).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted) }
                else { Text("loopt").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent) }
            }
            .monospacedDigit()
            Capsule().fill(color).frame(width: 3, height: 32)
        }
        .padding(10)
        .background(Theme.cardHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private func timeLabel(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? DV.clock(d) : "[\(d.formatted(.dateTime.weekday(.abbreviated)))] \(DV.clock(d))"
    }
}

// MARK: toevoegen / wijzigen

struct ActivityEditSheet: View {
    let existing: Activity?
    @EnvironmentObject var acts: ActivityStore
    @EnvironmentObject var store: DayStore
    @Environment(\.dismiss) private var dismiss
    @State private var type: ActivityType = .tennis
    @State private var startNow = false
    @State private var start = Date().addingTimeInterval(-3600)
    @State private var end = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Soort") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                        ForEach(ActivityType.allCases) { t in
                            Button { type = t } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: t.icon).font(.title2)
                                    Text(t.name).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(type == t ? actBlue.opacity(0.3) : Theme.cardHi, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(type == t ? actBlue : .clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    if existing == nil { Toggle("Nu starten", isOn: $startNow) }
                    if !startNow {
                        DatePicker("Begin", selection: $start, in: ...Date())
                        DatePicker("Einde", selection: $end, in: start...Date())
                    }
                } footer: {
                    Text(startNow ? "Stop de activiteit op Vandaag als je klaar bent. Hartslag wordt alleen opgeslagen als de app met je band verbonden is."
                                  : "Statistieken komen uit de opgeslagen hartslag in deze periode.")
                }
                if let existing {
                    Section {
                        Button("Verwijder activiteit", role: .destructive) { acts.delete(existing.id); dismiss() }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Activiteit toevoegen" : "Activiteit wijzigen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Bewaar", action: saveAndClose).disabled(!startNow && end <= start) }
            }
            .onAppear {
                if let e = existing { type = e.type; start = e.start; end = e.end ?? Date() }
            }
        }
    }

    private func saveAndClose() {
        if var e = existing {
            e.type = type
            if !e.isOngoing { e.start = start; e.end = end } else { e.start = start }
            acts.update(e, store: store)
        } else {
            acts.add(Activity(type: type, start: startNow ? Date() : start, end: startNow ? nil : end), store: store)
        }
        dismiss()
    }
}

// MARK: detail

struct ActivityDetailView: View {
    let id: UUID
    @EnvironmentObject var acts: ActivityStore
    @EnvironmentObject var store: DayStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var hr: [(Date, Double)] = []

    private var a: Activity? { acts.items.first { $0.id == id } }

    var body: some View {
        Group {
            if let a {
                content(a)
            } else {
                Text("Activiteit verwijderd").foregroundStyle(Theme.muted).onAppear { dismiss() }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let a {
                    HStack(spacing: 8) {
                        Image(systemName: a.type.icon).font(.title3)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(a.type.name.uppercased()).font(.subheadline.weight(.bold)).tracking(1.5)
                            Text("\(a.start.formatted(.dateTime.day().month(.abbreviated))) \(DV.clock(a.start)) tot \(a.end.map(DV.clock) ?? "nu")")
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) { Button { editing = true } label: { Image(systemName: "ellipsis") } }
        }
        .sheet(isPresented: $editing) { if let a { ActivityEditSheet(existing: a) } }
        .task(id: "\(a?.start.timeIntervalSince1970 ?? 0)-\(a?.end?.timeIntervalSince1970 ?? 0)-\(store.revision)") { loadHr() }
    }

    private func loadHr() {
        guard let a else { return }
        let lo = a.start.addingTimeInterval(-300), hi = a.effectiveEnd.addingTimeInterval(300)
        var s = store.samples(day: a.start)
        if !Calendar.current.isDate(a.start, inSameDayAs: hi) { s += store.samples(day: hi) }
        var b: [Int: (Double, Int)] = [:]
        for x in s where x.hr > 0 {
            let d = Date(timeIntervalSince1970: TimeInterval(x.t))
            guard d >= lo && d <= hi else { continue }
            let k = Int(x.t) / 15; b[k, default: (0, 0)].0 += Double(x.hr); b[k, default: (0, 0)].1 += 1
        }
        hr = b.keys.sorted().map { (Date(timeIntervalSince1970: TimeInterval($0 * 15)), b[$0]!.0 / Double(b[$0]!.1)) }
    }

    @ViewBuilder private func content(_ a: Activity) -> some View {
        let prev = acts.previous(a)
        let ps = prev.compactMap(\.summary)
        let sum = a.summary
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                if a.isOngoing {
                    Button { acts.stop(a.id, store: store) } label: {
                        Label("Stop activiteit", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.hr).controlSize(.large)
                }
                HStack(alignment: .top, spacing: 28) {
                    big(sum.map { String(format: "%.1f", $0.strain) } ?? "–", "Belasting", color: actBlue,
                        avg: DV.mean(ps.map(\.strain)).map { String(format: "%.1f", $0) }, delta: sum.flatMap { s in DV.mean(ps.map(\.strain)).map { s.strain - $0 } })
                    let st = prev.compactMap(\.steps).map(Double.init)
                    big(a.steps.map { $0.formatted() } ?? "–", "Stappen", color: Theme.text,
                        avg: DV.mean(st).map { Int($0).formatted() }, delta: a.steps.flatMap { s in DV.mean(st).map { Double(s) - $0 } })
                }
                chart(a)
                HStack {
                    Spacer()
                    Text("DUUR").font(Theme.label).tracking(1.5).foregroundStyle(Theme.muted)
                    Text(fmtDur(a.duration)).font(.subheadline.weight(.bold)).monospacedDigit()
                }
                if let sum { zones(sum) }
                stats(a, sum, ps)
                Text(note(a)).font(.caption).foregroundStyle(Theme.muted)
            }
            .padding()
        }
    }

    private func big(_ v: String, _ label: String, color: Color, avg: String?, delta: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(v).font(Theme.number(44)).foregroundStyle(color).monospacedDigit()
                if let avg { DeltaPill(text: avg, delta: delta) }
            }
            Text(label.uppercased()).font(Theme.label).tracking(1.8).foregroundStyle(Theme.muted)
        }
    }

    private func chart(_ a: Activity) -> some View {
        Card {
            if hr.count > 1 {
                Chart {
                    ForEach(hr.indices, id: \.self) { i in
                        AreaMark(x: .value("Tijd", hr[i].0), yStart: .value("", 40), yEnd: .value("bpm", hr[i].1))
                            .foregroundStyle(LinearGradient(colors: [actBlue.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Tijd", hr[i].0), y: .value("bpm", hr[i].1))
                            .foregroundStyle(actBlue).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    RuleMark(x: .value("Begin", a.start)).foregroundStyle(Theme.muted).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    RuleMark(x: .value("Einde", a.effectiveEnd)).foregroundStyle(Theme.muted).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                .chartYScale(domain: max(40, (hr.map(\.1).min() ?? 60) - 10)...((hr.map(\.1).max() ?? 150) + 10))
                .chartXAxis { AxisMarks(values: [a.start, a.effectiveEnd]) { _ in AxisValueLabel(format: .dateTime.hour().minute()) } }
                .frame(height: 220)
            } else {
                Text("Geen hartslag opgeslagen in deze periode. De app moet tijdens de activiteit met je band verbonden zijn, of de Whoop-historie moet zijn uitgelezen.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
            }
        }
    }

    private func zones(_ s: ActivitySummary) -> some View {
        let bounds = WhoopScores.zoneLowerBounds(UserProfile.current)
        let total = max(1, s.zoneSec.reduce(0, +))
        return VStack(spacing: 8) {
            ForEach((0...5).reversed(), id: \.self) { z in
                let frac = s.zoneSec[z] / total
                let range = z == 0 ? "<\(bounds[1]) BPM" : z == 5 ? "\(bounds[5])+ BPM" : "\(bounds[z])–\(bounds[z + 1] - 1) BPM"
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("ZONE \(z)").font(.subheadline.weight(.bold)).tracking(1.2)
                        Text(range).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                        Text("\(Int((frac * 100).rounded()))%").font(.caption.weight(.semibold)).foregroundStyle(Theme.zones[z].color)
                        Spacer()
                        Text(fmtDur(s.zoneSec[z])).font(.subheadline.weight(.bold)).monospacedDigit()
                    }
                    if frac > 0 {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.line)
                                Capsule().fill(Theme.zones[z].color).frame(width: max(6, g.size.width * frac))
                            }
                        }
                        .frame(height: 10)
                    }
                }
                .opacity(frac > 0 ? 1 : 0.45)
                .padding(14)
                .background(Theme.cardHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func stats(_ a: Activity, _ s: ActivitySummary?, _ ps: [ActivitySummary]) -> some View {
        let durs = acts.previous(a).map(\.duration)
        let tiles: [(String, String, String, String?, Double?)] = [
            ("flame", "Calorieën", s.map { "\(Int($0.kcal.rounded())) kcal" } ?? "–",
             DV.mean(ps.map(\.kcal)).map { "\(Int($0.rounded())) kcal" }, s.flatMap { x in DV.mean(ps.map(\.kcal)).map { x.kcal - $0 } }),
            ("heart", "Gem. HR", s.map { "\(Int($0.avgHr.rounded())) bpm" } ?? "–",
             DV.mean(ps.map(\.avgHr)).map { "\(Int($0.rounded())) bpm" }, s.flatMap { x in DV.mean(ps.map(\.avgHr)).map { x.avgHr - $0 } }),
            ("arrow.up.heart", "Max. HR", s.map { "\(Int($0.maxHr.rounded())) bpm" } ?? "–",
             DV.mean(ps.map(\.maxHr)).map { "\(Int($0.rounded())) bpm" }, s.flatMap { x in DV.mean(ps.map(\.maxHr)).map { x.maxHr - $0 } }),
            ("stopwatch", "Duur", fmtDur(a.duration),
             DV.mean(durs).map(fmtDur), DV.mean(durs).map { a.duration - $0 })
        ]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("KERNCIJFERS").font(.subheadline.weight(.bold)).tracking(1.5)
                Spacer()
                Text(ps.isEmpty ? "NOG GEEN VERGELIJKING" : "VS. 30-DAAGS GEMIDDELDE").font(Theme.label).tracking(1.2).foregroundStyle(Theme.muted)
            }
            .padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(tiles, id: \.1) { t in
                        VStack(alignment: .leading, spacing: 14) {
                            Label(t.1.uppercased(), systemImage: t.0).font(Theme.label).tracking(1.2).foregroundStyle(Theme.muted)
                            Text(t.2).font(Theme.number(28)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                            if let avg = t.3 { DeltaPill(text: avg, delta: t.4) } else { Text(" ").font(.caption) }
                        }
                        .frame(width: 170, alignment: .leading).padding(16)
                        .background(Theme.cardHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }
    }

    private func note(_ a: Activity) -> String {
        var t = "Zones op basis van je hartslagreserve (max- en rust-HR uit je profiel). Calorieën zijn een schatting uit je hartslag. Stappen komen van je iPhone (alleen als je hem bij je had)."
        if a.auto { t += " Automatisch herkend op verhoogde hartslag; tik op ⋯ om de soort of tijden aan te passen of te verwijderen." }
        return t
    }
}

/// Kleine pil met het gemiddelde en een pijl omhoog/omlaag t.o.v. dat gemiddelde.
struct DeltaPill: View {
    let text: String
    let delta: Double?
    var body: some View {
        HStack(spacing: 4) {
            if let delta, abs(delta) > 1e-6 {
                Image(systemName: delta > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 8))
            }
            Text(text).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(Theme.text.opacity(0.85))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.cardHi, in: RoundedRectangle(cornerRadius: 6))
    }
}
