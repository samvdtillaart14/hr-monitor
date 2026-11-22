# Handmatige tests op de iPhone

Voor elke release, na groene CI. Duur: ±20 minuten plus één nacht. Zet bij twijfel in Instellingen → Ontwikkelaarsopties een ruwe opname aan; die kan later als fixture dienen (zie TESTPLAN §2).

Noteer per regel ✓ of ✗ met tijd. Een ✗ wordt eerst een automatische test (als dat kan), dan pas een fix.

## A. Installeren en starten
- [ ] **A1.** Update via AltStore of de ⬇︎-knop: versie in Instellingen is het nieuwe buildnummer.
- [ ] **A2.** App start zonder band in de buurt, zonder crash. Tabbladen openen allemaal.
- [ ] **A3.** Bestaande data is er nog: Vandaag toont de nacht van vandaag, Gezondheid toont profiel en leeftijd.

## B. Verbinding
- [ ] **B1.** Verbinden: binnen 10 s "verbonden", hartslag loopt op Live en wijkt < 3 bpm af van de Whoop-app.
- [ ] **B2.** Band 2 min buiten bereik (iPhone in de magnetron of andere kamer), terug: app herverbindt zelf. Daarna is het gat in de grafiek binnen 2 min gevuld met historie.
- [ ] **B3.** App wegvegen, scherm uit, 15 min wachten, app openen: tussenliggende data is er (iOS herstelt de verbinding op de achtergrond).
- [ ] **B4.** iPhone herstarten, app niet openen, 15 min wachten, dan openen: data loopt door vanaf kort na de herstart.
- [ ] **B5.** Bluetooth uit en weer aan: geen crash, herverbindt.

## C. Historie-sync
- [ ] **C1.** Schakelaar "Whoop-app vervangen" **uit**, ruwe opname 10 min aan: in de opname staat geen enkele WRITE met `23 xx 17` (cmd 23) van onze app.
- [ ] **C2.** Schakelaar **aan**, Whoop-app volledig gesloten: "Nu synchroniseren" eindigt met "Klaar: n blokken"; grafiek heeft geen gaten.
- [ ] **C3.** Schakelaar **aan**, Whoop-app open op de achtergrond: Whoop-app synchroniseert nog en toont dezelfde nacht als normaal. (Risico BUG-10.)
- [ ] **C4.** Na een sync loopt de hartslag op Live door en verschijnt HRV binnen 2 min (Whoop-app zet realtime soms uit).

## D. Scores (na een nacht met de band)
- [ ] **D1.** Inslaap- en wektijd binnen 15 min van wat je zelf weet (en van de Whoop-app, behalve als die het begin mist).
- [ ] **D2.** Uitgeslapen na 08:00 met kort wakker moment: de ochtend hoort bij de nacht, niet bij dutjes. (BUG-2)
- [ ] **D3.** Herstel ligt binnen ±15 %-punt van Whoop; nooit 1 % of 99 % bij een normale nacht. (BUG-1)
- [ ] **D4.** HRV en rust-HR binnen ±15 % van Whoop.
- [ ] **D5.** Belasting van gisteren binnen ±2 van Whoop; zones tellen samen op tot de gemeten tijd.
- [ ] **D6.** Levensduur: na één dag data geen extreme waarden; zones 0:00 geeft niet ongemerkt jaren. (BUG-12)
- [ ] **D7.** Stappen gevuld (of duidelijk "niet beschikbaar"), niet leeg.
- [ ] **D8.** Geen "NaN", "inf", "--" waar wel data is.

## E. Opnames en export
- [ ] **E1.** Ruwe opname van een nacht delen: zip-delen < 30 MB, uploaden in Claude lukt, `unzip -t` geeft geen fouten.
- [ ] **E2.** Opname die doorliep tijdens een app-herstart hervat met de teller.

## F. Bijzondere momenten (alleen als ze zich voordoen)
- [ ] **F1.** Reizen naar een andere tijdzone: de nacht na aankomst is één nacht, geen crash. (BUG-3, BUG-11)
- [ ] **F2.** Zomer-/wintertijdwissel (laatste zondag van maart en oktober): nacht van de wissel klopt.
- [ ] **F3.** iPhone-opslag bijna vol: melding, geen crash.
- [ ] **F4.** Band leeg en weer opgeladen: geen dag in 1970 of in de toekomst. (BUG-5)
