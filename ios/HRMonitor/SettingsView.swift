import SwiftUI

/// Instellingen (tandwiel op het tabblad Live): updates en de ontwikkelaarsopties.
/// Met de ontwikkelaarsopties aan verschijnen de Verkenner, de opnames en de opnameknop;
/// de gewone gebruiker hoeft die ruwe data nooit te zien.
struct SettingsView: View {
    static let devKey = "settings.devMode"
    @AppStorage(SettingsView.devKey) private var devMode = false
    @EnvironmentObject var rec: Recorder
    @EnvironmentObject var raw: RawLogger
    @EnvironmentObject var ble: BLEManager
    @AppStorage(BLEManager.selfSyncKey) private var selfSync = false

    var body: some View {
        List {
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
                        Text("Laatst klaar: \(d.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
            } header: { Text("Synchronisatie") } footer: {
                Text(selfSync ? "De app haalt elke 15 minuten zelf de historie op. Draait de Whoop-app mee, dan laat de app het bevestigen aan Whoop over. Is de Whoop-app dicht, dan bevestigt de app zelf en krijgt Whoop die data niet meer." : "Uit: de app leest alleen mee met de Whoop-app; Whoop houdt alle data. Zet aan om zonder Whoop-app te synchroniseren.")
            }
            Section {
                Toggle("Ontwikkelaarsopties", isOn: $devMode).tint(Theme.accent)
                if devMode {
                    NavigationLink { ExplorerView() } label: { Label("Verkenner (BLE-data en commando's)", systemImage: "antenna.radiowaves.left.and.right") }
                    NavigationLink { FilesView() } label: { Label("Opnames (CSV-bestanden)", systemImage: "folder") }
                }
            } footer: {
                Text(devMode
                     ? "De Verkenner, de opnames en de opnameknop op Live zijn zichtbaar. Lopende opnames gaan door als je dit uitzet."
                     : "Zet aan om de Verkenner, ruwe opnames en de opnameknop te tonen. Alleen nodig voor het ontcijferen van de banddata.")
            }
            if !devMode && (rec.isRecording || raw.isRecording) {
                Section {
                    if rec.isRecording { Button("Stop hartslagopname", role: .destructive) { rec.stop() } }
                    if raw.isRecording { Button("Stop ruwe opname", role: .destructive) { raw.stop() } }
                } footer: { Text("Er loopt nog een opname op de achtergrond.") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Instellingen")
    }
}
