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
    static var restHr: Double { measuredRestHr ?? Calibration.standard.profile.restingHr }

    /// Rust-HR uit de nachten: mediaan van de rust-HR per nacht (laagste stabiele hartslag tijdens diepe slaap).
    static func updateRestHr(from nights: [Double]) {
        let v = nights.filter { $0.isFinite && $0 >= 30 && $0 <= 110 }.sorted()
        guard !v.isEmpty else { return }
        let m = v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
        d.set(m.rounded(), forKey: restHrAutoKey)
    }

    /// Kalibratie voor de scores-module met jouw profiel erin.
    static func calibration() -> Calibration {
        var c = Calibration.standard
        if let age { c.profile.age = age }
        if d.object(forKey: "profile.male") != nil { c.profile.male = d.bool(forKey: "profile.male") }
        c.profile.maxHr = maxHr
        c.profile.restingHr = min(restHr, maxHr - 20)
        return c
    }

    /// Alleen het profieldeel, voor de zonekleuren.
    static var current: Calibration.Profile { calibration().profile }
}
