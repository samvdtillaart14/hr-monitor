# Testplan HR Monitor

Doel: elke nieuwe versie gaat pas naar AltStore als de automatische tests groen zijn en de korte handmatige ronde op de iPhone is gedaan. Dit document zegt per module wat er getest wordt, hoe, en welke bugs we al gevonden hebben.

## 1. Opbouw

| Laag | Wat | Waar | Draait |
|---|---|---|---|
| 1. Referentie (JS) | Scores-algoritmes en een referentieparser van het BLE-protocol | `scores/` (`node --test test/*.test.mjs`) | CI (Ubuntu) en lokaal op elke pc met Node 22 |
| 2. Scores (Swift) | `WhoopScores`-pakket: pariteit met JS op dezelfde fixture, plus randgevallen | `ios/WhoopScores` (`swift test`) | CI (macOS) |
| 3. App-logica (Swift) | Parser, historie-sync, dagopslag, ScoreModel, profiel, export: de app-bestanden zonder scherm of Bluetooth | `ios/AppTests` (`./sync-app-sources.sh && swift test`) | CI (macOS) |
| 4. Build | Volledige iOS-app compileert | `.github/workflows/ios.yml` | CI bij elke push |
| 5. Handmatig | Alles wat alleen met band, iPhone en tijd te zien is | [HANDMATIGE-TESTS.md](HANDMATIGE-TESTS.md) | Voor elke release, ±20 min |

**Releasepoort.** Merge naar `main` alleen als de workflows *Tests* en *iOS build* groen zijn. Een release met wijzigingen in BLE, sync of opslag krijgt daarna de handmatige ronde (minimaal blok A, B en C).

**Bekende bugs in de tests.** Een test die een nog niet opgeloste bug beschrijft staat in JS als `{ todo: 'BUG-x …' }` en in Swift in een `XCTExpectFailure("BUG-x …")`. Zo blijft CI groen, maar je ziet hem wel. Swift meldt *expected failure not found* zodra de bug is opgelost. Haal dan het `XCTExpectFailure`-blok (of de `todo`) weg; vanaf dat moment bewaakt de test de oplossing.

## 2. Testdata

- **Echte BLE-opnames** (`testdata/ble/*.json`): korte stukken uit Sams RUW-ALLES-opnames van 21 en 22 november, met de notificaties precies zoals ze binnenkwamen (dus met de echte fragmentatie in stukken van 244 bytes). Bij elk stuk staat de verwachte uitkomst van de referentieparser. Swift en JS moeten allebei precies die uitkomst geven.
  - `sync-sessie`: Whoop-app-sync met START/END-bursts, 13 acks (0x24 cmd 23), herhaalde END zonder ack, COMPLETE, 616 records, live 0x28, firmwarelog.
  - `nacht-download`: inhaaldownload 's ochtends, met frames van 2140 en 1244 bytes over meerdere notificaties, plus IMU.
  - `live-rr`: live 0x28 met RR, en 2A37-meldingen.
  - Nieuwe fixture maken: `node scores/test/make-ble-fixture.mjs <RUW-ALLES.csv> testdata/ble/<naam>.json <van:tot> …`. Neem korte stukken: de repo is openbaar.
- **Synthetische nacht** (`scores/test/fixtures/night.json`): deterministisch gegenereerd (`scores/test/synth.js`), met bekende fases, rust-HR en ademfrequentie.
- **Kalibratie en volledige nachten** staan bewust niet in de repo. Ze staan in de projectbestanden (`scores/whoop-calibration.json`) en worden met `scores/compare.mjs` handmatig vergeleken (zie §4.5).

## 3. Draaien

```sh
cd scores && node --test test/*.test.mjs                        # JS, elke pc
cd ios/WhoopScores && swift test                                # Mac
cd ios/AppTests && ./sync-app-sources.sh && swift test          # Mac
```

Een nieuw app-bestand met testbare logica (alleen `Foundation`) zet je in de lijst in `ios/AppTests/sync-app-sources.sh`.

## 4. Testgevallen per module

Status: ✅ automatisch, ⚠️ automatisch maar bekende bug (todo / expected failure), 🖐 handmatig, ⬜ nog niet gedekt.

### 4.1 BLE-parsing (`WhoopParser.swift`; JS: `scores/ble-frames.js`)

| ID | Test | Status |
|---|---|---|
| BLE-01 | Commandoframes byte voor byte gelijk aan 8 frames die de band echt accepteerde (hello, 0x16, 0x03, 0x6A), inclusief volgnummer en opvulling | ✅ JS + Swift |
| BLE-02 | CRC16-Modbus en CRC32 met bekende controlewaarden | ✅ JS + Swift |
| BLE-03 | Elk frame in de echte opnames heeft een geldige CRC32-trailer (dus de controle gooit nooit goede data weg) | ✅ JS + Swift |
| BLE-04 | Uitkomst op echte opnames gelijk aan de referentie: frames, typen, records (tijd, HR, RR, huidtemp, oriëntatie, temp2/3), trims, antwoorden, COMPLETE, live | ✅ Swift tegen JS |
| BLE-05 | Plausibiliteit records: HR 30–220, RR 250–2500 ms, ≤4 RR per seconde, geen dubbele tijden | ✅ JS |
| BLE-06 | Byte voor byte voeden geeft hetzelfde als per notificatie | ✅ JS + Swift |
| BLE-07 | Rommel tussen de frames (losse 0xAA, nullen) → alle frames teruggevonden | ✅ JS + Swift |
| BLE-08 | Notificatie valt weg → nooit een verkeerd record; met CRC32-controle minder verlies | ✅ JS + Swift |
| BLE-09 | Kapotte databyte → dat frame overgeslagen, de rest wel gelezen | ✅ JS + Swift |
| BLE-10 | Half frame, dan nieuwe verbinding (`resetBuffers`) → oude helft telt niet mee | ✅ JS + Swift |
| BLE-11 | Buffer begrensd bij eindeloze rommel | ✅ JS + Swift |
| BLE-12 | Record met onmogelijke tijd (klok van de band niet gezet) wordt genegeerd | ✅ JS + Swift |
| BLE-13 | Live 0x28: RR in 1/1024 s → ms; mediaan past bij de hartslag | ✅ JS |
| BLE-14 | 2A37 (standaard hartslag): flags, 16-bit HR, energie, meerdere RR | ⬜ zit in `BLEManager.handleHR` (CoreBluetooth). Advies: verplaatsen naar een losse functie, dan in AppTests (fixture `live-rr` bevat al 2A37). |
| BLE-15 | Verbinden, herverbinden, iOS-herstel op de achtergrond | 🖐 B1–B4 |

### 4.2 Historie-sync en ack (`HistorySync.swift`, `BLEManager`)

De beslislogica (wanneer wel of niet zelf cmd 23 sturen) zit sinds deze versie in `HistorySync`. `BLEManager` voert alleen uit (frame sturen, timers, status).

| ID | Test | Status |
|---|---|---|
| SYNC-01 | Opbouw ack: variant 0 (`01` + 8 bytes trim) en variant 1 (`01` + 4 bytes + 4 nullen) | ✅ Swift |
| SYNC-02 | Handmatig cmd 23 via de verkenner wordt herkend en geblokkeerd | ✅ Swift |
| SYNC-03 | Whoop-app draait mee: die bevestigt, wij sturen niets; wachttijd blijft 3 s | ✅ Swift |
| SYNC-04 | Standalone: eerste burst na 3 s, daarna 0,3 s; teller klopt; nieuwe sync begint weer met 3 s | ✅ Swift |
| SYNC-05 | Nieuwe END vervangt een wachtende; één END geeft nooit twee acks | ✅ Swift |
| SYNC-06 | "Mislukt" telt alleen als weigering bij onze eigen ack | ✅ Swift |
| SYNC-07 | "Bezig" (2) gevolgd door "ok" blijft onze ack (BUG-6) | ✅ Swift |
| SYNC-08 | Antwoorden op andere commando's veranderen niets | ✅ Swift |
| SYNC-09 | Echte Whoop-sync afspelen: elke END die de Whoop-app bevestigde, bevestigen wij niet nog eens | ✅ Swift |
| SYNC-10 | Schakelaar uit: nooit cmd 23 op de band (ruwe opname controleren op WRITE …23 17) | 🖐 C1 |
| SYNC-11 | Schakelaar aan, Whoop-app gesloten: volledige sync tot "Klaar: n blokken", geen gat in de grafiek | 🖐 C2 |
| SYNC-12 | Schakelaar aan, Whoop-app open: Whoop-app blijft synchroniseren en toont dezelfde nacht | 🖐 C3 (risico BUG-10) |
| SYNC-13 | Vastgelopen sync (>120 s) wordt losgelaten; elke 15 min nieuwe aanvraag; na herverbinden max. 1× per 10 min | ⬜ timers in BLEManager; nu alleen 🖐 C4 |

### 4.3 Dagopslag (`DayStore.swift`)

| ID | Test | Status |
|---|---|---|
| STORE-01 | Historie wint van live in dezelfde seconde; live erna verandert niets | ✅ Swift |
| STORE-02 | Twee live-pakketten in één seconde: alle slagen bewaard | ✅ Swift |
| STORE-03 | Dubbel historierecord genegeerd | ✅ Swift |
| STORE-04 | Beweging uit oriëntatie: q en −q zijn gelijk, 90° draaien telt, na een gat >5 s geen vergelijking | ✅ Swift |
| STORE-05 | Oriëntatie met NaN wordt niet opgeslagen | ✅ Swift |
| STORE-06 | Opslaan en opnieuw inlezen: HR, RR, bron, oriëntatie, beweging blijven gelijk | ✅ Swift |
| STORE-07 | Oud bestandsformaat (zonder bronkolom) wordt goed ingelezen | ✅ Swift |
| STORE-08 | Nachtvenster altijd oplopend in tijd, ook na een tijdzonewissel (BUG-3) | ✅ Swift |
| STORE-09 | Live zonder hartslag (0) wordt niet opgeslagen | ✅ Swift |
| STORE-10 | Dagindeling volgt de lokale kalender | ✅ Swift |
| STORE-11 | Opslag vol: geen crash, melding, buffer begrensd | 🖐 (simuleren lastig); code: `safeWrite` |
| STORE-12 | App wordt door iOS gestopt en op de achtergrond herstart: geen data kwijt | 🖐 B3 |

### 4.4 Slaap (`WhoopScores.analyzeNight`, `detectSleep`, `mainSleep`, `stageSleep`)

| ID | Test | Status |
|---|---|---|
| SLP-01 | Synthetische nacht: begin, einde, fases, verstoringen, HRV, rust-HR, ademhaling, huidtemp gelijk in Swift en JS | ✅ (bestaand) |
| SLP-02 | Ademfrequentie uit RSA 15/min; trage golven winnen niet | ✅ (bestaand) |
| SLP-03 | Nachtblokken tussen 22:00 en 08:00 worden één nacht; middagdutje blijft dutje (RG-13) | ✅ JS + Swift |
| SLP-04 | Los staartje na het wakker worden telt niet mee | ✅ (bestaand) |
| SLP-05 | Uitslapen na 08:00 met kort wakker moment blijft één nacht (RG-12) | ✅ JS + Swift (BUG-2) |
| SLP-06 | Zelfde lokale nacht bij UTC+1 en UTC+2 (zomertijd) geeft dezelfde hoofdslaap (RG-14) | ✅ JS + Swift |
| SLP-07 | Echte nacht tegen de Whoop-waarden (begin/einde ±15 min, slaapduur ±30 min, fases ±15 %-punt) | 🖐 §4.5, na elke wijziging aan slaap |

### 4.5 Scores (strain, herstel, slaapbehoefte, stress, energie)

| ID | Test | Status |
|---|---|---|
| SCO-01 | Pariteit Swift = JS voor strain, herstel, slaapbehoefte/schuld/prestatie/consistentie, calorieën | ✅ (bestaand) |
| SCO-02 | Zones, strain monotoon en < 21, kalibratie-JSON tolerant voor oude bestanden | ✅ (bestaand) |
| SCORE-01 | Geen data: geen nacht, dag met strain 0 en energie 0 | ✅ Swift |
| SCORE-02 | Eén nacht: behoefte, prestatie, stress, HR-grafiek; zonder eigen basislijn geen herstel maar "nog n nachten", met kalibratie herstel 1–99; consistentie pas vanaf 2 nachten | ✅ Swift |
| SCORE-03 | Geen RR: geen herstel (nil) in plaats van een gok | ✅ Swift |
| SCORE-04 | Te weinig data (≤ 30 min): geen nacht | ✅ Swift |
| SCORE-05 | Slaapschuld loopt door over opeenvolgende nachten, niet over een gat van dagen | ✅ Swift |
| SCORE-06 | Dagbelasting en energie (rustverbruik over niet-gemeten tijd) | ✅ Swift |
| SCORE-07 | Historie uit het nachtarchief wordt gebruikt | ✅ Swift |
| SCORE-08 | Alle waarden voor de schermen eindig (geen NaN of ∞) | ✅ Swift |
| RG-09 | Herstel eerste nachten (< 4 nachten historie) bij normale eigen waarden niet extreem | ✅ JS + Swift (BUG-1) |
| RG-10/11 | Herstel met identieke historie (sd 0) eindig en gemiddeld; altijd 1–99 | ✅ JS + Swift |
| RG-16/17 | Losse hartslagpiek geeft nauwelijks belasting; 0 minuten in zones geeft 0 | ✅ JS (+ Swift RG-16) |
| RG-18 | Slaapschuld altijd tussen 0 en plafond | ✅ JS + Swift |
| SCO-10 | Kalibratie tegen Whoop-export: RMSE herstel ≤ 9 %-punt, strain ≤ 1,0, slaapprestatie ≤ 6 %-punt (`node scores/calibrate.mjs`, rapport in projectbestanden) | 🖐 bij elke wijziging aan scores |
| SCO-11 | Levensduur/biologische leeftijd (`AgeModel`) | ⬜ zit in `HealthTab.swift` (SwiftUI). Advies: naar eigen bestand, dan testen: 1 dag data, zones 0:00, ontbrekende waarden (BUG-12) |
| SCO-12 | Stress overdag (`StressView.buckets`) | ⬜ zelfde advies |

### 4.6 Profiel en kalibratie (`UserProfile.swift`)

| ID | Test | Status |
|---|---|---|
| PROF-01 | Rust-HR = mediaan van plausibele nachten (30–110), pas vanaf 3 nachten | ✅ Swift |
| PROF-02 | Kalibratie gebruikt profiel; rust-HR altijd ≥ 20 onder max-HR | ✅ Swift |
| PROF-03 | Onzinnig gewicht wordt genegeerd | ✅ Swift |
| PROF-04 | Ongeldige kalibratie geweigerd; geldige aangevuld met standaardwaarden | ✅ Swift |

### 4.7 Opnames en export (`FileSplitter`, `ZipExport`, `Recorder`)

| ID | Test | Status |
|---|---|---|
| FILE-01 | Opsplitsen: elke regel precies één keer, kopregel in elk deel, alleen hele regels, origineel pas daarna weg | ✅ Swift |
| FILE-02 | Regel langer dan een deel blijft heel | ✅ Swift |
| FILE-03 | Namen `_deelN` | ✅ Swift |
| FILE-04 | Zip is geldig (`unzip -t`), gecomprimeerd en compleet | ✅ Swift |
| FILE-05 | Soort opname uit bestandsnaam | ✅ Swift |
| FILE-06 | Zip van een nacht < 30 MB en uploadbaar in Claude | 🖐 E1 |

### 4.8 Randgevallen (overzicht)

| Randgeval | Gedekt door |
|---|---|
| Geen of weinig data | RG-01, RG-02, SCORE-01, SCORE-04 |
| Gaten (band af, verbinding weg) | RG-05, BLE-08, BLE-10, SCORE-05; 🖐 B2 |
| Eerste dag / eerste nachten | RG-09, SCORE-02, SCORE-07, PROF-01 |
| Ontbrekende RR | RG-03, RG-04, SCORE-03 |
| Ontbrekende beweging (alleen live) | RG-04 (zie BUG-9) |
| Dubbele data | RG-06, STORE-01, STORE-03, BLE-04 |
| Tijdzones en zomertijd | RG-14, STORE-08, STORE-10; BUG-3, BUG-11 |
| Klok van de band fout | BLE-12 |
| Kapotte of verloren BLE-data | BLE-07 t/m BLE-11 |
| Opslag vol | STORE-11 🖐 |
| App op de achtergrond / door iOS gestopt | 🖐 B3, B4 |

## 5. Gevonden bugs

Status: **opgelost** in deze PR, **andere thread** (wordt opgelost in de thread "Bereken Whoop-scores"), **open**.

| # | Bug | Gevonden met | Status |
|---|---|---|---|
| BUG-1 | Herstel 1–2 % bij normale waarden zolang er < 4 nachten historie is: de basislijn valt terug op populatiewaarden (HRV 60 ms, rust-HR 55). Bij Sams HRV ~30 ms geeft dat z ≈ −2,8 → 1–2 %. | RG-09 | **opgelost** (PR #13) |
| BUG-2 | Uitslapen: slaap 03:00–08:10, 25 min wakker, 08:35–10:30 → het deel na 08:00 telt als dutje, de nacht wordt 2 uur te kort. `mainSleep` voegt alleen blokken samen die zelf (deels) tussen 22 en 08 liggen. | RG-12 | **opgelost** (PR #13) |
| BUG-3 | Ongesorteerde samples (na een tijdzonewissel kan het bestand van gisteren latere seconden bevatten) → crash in `epochs` (index −1) en negatieve belasting/energie. | RG-07, RG-08, STORE-08 | **opgelost** in `DayStore.samples` (sorteert als nodig); in het algoritme zelf nog open |
| BUG-4 | Valt er één BLE-notificatie weg, dan slokte de parser de volgende frames op (alleen de header-CRC werd gecontroleerd). In de test kwamen na een weggevallen notificatie 37 661 i.p.v. 32 522 records terug met CRC32-controle (+16 %). | BLE-08 | **opgelost** (CRC32-controle) |
| BUG-5 | Records met onmogelijke tijd (bv. klok van de band niet gezet) zouden als dag in 1970 of in de toekomst worden opgeslagen. | BLE-12 | **opgelost** |
| BUG-6 | Sync: antwoordt de band "bezig" op onze ack, dan werd het latere "ok" aan de Whoop-app toegeschreven → daarna elke burst 3 s wachten in plaats van 0,3 s. | SYNC-07 | **opgelost** |
| BUG-7 | Live "contact: niet gemeld": de band zet de contactbit in 2A37 nooit (flags altijd 0x00 of 0x10 in 1 460 meldingen). | analyse opnames | andere thread |
| BUG-8 | Live-HRV "--": RR zit maar in ~17 % van de 2A37-meldingen en ~15 % van de 0x28-pakketten, met veel artefacten (gesplitste slag 974+325 ms, gemiste slag 2 071 ms). `BLEManager` gebruikt alleen 2A37 en filtert alleen sprongen > 300 ms. 0x28 stopt bovendien nadat de Whoop-app realtime uitzet (0x03). | BLE-13, analyse | andere thread |
| BUG-9 | Zonder bewegingsdata (alleen live) telt wakker liggen als slaap: synthetische nacht 266 i.p.v. 220 min. | RG-04 | open (bekend, laag) |
| BUG-10 | Schakelaar "Whoop-app vervangen" aan terwijl de Whoop-app draait: in de opname liet de Whoop-app een END bewust onbevestigd (4× herhaald, daarna nieuwe 0x22). Wij bevestigen die na 3 s wel. Effect onbekend. | sync-sessie | open, 🖐 C3 |
| BUG-11 | Zomertijd: `ScoreModel` gebruikt de huidige UTC-afwijking voor alle 7 nachten; nachten vóór de wissel schuiven 1 uur voor de 22–08-regel en de consistentie. | code-review | open (laag, 2× per jaar) |
| BUG-12 | Levensduur na één dag extreem; zones 0:00 geven toch jaren; stappen leeg. Niet automatisch testbaar zolang `AgeModel` in een SwiftUI-bestand zit. | screenshots | andere thread |

## 6. Nog niet gedekt en advies

1. **2A37-parser en live-RMSSD** uit `BLEManager` halen naar een los bestand (zoals `HistorySync`), dan BLE-14 en een live-HRV-test op `live-rr`.
2. **`AgeModel` en `StressView.buckets`** naar eigen bestanden; dan SCO-11/12 met randgevallen (1 dag, 0 minuten, ontbrekende waarden).
3. **Timers in de sync** (SYNC-13): klok injecteerbaar maken, dan automatisch.
4. **Echte nachten als regressietest**: zodra er een paar nachten met Whoop-waarden zijn, een privé-map (niet in de repo) met `compare.mjs` als vaste stap voor een release met slaapwijzigingen.
5. **Na een opgeloste bug** altijd eerst een test die faalt, dan de fix.
