import SwiftUI

/// Verbindingsstatus met de band, verbreken en zoeken (Instellingen).
struct BandConnectionSection: View {
    @EnvironmentObject var ble: BLEManager
    @State private var showDevices = false

    var body: some View {
        Section {
            statusRow
        } header: { Text("Band") }
        .sheet(isPresented: $showDevices) { DeviceSheet(isPresented: $showDevices) }
    }

    private var statusRow: some View {
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

}
