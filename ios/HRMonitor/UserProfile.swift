import Foundation
import WhoopScores

/// Profielwaarden die je zelf invult (Profiel-scherm op het tabblad Gezondheid).
/// Alle berekeningen (zones, belasting, slaap, herstel, calorieën) lezen ze hier uit.
enum UserProfile {
    static let maxHrKey = "profile.maxHr"
    static let restHrKey = "profile.restHr"

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

    /// Ingevulde rust-HR (bpm), of de standaard.
    static var restHr: Double {
        let v = d.double(forKey: restHrKey)
        return v > 0 ? v : Calibration.standard.profile.restingHr
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
