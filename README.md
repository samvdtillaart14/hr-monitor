# Whoop BLE Reader

Web Bluetooth-app (één HTML-bestand) die rechtstreeks verbindt met een BLE-apparaat, zoals een Whoop-band, en de ruwe data uitleest.

## Functies
- Alle services en characteristics tonen
- Lezen, pollen, notify/indicate, schrijven (hex of tekst)
- Live log in hex, decimaal of geïnterpreteerd (u8/u16/u32/f32/ASCII)
- Decodering Heart Rate Measurement (0x2A37 → bpm + RR-intervallen) en Battery Level
- Export naar CSV (`;`-gescheiden) en JSON

## Gebruik
Web Bluetooth werkt alleen in Chrome of Edge, via https of `http://localhost` (niet via `file://`).

- **Online:** via GitHub Pages (Settings → Pages → branch `main`).
- **Lokaal:** start `start-server.bat` (vereist Python) en open `http://localhost:8000/index.html`.

Whoop: zet *Heart Rate Broadcast* aan in de Whoop-app voor de standaard Heart Rate Service (0x180D). De band verbindt vaak maar met één apparaat tegelijk.
