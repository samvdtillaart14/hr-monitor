import Foundation
import CoreBluetooth
import UIKit
import WhoopScores

/// Verbindt met een BLE-hartslagband (standaard Heart Rate Service 0x180D),
/// blijft op de achtergrond verbonden (UIBackgroundModes: bluetooth-central)
/// en herverbindt automatisch met het laatst gebruikte apparaat.
final class BLEManager: NSObject, ObservableObject {
    static let hrService = CBUUID(string: "180D")
    static let hrMeasurement = CBUUID(string: "2A37")
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
    private static let lastDeviceKey = "lastDeviceUUID"
    private static let restoreID = "nl.samvdtillaart.hrmonitor.central"

    enum State: Equatable { case off, idle, scanning, connecting, connected, unauthorized }

    struct Found: Identifiable, Equatable {
        let id: UUID
        let name: String
        var rssi: Int
    }

    struct Sample: Identifiable {
        let id = UUID()
        let time: Date
        let bpm: Int
    }

    @Published var state: State = .idle
    @Published var found: [Found] = []
    @Published var deviceName: String?
    @Published var bpm: Int?
    @Published var contact: String = "-"
    @Published var lastRR: Double?
    @Published var rmssd: Double?
    @Published var battery: Int?
    @Published var samples: [Sample] = []   // laatste 5 min voor de grafiek
    @Published var sessionMin: Int?
    @Published var sessionMax: Int?
    @Published var sessionAvg: Double?
    @Published var sessionStart: Date?

    let recorder = Recorder()
    let raw = RawLogger()
    let whoop = WhoopParser()
    /// Dagopslag voor de scores (wordt door de app gezet).
    var store: DayStore?

    /// Alle gevonden characteristics, voor de verkenner.
    struct CharInfo: Identifiable {
        var id: String { service + "/" + uuid }
        let service: String
        let uuid: String
        let props: String
        var notifying = false
        var last = ""
        var count = 0
    }
    @Published var chars: [CharInfo] = []
    private var charRefs: [String: CBCharacteristic] = [:]

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var rrWindow: [(Date, Double)] = []
    private var lastWhoopRR = Date.distantPast
    /// App geopend terwijl de band nog niet verbonden was: historie opvragen zodra dat kan.
    fileprivate var openRequested = false

    /// RR-intervallen toevoegen en live HRV (RMSSD over 5 min) bijwerken. Intervallen die niet bij de hartslag
    /// passen (buiten 300–2000 ms of > 35 % van 60000/HR af) en sprongen > 20 % tussen opeenvolgende slagen
    /// tellen niet mee. Pas vanaf 30 bruikbare paren een waarde.
    func addRR(_ rrs: [Double], hr: Int, fromWhoop: Bool) {
        let now = Date()
        if fromWhoop && !rrs.isEmpty { lastWhoopRR = now }
        let expected = hr > 0 ? 60000 / Double(hr) : nil
        let ok = rrs.filter { r in r >= 300 && r <= 2000 && (expected.map { abs(r - $0) <= 0.35 * $0 } ?? true) }
        if let last = ok.last { lastRR = last }
        else if rrWindow.last(where: { $0.1.isFinite }).map({ now.timeIntervalSince($0.0) > 10 }) ?? true { lastRR = nil }
        // gat in de reeks markeren met NaN, zodat er geen verschil over het gat wordt berekend
        if ok.count < rrs.count || (rrWindow.last.map { now.timeIntervalSince($0.0) > 5 } ?? false) { rrWindow.append((now, .nan)) }
        rrWindow.append(contentsOf: ok.map { (now, $0) })
        rrWindow.removeAll { now.timeIntervalSince($0.0) > 300 }
        let w = rrWindow.map(\.1)
        var s = 0.0, n = 0
        if w.count > 1 {
            for k in 1..<w.count where w[k].isFinite && w[k - 1].isFinite {
                let d = w[k] - w[k - 1]
                if abs(d) <= 0.2 * w[k - 1] { s += d * d; n += 1 }
            }
        }
        rmssd = n >= 30 ? (s / Double(n)).squareRoot() : nil
    }
    private var sum = 0.0, count = 0
    private var userDisconnected = false
    /// laatste automatische historie-aanvraag (cmd 22), om niet bij elke korte herverbinding alles opnieuw op te halen
    private var lastHistoryRequest = Date.distantPast
    private var historyRequestedThisConnection = false

    // MARK: zelf synchroniseren (standalone, zonder Whoop-app)
    static let selfSyncKey = "sync.selfSync"
    private static let ackVariantKey = "sync.ackVariant"
    private static let lastSyncKey = "sync.lastComplete"
    /// Bezig met een historie-overdracht die wij zelf afhandelen.
    @Published private(set) var syncing = false
    @Published private(set) var lastSyncComplete: Date? = UserDefaults.standard.object(forKey: BLEManager.lastSyncKey) as? Date
    @Published private(set) var syncStatus: String?
    private var syncStarted = Date.distantPast
    private var sync = HistorySync()
    var selfSync: Bool { UserDefaults.standard.bool(forKey: Self.selfSyncKey) }
    /// Antwoord van de band op een wekkercommando: cmd, resultaat (1 ok, 0 geweigerd, 3 onbekend), body.
    var onAlarmResponse: ((UInt8, UInt8, [UInt8]) -> Void)?
    /// Whoop-service gevonden na (her)verbinden: moment om bv. de wekker opnieuw naar de band te sturen.
    var onWhoopReady: (() -> Void)?

    override init() {
        super.init()
        whoop.onRecord = { [weak self] r in
            guard let st = self?.store else { return }
            MainActor.assumeIsolated { st.addRecord(r) }
        }
        whoop.onLive = { [weak self] hr, rr in self?.addRR(rr.map(Double.init), hr: hr, fromWhoop: true) }
        whoop.onHistoryEnd = { [weak self] trim in self?.ackBurst(trim) }
        whoop.onHistoryComplete = { [weak self] in self?.syncDone() }
        whoop.onResponse = { [weak self] cmd, res in self?.handleResponse(cmd: cmd, result: res) }
        whoop.onResponseBody = { [weak self] cmd, res, body in
            // Wekkercommando's, plus onbekende commando's (bv. van de Whoop-app) voor het wekkerlogboek.
            let routine: Set<UInt8> = [0x03, 0x16, 0x17, 0x22]
            if res != 2, SleepPlanner.BandAlarm.isAlarmCommand(cmd) || !routine.contains(cmd) { self?.onAlarmResponse?(cmd, res, body) }
        }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID,
                                             CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // MARK: acties

    func scan() {
        guard central.state == .poweredOn else { return }
        found = []
        state = .scanning
        // Eerst apparaten die de Heart Rate Service adverteren; zonder filter
        // vindt iOS ook banden die de service pas na verbinden tonen.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if self?.state == .scanning { self?.stopScan() }
        }
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(_ id: UUID) {
        guard let p = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        central.stopScan()
        userDisconnected = false
        peripheral = p
        p.delegate = self
        state = .connecting
        deviceName = p.name
        UserDefaults.standard.set(id.uuidString, forKey: Self.lastDeviceKey)
        // connect() verloopt niet: iOS verbindt zodra de band in bereik is, ook op de achtergrond.
        central.connect(p, options: nil)
    }

    /// Schrijft hex-bytes naar een characteristic (voor commando's aan de band).
    func write(hex: String, to id: String) -> String? {
        guard let ch = charRefs[id], let p = peripheral else { return "Characteristic niet gevonden" }
        let clean = hex.replacingOccurrences(of: "0x", with: "").filter(\.isHexDigit)
        guard clean.count % 2 == 0, !clean.isEmpty else { return "Oneven of leeg aantal hex-tekens" }
        var bytes = [UInt8](); var i = clean.startIndex
        while i < clean.endIndex { let j = clean.index(i, offsetBy: 2); bytes.append(UInt8(clean[i..<j], radix: 16)!); i = j }
        // Nooit cmd 23 (historie bevestigen) naar de band: dat kan data wissen voordat de Whoop-app heeft gesynchroniseerd.
        if ch.uuid.uuidString.hasPrefix("FD4B0002"), HistorySync.isAckCommand(bytes) {
            return "Cmd 23 is geblokkeerd: dat kan data op de band wissen."
        }
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(bytes), for: ch, type: type)
        raw.log(service: ch.service?.uuid.uuidString ?? "", char: ch.uuid.uuidString, kind: "WRITE", data: Data(bytes))
        return nil
    }

    /// Stuurt een Whoop-commando naar FD4B0002 (met CRC's). Alleen voor veilige, lezende commando's.
    func sendWhoop(cmd: UInt8, body: [UInt8]) -> String? {
        guard cmd != 23 else { return "Cmd 23 is geblokkeerd: dat kan data op de band wissen." }
        return sendFrame(cmd: cmd, body: body)
    }

    private func sendFrame(cmd: UInt8, body: [UInt8]) -> String? {
        guard let p = peripheral, let ch = charRefs.first(where: { $0.key.hasPrefix("FD4B0001") && $0.key.hasSuffix("FD4B0002-CCE1-4033-93CE-002D5875F58A") })?.value
        else { return "Whoop-service niet gevonden. Verbind eerst." }
        let f = whoop.frame(cmd: cmd, body: body)
        p.writeValue(f, for: ch, type: .withResponse)
        raw.log(service: ch.service?.uuid.uuidString ?? "", char: ch.uuid.uuidString, kind: "WRITE", data: f)
        return nil
    }

    func read(_ id: String) { if let ch = charRefs[id] { peripheral?.readValue(for: ch) } }

    func disconnect() {
        userDisconnected = true
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        UserDefaults.standard.removeObject(forKey: Self.lastDeviceKey)
        state = .idle
    }

    func resetSession() {
        samples = []; rrWindow = []; sum = 0; count = 0
        sessionMin = nil; sessionMax = nil; sessionAvg = nil; rmssd = nil
        sessionStart = state == .connected ? Date() : nil
    }

    private func reconnectLast() {
        guard let s = UserDefaults.standard.string(forKey: Self.lastDeviceKey), let id = UUID(uuidString: s) else { return }
        connect(id)
    }

    // MARK: decodering Heart Rate Measurement (Bluetooth SIG, 0x2A37)

    private func handleHR(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 2 else { return }
        let flags = b[0]
        var i = 1
        let hr: Int
        if flags & 0x01 != 0 {
            guard b.count >= 3 else { return }
            hr = Int(b[1]) | Int(b[2]) << 8; i = 3
        } else { hr = Int(b[1]); i = 2 }
        if flags & 0x08 != 0 { i += 2 }   // Energy Expended
        var rrs: [Double] = []
        if flags & 0x10 != 0 {
            while i + 1 < b.count {
                rrs.append(Double(Int(b[i]) | Int(b[i + 1]) << 8) / 1024.0 * 1000.0)
                i += 2
            }
        }
        // De Whoop meldt het contactbit niet; dan leiden we het af uit de hartslag zelf.
        if flags & 0x04 != 0 { contact = flags & 0x02 != 0 ? "goed" : "geen contact" }
        else { contact = hr > 0 ? "goed (hartslag ontvangen)" : "geen hartslag" }

        let now = Date()
        if sessionStart == nil { sessionStart = now }
        if hr > 0 {
            bpm = hr
            sum += Double(hr); count += 1
            sessionMin = min(sessionMin ?? hr, hr)
            sessionMax = max(sessionMax ?? hr, hr)
            sessionAvg = sum / Double(count)
            samples.append(Sample(time: now, bpm: hr))
            samples.removeAll { now.timeIntervalSince($0.time) > 300 }
        }
        // RR van het Whoop-kanaal (0x28) heeft voorrang; die van de standaard-HR-service alleen als dat stil is.
        if now.timeIntervalSince(lastWhoopRR) > 10 { addRR(rrs, hr: hr, fromWhoop: false) }
        recorder.append(time: now, bpm: hr, rr: rrs, battery: battery)
        if let st = store {
            let rrInt = rrs.map { Int($0.rounded()) }
            MainActor.assumeIsolated { st.addLive(hr: hr, rr: rrInt) }
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            if state == .off || state == .unauthorized { state = .idle }
            if let p = peripheral {
                // Na herstart door iOS: verbinding opnieuw opbouwen of abonnementen herstellen.
                if p.state == .disconnected && !userDisconnected { state = .connecting; c.connect(p, options: nil) }
                // Ook na herstel door iOS: characteristics opnieuw zoeken, anders kan de app de band geen commando's sturen.
                else if p.state == .connected && (p.services == nil || charRefs.isEmpty) { p.discoverServices(nil) }
            } else { reconnectLast() }
        case .unauthorized: state = .unauthorized
        default: state = .off
        }
    }

    /// iOS heeft de app op de achtergrond opnieuw gestart voor een BLE-gebeurtenis.
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
            peripheral = p
            p.delegate = self
            peripherals[p.identifier] = p
            deviceName = p.name
            state = p.state == .connected ? .connected : .connecting
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String)
        guard let name, !name.isEmpty else { return }   // naamloze apparaten overslaan
        peripherals[p.identifier] = p
        if let k = found.firstIndex(where: { $0.id == p.identifier }) { found[k].rssi = rssi.intValue }
        else { found.append(Found(id: p.identifier, name: name, rssi: rssi.intValue)) }
        found.sort { ($0.name.lowercased().contains("whoop") ? 0 : 1, -$0.rssi) < ($1.name.lowercased().contains("whoop") ? 0 : 1, -$1.rssi) }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        state = .connected
        deviceName = p.name
        if sessionStart == nil { sessionStart = Date() }
        chars = []; charRefs = [:]
        whoop.resetBuffers()
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if !userDisconnected { c.connect(p, options: nil) }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        bpm = nil
        contact = "-"
        historyRequestedThisConnection = false
        if userDisconnected { state = .idle; return }
        state = .connecting
        c.connect(p, options: nil)   // wacht tot de band terug in bereik is
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            let pr = ch.properties
            var names: [String] = []
            if pr.contains(.read) { names.append("read") }
            if pr.contains(.write) { names.append("write") }
            if pr.contains(.writeWithoutResponse) { names.append("writeNR") }
            if pr.contains(.notify) { names.append("notify") }
            if pr.contains(.indicate) { names.append("indicate") }
            let info = CharInfo(service: s.uuid.uuidString, uuid: ch.uuid.uuidString, props: names.joined(separator: " · "))
            charRefs[info.id] = ch
            if !chars.contains(where: { $0.id == info.id }) { chars.append(info) }
            // Alles op notify/indicate zetten, zodat de verkenner alle data ziet.
            if pr.contains(.notify) || pr.contains(.indicate) { p.setNotifyValue(true, for: ch) }
            if pr.contains(.read) { p.readValue(for: ch) }
        }
        requestHistoryIfReady()
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        let id = (ch.service?.uuid.uuidString ?? "") + "/" + ch.uuid.uuidString
        if let k = chars.firstIndex(where: { $0.id == id }) { chars[k].notifying = ch.isNotifying }
        if let error { raw.log(service: ch.service?.uuid.uuidString ?? "", char: ch.uuid.uuidString, kind: "ERROR", data: Data(), note: error.localizedDescription) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        let sid = ch.service?.uuid.uuidString ?? ""
        let id = sid + "/" + ch.uuid.uuidString
        if let k = chars.firstIndex(where: { $0.id == id }) {
            chars[k].last = d.map { String(format: "%02x", $0) }.joined(separator: " ")
            chars[k].count += 1
        }
        raw.log(service: sid, char: ch.uuid.uuidString, kind: ch.isNotifying ? "NOTIFY" : "READ", data: d)
        if sid.hasPrefix("FD4B") { whoop.handle(d, channel: ch.uuid.uuidString) }
        if ch.uuid == Self.hrMeasurement { handleHR(d); syncIfDue() }
        else if ch.uuid == Self.batteryLevel, let v = d.first { battery = Int(v) }
    }
}

extension BLEManager {
    /// Bevestigt een burst zodat de band de volgende stuurt, alleen als "Whoop-app vervangen" aan staat.
    /// Draait de Whoop-app mee, dan bevestigt die binnen een fractie van een seconde zelf; wij wachten daarom
    /// eerst (zie HistorySync.burstEnded) en bevestigen alleen als er geen ack van de Whoop-app voorbij kwam.
    fileprivate func ackBurst(_ trim: [UInt8]) {
        guard selfSync else { return }
        let wait = sync.burstEnded(trim: trim)
        syncing = true; syncStarted = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.selfSync,
                  let body = self.sync.ackDue(trim: trim, variant: UserDefaults.standard.integer(forKey: Self.ackVariantKey))
            else { return }
            if self.sendFrame(cmd: HistorySync.ackCmd, body: body) == nil {
                self.sync.ackSent()
                self.syncStarted = Date()
                self.syncStatus = "Bezig: \(self.sync.acksSent) blokken opgehaald"
            }
        }
    }

    /// Stuurt een wekkercommando (SleepPlanner.BandAlarm) naar de band. nil = verstuurd.
    func sendBandAlarm(_ cmd: UInt8, body: [UInt8]) -> String? {
        sendFrame(cmd: cmd, body: body)
    }

    fileprivate func handleResponse(cmd: UInt8, result: UInt8) {
        if SleepPlanner.BandAlarm.isAlarmCommand(cmd) { return }   // afgehandeld via onAlarmResponse
        guard selfSync, sync.response(cmd: cmd, result: result) == .rejected else { return }
        // Ack geweigerd: andere opbouw proberen bij de volgende burst en de historie opnieuw opvragen.
        let v = UserDefaults.standard.integer(forKey: Self.ackVariantKey)
        UserDefaults.standard.set(v == 0 ? 1 : 0, forKey: Self.ackVariantKey)
        syncStatus = "Ack geweigerd, andere variant wordt geprobeerd"
        syncing = false
        lastHistoryRequest = .distantPast
    }

    fileprivate func syncDone() {
        syncing = false
        let n = sync.reset()
        if selfSync {
            lastSyncComplete = Date()
            UserDefaults.standard.set(lastSyncComplete, forKey: Self.lastSyncKey)
            syncStatus = n > 0 ? "Klaar: \(n) blokken" : "Klaar, niets nieuws"
        }
    }

    /// Standalone: vraag elke 15 minuten zelf de historie op (gaat mee op de hartslagmeldingen, dus ook op de achtergrond).
    fileprivate func syncIfDue() {
        guard selfSync, state == .connected else { return }
        if syncing, Date().timeIntervalSince(syncStarted) > 120 { syncing = false }   // vastgelopen overdracht
        guard !syncing, Date().timeIntervalSince(lastHistoryRequest) > 900 else { return }
        syncNow()
    }

    /// Start direct een synchronisatie (ook via de knop in Instellingen).
    func syncNow() {
        guard state == .connected, sendWhoop(cmd: 22, body: [0x00]) == nil else { return }
        lastHistoryRequest = Date()
        sync.reset()
        syncing = true; syncStarted = Date()
        syncStatus = "Historie opgevraagd…"
    }

    /// Bij het openen van de app: historie opvragen (cmd 22). Met "Whoop-app vervangen" uit leest de app alleen
    /// mee en bevestigt niets (geen cmd 23); dan bevestigt de Whoop-app of blijft de data op de band staan.
    func syncOnOpen() {
        guard Date().timeIntervalSince(lastHistoryRequest) > 120 else { return }
        if state == .connected {
            if selfSync { syncNow() }
            else if sendWhoop(cmd: 22, body: [0x00]) == nil { lastHistoryRequest = Date() }
        } else {
            openRequested = true   // zodra de verbinding er is
        }
    }
    /// Haalt na (her)verbinden de opgeslagen historie van de band op (cmd 22, alleen lezen; er wordt nooit
    /// cmd 23 gestuurd, dus de band wist niets). Zo vullen gaten door een weggevallen verbinding zich vanzelf.
    /// Hooguit eens per 10 minuten.
    /// Na het openen van de app hooguit eens per 2 minuten.
    fileprivate func requestHistoryIfReady() {
        let minGap: TimeInterval = openRequested ? 120 : 600
        guard !historyRequestedThisConnection,
              Date().timeIntervalSince(lastHistoryRequest) > minGap,
              charRefs.keys.contains(where: { $0.hasPrefix("FD4B0001") && $0.hasSuffix("FD4B0002-CCE1-4033-93CE-002D5875F58A") })
        else { return }
        historyRequestedThisConnection = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.state == .connected else { return }
            self.onWhoopReady?()
        }
        // Even wachten tot de notificaties van de band aan staan, anders gaan de eerste records verloren.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.state == .connected else { self?.historyRequestedThisConnection = false; return }
            if self.sendWhoop(cmd: 22, body: [0x00]) == nil { self.lastHistoryRequest = Date(); self.openRequested = false }
            else { self.historyRequestedThisConnection = false }
        }
    }
}

