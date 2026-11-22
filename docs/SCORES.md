# Whoop-scores nabootsen

Code: `scores/whoop-scores.js` (browser/Node) en `ios/WhoopScores` (Swift-package, gekoppeld aan de app). Beide doen exact hetzelfde. De Swift-tests vergelijken met uitkomsten van de JS-versie (`scores/test/fixtures/night.json`).

## Werkwijze per score
Gebaseerd op Whoop's eigen uitleg; de vorm van de formules is een eigen keuze, de parameters worden gefit op jouw Whoop-export.

| Score | Methode | Parameters uit export |
|---|---|---|
| **Slaapdetectie** | Epochs van 60 s. Slaap = weinig beweging (hoekverandering van de oriëntatie-quaternion, 7-min-mediaan onder een automatische drempel) én HR < rust-HR + 20. Gaten ≤ 15 min worden samengevoegd; een los staartje < 20 min na het wakker worden telt niet mee. Langste periode = hoofdslaap. Slaap tussen 22:00 en 08:00 (lokale tijd) is altijd nachtslaap: alle nachtblokken binnen 4 uur van elkaar worden één nacht, met de tussentijd als wakker. Dutjes alleen overdag. | – |
| **Slaapfases** | Wakker: beweging of buiten de slaapkandidaten. Diep: lage, stabiele HR, hoge RMSSD, vroeg in de nacht. REM: wisselende HR, lagere RMSSD, later in de nacht, niet in de eerste 45 min. Diep en REM worden op rangorde toegekend, zodat de verdeling jouw gemiddelde Whoop-verdeling volgt. | `deepFrac`, `remFrac` |
| **HRV** | RMSSD over 5-min-vensters met schone RR (300–2000 ms, ≤ 20 % van de lokale mediaan). Gemiddelde over alle 5-min-vensters in slaap (rust-HR idem); dat kwam op een echte nacht het dichtst bij Whoop (HRV ±1 ms, rust-HR ±1 bpm). `hrvFrom: 'lastDeep'` geeft het laatste diepe blok. | correctie a + b·x |
| **Rust-HR** | Gemiddelde HR in dezelfde vensters. | correctie |
| **Ademfrequentie** | Piek in 0,1–0,5 Hz van het RR-tachogram (sinusaritmie), mediaan over 2-min-vensters in slaap. | correctie |
| **Strain** | Minuten per HR-zone (hartslagreserve, zones 50–60 % … 90–100 %), gewogen k^γ (zone 0 apart); `min(21, a·ln(1 + T/b))`. | `a`, `b`, gewicht zone 0, γ |
| **Slaapbehoefte** | basis + k·slaapschuld + k·(strain gisteren − 10) − dutjes. | alle drie de coëfficiënten |
| **Slaapprestatie** | c0 + c1·toereikendheid (geslapen/behoefte) + c2·efficiëntie + c3·consistentie, zoals Whoop sinds 2023. | c0…c3 |
| **Consistentie** | Gemiddelde overlap (doorsnede/vereniging op de 24-uursklok) van vannacht met elk van de 3 nachten ervoor. | – |
| **Recovery** | Logistisch model op z-scores t.o.v. je eigen basislijn (ln HRV, rust-HR, ademfrequentie, huidtemp), slaapprestatie, de slaapdelen apart (toereikendheid, efficiëntie, consistentie) en de interactie HRV × slaapprestatie. | gewichten + venster (7–60 dagen) |
| **SpO₂** | Ratio-of-ratios, pas bruikbaar als de ruwe optische data gedecodeerd is. | – |

Recovery is het best te benaderen: `physiological_cycles.csv` bevat Whoop's eigen invoer én uitkomst, dus het model wordt direct op Whoop's functie gefit. Hoe dicht we uiteindelijk zitten, hangt dan vooral af van hoe goed onze HRV en rust-HR die van Whoop volgen; daarvoor dienen de correcties.

## Resultaat op Sams export (21-11-2026: 184 cycli, 157 workouts, 178 nachten)
Fout van ons model t.o.v. Whoop, met Whoop's eigen invoerwaarden:

| Score | RMSE |
|---|---|
| Strain (workouts) | 0,88 punt |
| Slaapprestatie | 5,7 %-punt (alleen geslapen/behoefte: 7,6) |
| Slaapbehoefte | 19 min |
| Consistentie (eigen formule, zonder fit) | 9,6 %-punt, r = 0,89 |
| Recovery | 8,1 %-punt (kruisvalidatie; laatste 20 % als holdout: 8,9) |

Recovery: het belangrijkste inzicht is de interactie HRV × slaapprestatie. Een hoge HRV telt bij Whoop pas echt mee na een goede nacht. Daarmee zakt de fout van 10,2 naar 8,1 punten. Het basislijnvenster komt uit op 30 dagen, gelijk aan de basislijn die de Whoop-app toont. Daarnaast weegt de toereikendheid (geslapen/behoefte) zwaar. Rust-HR en ademfrequentie dragen in Sams data nauwelijks bij. Andere basislijnen (7–120 dagen, exponentieel, rangorde) en extra invoer (strain, slaapschuld, fases) hielpen niet.

De kalibratie zelf staat niet in deze (openbare) repo; `whoop-calibration*.json` staat in `.gitignore`.

## Kalibreren
1. Whoop-app → Profiel → App Settings → Data Export; zip uitpakken.
2. `node scores/calibrate.mjs <export-map> > whoop-calibration.json` (het rapport met de fitfout gaat naar stderr).
3. Na een paar eigen nachten: `node scores/analyze.mjs whoop_historie_….csv whoop-calibration.json` per nacht. Verzamel de `eigen-nachten.csv`-regels en kalibreer opnieuw met `node scores/calibrate.mjs <export-map> eigen-nachten.csv`. Dat voegt per meetwaarde een lineaire correctie toe naar de Whoop-waarde.
4. Eén nacht naast Whoop zetten: `node scores/compare.mjs whoop_historie_….csv <export-map> whoop-calibration.json`. Dat geeft een tabel met slaaptijden, fases, HRV, rust-HR, ademfrequentie, prestatie en Recovery, eigen tegenover Whoop. De export moet van ná die nacht zijn.
5. In de app: `try Calibration.load(from: url)`; in JS: `JSON.parse(...)` als laatste argument.

## Tests
- JS: `cd scores && node --test test/*.test.mjs`
- Swift: `cd ios/WhoopScores && swift test`
- CI: `.github/workflows/scores.yml`.

De fit-test maakt een nep-export met bekende parameters en controleert dat de kalibratie ze terugvindt.

## API voor de schermen (Swift `WhoopScores`; JS-namen gelijk in `scores/whoop-scores.js`)
| Functie | Levert |
|---|---|
| `analyzeNight(samples, cal, baseline:, tzOffsetMin:)` | slaaptijden, fases per minuut, wake-events, HRV, rust-HR, ademfrequentie, huidtemp, **slaapstress per minuut** (`stress`, `stressMin`, `highStressPct`) |
| `sleepNeedParts(debtMin:prevDayStrain:napMin:)` | opbouw behoefte: gezond minimum, strain, schuld, dutjes, totaal |
| `sleepDebt(prevDebtMin:prevNeedMin:prevAsleepMin:)` | slaapschuld voor de komende nacht |
| `sleepSufficiency`, `sleepConsistency`, `sleepPerformance` | de bijdragen en de slaapprestatie |
| `recovery(_:history:)` | Recovery 1–99 % |
| `strain(samples)` | strain, belasting, minuten per zone 0–5 |
| `calories(samples)` | kcal (rustmetabolisme + Keytel); profiel in `Calibration.profile` |
| `History.importWhoop(cycles:sleeps:)` | `[DayRecord]` uit de Whoop-export als startgeschiedenis |
| `History.trailingMean`, `History.typicalRange`, `History.nextDebt` | "vs. laatste 30 dagen", normaalbereik (p25–p75), schuld |
| `Calibration.load(from:)` | kalibratie-JSON; ontbrekende velden krijgen standaardwaarden |

Stappen worden nog niet berekend: daarvoor is de IMU-data nodig.

## Slaapplanner en wekker (`SleepPlanner.swift`, app: `SleepAlarm.swift`, `SleepPlannerView.swift`)
- **Slaapbehoefte vannacht** = basis (`needBaseMin`) + belasting van vandaag (`needPerStrainMin` per punt boven `strainRef`) + slaapschuld (uit de afgelopen nacht: `sleepDebt`) − dutjes van vandaag. Zelfde formules als de slaapbehoefte achteraf, dus planner en slaapscore lopen gelijk.
- **Bedtijd** = wektijd − (doel × behoefte / efficiëntie + inslaaptijd), afgerond op 5 min. Doelen: 100 / 85 / 70 %. Efficiëntie = gemiddelde van de laatste 7 nachten (anders 90 %), inslaaptijd 15 min.
- **Ritme** = mediaan van inslapen en opstaan over de laatste 14 nachten (vanaf 3 nachten), anders de ingestelde tijden (standaard 23:30–07:30).
- **Wekkermodi:** vaste tijd; slaapdoel (eerder zodra de geslapen tijd het doel haalt); groen herstel (eerder zodra de geschatte herstelscore ≥ 67 %). Slimme modi gaan hooguit 90 min eerder af en rekenen elke 5 min op de binnenkomende hartslag; de ingestelde tijd is altijd de laatste tijd.
- **Wekken:** alleen op de band. Vaste tijd via cmd 66 (de band trilt zelf); slimme modi via cmd 68 (nu trillen), met cmd 66 op de laatste tijd als vangnet. Zie WHOOP5-PROTOCOL.md.
- **Slaapeinde:** een uitslaapblok na 08:00 hoort alleen bij de nacht als de HR daarin hooguit `extendMaxHrRise` (4) bpm boven die van de hoofdslaap ligt en de telefoon in de tussentijd niet aan was.
