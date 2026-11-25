import SwiftUI

/// Toont alle services/characteristics van de band, de laatste ruwe waarde,
/// een live log, en laat je de ruwe data opnemen of hex-commando's sturen.
struct ExplorerView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var raw: RawLogger
    @EnvironmentObject var whoop: WhoopParser
    @State private var target: String?
    @State private var hex = ""
    @State private var error: String?

    private var grouped: [(String, [BLEManager.CharInfo])] {
        Dictionary(grouping: ble.chars, by: \.service).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        List {
            Section {
                Button {
                    if raw.isRecording { Recorder.alwaysOn = false; raw.stop() } else { raw.start() }
                } label: {
                    Label(raw.isRecording ? "Stop ruwe opname (\(raw.rows) regels)" : "Start ruwe opname",
                          systemImage: raw.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .tint(raw.isRecording ? .gray : .red)
            } footer: {
                Text("Neemt alle data van alle characteristics op in ruw_<datum>.csv (zie Opnames). Loopt ook door met scherm uit.")
            }

            Section {
                LabeledContent("Geldige frames", value: "\(whoop.frames)")
                if whoop.badFrames > 0 { LabeledContent("Ongeldige frames", value: "\(whoop.badFrames)") }
                LabeledContent("Historische records (uniek)", value: "\(whoop.records)")
                if let r = whoop.lastRecord {
                    LabeledContent("Laatste record", value: Date(timeIntervalSince1970: TimeInterval(r.time)).formatted(date: .omitted, time: .standard))
                    LabeledContent("HR in record", value: "\(r.hr) bpm")
                    LabeledContent("Huidtemp", value: r.skinTemp.map { String(format: "%.2f °C", $0) } ?? "–")
                }
                if let t = whoop.lastLiveTime {
                    LabeledContent("Live-pakket (tijd band)", value: t.formatted(date: .omitted, time: .standard))
                }
                ForEach(whoop.typeCounts.keys.sorted(), id: \.self) { k in
                    LabeledContent(String(format: "Type 0x%02X", k), value: "\(whoop.typeCounts[k] ?? 0)")
                }
                if let r = whoop.lastResponse { LabeledContent("Laatste antwoord", value: r) }
                if let hr = whoop.liveHR {
                    LabeledContent("Live HR (Whoop-kanaal)", value: "\(hr) bpm" + (whoop.liveRR.isEmpty ? "" : " · RR \(whoop.liveRR.map(String.init).joined(separator: ", ")) ms"))
                }
                if !whoop.logLines.isEmpty {
                    DisclosureGroup("Firmware-log (\(whoop.logLines.count))") {
                        ForEach(Array(whoop.logLines.enumerated().reversed()), id: \.offset) { Text($0.element).font(.caption2.monospaced()) }
                    }
                }
                Button("Stuur hello (veilig, alleen info)") { error = ble.sendWhoop(cmd: 0x91, body: [0x01]) }
                Button("Realtime-hartslag aan (cmd 3)") { error = ble.sendWhoop(cmd: 3, body: [0x01]) }
                Button("Historie opvragen (cmd 22)") { error = ble.sendWhoop(cmd: 22, body: [0x00]) }
                Button("Bewegingsdata aan (cmd 106)") { error = ble.sendWhoop(cmd: 106, body: [0x01, 0x01]) }
                Button("Ruwe sensordata aan (cmd 81)") { error = ble.sendWhoop(cmd: 81, body: [0x01]) }
                Button("Ruwe sensordata uit (cmd 82)") { error = ble.sendWhoop(cmd: 82, body: [0x01]) }
                if whoop.imuFrames > 0, let a = whoop.lastAccel {
                    LabeledContent("IMU-frames", value: "\(whoop.imuFrames) · acc \(a.0)/\(a.1)/\(a.2)")
                }
            } header: { Text("Whoop-decoder") } footer: {
                Text("Historische records worden opgeslagen in whoop_historie_<datum>.csv (zie Opnames). Decodering van HR en huidtemperatuur is nog voorlopig.")
            }

            if ble.chars.isEmpty {
                Text(ble.state == .connected ? "Services worden geladen…" : "Verbind eerst met je band.").foregroundStyle(.secondary)
            }

            ForEach(grouped, id: \.0) { svc, list in
                Section("Service \(svc)") {
                    ForEach(list) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(c.uuid).font(.caption.monospaced()).lineLimit(1).minimumScaleFactor(0.6)
                                Spacer()
                                if c.notifying { Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green) }
                                Text("\(c.count)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(c.props).font(.caption2).foregroundStyle(.secondary)
                            if !c.last.isEmpty {
                                Text(c.last).font(.caption2.monospaced()).lineLimit(3).textSelection(.enabled)
                            }
                            HStack {
                                if c.props.contains("read") { Button("Lees") { ble.read(c.id) }.buttonStyle(.bordered) }
                                if c.props.contains("write") { Button("Schrijf…") { target = c.id; hex = "" }.buttonStyle(.bordered) }
                            }
                            .font(.caption)
                        }
                    }
                }
            }

            Section {
                ForEach(raw.lines.suffix(150).reversed()) { l in
                    Text(l.text).font(.caption2.monospaced()).lineLimit(2)
                }
            } header: {
                HStack { Text("Live log (nieuwste boven)"); Spacer(); Button("Wis") { raw.clear() }.font(.caption) }
            }
        }
        .navigationTitle("Verkenner")
        .alert("Hex sturen", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            TextField("bv. aa 01 ff", text: $hex)
            Button("Stuur") { if let t = target { error = ble.write(hex: hex, to: t) }; target = nil }
            Button("Annuleer", role: .cancel) { target = nil }
        } message: { Text(target ?? "") }
        .alert("Fout", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}
