import SwiftUI
import WhoopScores

/// Kalender met per dag een gekleurd bolletje voor het herstel (rood/geel/groen).
/// Tik op een dag om die dag op Vandaag te bekijken.
struct RecoveryCalendarSheet: View {
    @Binding var selected: Date
    let minDate: Date
    @Environment(\.dismiss) private var dismiss
    private let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.locale = DV.nl; c.firstWeekday = 2; return c }()

    var body: some View {
        let nights = NightArchive.shared.all
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                        ForEach(months, id: \.self) { m in
                            month(m, nights: nights).id(m)
                        }
                        legend
                    }.padding()
                }
                .onAppear { if let l = months.last { proxy.scrollTo(l, anchor: .bottom) } }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Kalender")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Klaar") { dismiss() } }
        }
    }

    /// Eerste dag van deze maand en de 2 maanden ervoor (het archief bewaart 90 nachten).
    private var months: [Date] {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        return (0...2).reversed().compactMap { cal.date(byAdding: .month, value: -$0, to: first) }
    }

    private func month(_ start: Date, nights: [String: NightMetrics]) -> some View {
        let days = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        let lead = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return VStack(alignment: .leading, spacing: 10) {
            Text(start.formatted(.dateTime.locale(DV.nl).month(.wide).year()).capitalized).font(.headline)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(["ma", "di", "wo", "do", "vr", "za", "zo"], id: \.self) {
                    Text($0).font(.caption2).foregroundStyle(Theme.muted)
                }
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 40) }
                ForEach(0..<days, id: \.self) { i in
                    let d = cal.date(byAdding: .day, value: i, to: start)!
                    cell(d, recovery: nights[DayStore.dayFmt.string(from: d)]?.recovery)
                }
            }
        }
    }

    private func cell(_ d: Date, recovery: Double?) -> some View {
        let enabled = d >= minDate && d <= Date()
        let isSel = cal.isDate(d, inSameDayAs: selected)
        let r = recovery.map { Int($0.rounded()) }
        return Button {
            selected = cal.isDateInToday(d) ? Date() : d
            dismiss()
        } label: {
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: d))")
                    .font(.subheadline.weight(cal.isDateInToday(d) ? .heavy : .regular))
                    .foregroundStyle(enabled ? Theme.text : Theme.muted.opacity(0.5))
                ZStack {
                    Circle().fill(r == nil ? Theme.line : DV.recoveryColor(r)).frame(width: 22, height: 22)
                    if let r { Text("\(r)").font(.system(size: 9, weight: .bold)).foregroundStyle(.black) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.vertical, 2)
            .background(isSel ? Theme.cardHi : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            item(Theme.accent, "67–100%"); item(Theme.zones[3].color, "34–66%"); item(Theme.hr, "0–33%")
        }.font(.caption).foregroundStyle(Theme.muted)
    }

    private func item(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 8, height: 8); Text(t) }
    }
}
