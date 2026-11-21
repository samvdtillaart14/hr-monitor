# HR Monitor

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
