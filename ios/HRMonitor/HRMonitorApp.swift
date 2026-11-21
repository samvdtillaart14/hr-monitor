import SwiftUI
import Charts

@main
struct HRMonitorApp: App {
    @StateObject private var ble = BLEManager()
    @StateObject private var store = DayStore()
    var body: some Scene {
        WindowGroup {
            TabView {
                TodayView().tabItem { Label("Vandaag", systemImage: "sun.max.fill") }
                ContentView().tabItem { Label("Live", systemImage: "heart.fill") }
            }
                .onAppear { ble.store = store }
                .environmentObject(store)
                .environmentObject(ble)
                .environmentObject(ble.recorder)
                .environmentObject(ble.raw)
                .environmentObject(ble.whoop)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var rec: Recorder
    @EnvironmentObject var whoop: WhoopParser
    @State private var showDevices = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.gap) {
                    statusBar
                    HeartRing(bpm: ble.bpm).padding(.vertical, 12)
                    hrTile
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.gap), GridItem(.flexible())], spacing: Theme.gap) {
                        Tile(title: "Min / gem / max", value: mmText, unit: "", small: true, index: 1)
                        Tile(title: "RR-interval", value: ble.lastRR.map { "\(Int($0))" } ?? "--", unit: "ms", index: 2)
                        Tile(title: "HRV (RMSSD)", value: ble.rmssd.map { "\(Int($0))" } ?? "--", unit: "ms", index: 3)
                        Tile(title: "Huidtemp", value: whoop.lastRecord?.skinTemp.map { String(format: "%.1f", $0) } ?? "--", unit: "°C", index: 4)
                        Tile(title: "Batterij", value: ble.battery.map(String.init) ?? "--", unit: "%", index: 5)
                        Tile(title: "Zone", value: ble.bpm.map { Theme.zone($0).name } ?? "--", unit: "", small: true, index: 6)
                    }
                    chart
                    Card(title: "Tijd per zone", index: 8) { ZoneTime(samples: ble.samples) }
                    recordSection
                }
                .padding()
            }
            .background(Theme.bg.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .navigationTitle("HR Monitor")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink("Verkenner") { ExplorerView() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink { UpdateView() } label: { Image(systemName: "arrow.down.circle") }
                    NavigationLink("Opnames") { FilesView() }
                }
            }
            .sheet(isPresented: $showDevices) { DeviceSheet(isPresented: $showDevices) }
        }
    }

    private var mmText: String {
        guard let a = ble.sessionMin, let b = ble.sessionAvg, let c = ble.sessionMax else { return "--" }
        return "\(a) / \(Int(b.rounded())) / \(c)"
    }

    private var statusBar: some View {
        HStack {
            Circle().fill(statusColor).frame(width: 10, height: 10)
                .shadow(color: statusColor, radius: ble.state == .connected ? 6 : 0)
            Text(statusText).font(.subheadline)
            Spacer()
            if ble.state == .connected || ble.state == .connecting {
                Button("Verbreek", role: .destructive) { ble.disconnect() }
            } else {
                Button("Zoek band") { showDevices = true; ble.scan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(ble.state == .off || ble.state == .unauthorized)
            }
        }
    }

    private var statusText: String {
        switch ble.state {
        case .off: return "Bluetooth staat uit"
        case .unauthorized: return "Geen Bluetooth-toestemming (Instellingen)"
        case .idle: return "Niet verbonden"
        case .scanning: return "Zoeken…"
        case .connecting: return "Wachten op \(ble.deviceName ?? "band")…"
        case .connected: return "Verbonden: \(ble.deviceName ?? "band")"
        }
    }
    private var statusColor: Color {
        switch ble.state {
        case .connected: return .green
        case .connecting, .scanning: return .orange
        default: return .gray
        }
    }

    private var hrTile: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CONTACT").font(Theme.label).foregroundStyle(Theme.muted).tracking(2)
                    Text(ble.contact).font(.headline)
                }
                Spacer()
                if let s = ble.sessionStart {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("SESSIE").font(Theme.label).foregroundStyle(Theme.muted).tracking(2)
                        Text(s, style: .timer).font(.headline).monospacedDigit()
                    }
                }
            }
        }
    }

    private var chart: some View {
        let zc = ble.bpm.map { Theme.zone($0).color } ?? Theme.hr
        return Card(title: "Hartslag · laatste 5 min", index: 7) {
            Chart(ble.samples) {
                AreaMark(x: .value("Tijd", $0.time), y: .value("bpm", $0.bpm))
                    .foregroundStyle(LinearGradient(colors: [zc.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Tijd", $0.time), y: .value("bpm", $0.bpm))
                    .foregroundStyle(zc).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis(.hidden)
            .frame(height: 180)
            .animation(.easeInOut(duration: 0.6), value: ble.samples.count)
        }
    }

    private var recordSection: some View {
        VStack(spacing: 8) {
            Button {
                rec.isRecording ? rec.stop() : rec.start()
            } label: {
                Label(rec.isRecording ? "Stop opname" : "Start opname",
                      systemImage: rec.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(rec.isRecording ? Theme.cardHi : Theme.hr).controlSize(.large)
            .clipShape(Capsule())
            if rec.isRecording {
                Text("\(rec.rows) metingen opgeslagen · loopt door met scherm uit").font(.footnote).foregroundStyle(.secondary)
            }
            Button("Sessie-statistieken wissen") { ble.resetSession() }.font(.footnote)
        }
    }
}

struct Tile: View {
    let title: String, value: String, unit: String
    var small = false
    var index = 0
    var body: some View {
        Card(title: title, index: index) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Theme.number(small ? 22 : 32)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText()).animation(Theme.spring, value: value)
                Text(unit).font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct DeviceSheet: View {
    @EnvironmentObject var ble: BLEManager
    @Binding var isPresented: Bool
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ble.found) { d in
                        Button {
                            ble.connect(d.id); isPresented = false
                        } label: {
                            HStack { Text(d.name); Spacer(); Text("\(d.rssi) dBm").foregroundStyle(.secondary).font(.footnote) }
                        }
                    }
                } footer: {
                    Text("Zet in de Whoop-app Heart Rate Broadcast aan. Sluit de Whoop-app als de band niet verschijnt; hij verbindt vaak maar met één apparaat tegelijk.")
                }
            }
            .overlay { if ble.found.isEmpty { ProgressView("Zoeken…") } }
            .navigationTitle("Kies je band")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Sluit") { ble.stopScan(); isPresented = false } } }
        }
    }
}

struct FilesView: View {
    @EnvironmentObject var rec: Recorder
    var body: some View {
        List {
            ForEach(rec.files, id: \.self) { url in
                let kind = Recorder.Kind.of(url)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                ShareLink(item: url) {
                    HStack(spacing: 12) {
                        Image(systemName: kind?.icon ?? "doc.text").foregroundStyle(Theme.accent).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind?.title ?? "Bestand").font(.headline).foregroundStyle(Theme.text)
                            Text(url.lastPathComponent).font(.caption.monospaced()).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .swipeActions {
                    if url != rec.currentURL || !rec.isRecording {
                        Button("Verwijder", role: .destructive) { rec.delete(url) }
                    }
                }
            }
        }
        .overlay { if rec.files.isEmpty { Text("Nog geen opnames").foregroundStyle(.secondary) } }
        .navigationTitle("Opnames")
        .onAppear { rec.refresh() }
    }
}
