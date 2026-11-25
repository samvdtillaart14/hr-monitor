import SwiftUI
import WhoopScores

/// Ontwikkelaarstool: zoekt het trilcommando van de band door een vaste lijst kandidaten één voor één te sturen.
/// Alleen commando's uit `allowed` kunnen worden verstuurd; reset-, firmware-, historie- en herstartcommando's niet.
struct HapticProbeView: View {
    struct Candidate: Identifiable {
        let id: Int
        let cmd: UInt8
        let body: () -> [UInt8]
        let note: String
    }
    struct Result: Codable, Identifiable {
        var id: Int
        var cmd: UInt8
        var body: String
        var response: String
        var felt: Bool
    }

    /// Alleen het wekkerdeel: SET (66) en RUN (68). Niets anders kan worden verstuurd.
    static let allowed: Set<UInt8> = [0x42, 0x44]
    private static let resultsKey = "probe.hapticResults"

    @EnvironmentObject var ble: BLEManager
    @State private var index = 0
    @State private var lastResponse = "–"
    @State private var sentAt: Date?
    @State private var results: [Result] = Self.load()

    private static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
    /// Wekker 8 over 2 s, met aangepaste staart (zelfde opbouw als de Whoop-app: `04 id` + tijd + 15 bytes).
    private static func alarm8(_ edit: @escaping (inout [UInt8]) -> Void) -> () -> [UInt8] {
        {
            var tail: [UInt8] = [0, 0, 0x2F, 0x98, 0, 0, 0, 0, 0, 0, 0, 0, 0x07, 0x1E, 0x00]
            edit(&tail)
            return [0x04, 0x08] + le32(UInt32(Date().addingTimeInterval(2).timeIntervalSince1970)) + tail
        }
    }

    static let candidates: [Candidate] = {
        var c: [Candidate] = []
        func add(_ cmd: UInt8, _ body: @escaping () -> [UInt8], _ note: String) { c.append(.init(id: c.count, cmd: cmd, body: body, note: note)) }
        // Eerst de huidige bevestigingstrilling als referentie.
        add(0x42, alarm8 { $0[12] = 1; $0[13] = 1 }, "Wekker 8, 1× 1 s (huidige bevestiging, referentie)")
        add(0x42, alarm8 { _ in }, "Wekker 8 met de staart van de Whoop-app (7× / 30 s?), even laten lopen")
        // Byte 12 (vermoedelijk herhalingen) en byte 13 (vermoedelijk duur).
        for (r, d) in [(3, 1), (1, 3), (1, 0), (2, 0), (3, 0), (0, 1)] as [(UInt8, UInt8)] {
            add(0x42, alarm8 { $0[12] = r; $0[13] = d }, "Wekker 8, byte12 = \(r), byte13 = \(d)")
        }
        // Bytes 2–3 (2F 98 bij de Whoop-app): mogelijk het trilpatroon.
        for p: UInt8 in [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x10, 0x20] {
            add(0x42, alarm8 { $0[2] = p; $0[3] = 0; $0[12] = 1; $0[13] = 1 }, "Wekker 8, patroonbytes = \(String(format: "%02X", p)) 00")
        }
        for b in 4...11 {
            add(0x42, alarm8 { $0[b] = 0x01; $0[12] = 1; $0[13] = 1 }, "Wekker 8, onbekende byte \(b) = 01")
        }
        // RUN (68) in de 5.0-vorm: wekker 8 meteen laten afgaan.
        add(0x44, { [0x04, 0x08] }, "RUN: wekker 8 nu laten afgaan (5.0-vorm)")
        return c
    }()

    var body: some View {
        let c = Self.candidates[index]
        List {
            Section {
                Text("Stuurt per stap één kandidaat-commando naar de band. Voel je iets, druk op Trilde!, anders op Niets. Alleen het wekkercommando (SET en RUN, wekker 8) met andere instellingen; elk ander commando is geblokkeerd. Je echte wekker blijft ongemoeid. Klein risico: een vreemde instelling kan wekker 8 langer laten trillen; tik dan op de band om hem uit te zetten. Doe dit niet terwijl de Whoop-app synchroniseert.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            Section("Stap \(index + 1) van \(Self.candidates.count)") {
                Text(c.note).font(.headline)
                Text("cmd \(c.cmd) · \(hex(c.body()))").font(.caption.monospaced()).foregroundStyle(Theme.muted)
                Button("Verstuur") { send(c) }.disabled(ble.state != .connected || !Self.allowed.contains(c.cmd))
                Text("Antwoord band: \(lastResponse)").font(.caption.monospaced())
                HStack {
                    Button("Trilde!") { record(c, felt: true) }.buttonStyle(.borderedProminent).tint(Theme.accent)
                    Spacer()
                    Button("Niets") { record(c, felt: false) }.buttonStyle(.bordered)
                }.disabled(sentAt == nil)
            }
            Section("Resultaten") {
                ForEach(results.reversed()) { r in
                    HStack {
                        Image(systemName: r.felt ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(r.felt ? Theme.accent : Theme.muted)
                        Text("cmd \(r.cmd) [\(r.body)] → \(r.response)").font(.caption.monospaced())
                    }
                }
                if !results.isEmpty {
                    ShareLink(item: results.map { "\($0.felt ? "TRILDE" : "niets") cmd \($0.cmd) [\($0.body)] → \($0.response)" }.joined(separator: "\n")) {
                        Label("Deel resultaten", systemImage: "square.and.arrow.up")
                    }
                    Button("Opnieuw beginnen", role: .destructive) { results = []; index = 0; save() }
                }
            }
        }
        .navigationTitle("Trilcommando zoeken")
        .onAppear { ble.onProbeResponse = { cmd, res, body in lastResponse = "cmd \(cmd) → \(SleepAlarm.resultText(res)) [\(hex(body))]" } }
        .onDisappear { ble.onProbeResponse = nil }
    }

    private func send(_ c: Candidate) {
        guard Self.allowed.contains(c.cmd) else { return }
        lastResponse = "wacht…"
        let body = c.body()
        if let e = ble.sendBandAlarm(c.cmd, body: body) { lastResponse = "niet verstuurd: \(e)"; return }
        sentAt = Date()
    }

    private func record(_ c: Candidate, felt: Bool) {
        results.append(Result(id: results.count, cmd: c.cmd, body: hex(c.body()), response: lastResponse, felt: felt))
        save()
        sentAt = nil
        lastResponse = "–"
        if index + 1 < Self.candidates.count { index += 1 }
    }

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

    private func save() {
        if let d = try? JSONEncoder().encode(results) { UserDefaults.standard.set(d, forKey: Self.resultsKey) }
    }
    private static func load() -> [Result] {
        (UserDefaults.standard.data(forKey: resultsKey)).flatMap { try? JSONDecoder().decode([Result].self, from: $0) } ?? []
    }
}
