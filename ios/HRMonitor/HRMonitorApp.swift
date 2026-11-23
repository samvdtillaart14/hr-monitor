import SwiftUI
import Charts
import UserNotifications
import Combine
import WidgetKit

/// Bluetooth, dagopslag, scores en activiteiten bestaan vanaf de start van de app, ook als iOS de app
/// op de achtergrond opnieuw start voor de band (dan verschijnt er geen scherm en loopt onAppear niet).
@MainActor
final class AppServices {
    static let shared = AppServices()
    let store = DayStore()
    let ble = BLEManager()
    let acts = ActivityStore()
    let scores = ScoreModel()
    let screen = ScreenMonitor()
    private(set) lazy var alarm = SleepAlarm(ble: ble, store: store, scores: scores)
    private var widgetSub: AnyCancellable?
    private init() {
        let alarm = self.alarm
        ble.store = store
        // Bij elke hartslag ook de schermstatus lezen (hooguit 1× per 2 s) en de slimme wekker bijwerken.
        store.onLive = { [weak acts, weak screen, weak alarm] hr in
            MainActor.assumeIsolated { acts?.live(hr: hr); screen?.poll(); alarm?.tick(); InsightNotifications.checkWeekly() }
        }
        scores.awakeIntervals = { [weak screen] in screen?.wakeIntervals() ?? [] }
        screen.onMorning = { MorningBrief.send(services: AppServices.shared) }
        ble.onAlarmResponse = { [weak alarm] cmd, res, body in MainActor.assumeIsolated { alarm?.bandResponse(cmd: cmd, result: res, body: body) } }
        ble.onWhoopReady = { [weak alarm] in MainActor.assumeIsolated { alarm?.bandResend() } }
        alarm.rearm()
        InsightNotifications.scheduleJournal()
        // Widget bijwerken zodra er nieuwe nachtscores zijn.
        widgetSub = scores.$nights.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateWidget() } }
        }
    }

    func updateWidget() {
        let n = scores.lastNight
        let p = alarm.plan()
        var s = WidgetSnapshot()
        s.recovery = n?.recovery
        s.sleepPerf = n?.performance.map { Int($0.rounded()) }
        s.asleepMin = n?.r.asleepMin
        s.bedtime = p.bedtime
        s.wake = p.wake
        s.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Direct aanmaken: CoreBluetooth moet de centrale met het herstel-ID bij het opstarten terugzien.
        _ = AppServices.shared
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        if ScreenMonitor.morningOn { MorningBrief.requestPermission() }
        return true
    }
}

@main
struct HRMonitorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    private let services = AppServices.shared
    @ObservedObject private var router = AppRouter.shared
    var body: some Scene {
        WindowGroup {
            TabView {
                TodayView().tabItem { Label("Vandaag", systemImage: "sun.max.fill") }
                ContentView().tabItem { Label("Live", systemImage: "heart.fill") }
                HealthTab().tabItem { Label("Gezondheid", systemImage: "heart.text.square.fill") }
            }
                .sheet(item: $router.sheet) { s in
                    switch s {
                    case .journal: JournalView()
                    case .week: WeekReportSheet()
                    }
                }
                .environment(\.locale, DV.nl)
                .environmentObject(services.store)
                .environmentObject(services.acts)
                .environmentObject(services.scores)
                .environmentObject(services.alarm)
                .environmentObject(services.ble)
                .environmentObject(services.ble.recorder)
                .environmentObject(services.ble.raw)
                .environmentObject(services.ble.whoop)
                .environmentObject(services.screen)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        // Openstaande metingen direct wegschrijven als de app naar de achtergrond gaat.
        .onChange(of: phase) { _, p in if p == .active { services.ble.syncOnOpen() }; if p != .active { services.store.flush(); BandLog.shared.flush(); services.acts.route.persist() } }
    }
}

struct ContentView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var rec: Recorder
    @EnvironmentObject var whoop: WhoopParser
    @State private var showDevices = false
    @AppStorage(SettingsView.devKey) private var devMode = false
    @AppStorage(Display.liveMinMax) private var showMinMax = true
    @AppStorage(Display.liveRR) private var showRR = true
    @AppStorage(Display.liveHRV) private var showHRV = true
    @AppStorage(Display.liveSkin) private var showSkin = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.gap) {
                    statusBar
                    HeartRing(bpm: ble.bpm).padding(.vertical, 12)
                    hrTile
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.gap), GridItem(.flexible())], spacing: Theme.gap) {
                        if showMinMax { Tile(title: "Min / gem / max", value: mmText, unit: "", small: true, index: 1) }
                        if showRR { Tile(title: "RR-interval", value: ble.lastRR.map { "\(Int($0))" } ?? "--", unit: "ms", index: 2) }
                        if showHRV { Tile(title: "HRV (RMSSD)", value: ble.rmssd.map { "\(Int($0))" } ?? "--", unit: "ms", index: 3) }
                        if showSkin { Tile(title: "Huidtemp", value: whoop.lastRecord?.skinTemp.map { String(format: "%.1f", $0) } ?? "--", unit: "°C", index: 4) }
                        Tile(title: "Batterij", value: ble.battery.map(String.init) ?? "--", unit: "%", index: 5)
                        Tile(title: "Zone", value: ble.bpm.map { Theme.zone($0).name } ?? "--", unit: "", small: true, index: 6)
                    }
                    chart
                    Card(title: "Tijd per zone", index: 8) { ZoneTime(samples: ble.samples) }
                    if devMode || rec.isRecording { recordSection }
                }
                .padding()
            }
            .background(Theme.bg.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .navigationTitle("Pulse")
            .toolbar {
                if devMode {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink("Verkenner") { ExplorerView() }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if devMode { NavigationLink("Opnames") { FilesView() } }
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
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
            if let e = rec.error { Text(e).font(.footnote).foregroundStyle(Theme.hr) }
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
    @State private var busy: String?
    @State private var share: ShareItems?
    @State private var failure: String?

    /// Eén opname = alle delen met dezelfde naam (zonder "_deelN").
    struct Recording: Identifiable {
        let stem: String
        var parts: [URL]
        var id: String { stem }
        var size: Int { parts.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }
    }
    struct ShareItems: Identifiable { let id = UUID(); let urls: [URL] }

    private var recordings: [Recording] {
        var order: [String] = []
        var map: [String: [URL]] = [:]
        for u in rec.files {
            let stem = FileSplitter.baseStem(u.deletingPathExtension().lastPathComponent)
            if map[stem] == nil { order.append(stem) }
            map[stem, default: []].append(u)
        }
        return order.map { Recording(stem: $0, parts: map[$0]!.sorted { FileSplitter.partNumber($0) < FileSplitter.partNumber($1) }) }
    }

    private func isActive(_ r: Recording) -> Bool {
        let raw = UserDefaults.standard.string(forKey: RawLogger.activeKey)
        return r.parts.contains { (rec.isRecording && $0 == rec.currentURL) || $0.lastPathComponent == raw }
    }

    var body: some View {
        List {
            ForEach(recordings) { r in
                let kind = r.parts.first.flatMap(Recorder.Kind.of)
                let row = HStack(spacing: 12) {
                    Image(systemName: kind?.icon ?? "doc.text").foregroundStyle(Theme.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind?.title ?? "Bestand").font(.headline).foregroundStyle(Theme.text)
                        Text(r.stem).font(.caption.monospaced()).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if busy == r.stem { ProgressView() } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(r.size), countStyle: .file))
                            if r.parts.count > 1 { Text("\(r.parts.count) delen") }
                        }.font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                Group {
                    if r.parts.count == 1 && r.size <= ZipExport.zipLimit {
                        ShareLink(item: r.parts[0]) { row }
                    } else {
                        Button { zip(r) } label: { row }.disabled(busy != nil)
                    }
                }
                .contextMenu {
                    Button { zip(r) } label: { Label("Deel als zip", systemImage: "doc.zipper") }
                    ShareLink(items: r.parts) { Label("Deel losse CSV's", systemImage: "doc.on.doc") }
                }
                .swipeActions {
                    if !isActive(r) {
                        Button("Verwijder", role: .destructive) { r.parts.forEach(rec.delete) }
                    }
                }
            }
        }
        .overlay { if rec.files.isEmpty { Text("Nog geen opnames").foregroundStyle(.secondary) } }
        .navigationTitle("Opnames")
        .onAppear { rec.refresh(); rec.splitLargeFiles() }
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .alert("Zippen mislukt", isPresented: .init(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: { Text(failure ?? "") }
    }

    /// Zipt alle delen op de achtergrond (max. 25 MB per zip) en opent het deelmenu met alle zips tegelijk.
    private func zip(_ r: Recording) {
        guard busy == nil else { return }
        busy = r.stem
        let parts = r.parts, stem = r.stem
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ZipExport.make(name: stem, files: parts) }
            DispatchQueue.main.async {
                busy = nil
                switch result {
                case .success(let urls): share = ShareItems(urls: urls)
                case .failure(let e): failure = e.localizedDescription
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
