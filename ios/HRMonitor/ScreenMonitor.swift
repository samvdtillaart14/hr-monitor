import Foundation
import UIKit
import UserNotifications
import notify
import WhoopScores

/// Houdt bij wanneer het iPhone-scherm aan staat en of de telefoon ontgrendeld is.
///
/// iOS geeft apps buiten de App Store geen Schermtijd-gegevens (Family Controls is een entitlement dat
/// AltStore niet kan meegeven, en DeviceActivity toont alleen een rapport, geen tijdstippen). Daarom luistert
/// de app zelf naar de systeemsignalen 'scherm zwart' (com.apple.springboard.hasBlankedScreen) en
/// 'vergrendeld' (com.apple.springboard.lockstate), en ontgrendelen via beschermde data (isProtectedDataAvailable).
/// Dat werkt alleen zolang de app draait; dankzij de Bluetooth-verbinding met de band is dat 's nachts zo.
@MainActor
final class ScreenMonitor: ObservableObject {
    static let enabledKey = "screen.asWake"
    static let morningKey = "morning.enabled"
    static let morningStartKey = "morning.startHour"
    private static let lastBriefKey = "morning.lastDay"

    @Published private(set) var spans: [ScreenSpan] = []
    @Published private(set) var screenOn = true
    @Published private(set) var lastEvent: Date?
    /// Wordt aangeroepen op het eerste telefoonmoment van de ochtend.
    var onMorning: (() -> Void)?

    private var current: ScreenSpan?
    private var blankToken: Int32 = -1
    private var lockToken: Int32 = -1
    private var lastPoll = Date.distantPast
    private static var url: URL { Recorder.folder.appendingPathComponent("screen.json") }

    static var asWake: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var morningOn: Bool { UserDefaults.standard.object(forKey: morningKey) as? Bool ?? true }
    static var morningStart: Double { UserDefaults.standard.object(forKey: morningStartKey) as? Double ?? 5 }

    init() {
        if let d = try? Data(contentsOf: Self.url), let v = try? JSONDecoder().decode([ScreenSpan].self, from: d) { spans = v }
        notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &blankToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(force: true) }
        }
        notify_register_dispatch("com.apple.springboard.lockstate", &lockToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(force: true) }
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            // Kan pas na een iOS-pauze binnenkomen: alleen meetellen als het scherm nog aan staat.
            MainActor.assumeIsolated { guard let self else { return }; let on = self.readState().on ?? true; self.update(on: on, unlocked: on) }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(on: true, unlocked: true) }
        }
        // Begintoestand: open de app zich zichtbaar, dan staat het scherm aan.
        let st = readState()
        update(on: st.on ?? (UIApplication.shared.applicationState == .active), unlocked: st.unlocked ?? false)
    }

    /// Goedkoop: leest de systeemstatus. Aangeroepen bij elke hartslag van de band (de app is dan wakker),
    /// zodat ook wijzigingen tijdens een korte iOS-pauze worden opgepikt.
    func poll(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPoll) >= 2 else { return }
        lastPoll = now
        let st = readState()
        guard let on = st.on else { return }
        update(on: on, unlocked: st.unlocked ?? false)
    }

    /// (scherm aan?, ontgrendeld?) volgens iOS; nil als de status niet leesbaar is.
    private func readState() -> (on: Bool?, unlocked: Bool?) {
        var on: Bool?, unlocked: Bool?
        var v: UInt64 = 0
        if blankToken != -1, notify_get_state(blankToken, &v) == 0 { on = v == 0 }
        // De lockstate-status zelf is niet betrouwbaar op elke iOS-versie; die melding dient alleen als seintje.
        // Ontgrendeld = beschermde data beschikbaar (met toegangscode is die ~10 s na vergrendelen weer dicht).
        let app = UIApplication.shared
        if app.applicationState == .active { on = true; unlocked = true }
        else if on == true { unlocked = app.isProtectedDataAvailable }
        return (on, unlocked)
    }

    private func update(on: Bool, unlocked: Bool) {
        let now = Date().timeIntervalSince1970
        if on {
            if current == nil { current = ScreenSpan(start: now, end: now, unlocked: unlocked); lastEvent = Date() }
            current!.end = now
            if unlocked { current!.unlocked = true }
        } else if var c = current {
            c.end = now
            current = nil
            if c.seconds >= 1 || c.unlocked { append(c) }
            lastEvent = Date()
        }
        screenOn = on
        checkMorning()
    }

    private func checkMorning() {
        guard Self.morningOn, onMorning != nil, let c = current, c.unlocked || c.seconds >= 10 else { return }
        let tz = Double(TimeZone.current.secondsFromGMT()) / 60
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.object(forKey: Self.lastBriefKey) as? Int
        guard ScreenActivity.morningBriefDue(now: now, tzOffsetMin: tz, lastBriefDay: last, startHour: Self.morningStart) else { return }
        UserDefaults.standard.set(ScreenActivity.localDay(now, tzOffsetMin: tz), forKey: Self.lastBriefKey)
        onMorning?()
    }

    private func append(_ s: ScreenSpan) {
        spans.append(s)
        let cutoff = Date().timeIntervalSince1970 - 14 * 86400
        spans.removeAll { $0.end < cutoff }
        if let d = try? JSONEncoder().encode(spans) { try? d.write(to: Self.url, options: .atomic) }
    }

    /// Alle schermperiodes inclusief de lopende.
    var allSpans: [ScreenSpan] {
        guard var c = current else { return spans }
        c.end = Date().timeIntervalSince1970
        return spans + [c]
    }

    /// Wakker-periodes voor de slaapdetectie (leeg als de instelling uit staat).
    func wakeIntervals() -> [Range<Double>] {
        Self.asWake ? ScreenActivity.wakeIntervals(allSpans) : []
    }

    /// Voor testen vanuit Instellingen: de melding morgen opnieuw toestaan.
    func resetMorning() { UserDefaults.standard.removeObject(forKey: Self.lastBriefKey) }
}

/// De ochtendmelding: slaap en herstel van afgelopen nacht, direct als je je telefoon pakt.
@MainActor
enum MorningBrief {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Rekent de nacht opnieuw uit (met het schermmoment als einde van de slaap) en stuurt de melding.
    static func send(services: AppServices) {
        let app = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = app.beginBackgroundTask(withName: "ochtendmelding") { app.endBackgroundTask(task); task = .invalid }
        services.store.flush()
        services.scores.refresh(store: services.store) {
            post(text(services.scores.lastNight))
            InsightNotifications.checkIllness(services.scores.lastNight)
            InsightNotifications.morningJournal()
            if task != .invalid { app.endBackgroundTask(task); task = .invalid }
        }
    }

    static func text(_ n: Night?) -> (title: String, body: String) {
        guard let n else {
            return ("Goedemorgen", "Geen nachtslaap gemeten. Droeg je de band en was de app verbonden?")
        }
        func hm(_ m: Int) -> String { "\(m / 60):" + String(format: "%02d", m % 60) }
        let f = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        var parts: [String] = []
        if let r = n.recovery { parts.append("Herstel \(r)%") }
        var sleep = "Slaap \(hm(n.r.asleepMin))"
        if let p = n.performance { sleep += " (\(Int(p.rounded()))%)" }
        parts.append(sleep)
        if n.r.hrv.isFinite { parts.append("HRV \(Int(n.r.hrv.rounded())) ms") }
        if n.r.rhr.isFinite { parts.append("rust-HR \(Int(n.r.rhr.rounded()))") }
        let body = parts.joined(separator: " · ") + "\n\(n.onset.formatted(f))–\(n.wake.formatted(f)), \(n.r.disturbances)× wakker"
        let title: String
        switch n.recovery {
        case let r? where r >= 67: title = "Goedemorgen, goed hersteld"
        case let r? where r >= 34: title = "Goedemorgen, redelijk hersteld"
        case .some: title = "Goedemorgen, rustig aan vandaag"
        case nil: title = "Goedemorgen"
        }
        return (title, body)
    }

    static func post(_ t: (title: String, body: String)) {
        let c = UNMutableNotificationContent()
        c.title = t.title; c.body = t.body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ochtend", content: c, trigger: nil))
    }
}

/// Meldingen ook tonen als de app open staat.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
    /// Tik op een melding: ochtendoverzicht, dagboek of weekrapport openen.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let req = response.notification.request
        if req.identifier == "ochtend" { await MainActor.run { MorningRouter.shared.show = true }; return }
        guard let raw = req.content.userInfo["sheet"] as? String,
              let s = AppRouter.Sheet(rawValue: raw) else { return }
        await MainActor.run { AppRouter.shared.sheet = s }
    }
}
