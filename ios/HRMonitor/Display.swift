import SwiftUI

/// Welke onderdelen zichtbaar zijn (Instellingen › Weergave). Standaard alles aan.
enum Display {
    static let liveMinMax = "ui.show.live.minmax"
    static let liveSkin = "ui.show.live.skin"
    static let todayStressTile = "ui.show.today.stressTile"
    static let todayStressChart = "ui.show.today.stressChart"
    static let sleepStages = "ui.show.sleep.stages"
    static let healthAge = "ui.show.health.age"
    static let healthPace = "ui.show.health.pace"
    static let healthWeekAge = "ui.show.health.weekAge"
}

/// Sectie in Instellingen met schakelaars per onderdeel.
struct DisplaySettingsSection: View {
    @AppStorage(Display.liveMinMax) private var liveMinMax = true
    @AppStorage(Display.liveSkin) private var liveSkin = true
    @AppStorage(Display.todayStressTile) private var stressTile = true
    @AppStorage(Display.todayStressChart) private var stressChart = true
    @AppStorage(Display.sleepStages) private var stages = true
    @AppStorage(Display.healthAge) private var age = true
    @AppStorage(Display.healthPace) private var pace = true
    @AppStorage(Display.healthWeekAge) private var weekAge = true

    var body: some View {
        Section {
            Toggle("Live: min / gem / max", isOn: $liveMinMax)
            Toggle("Live: huidtemperatuur", isOn: $liveSkin)
            Toggle("Vandaag: stresstegel", isOn: $stressTile)
            Toggle("Vandaag: stressgrafiek", isOn: $stressChart)
            Toggle("Slaap: slaapfases", isOn: $stages)
            Toggle("Gezondheid: biologische leeftijd", isOn: $age)
            Toggle("Gezondheid: verouderingstempo", isOn: $pace)
            Toggle("Levensduur: leeftijd per week", isOn: $weekAge)
        } header: { Text("Weergave") } footer: {
            Text("Zet onderdelen uit die je niet nodig hebt. Slaapfases zijn geschat uit hartslag; de biologische leeftijd per week schommelt. Er wordt niets gewist.")
        }
        .tint(Theme.accent)
    }
}
