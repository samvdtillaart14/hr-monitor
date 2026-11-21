# Whoop-scores nabootsen

Code: `scores/whoop-scores.js` (browser/Node) en `ios/WhoopScores` (Swift-package, gekoppeld aan de app). Beide doen exact hetzelfde. De Swift-tests vergelijken met uitkomsten van de JS-versie (`scores/test/fixtures/night.json`).

## Werkwijze per score
Gebaseerd op Whoop's eigen uitleg; de vorm van de formules is een eigen keuze, de parameters worden gefit op jouw Whoop-export.

| Score | Methode | Parameters uit export |
|---|---|---|
| **Slaapdetectie** | Epochs van 60 s. Slaap = weinig beweging (hoekverandering van de oriëntatie-quaternion, 7-min-gemiddelde onder een automatische drempel) én HR < rust-HR + 20. Gaten ≤ 15 min worden samengevoegd. Langste periode = hoofdslaap, de rest dutjes. | – |
| **Slaapfases** | Wakker: beweging of buiten de slaapkandidaten. Diep: lage, stabiele HR, hoge RMSSD, vroeg in de nacht. REM: wisselende HR, lagere RMSSD, later in de nacht, niet in de eerste 45 min. Diep en REM worden op rangorde toegekend, zodat de verdeling jouw gemiddelde Whoop-verdeling volgt. | `deepFrac`, `remFrac` |
| **HRV** | RMSSD over 5-min-vensters met schone RR (300–2000 ms, ≤ 20 % van de lokale mediaan). Gemiddelde over het laatste diepe-slaapblok, zoals Whoop. | correctie a + b·x |
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
| Recovery | 8,3 %-punt (holdout laatste 20 %: 7,2) |

Recovery: het belangrijkste inzicht is de interactie HRV × slaapprestatie. Een hoge HRV telt bij Whoop pas echt mee na een goede nacht. Daarmee zakt de fout van 10,2 naar 8,3 punten (holdout van 9,5 naar 7,2). Daarnaast weegt de toereikendheid (geslapen/behoefte) zwaar. Rust-HR en ademfrequentie dragen in Sams data nauwelijks bij. Andere basislijnen (7–120 dagen, exponentieel, rangorde) en extra invoer (strain, slaapschuld, fases) hielpen niet.

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
