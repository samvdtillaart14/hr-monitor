import Foundation
import WhoopScores

/// Profielwaarden: max-HR vul je zelf in (Profiel-scherm op het tabblad Gezondheid), rust-HR wordt berekend.
/// Alle berekeningen (zones, belasting, slaap, herstel, calorieën) lezen ze hier uit.
enum UserProfile {
    static let maxHrKey = "profile.maxHr"
    /// Rust-HR berekend uit je nachten (mediaan), bijgewerkt door ScoreModel.
    static let restHrAutoKey = "profile.restHrAuto"

    private static var d: UserDefaults { .standard }

    /// Leeftijd in jaren uit de geboortedatum, of nil als die niet is ingevuld.
    static var age: Double? {
        let b = d.double(forKey: "profile.birth")
        return b > 0 ? (Date().timeIntervalSince1970 - b) / 31_557_600 : nil
    }

    /// Schatting als je geen max-HR invult: 208 − 0,7 × leeftijd (Tanaka), anders de standaard.
    static var estimatedMaxHr: Double {
        age.map { (208 - 0.7 * $0).rounded() } ?? Calibration.standard.profile.maxHr
    }

    /// Ingevulde max-HR (bpm), of de schatting.
    static var maxHr: Double {
        let v = d.double(forKey: maxHrKey)
        return v > 0 ? v : estimatedMaxHr
    }

    /// Berekende rust-HR (bpm), of nil zolang er nog geen nacht is gemeten.
    static var measuredRestHr: Double? {
        let v = d.double(forKey: restHrAutoKey)
        return v > 0 ? v : nil
    }

    /// Berekende rust-HR, of de standaard zolang er nog geen nacht is gemeten.
    static var restHr: Double { measuredRestHr ?? (importedCalibration ?? .standard).profile.restingHr }

    /// Rust-HR uit de nachten: mediaan van de rust-HR per nacht (gemiddelde HR tijdens de slaap).
    /// Pas vanaf 3 nachten; één nacht (bv. met alcohol) verschuift anders je hartslagzones.
    static func updateRestHr(from nights: [Double]) {
        let v = nights.filter { $0.isFinite && $0 >= 30 && $0 <= 110 }.sorted()
        guard v.count >= 3 else { d.removeObject(forKey: restHrAutoKey); return }
        let m = v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
        d.set(m.rounded(), forKey: restHrAutoKey)
    }

    static let weightKey = "profile.weight", heightKey = "profile.height"

    // MARK: kalibratie uit de Whoop-export (whoop-calibration.json)

    /// Opgeslagen in Documenten (niet in de openbare repo).
    static var calibrationURL: URL { Recorder.folder.appendingPathComponent("calibration.json") }
    private static var cachedCal: Calibration?
    private static var cacheLoaded = false

    /// Geïmporteerde kalibratie, of nil.
    static var importedCalibration: Calibration? {
        if !cacheLoaded {
            cachedCal = try? Calibration.load(from: calibrationURL)
            cacheLoaded = true
        }
        return cachedCal
    }

    /// Leest en bewaart een kalibratiebestand; gooit een fout als het geen geldige kalibratie is.
    static func importCalibration(from url: URL) throws {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let cal = try Calibration.decodeLenient(data)
        try data.write(to: calibrationURL, options: .atomic)
        cachedCal = cal; cacheLoaded = true
    }

    static func removeCalibration() {
        try? FileManager.default.removeItem(at: calibrationURL)
        cachedCal = nil; cacheLoaded = true
    }

    /// Kalibratie voor de scores-module met jouw profiel erin.
    static func calibration() -> Calibration {
        var c = importedCalibration ?? Calibration.standard
        // Een geïmporteerde kalibratie komt uit je eigen Whoop-export: de basislijn daarin is persoonlijk.
        if importedCalibration != nil { c.recovery.baselinePersonal = true }
        if let age { c.profile.age = age }
        if d.object(forKey: "profile.male") != nil { c.profile.male = d.bool(forKey: "profile.male") }
        let w = d.double(forKey: weightKey), h = d.double(forKey: heightKey)
        if w >= 30 && w <= 250 { c.profile.weightKg = w }
        if h >= 120 && h <= 230 { c.profile.heightCm = h }
        c.profile.maxHr = maxHr
        c.profile.restingHr = min(restHr, maxHr - 20)
        return c
    }

    /// Alleen het profieldeel, voor de zonekleuren.
    static var current: Calibration.Profile { calibration().profile }
}
