import Foundation
import SwiftUI

/// Vertaalde tekst: de Nederlandse tekst is de sleutel; in het Engels komt de vertaling uit en.lproj/Localizable.strings.
func L(_ s: String) -> String { NSLocalizedString(s, comment: "") }

extension Text {
    /// Tekst uit een variabele: ook vertalen (letterlijke teksten in Text("…") vertaalt SwiftUI zelf).
    init(_ s: String) { self.init(verbatim: L(s)) }
}

/// Gegevens voor de widget, gedeeld via de app-groep (app schrijft, widget leest).
struct WidgetSnapshot: Codable {
    var recovery: Int?
    var sleepPerf: Int?
    var asleepMin: Int?
    /// belasting van vandaag (0–21)
    var strain: Double?
    var bedtime: Date?
    var wake: Date?
    var updated = Date()

    static let fallbackGroup = "group.nl.samvdtillaart.hrmonitor"

    /// App-groep uit het eigen provisioning-profiel: AltStore past de groepsnaam aan je Apple ID aan,
    /// dus de vaste naam klopt dan niet meer.
    static let groupID: String = {
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let start = data.range(of: Data("<?xml".utf8)),
           let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
           let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
           let ent = plist["Entitlements"] as? [String: Any],
           let groups = ent["com.apple.security.application-groups"] as? [String],
           let g = groups.first(where: { $0.contains("hrmonitor") }) ?? groups.first {
            return g
        }
        return fallbackGroup
    }()

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent("widget.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let url, let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }

    func save() {
        guard let url = Self.url, let d = try? JSONEncoder().encode(self) else { return }
        try? d.write(to: url, options: .atomic)
    }
}
