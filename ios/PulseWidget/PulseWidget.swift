import WidgetKit
import SwiftUI
import UIKit

struct Entry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snap: WidgetSnapshot(recovery: 72, sleepPerf: 85, asleepMin: 452, strain: 9, bedtime: Date(), wake: Date()))
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
private func hex(_ v: UInt32) -> Color {
    Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}
private let sleepC = hex(0x8FA8C8), strainC = hex(0x3B82F6), lineC = Color.primary.opacity(0.1)

/// Zelfde ring als op Vandaag: grijze baan, gekleurde boog, getal in het midden, label eronder.
struct WidgetRing: View {
    let label: String, value: Double?, text: String, color: Color
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(lineC, lineWidth: 7)
                Circle().trim(from: 0, to: min(1, max(0, value ?? 0)))
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(text).font(.system(size: 20, weight: .heavy)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1).padding(6)
                    .foregroundStyle(.primary)
            }
            .frame(width: 78, height: 78)
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
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
        case .systemMedium:
            HStack(spacing: 4) {
                WidgetRing(label: "Slaap", value: s?.sleepPerf.map { Double($0) / 100 },
                           text: s?.sleepPerf.map { "\($0)%" } ?? "--", color: sleepC)
                WidgetRing(label: "Herstel", value: s?.recovery.map { Double($0) / 100 },
                           text: s?.recovery.map { "\($0)%" } ?? "--", color: recColor(s?.recovery))
                WidgetRing(label: "Belasting", value: s?.strain.map { $0 / 21 },
                           text: s?.strain.map { String(format: "%.0f", $0) } ?? "--", color: strainC)
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
            PulseWidgetView(entry: e).containerBackground(Color(UIColor.systemBackground), for: .widget)
        }
        .configurationDisplayName("Pulse")
        .description("Slaap, herstel en belasting zoals op Vandaag.")
        .supportedFamilies([.systemMedium, .systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
