import SwiftUI

/// Controleert de AltStore-bron (apps.json in de repo) op een nieuwere build
/// en opent AltStore om die te installeren. Installeren vereist nog steeds AltServer (pc) op hetzelfde wifi.
@MainActor
final class Updater: ObservableObject {
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/samvdtillaart14/hr-monitor/main/apps.json")!
    static let ipaURL = "https://github.com/samvdtillaart14/hr-monitor/releases/download/latest/HRMonitor.ipa"

    @Published var latest: String?
    @Published var available = false
    @Published var checking = false
    @Published var error: String?

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    private var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0 }

    func check() async {
        checking = true; defer { checking = false }
        do {
            var req = URLRequest(url: Self.sourceURL)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let v = ((json?["apps"] as? [[String: Any]])?.first?["versions"] as? [[String: Any]])?.first
            let build = Int(v?["buildVersion"] as? String ?? "0") ?? 0
            latest = v?["version"] as? String
            available = build > currentBuild
            error = nil
        } catch {
            self.error = "Kon niet controleren: \(error.localizedDescription)"
        }
    }

    /// Opent AltStore met de nieuwste .ipa.
    func install() {
        let enc = Self.ipaURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? Self.ipaURL
        if let u = URL(string: "altstore://install?url=\(enc)") { UIApplication.shared.open(u) }
    }

    /// Voegt de bron eenmalig toe aan AltStore, zodat AltStore zelf ook updates meldt.
    func addSource() {
        let enc = Self.sourceURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        if let u = URL(string: "altstore://source?url=\(enc)") { UIApplication.shared.open(u) }
    }
}

struct UpdateView: View {
    @StateObject private var up = Updater()
    var body: some View {
        List {
            Section {
                LabeledContent("Geïnstalleerd", value: up.current)
                LabeledContent("Nieuwste", value: up.latest ?? (up.checking ? "Controleren…" : "–"))
                if let e = up.error { Text(e).foregroundStyle(Theme.hr).font(.footnote) }
            }
            Section {
                Button {
                    up.install()
                } label: {
                    Label(up.available ? "Update naar \(up.latest ?? "")" : "Nieuwste versie opnieuw installeren",
                          systemImage: "arrow.down.circle.fill")
                }
                .tint(Theme.accent)
                Button("Opnieuw controleren") { Task { await up.check() } }
            } footer: {
                Text("Opent AltStore en installeert de nieuwste build. Je pc met AltServer moet aan staan en op hetzelfde wifi zitten.")
            }
            Section {
                Button("Bron toevoegen aan AltStore") { up.addSource() }
            } footer: {
                Text("Eenmalig. Daarna meldt AltStore zelf nieuwe versies onder 'Updates'.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Update")
        .task { await up.check() }
    }
}
