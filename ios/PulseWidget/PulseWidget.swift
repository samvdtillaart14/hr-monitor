import WidgetKit
import SwiftUI

struct Entry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snap: WidgetSnapshot(recovery: 72, sleepPerf: 85, asleepMin: 452, bedtime: Date(), wake: Date()))
    }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Entry(date: Date(), snap: WidgetSnapshot.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // De app ververst de widget zelf zodra er nieuwe scores zijn; dit is alleen een vangnet.
        completion(Timeline(entries: [Entry(date: Date(), snap: WidgetSnapshot.load())],
                            policy: .after(Date().addingTimeInterval(1800))))
    }
}

private let accent = Color(red: 0, green: 0.945, blue: 0.624)
private func recColor(_ r: Int?) -> Color {
    guard let r else { return .gray }
    return r >= 67 ? accent : r >= 34 ? Color(red: 1, green: 0.8, blue: 0.2) : Color(red: 1, green: 0.3, blue: 0.37)
}
private func clock(_ d: Date?) -> String { d?.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) ?? "--:--" }
private func hm(_ m: Int?) -> String { m.map { "\($0 / 60):" + String(format: "%02d", $0 % 60) } ?? "--" }

struct PulseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let s = entry.snap
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(s?.recovery ?? 0), in: 0...100) { Text("H") } currentValueLabel: { Text(s?.recovery.map(String.init) ?? "--") }
                .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Herstel \(s?.recovery.map { "\($0)%" } ?? "--")").font(.headline)
                Text("Slaap \(hm(s?.asleepMin))").font(.caption)
                Text("Bed \(clock(s?.bedtime)) · wekker \(clock(s?.wake))").font(.caption)
            }
        case .accessoryInline:
            Text("Herstel \(s?.recovery.map { "\($0)%" } ?? "--") · bed \(clock(s?.bedtime))")
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text("HERSTEL").font(.caption2.bold()).foregroundStyle(.secondary)
                Text(s?.recovery.map { "\($0)%" } ?? "--").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(recColor(s?.recovery))
                Text("Slaap \(hm(s?.asleepMin))\(s?.sleepPerf.map { " · \($0)%" } ?? "")").font(.caption)
                Label(clock(s?.bedtime), systemImage: "moon.zzz.fill").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@main
struct PulseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PulseWidget", provider: Provider()) { e in
            PulseWidgetView(entry: e).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Pulse")
        .description("Herstel, slaap en bedtijd.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
