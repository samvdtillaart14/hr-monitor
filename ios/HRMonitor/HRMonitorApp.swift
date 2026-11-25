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
    private var widgetDaySub: AnyCancellable?
    private var batterySub: AnyCancellable?
    /// Band 3× laten trillen bij 5% batterij (standaard aan); opgeslagen als "uit".
    static let battery5BuzzOffKey = "band.battery5BuzzOff"
    private static let battery5SentKey = "band.battery5Sent"
    private init() {
        let alarm = self.alarm
        ble.store = store
        // Bij elke hartslag ook de schermstatus lezen (hooguit 1× per 2 s) en de slimme wekker bijwerken.
        store.onLive = { [weak acts, weak screen, weak alarm] hr in
            MainActor.assumeIsolated { acts?.live(hr: hr); screen?.poll(); alarm?.tick(); InsightNotifications.checkWeekly(); InsightNotifications.checkMonthly() }
        }
        scores.awakeIntervals = { [weak screen] in screen?.wakeIntervals() ?? [] }
        screen.onMorning = { MorningBrief.send(services: AppServices.shared) }
        ble.onAlarmResponse = { [weak alarm] cmd, res, body in MainActor.assumeIsolated { alarm?.bandResponse(cmd: cmd, result: res, body: body) } }
        ble.onWhoopReady = { [weak alarm] in MainActor.assumeIsolated { alarm?.bandResend() } }
        ble.whoop.onDoubleTap = { [weak self] in MainActor.assumeIsolated { self?.bandTapped() } }
        alarm.rearm()
        // Bij 5% batterij 3× trillen, één keer per ontlading (opnieuw na opladen tot ≥ 20%).
        batterySub = ble.$battery.compactMap { $0 }.removeDuplicates().sink { [weak alarm] pct in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let d = UserDefaults.standard
                    if pct >= 20 { d.set(false, forKey: Self.battery5SentKey); return }
                    guard pct <= 5, pct > 0, !d.bool(forKey: Self.battery5SentKey), !d.bool(forKey: Self.battery5BuzzOffKey) else { return }
                    d.set(true, forKey: Self.battery5SentKey)
                    alarm?.buzz(times: 3)
                }
            }
        }
        InsightNotifications.scheduleJournal()
        // Widget bijwerken zodra er nieuwe nachtscores zijn.
        widgetSub = scores.$nights.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateWidget() } }
        }
        // Belasting loopt over de dag op: hooguit elk kwartier de widget bijwerken (iOS beperkt het aantal verversingen).
        widgetDaySub = scores.$days.dropFirst().throttle(for: .seconds(900), scheduler: RunLoop.main, latest: true).sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateWidget() } }
        }
    }

    /// Dubbeltik op de band. In de eerste minuut nadat de wekker afgaat is de tik voor de wekker;
    /// anders start of stopt hij een activiteit, met een melding als bevestiging.
    func bandTapped(now: Date = Date()) {
        guard UserDefaults.standard.object(forKey: Self.tapActivityKey) as? Bool ?? true else { return }
        // Alleen de eerste minuut nadat de wekker afgaat is een dubbeltik voor de wekker.
        if now.timeIntervalSince(alarm.lastFired) >= 0 && now.timeIntervalSince(alarm.lastFired) < 60 { return }
        if alarm.schedule.enabled {
            let w = alarm.schedule.nextWake(after: now.addingTimeInterval(-60))
            if w.rule.enabled && w.date <= now { return }
        }
        if now.timeIntervalSince(alarm.lastBuzz) < 15 { return }
        guard let r = acts.toggleFromBand(store: store) else { return }
        if r.started { alarm.buzz() }
        InsightNotifications.post("band-tik", r.started ? "\(r.activity.type.name) gestart" : "\(r.activity.type.name) gestopt",
                                  r.started ? "Tik nog een keer op je band om te stoppen. Soort wijzigen kan op Vandaag."
                                            : "Opgeslagen op Vandaag.")
    }
    static let tapActivityKey = "band.tapActivity"

    func updateWidget() {
        let n = scores.lastNight
        let p = alarm.plan()
        var s = WidgetSnapshot()
        s.recovery = n?.recovery
        s.sleepPerf = n?.performance.map { Int($0.rounded()) }
        s.asleepMin = n?.r.asleepMin
        s.strain = scores.today?.strain
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
    @State private var splash = true
    @AppStorage(Display.appearance) private var appearance = "dark"
    var body: some Scene {
        WindowGroup {
            TabView {
                TodayView().tabItem { Label("Vandaag", systemImage: "sun.max.fill") }
                ContentView().tabItem { Label("Live", systemImage: "heart.fill") }
                HealthTab().tabItem { Label("Gezondheid", systemImage: "heart.text.square.fill") }
            }
                .sheet(item: $router.sheet) { s in
                    switch s {
                    case .journal: JournalView().presentationDetents([.large]).interactiveDismissDisabled(false)
                    case .week: WeekReportSheet()
                    case .month: MonthReportSheet()
                    }
                }
                .sheet(item: $router.activity) { ActivitySummarySheet(id: $0.id) }
                .overlay { if splash { SplashView(visible: $splash).transition(.opacity) } }
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
                .preferredColorScheme(Display.scheme(appearance))
                .tint(Theme.accent)
                .morningOverview()
        }
        // Openstaande metingen direct wegschrijven als de app naar de achtergrond gaat.
        .onChange(of: phase) { _, p in if p == .active { services.ble.syncOnOpen() }; if p != .active { services.store.flush(); BandLog.shared.flush(); services.acts.route.persist() } }
    }
}

struct ContentView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var rec: Recorder
    @EnvironmentObject var whoop: WhoopParser
    @AppStorage(SettingsView.devKey) private var devMode = false
    @AppStorage(Display.liveMinMax) private var showMinMax = true
    @AppStorage(Display.liveSkin) private var showSkin = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.gap) {
                    statusBar
                    HeartRing(bpm: ble.bpm).padding(.vertical, 12)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.gap), GridItem(.flexible())], spacing: Theme.gap) {
                        if showMinMax { Tile(title: "Min / gem / max", value: mmText, unit: "", small: true, index: 1) }
                        if showSkin { Tile(title: "Huidtemp", value: whoop.lastRecord?.skinTemp.map { String(format: "%.1f", $0) } ?? "--", unit: "°C", index: 4) }
                    }
                    chart
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
        }
    }

    private var mmText: String {
        guard let a = ble.sessionMin, let b = ble.sessionAvg, let c = ble.sessionMax else { return "--" }
        return "\(a) / \(Int(b.rounded())) / \(c)"
    }

    /// Alleen als er geen verbinding is: korte verwijzing naar Instellingen (verbinden/verbreken staat daar).
    @ViewBuilder private var statusBar: some View {
        if ble.state != .connected {
            NavigationLink { SettingsView() } label: {
                HStack {
                    Circle().fill(ble.state == .connecting || ble.state == .scanning ? Color.orange : Color.gray).frame(width: 10, height: 10)
                    Text(ble.state == .connecting ? "Wachten op de band…" : "Niet verbonden · verbinden in Instellingen").font(.subheadline)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                }
            }.buttonStyle(.plain)
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
                if rec.isRecording { Recorder.alwaysOn = false; rec.stop() } else { rec.start() }
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

/// Opnames in mappen per dag (bv. "25 nov"), daarbinnen deel 1, deel 2, … op tijd.
struct FilesView: View {
    @EnvironmentObject var rec: Recorder
    /// nil = overzicht met dagmappen; anders de opnames van die dag (dd-MM).
    var day: String? = nil
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

    /// Dag (dd-MM) en tijd (uu:mm) uit de bestandsnaam, bv. WHOOP-HISTORIE_25-11_21u14-03 of WHOOP-HISTORIE_25-11.
    static func dayAndTime(_ stem: String) -> (day: String, time: String?)? {
        let parts = stem.split(separator: "_").map(String.init)
        guard let i = parts.firstIndex(where: { $0.count == 5 && $0.dropFirst(2).first == "-" && $0.replacingOccurrences(of: "-", with: "").allSatisfy(\.isNumber) })
        else { return nil }
        var time: String?
        if i + 1 < parts.count, let u = parts[i + 1].firstIndex(of: "u") {
            let p = parts[i + 1]
            time = p[..<u] + ":" + p[p.index(after: u)...].prefix(2)
        }
        return (parts[i], time)
    }

    /// "25-11" → "25 nov"; dagen sorteren nieuwste eerst (jaargrens: een maand ná nu is vorig jaar).
    static func dayTitle(_ d: String) -> String {
        let m = ["jan", "feb", "mrt", "apr", "mei", "jun", "jul", "aug", "sep", "okt", "nov", "dec"]
        let p = d.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2, (1...12).contains(p[1]) else { return d }
        return "\(p[0]) \(m[p[1] - 1])"
    }
    static func daySortKey(_ d: String) -> Int {
        let p = d.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2 else { return 0 }
        let now = Calendar.current.dateComponents([.month, .year], from: Date())
        let year = (now.year ?? 2026) - (p[1] > (now.month ?? 12) ? 1 : 0)
        return year * 10000 + p[1] * 100 + p[0]
    }

    private var byDay: [(day: String, recs: [Recording])] {
        var map: [String: [Recording]] = [:]
        for r in recordings { map[Self.dayAndTime(r.stem)?.day ?? "overig", default: []].append(r) }
        return map.keys.sorted { Self.daySortKey($0) > Self.daySortKey($1) }.map { k in
            (k, map[k]!.sorted { (Self.dayAndTime($0.stem)?.time ?? "") < (Self.dayAndTime($1.stem)?.time ?? "") })
        }
    }

    private func isActive(_ r: Recording) -> Bool {
        let raw = UserDefaults.standard.string(forKey: RawLogger.activeKey)
        return r.parts.contains { (rec.isRecording && $0 == rec.currentURL) || $0.lastPathComponent == raw }
    }

    var body: some View {
        List {
            if let day {
                dayList(byDay.first { $0.day == day }?.recs ?? [])
            } else {
                ForEach(byDay, id: \.day) { d in
                    NavigationLink { FilesView(day: d.day) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill").foregroundStyle(Theme.accent).frame(width: 24)
                            Text(d.day == "overig" ? "Overig" : Self.dayTitle(d.day)).font(.headline).foregroundStyle(Theme.text)
                            Spacer()
                            Text("\(d.recs.count) \(d.recs.count == 1 ? "deel" : "delen") · " + ByteCountFormatter.string(fromByteCount: Int64(d.recs.reduce(0) { $0 + $1.size }), countStyle: .file))
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
        }
        .overlay { if rec.files.isEmpty { Text("Nog geen opnames").foregroundStyle(.secondary) } }
        .navigationTitle(day.map { $0 == "overig" ? "Overig" : Self.dayTitle($0) } ?? "Opnames")
        .onAppear { rec.refresh(); if day == nil { rec.splitLargeFiles() } }
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .alert("Zippen mislukt", isPresented: .init(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: { Text(failure ?? "") }
    }

    @ViewBuilder private func dayList(_ recs: [Recording]) -> some View {
            ForEach(Array(recs.enumerated()), id: \.element.id) { idx, r in
                let kind = r.parts.first.flatMap(Recorder.Kind.of)
                let time = Self.dayAndTime(r.stem)?.time
                let row = HStack(spacing: 12) {
                    Image(systemName: kind?.icon ?? "doc.text").foregroundStyle(Theme.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Deel \(idx + 1)" + (time.map { " · \($0)" } ?? " · hele dag")).font(.headline).foregroundStyle(Theme.text)
                        Text(kind?.title ?? r.stem).font(.caption).foregroundStyle(Theme.muted)
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
