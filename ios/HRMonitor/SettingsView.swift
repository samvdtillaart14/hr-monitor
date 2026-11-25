import SwiftUI

/// Instellingen (tandwiel op het tabblad Live): updates en de ontwikkelaarsopties.
/// Met de ontwikkelaarsopties aan verschijnen de Verkenner, de opnames en de opnameknop;
/// de gewone gebruiker hoeft die ruwe data nooit te zien.
struct SettingsView: View {
    static let devKey = "settings.devMode"
    @AppStorage(SettingsView.devKey) private var devMode = false
    @AppStorage(Recorder.alwaysOffKey) private var alwaysOff = false
    @AppStorage(ActivityStore.autoDetectOffKey) private var autoDetectOff = false
    @AppStorage(ActivityStore.summaryOffKey) private var summaryOff = false
    @AppStorage(BLEManager.lowBatteryOffKey) private var lowBatteryOff = false
    @AppStorage(BLEManager.fitOffKey) private var fitOff = false
    @AppStorage(AppServices.battery5BuzzOffKey) private var battery5Off = false
    @AppStorage(AppServices.tapActivityKey) private var tapActivity = true
    @AppStorage(BandMetricsCard.spo2Key) private var showSpo2 = true
    @AppStorage(BandMetricsCard.skinKey) private var showSkin = true
    @AppStorage(BandMetricsCard.respKey) private var showResp = true
    @AppStorage(HrrCard.key) private var showHrr = true
    @AppStorage(Vo2Card.key) private var showVo2 = true
    @AppStorage(SignalsCard.key) private var showSignals = true
    @AppStorage(InactivityCard.key) private var showInactivity = true
    @EnvironmentObject var rec: Recorder
    @EnvironmentObject var raw: RawLogger
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var acts: ActivityStore
    @AppStorage(BLEManager.selfSyncKey) private var selfSync = false
    @AppStorage(ScreenMonitor.morningKey) private var morning = true
    @AppStorage(ScreenMonitor.morningStartKey) private var morningStart = 5.0
    @AppStorage(ScreenMonitor.enabledKey) private var screenAsWake = true
    @EnvironmentObject var screen: ScreenMonitor
    @State private var exporting = false
    @State private var share: WeekShare?
    @State private var failure: String?

    var body: some View {
        List {
            BandConnectionSection()
            Section {
                NavigationLink { UpdateView() } label: { Label("Update", systemImage: "arrow.down.circle") }
            }
            Section {
                Toggle("Whoop-app vervangen", isOn: $selfSync).tint(Theme.accent)
                if selfSync {
                    Button { ble.syncNow() } label: { Label("Nu synchroniseren", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(ble.state != .connected || ble.syncing)
                    if let s = ble.syncStatus { Text(s).font(.footnote).foregroundStyle(Theme.muted) }
                    if let d = ble.lastSyncComplete {
                        Text("Laatst klaar: \(d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: DV.nl)))").font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
            } header: { Text("Synchronisatie") } footer: {
                Text(selfSync ? "De app haalt elke 15 minuten zelf de historie op. Draait de Whoop-app mee, dan laat de app het bevestigen aan Whoop over. Is de Whoop-app dicht, dan bevestigt de app zelf en krijgt Whoop die data niet meer." : "Uit: de app leest alleen mee met de Whoop-app; Whoop houdt alle data. Zet aan om zonder Whoop-app te synchroniseren.")
            }
            Section {
                Toggle("Ochtendmelding", isOn: $morning).tint(Theme.accent)
                    .onChange(of: morning) { _, on in if on { MorningBrief.requestPermission() } }
                if morning {
                    Stepper("Vanaf \(Self.clock(morningStart))", value: $morningStart, in: 3...11, step: 0.5)
                    Button { MorningBrief.send(services: AppServices.shared) } label: { Label("Nu proberen", systemImage: "bell") }
                }
                Toggle("Telefoon aan = wakker", isOn: $screenAsWake).tint(Theme.accent)
                if devMode {
                    let tonight = screen.allSpans.filter { $0.end > Date().timeIntervalSince1970 - 86400 }
                    Text("Scherm nu \(screen.screenOn ? "aan" : "uit") · afgelopen 24 u \(tonight.count)× aan, \(tonight.filter(\.unlocked).count)× ontgrendeld")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
            } header: { Text("Slaap en ochtend") } footer: {
                Text("De ochtendmelding komt zodra je na \(Self.clock(morningStart)) je telefoon ontgrendelt of het scherm 10 s aan staat, één keer per dag. Met 'Telefoon aan = wakker' tellen minuten met ontgrendelde telefoon (of scherm langer dan 30 s aan) nooit als slaap; een melding die alleen het scherm laat oplichten telt niet. Werkt alleen als de app op de achtergrond draait, dus met de band verbonden. Schermtijd zelf kan iOS niet aan deze app geven.")
            }
            Section {
                Button {
                    exporting = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        let r = Result { try BandLog.exportWeek() }
                        DispatchQueue.main.async {
                            exporting = false
                            switch r {
                            case .success(let urls): share = WeekShare(urls: urls)
                            case .failure(let e): failure = e.localizedDescription
                            }
                        }
                    }
                } label: {
                    HStack {
                        Label("Laatste week delen", systemImage: "square.and.arrow.up")
                        if exporting { Spacer(); ProgressView() }
                    }
                }.disabled(exporting)
            } header: { Text("Bandgegevens") } footer: {
                Text("De app bewaart de data van de band automatisch, steeds de laatste \(BandLog.keepDays) dagen. Delen maakt zip-bestanden van max. 25 MB, klein genoeg om naar Claude te sturen.")
            }
            InsightSettingsSection()
            DisplaySettingsSection()
            Section {
                Toggle("GPS automatisch aan", isOn: $acts.autoGps).tint(Theme.accent)
            } header: { Text("Activiteiten") } footer: {
                Text("Zet de GPS vanzelf aan bij verhoogde hartslag of als je iPhone hardlopen/fietsen ziet. Kies bij locatie \"Altijd\".")
            }
            Section {
                Toggle("Zuurstof (SpO2)", isOn: $showSpo2).tint(Theme.accent)
                Toggle("Huidtemperatuur", isOn: $showSkin).tint(Theme.accent)
                Toggle("Ademfrequentie", isOn: $showResp).tint(Theme.accent)
                Toggle("Herstel na inspanning", isOn: $showHrr).tint(Theme.accent)
                Toggle("VO₂max (geschat)", isOn: $showVo2).tint(Theme.accent)
                Toggle("Lichaamssignalen (ziekte)", isOn: $showSignals).tint(Theme.accent)
                Toggle("Inactiviteit", isOn: $showInactivity).tint(Theme.accent)
            } header: { Text("Band-functies op Gezondheid") } footer: {
                Text("SpO2 is een voorlopige uitlezing van de band (nog niet bevestigd). Huidtemperatuur toont de afwijking van je eigen normaal.")
            }
            Section {
                Toggle("Activiteiten automatisch herkennen", isOn: Binding(get: { !autoDetectOff }, set: { autoDetectOff = !$0 })).tint(Theme.accent)
                Toggle("Dubbeltik op band start/stopt activiteit", isOn: $tapActivity).tint(Theme.accent)
                Toggle("Samenvatting na activiteit", isOn: Binding(get: { !summaryOff }, set: { summaryOff = !$0 })).tint(Theme.accent)
                Toggle("Melding bij bandbatterij 10%", isOn: Binding(get: { !lowBatteryOff }, set: { lowBatteryOff = !$0 })).tint(Theme.accent)
                Toggle("Melding als de band niet goed zit", isOn: Binding(get: { !fitOff }, set: { fitOff = !$0 })).tint(Theme.accent)
                Toggle("Band trilt 3× bij 5% batterij", isOn: Binding(get: { !battery5Off }, set: { battery5Off = !$0 })).tint(Theme.accent)
            } header: { Text("Activiteiten") } footer: {
                Text("Dubbeltik op de band (behalve in de minuut dat je wekker afgaat) start een activiteit van dezelfde soort als de vorige; nog een dubbeltik stopt hem.")
            }
            Section {
                Toggle("Altijd alles opnemen", isOn: Binding(get: { !alwaysOff }, set: { on in
                    alwaysOff = !on
                    if !on { rec.stop(); raw.stop() }
                })).tint(Theme.accent)
            } footer: {
                Text("Hartslag en alle banddata gaan de hele dag naar Opnames, per dag in een eigen map. Kost ca. 10–50 MB per dag.")
            }
            Section {
                Toggle("Ontwikkelaarsopties", isOn: $devMode).tint(Theme.accent)
                if devMode {
                    NavigationLink { ExplorerView() } label: { Label("Verkenner (BLE-data en commando's)", systemImage: "antenna.radiowaves.left.and.right") }
                    NavigationLink { FilesView() } label: { Label("Opnames (CSV-bestanden)", systemImage: "folder") }
                    NavigationLink { HapticProbeView() } label: { Label("Trilcommando zoeken", systemImage: "waveform.path") }
                }
            } footer: {
                Text(devMode
                     ? "De Verkenner, de opnames en de opnameknop op Live zijn zichtbaar. Lopende opnames gaan door als je dit uitzet."
                     : "Zet aan om de Verkenner, ruwe opnames en de opnameknop te tonen. Alleen nodig voor het ontcijferen van de banddata.")
            }
            BackupSection()
            if !devMode && alwaysOff && (rec.isRecording || raw.isRecording) {
                Section {
                    if rec.isRecording { Button("Stop hartslagopname", role: .destructive) { alwaysOff = true; rec.stop() } }
                    if raw.isRecording { Button("Stop ruwe opname", role: .destructive) { alwaysOff = true; raw.stop() } }
                } footer: { Text("Er loopt nog een opname op de achtergrond.") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Instellingen")
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .alert("Delen mislukt", isPresented: .init(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: { Text(failure ?? "") }
    }

    static func clock(_ h: Double) -> String { String(format: "%02d:%02d", Int(h), Int((h - Double(Int(h))) * 60)) }
}
struct WeekShare: Identifiable { let id = UUID(); let urls: [URL] }
