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

    /// Het wekkerdeel (SET 66, RUN 68) en de haptics-commando's uit het bekende Whoop-protocol:
    /// RUN_HAPTIC_PATTERN_MAVERICK (19), RUN_HAPTICS_PATTERN (79), GET_ALL_HAPTICS_PATTERN (80, alleen lezen)
    /// en STOP_HAPTICS (122). Niets anders kan worden verstuurd (geen reset, herstart, trim of historie).
    static let allowed: Set<UInt8> = [0x42, 0x44, 0x13, 0x4F, 0x50, 0x7A]
    private static let resultsKey = "probe.hapticResults"

    @EnvironmentObject var ble: BLEManager
    @State private var index = 0
    @State private var lastResponse = "–"
    @State private var sentAt: Date?
    @State private var results: [Result] = Self.load()
    // Automatisch doorlopen
    @State private var sweeping = false
    @State private var sweepIndex = 0
    @State private var sweepLog: [String] = []
    @State private var sweepSent: [(t: Date, text: String)] = []

    /// Alleen de haptics-commando's 79 en 19, met alle waarden voor de eerste byte (en varianten met een tweede byte).
    /// Geen wekkercommando's en geen andere commando-id's (die kunnen resetten, herstarten of data wissen).
    static let sweep: [(cmd: UInt8, body: [UInt8])] = {
        var out: [(UInt8, [UInt8])] = []
        // Allereerst de Whoop 5-vorm uit de noop-documentatie: commando 19 met revisie 01, acht effectbytes (DRV2625),
        // u16 lusregeling en een herhaalbyte. Waargenomen: 01 2F 98 00 00 00 00 00 00 00 00 00.
        for fx: [UInt8] in [[0x2F, 0x98], [0x2F], [0x2F, 0x98, 0x2F, 0x98], [0x01], [0x0E], [0x34], [0x2F, 0x2F, 0x2F]] {
            let effects = fx + [UInt8](repeating: 0, count: 8 - fx.count)
            for (loop, rep) in [((0, 0), 0), ((0, 0), 1), ((1, 0), 0), ((0, 0), 3)] as [((UInt8, UInt8), UInt8)] {
                out.append((0x13, [0x01] + effects + [loop.0, loop.1, rep]))
            }
        }
        // Daarna de Whoop 4-vorm: 79 met 5 bytes [preset, herhalingen, 00 00 00].
        for preset in 0...20 { for loop: UInt8 in [1, 3] { out.append((0x4F, [UInt8(preset), loop, 0, 0, 0])) } }
        // Daarna gericht: het trildeel uit het wekkerpakket. De firmware start bij een wekker een "custom haptics"-
        // sequentie op de DRV2625-trildriver; 2F 98 lijkt daar de reeks (effect 47 = buzz, 0x98 = 240 ms pauze),
        // gevolgd door 8 lege plekken, herhalingen (07) en duur (1E 00 = 30 s).
        let seqs: [[UInt8]] = [
            [0x00, 0x00, 0x2F, 0x98, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x01, 0x00],   // hele wekkerstaart, 1× 1 s
            [0x2F, 0x98, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x01, 0x00],               // vanaf het patroon
            [0x2F, 0x98, 0, 0, 0, 0, 0, 0, 0, 0, 0x07, 0x1E, 0x00],               // zoals de wekker (7×, 30 s)
            [0x2F, 0x98, 0, 0, 0, 0, 0, 0],                                         // alleen de 8 reeksplekken
            [0x2F, 0x98], [0x2F], [0x2F, 0x00],
            [0x01, 0, 0, 0, 0, 0, 0, 0], [0x0E, 0, 0, 0, 0, 0, 0, 0], [0x34, 0, 0, 0, 0, 0, 0, 0],
        ]
        for cmd: UInt8 in [0x4F, 0x13] {
            for pre: [UInt8] in [[], [0x01], [0x00], [0x04, 0x08]] {
                for q in seqs { out.append((cmd, pre + q)) }
            }
        }
        for p in 0...255 { out.append((0x4F, [UInt8(p)])) }
        for p in 0...255 { out.append((0x4F, [UInt8(p), 0x01])) }
        for p in 0...255 { out.append((0x4F, [0x01, UInt8(p)])) }
        for p in 0...255 { out.append((0x13, [UInt8(p)])) }
        return out
    }()
    /// tijd tussen twee commando's (s); ~1100 × 0,12 s ≈ 2 min
    static let sweepGap = 0.12

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
        // Eerst de echte haptics-commando's (zonder wekkertruc). 80 leest alleen de patronen uit.
        add(0x50, { [] }, "Haptics-patronen opvragen (80, alleen lezen: stuur het antwoord door)")
        add(0x50, { [0x01] }, "Haptics-patronen opvragen (80) met 01")
        for body: [UInt8] in [[], [0x00], [0x01], [0x02], [0x03], [0x01, 0x01], [0x01, 0x00], [0x00, 0x01, 0x00, 0x00]] {
            add(0x4F, { body }, "Trilpatroon (79) [\(body.map { String(format: "%02X", $0) }.joined(separator: " "))]")
        }
        for body: [UInt8] in [[], [0x00], [0x01], [0x02], [0x01, 0x01]] {
            add(0x13, { body }, "Trilpatroon Maverick (19) [\(body.map { String(format: "%02X", $0) }.joined(separator: " "))]")
        }
        add(0x7A, { [] }, "Trillen stoppen (122)")
        // Daarna de wekkertruc: eerst de huidige bevestigingstrilling als referentie.
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
        // Delen van het wekkerpakket: ingekort of zonder tijdstip.
        let buzzTail: [UInt8] = [0, 0, 0x2F, 0x98, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x01, 0x00]
        let soon = { le32(UInt32(Date().addingTimeInterval(2).timeIntervalSince1970)) }
        add(0x42, { [0x04, 0x08] }, "SET deel: alleen 04 08 (geen tijd, geen staart)")
        add(0x42, { [0x04, 0x08] + soon() }, "SET deel: 04 08 + tijd, zonder staart")
        add(0x42, { [0x04, 0x08] + soon() + Array(buzzTail.prefix(4)) }, "SET deel: tijd + eerste 4 staartbytes")
        add(0x42, { [0x04, 0x08] + buzzTail }, "SET deel: 04 08 + staart, zonder tijd")
        add(0x42, { [0x04, 0x08] + Array(buzzTail.suffix(3)) }, "SET deel: 04 08 + laatste 3 staartbytes (01 01 00)")
        add(0x42, { [0x04, 0x08, 0, 0, 0, 0] + buzzTail }, "SET deel: tijd 0 (= meteen?) + staart")
        // RUN (68): wekker 8 meteen laten afgaan, kale vorm en met delen van de staart.
        add(0x44, { [0x04, 0x08] }, "RUN: 04 08")
        add(0x44, { [0x04, 0x08] + Array(buzzTail.suffix(3)) }, "RUN: 04 08 + 01 01 00")
        add(0x44, { [0x04, 0x08] + buzzTail }, "RUN: 04 08 + volledige staart")
        add(0x44, { [0x04, 0x08] + soon() + buzzTail }, "RUN: volledig wekkerpakket")
        return c
    }()

    var body: some View {
        let c = Self.candidates[index]
        List {
            Section {
                Text("Stuurt per stap één kandidaat-commando naar de band. Voel je iets, druk op Trilde!, anders op Niets. Eerst de echte trilcommando's (79, 19, 122; 80 leest alleen), daarna het wekkercommando (wekker 8) met andere instellingen; elk ander commando is geblokkeerd. Je echte wekker blijft ongemoeid. Klein risico: een vreemde instelling kan wekker 8 langer laten trillen; tik dan op de band om hem uit te zetten. Doe dit niet terwijl de Whoop-app synchroniseert.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            Section {
                Text("\(Self.sweep.count) trilcommando's (79 en 19; eerst het trildeel uit het wekkerpakket, dan alle waarden) automatisch achter elkaar, zonder wekkertruc. Houd de band om. Voel je iets, druk dan meteen op Trilde nu!.")
                    .font(.footnote).foregroundStyle(Theme.muted)
                ProgressView(value: Double(sweepIndex), total: Double(Self.sweep.count))
                Text("\(sweepIndex) / \(Self.sweep.count)").font(.caption.monospaced())
                HStack {
                    Button(sweeping ? "Stop" : (sweepIndex > 0 ? "Verder" : "Start")) { if sweeping { sweeping = false } else { startSweep() } }
                        .buttonStyle(.bordered).disabled(ble.state != .connected)
                    Spacer()
                    Button("Trilde nu!") { feltNow() }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(sweepSent.isEmpty)
                }
                if !sweepLog.isEmpty {
                    ShareLink(item: sweepLog.joined(separator: "\n")) { Label("Deel log", systemImage: "square.and.arrow.up") }
                    Button("Opnieuw (log wissen)", role: .destructive) { sweeping = false; sweepIndex = 0; sweepLog = []; sweepSent = [] }
                }
            } header: { Text("Automatisch doorlopen") }
            Section {
                Button("Probeer 19 [01 2F 98 00 00 00 00 00 00 00 00 00] (Whoop 5)") {
                    lastResponse = "wacht…"
                    if let e = ble.sendBandAlarm(0x13, body: [0x01, 0x2F, 0x98, 0, 0, 0, 0, 0, 0, 0, 0, 0]) { lastResponse = "niet verstuurd: \(e)" }
                }.disabled(ble.state != .connected)
                Button("Probeer 79 [02 03 00 00 00] (Whoop 4)") {
                    lastResponse = "wacht…"
                    if let e = ble.sendBandAlarm(0x4F, body: [0x02, 0x03, 0, 0, 0]) { lastResponse = "niet verstuurd: \(e)" }
                }.disabled(ble.state != .connected)
                Text("Antwoord band: \(lastResponse)").font(.caption.monospaced())
            } header: { Text("Snelle test") }
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
        .onAppear { ble.onProbeResponse = { cmd, res, body in
            lastResponse = "cmd \(cmd) → \(SleepAlarm.resultText(res)) [\(hex(body))]"
            if sweeping || !sweepSent.isEmpty { sweepLog.append("\(Self.time()) ← \(lastResponse)") }
        } }
        .onDisappear { ble.onProbeResponse = nil; sweeping = false }
    }

    private static func time() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.S"; return f.string(from: Date())
    }

    private func startSweep() {
        sweeping = true
        Task { @MainActor in
            while sweeping && sweepIndex < Self.sweep.count && ble.state == .connected {
                let (cmd, body) = Self.sweep[sweepIndex]
                guard Self.allowed.contains(cmd) else { break }
                let text = "#\(sweepIndex + 1) cmd \(cmd) [\(hex(body))]"
                if let e = ble.sendBandAlarm(cmd, body: body) { sweepLog.append("\(Self.time()) niet verstuurd: \(e)"); break }
                sweepLog.append("\(Self.time()) → \(text)")
                sweepSent.append((Date(), text))
                if sweepSent.count > 20 { sweepSent.removeFirst() }
                sweepIndex += 1
                try? await Task.sleep(nanoseconds: UInt64(Self.sweepGap * 1e9))
            }
            sweeping = false
        }
    }

    /// Markeert de commando's van de laatste 3 s als kandidaat (reactietijd) en pauzeert.
    private func feltNow() {
        let recent = sweepSent.filter { Date().timeIntervalSince($0.t) <= 3 }.map(\.text)
        sweepLog.append("\(Self.time()) *** TRILDE *** kandidaten: " + recent.joined(separator: ", "))
        sweeping = false
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
