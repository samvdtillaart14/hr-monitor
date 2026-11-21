import SwiftUI
import Charts

@main
struct HRMonitorApp: App {
    @StateObject private var ble = BLEManager()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .environmentObject(ble.recorder)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var rec: Recorder
    @State private var showDevices = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    statusBar
                    hrTile
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        Tile(title: "Min / gem / max", value: mmText, unit: "", small: true)
                        Tile(title: "RR-interval", value: ble.lastRR.map { "\(Int($0))" } ?? "--", unit: "ms")
                        Tile(title: "HRV (RMSSD, 60 s)", value: ble.rmssd.map { "\(Int($0))" } ?? "--", unit: "ms")
                        Tile(title: "Batterij", value: ble.battery.map(String.init) ?? "--", unit: "%")
                    }
                    chart
                    recordSection
                }
                .padding()
            }
            .navigationTitle("HR Monitor")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
                Text("HARTSLAG").font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(ble.bpm.map(String.init) ?? "--")
                        .font(.system(size: 80, weight: .semibold, design: .rounded))
                        .foregroundStyle(.red).monospacedDigit()
                        .contentTransition(.numericText())
                    Text("bpm").foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("CONTACT").font(.caption).foregroundStyle(.secondary)
                Text(ble.contact)
                if let s = ble.sessionStart {
                    Text("SESSIE").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    Text(s, style: .timer).monospacedDigit()
                }
            }
        }
        .padding().background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .animation(.default, value: ble.bpm)
    }

    private var chart: some View {
        VStack(alignment: .leading) {
            Text("HARTSLAG, LAATSTE 5 MIN").font(.caption).foregroundStyle(.secondary)
            Chart(ble.samples) {
                LineMark(x: .value("Tijd", $0.time), y: .value("bpm", $0.bpm))
                    .foregroundStyle(.red).interpolationMethod(.monotone)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 200)
        }
        .padding().background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
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
            .buttonStyle(.borderedProminent).tint(rec.isRecording ? .gray : .red).controlSize(.large)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: small ? 20 : 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(unit).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding().background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
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
                ShareLink(item: url) {
                    Label(url.lastPathComponent, systemImage: "doc.text")
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
