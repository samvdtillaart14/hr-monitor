# Pulse

Web Bluetooth-app (één HTML-bestand) die rechtstreeks verbindt met een BLE-apparaat, zoals een Whoop-band, en de ruwe data uitleest.

## Functies
- Dashboard: hartslag, min/gem/max, RR-interval, HRV (RMSSD over 60 s), batterij, grafiek van 5 min
- Opnemen naar CSV (tijd, bpm, RR)
- Installeerbaar als app (PWA) in Chrome/Edge, werkt offline
- Alle services en characteristics tonen
- Lezen, pollen, notify/indicate, schrijven (hex of tekst)
- Live log in hex, decimaal of geïnterpreteerd (u8/u16/u32/f32/ASCII)
- Decodering Heart Rate Measurement (0x2A37 → bpm + RR-intervallen) en Battery Level
- Export naar CSV (`;`-gescheiden) en JSON

## Gebruik
Web Bluetooth werkt in Chrome of Edge (Windows, macOS, Android), via https of `http://localhost` (niet via `file://`). Op iPhone/iPad werkt geen enkele browser; gebruik daar de app **Bluefy – Web BLE Browser** (App Store).

- **Online:** via GitHub Pages (Settings → Pages → branch `main`).
- **Lokaal:** start `start-server.bat` (vereist Python) en open `http://localhost:8000/index.html`.

Whoop: zet *Heart Rate Broadcast* aan in de Whoop-app voor de standaard Heart Rate Service (0x180D). De band verbindt vaak maar met één apparaat tegelijk.

## iPhone-app (gratis, opname met scherm uit)

De map `ios/` bevat een eigen iPhone-app (SwiftUI + CoreBluetooth). Die blijft op de achtergrond verbonden en neemt op met het scherm uit. GitHub bouwt hem automatisch bij elke wijziging. De nieuwste `.ipa` staat altijd onder [Releases → latest](https://github.com/samvdtillaart14/hr-monitor/releases/tag/latest).

### Eenmalig installeren met AltStore (Windows)
1. Installeer **iTunes** en **iCloud** van apple.com (niet de Microsoft Store-versies) en daarna **AltServer** van altstore.io.
2. Sluit je iPhone met een kabel aan en tik op *Vertrouw*. Zet in iTunes **Synchroniseer met deze iPhone via wifi** aan.
3. Klik in het systeemvak op het AltServer-icoon → *Install AltStore* → kies je iPhone en log in met je Apple ID. Een gratis account volstaat.
4. Op de iPhone: *Instellingen → Algemeen → VPN en apparaatbeheer* → vertrouw je Apple ID. Zet ook *Instellingen → Privacy en beveiliging → Ontwikkelaarsmodus* aan.
5. Download `HRMonitor.ipa` op je iPhone (Releases → latest) → open AltStore → *My Apps* → **+** → kies het bestand.

### Vernieuwen
Een gratis Apple ID ondertekent apps voor 7 dagen. AltStore vernieuwt ze automatisch op de achtergrond als je iPhone en je pc (met AltServer actief) op hetzelfde wifi zitten. Laat je pc dus minstens eens per week aanstaan, of tik in AltStore op *Refresh All*.

### Gebruik
- Zet in de Whoop-app **Heart Rate Broadcast** aan en sluit daarna de Whoop-app.
- In Pulse: *Zoek band* → kies je Whoop → *Start opname*. Je kunt het scherm nu uitzetten.
- Opnames staan in de app onder *Opnames* (delen/AirDrop) en in de **Bestanden**-app → *Op mijn iPhone → Pulse*.
- Sluit de app niet geforceerd af door hem omhoog te vegen. Dan stopt iOS de Bluetooth-verbinding.

## Testen

Elke push draait de workflow **Tests** (JS-referentie, Swift-scores en app-logica) naast de iOS-build. Merge pas als beide groen zijn. Wat er getest wordt, de randgevallen en de lijst gevonden bugs staan in [docs/TESTPLAN.md](docs/TESTPLAN.md); de korte ronde op de iPhone voor een release in [docs/HANDMATIGE-TESTS.md](docs/HANDMATIGE-TESTS.md).
