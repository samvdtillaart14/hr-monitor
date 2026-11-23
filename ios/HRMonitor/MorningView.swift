import SwiftUI
import UniformTypeIdentifiers
import WhoopScores

/// Opent het ochtendoverzicht na een tik op de ochtendmelding.
@MainActor
final class MorningRouter: ObservableObject {
    static let shared = MorningRouter()
    @Published var show = false
}

extension View {
    /// Het ochtendoverzicht als volledig scherm boven de tabbladen.
    func morningOverview() -> some View { modifier(MorningOverviewModifier()) }
}

private struct MorningOverviewModifier: ViewModifier {
    @ObservedObject private var router = MorningRouter.shared
    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $router.show) { MorningView() }
    }
}

/// Ochtendoverzicht: in ~5 seconden te lezen. Eén hoofdregel, per kaart één getal en één zin, één advies.
struct MorningView: View {
    @EnvironmentObject var scores: ScoreModel
    @EnvironmentObject var store: DayStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let night = scores.lastNight
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                HStack {
                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide).locale(DV.nl)).capitalized)
                        .font(.subheadline).foregroundStyle(Theme.muted)
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .foregroundStyle(Theme.muted).accessibilityLabel("Sluiten")
                }
                if let night {
                    content(Self.summary(night, scores: scores))
                } else {
                    Text("Geen nacht gemeten").font(.system(size: 34, weight: .heavy))
                    Text("Droeg je de band en was de app verbonden? Open Vandaag zodra de band gesynchroniseerd is.")
                        .foregroundStyle(Theme.muted)
                }
                Button { dismiss() } label: {
                    Text("Naar vandaag").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).padding(.top, 8)
            }
            .padding()
        }
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { if scores.lastNight == nil { scores.refresh(store: store) } }
    }

    @ViewBuilder private func content(_ s: MorningSummary) -> some View {
        // De enige hoofdregel op dit scherm.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let r = s.recovery {
                    Text("\(r)%").font(Theme.number(56)).foregroundStyle(DV.recoveryColor(r))
                }
                Text(s.headline).font(.system(size: 26, weight: .heavy))
            }
            Text(s.sentence).foregroundStyle(Theme.muted)
        }
        .padding(.bottom, 4)
        ForEach(Array(s.cards.enumerated()), id: \.offset) { k, c in
            Card(title: c.title, index: k + 1) {
                Text(c.value).font(Theme.number(30))
                Text(c.sentence).font(.subheadline).foregroundStyle(Theme.muted)
            }
        }
        Card(title: "Advies", index: s.cards.count + 1) {
            Text(s.advice).font(.headline)
        }
    }

    /// Vergelijkt afgelopen nacht met je eigen gemiddelde (tot 30 eerdere nachten).
    static func summary(_ n: Night, scores: ScoreModel) -> MorningSummary {
        let prior = NightArchive.shared.metrics(before: DayStore.dayFmt.string(from: n.date), limit: 30)
        func mean(_ v: [Double]) -> Double? { v.count >= 3 ? v.reduce(0, +) / Double(v.count) : nil }
        let earlier = scores.nights.filter { $0.date < n.date }.map { Double($0.r.asleepMin) }
        return MorningSummary.make(.init(
            recovery: n.recovery, asleepMin: n.r.asleepMin, debtMin: Int(n.debtMin.rounded()),
            hrv: n.r.hrv.isFinite ? n.r.hrv : nil, rhr: n.r.rhr.isFinite ? n.r.rhr : nil,
            disturbances: n.r.disturbances,
            hrvBase: mean(prior.compactMap(\.hrv)), rhrBase: mean(prior.compactMap(\.rhr)),
            sleepBase: mean(earlier), baseNights: prior.count))
    }
}

/// Instellingen › Back-up: alle data bewaren en na herinstallatie terugzetten.
struct BackupSection: View {
    @State private var busy = false
    @State private var share: WeekShare?
    @State private var picking = false
    @State private var message: String?

    var body: some View {
        Section {
            Button { run { WeekShare(urls: try Backup.export()) } } label: {
                HStack {
                    Label("Back-up maken", systemImage: "externaldrive.badge.plus")
                    if busy { Spacer(); ProgressView() }
                }
            }.disabled(busy)
            Button { picking = true } label: { Label("Back-up terugzetten", systemImage: "externaldrive.badge.timemachine") }
                .disabled(busy)
        } header: { Text("Back-up") } footer: {
            Text("Bewaart al je metingen, nachten, activiteiten en instellingen in zip-bestanden (max. 25 MB per stuk). Zet ze in Bestanden of iCloud. Na opnieuw installeren: kies hier alle zip-bestanden tegelijk en open de app daarna opnieuw.")
        }
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            run {
                let open = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer { open.forEach { $0.stopAccessingSecurityScopedResource() } }
                let r = try Backup.restore(urls)
                var t = "\(r.restored) bestanden teruggezet"
                if r.kept > 0 { t += ", \(r.kept) overgeslagen (hier al vollediger)" }
                if r.settings { t += ", instellingen hersteld" }
                return t + ". Sluit de app helemaal af en open hem opnieuw om alles te laden."
            }
        }
        .alert("Back-up", isPresented: .init(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    /// Op de achtergrond uitvoeren; een WeekShare opent het deelmenu, tekst komt als melding.
    private func run(_ work: @escaping () throws -> Any) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try work() }
            DispatchQueue.main.async {
                busy = false
                switch r {
                case .success(let s as WeekShare): share = s
                case .success(let t as String): message = t
                case .success: break
                case .failure(let e): message = e.localizedDescription
                }
            }
        }
    }
}
