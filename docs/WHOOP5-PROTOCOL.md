# WHOOP 5.0/MG BLE-protocol: wat we zelf hebben geverifieerd
Band: WG50_r45, firmware 50.43.2.0, iOS 27 (21-11-2026). Bron voor de basis: openbaar werk van ryanbr/noop. Alles hieronder is gecontroleerd op eigen opnames.

## Service
`FD4B0001-CCE1-4033-93CE-002D5875F58A`
- `…0002`: commando's (write with response)
- `…0003`: antwoorden (type 0x24)
- `…0004`: events (type 0x30)
- `…0005`: data (types 0x28, 0x2F, 0x31, 0x32)
- `…0007`: notify, tot nu toe stil

## Frame
`AA 01 <len u16LE = totaal−8> <hdr 2B> <CRC16-Modbus(bytes 0..5) LE> <type> <seq> <cmd> <body…> <CRC32 LE>`
- **Header:** `00 01` bij een commando, `01 00` bij een antwoord of data. CRC16-Modbus: poly 0xA001, init 0xFFFF.
- **CRC32:** zlib-variant, over het deel vanaf byte 8 tot en met de padding. Die padding vult aan tot een veelvoud van 4.
- **Voorbeeld hello:** `AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D`.

## Antwoord (type 0x24)
- **Opbouw:** cmd @10, origin-seq @11, resultaat @12, body vanaf @13.
- **Resultaatcodes:** 0 = fout, 1 = ok, 2 = bezig, 3 = niet ondersteund.

## Commando's
- **0x91 hello:** antwoordt met o.a. het serienummer `5A00772111`.
- **0x03 realtime HR (body `01`):** resultaat ok. Daarna stuurt de band elke seconde een type-0x28-pakket.
- **0x16 (22) historie opvragen (body `00`):** resultaat ok, body `0b`.
- **0x17 (23) bevestiging historie:** dit verstuurt de Whoop-app. **Zelf niet versturen**, het wist mogelijk data op de band.
- **Wekker 0x42–0x45 (66–69):** SET / GET / RUN (nu trillen) / DISABLE; GET, RUN en DISABLE met body `01` (nummers uit noop). SET met `01` + u32LE tijd + nullen werd door de 5.0 **geweigerd** (resultaat 0). HR Monitor probeert nu 4 vormen (zie `SleepPlanner.BandAlarm.setBody`) en onthoudt welke werkt; het GET-antwoord en de ruwe bytes zijn met ontwikkelaarsopties zichtbaar in de slaapplanner. **Juiste vorm nog te bevestigen.** Gezien (22-11-2026): de Whoop-app zet de wekker wél met cmd 66 (resultaat 1, antwoord-body `04 01 00`, ook bij het verbinden). Vanuit HR Monitor weigert de 5.0 cmd 66/67/68 met elke geprobeerde body (resultaat 0; GET-body `00 00 00 00 01 00 00`, RUN-body `02 00 00`). Mogelijk vereist de 5.0 een andere vorm of de authenticatie van de Whoop-app.
- **0x22, 0x75, 0x76, 0x78, 0x8D:** worden door de Whoop-app gebruikt. 0x76 en 0x78 leveren feature-flags (tekst).

## Datapakketten
- **0x28 live HR/RR:** u32LE Unix-tijd @10, HR u8 @16, aantal RR @17, RR u16LE @18 in 1/1024 s.
- **0x2F historisch, layout @9:**
  - `0x12` (R18, 124 B, 1 per seconde), geverifieerd op 809 records:
    - Unix-tijd u32LE @15; volgnummer @11.
    - HR u8 @22 (kopie @37).
    - Aantal RR-intervallen u8 @23; RR u16LE **in ms** @24+2i. Voorbeeld: 858 ms bij 70 bpm.
    - 4× float32LE @41/45/49/53: oriëntatie of beweging. In rust is de norm ≈ 1,00, bij beweging wijkt die af. Mogelijk een quaternion.
    - u16LE @69 / 10 en @71 / 10: ±29 en ±31 °C, extra temperaturen (voorlopig).
    - Huidtemperatuur u16LE @73 / 100 °C (31,4–32,0 °C gemeten).
    - Ongeduid: @33–35, @57–61, @105–109 (optisch/kwaliteit?), @113–115.
  - `0x1A` (R26, 88 B, ±1 per 15 s): tijd u32LE @15; u32LE @23 ≈ 157 000 (DC-niveau?); 24× i16LE @27..74 (golfvorm, vermoedelijk PPG of beweging); float32 @75. Voorlopig.
- **0x31:** live status met tijd u32LE @11.
- **0x30 events (op 0004/0005):** event-id u16LE @10, tijd u32LE @12. Gezien: 3, 29, 63, 110, 123.
- **Feature-flags (via 0x74/0x76/0x78):** o.a. `enable_raw_data_w_ecg`, `cont_collection_mode`, `whoop_live_hr_in_adv`, `max_collection_backlog`.
- **0x32:** firmware-tekstlog, tekst vanaf byte 21.

## Belangrijk
De Whoop-app op dezelfde iPhone deelt de BLE-verbinding. Zijn sync (hello → config → 0x22 → 0x16 → 0x17-acks) is daardoor passief mee te lezen.

## Sync van de Whoop-app (passief gezien, 21/22-11-2026)
De commando's van de Whoop-app zelf zijn vanuit onze app niet te zien: iOS toont alleen eigen writes. De band beantwoordt wel elk commando op `…0003` (0x24, cmd @10), en die antwoorden komen ook bij ons binnen. Zo is het ritme af te leiden:
- **Elke 10 min (app op voorgrond/achtergrond actief):** 0x22 (resultaat 2 = bezig, dan 1) → 0x16 → reeks 0x2F-historie → ±40× 0x17-ack.
- **Elk ±uur:** 0x14, 0x73/0x74 of 0x75, dan ±19× 0x76 en 0x78 (feature-flags).
- **Bij (her)verbinden:** 0x91 hello (2×), 0x8D, 0x92, 0x45.
- **0x03 realtime-HR:** de Whoop-app stuurt dit ook (20:17–20:22 en 07:48). Direct daarna stoppen de 0x28-pakketten; 2A37 loopt door. Waarschijnlijk zet de Whoop-app realtime uit (body 00). Onze app moet 0x03 01 dus opnieuw sturen na een Whoop-sync.
- **'s Nachts (01:48–07:47) synchroniseerde de Whoop-app niet** (iOS liet hem slapen). Bij openen om 07:47 volgde een inhaaldownload: ~29 acks/min tot na 08:25. Tijdens zo'n download is de ruwe log ~375 MB/uur, 's nachts zonder sync ~17 MB/uur.
- Om de inhoud van de writes van de Whoop-app te zien is een BLE-sniffer nodig (nRF52840-dongle + nRF Sniffer in Wireshark), of PacketLogger met het Bluetooth-logprofiel op een Mac.

## Historie-sync stap voor stap (gereconstrueerd uit avond 21-11, 1119 bursts)
1. **0x22 data-range** (app → band). Antwoord-body vanaf @13: `01`, dan u32 nieuwste-pointer, u32 oudste-niet-gesynchroniseerd, u32, u32, u32 `08`, … Voorbeeld: `01 40 03 00 00 eb 00 00 00 11 03 00 00 eb 00 00 00 08 …`. De pointers lopen per sync op (0x340 → 0x580 → 0x800 …). Eerst resultaat 2 (bezig), dan 1.
2. **0x16 historie versturen** (body `00`) → resultaat 1, body `0b`.
3. **Band stuurt een burst:** 0x31 **START** (sub @10 = 1, 52 B) → reeks 0x2F-records (per seconde R20 2140 B, R21 1244 B, R18 124 B) → 0x31 **END** (sub @10 = 2, 36 B).
   - END-body vanaf @9: seq, `02`, u32 tijd, 6 B ?, **u32 trim**, **u32 `08`**, 4× 00. Voorbeeld `0b 02 23 e0 01 6b c2 55 34 00 00 00 8b fe 01 00 08 00 00 00 00 00 00`.
   - Het firmwarelog (0x32) bevestigt het: `BLE: History burst success. Trim: 0x00000008:000000bb`.
4. **App stuurt 0x17 (ack met trim)**, waarna de band de volgende burst start. Dat gebeurde in alle 1119 van de 1119 gevallen direct na een END. Zonder ack stopt de band na één burst.
5. Klaar: 0x31 **COMPLETE** (sub 3, 24 B), en in het log `Historical Dump Complete` + `PullStats`.

**Body van 0x17 (nog niet bevestigd):** de inhoud van de write zelf zien we niet. Op basis van Whoop 4 (`01` + batch u32 LE + nullen) is het vermoedelijk `01` + de 8 bytes trim/`08` uit END. Een ack zet de trim-pointer op de band vooruit: data tot die trim komt daarna **niet meer bij de Whoop-app/-cloud**. Daarom niet versturen zolang de Whoop-app in gebruik is.

## Zelf synchroniseren in HR Monitor ("Whoop-app vervangen")
- **Uit (standaard):** alleen 0x16 bij verbinden, nooit een ack. De Whoop-app houdt alle data.
- **Aan:** elke 15 min 0x16. Na elke END wacht de app op een ack van de Whoop-app: 3 s bij de eerste burst, daarna 0,3 s zolang de Whoop-app niet gereageerd heeft. Komt er geen ack, dan stuurt de app zelf 0x17. Body-variant 0: `01` + 8 bytes uit END. Krijgt die "mislukt" terug, dan wordt variant 1 gebruikt: `01` + trim u32 + 4 nullen.
