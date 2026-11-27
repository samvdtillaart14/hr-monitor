# Whoop 5.0: overzicht van commando's, events en datatypes

Stand 27-11-2026. Band WG50 (Whoop 5.0, geen MG). Details over het frame, de sync en de pakketindeling staan in [WHOOP5-PROTOCOL.md](WHOOP5-PROTOCOL.md).

**Bronnen**
- **Eigen:** eigen analyse op Sams band. Bronnen zijn BLE-opnames, het firmwarelog (0x32), een sysdiagnose-Bluetooth-log van de Whoop-app en antwoorden van de band.
- **noop:** ryanbr/noop (Whoop 5-docs).
- **W4:** openbare Whoop 4.0-reverse-engineering (commando-enum van de 4.0, onder andere jogolden/whoomp). Op de 5.0 zijn de nummers grotendeels gelijk, maar de bodies verschillen soms.
- Rudra5417/whoop5-protocol is niet nagekeken.

**Status**
- **Pulse:** de app gebruikt dit commando.
- **Dev:** alleen als knop in de Verkenner (Dev options).
- **Gezien:** de Whoop-app gebruikt het. We zien alleen het antwoord van de band, niet de body van de write.
- **Bekend:** bekend uit een bron, niet gebruikt en niet getest.
- **⚠ Gevaarlijk:** wist data, reset of herstart de band, of verandert firmware of kalibratie. **Nooit versturen.**

Resultaatcodes in het antwoord (type 0x24, byte @12): 0 = mislukt, 1 = ok, 2 = bezig, 3 = niet ondersteund.

## Commando's (app → band, characteristic FD4B0002)

| Nr (dec / hex) | Naam (W4) | Functie | Body op de 5.0 | Bron | Status |
|---|---|---|---|---|---|
| 1 / 0x01 | LINK_VALID | Verbinding controleren | ? | W4 | Bekend |
| 2 / 0x02 | GET_MAX_PROTOCOL_VERSION | Protocolversie opvragen | ? | W4 | Bekend |
| 3 / 0x03 | TOGGLE_REALTIME_HR | Live HR/RR aan of uit (type 0x28, 1 Hz) | `01` aan, `00` uit | Eigen, noop | **Pulse** (+ Dev). De Whoop-app zet het soms uit |
| 7 / 0x07 | REPORT_VERSION_INFO | Firmwareversies | ? | W4 | Bekend |
| 10 / 0x0A | SET_CLOCK | Klok van de band zetten | u32 Unix-tijd + … | W4 | Bekend. De Whoop-app doet dit al |
| 11 / 0x0B | GET_CLOCK | Klok uitlezen | ? | W4 | Bekend |
| 14 / 0x0E | TOGGLE_GENERIC_HR_PROFILE | Standaard-HR-broadcast (2A37) aan of uit | `01`/`00` | W4 | Bekend. Niet nodig: 2A37 staat aan |
| 16 / 0x10 | TOGGLE_R7_DATA_COLLECTION | Dataverzameling R7 | ? | W4 | Bekend |
| **19 / 0x13** | RUN_HAPTIC_PATTERN_MAVERICK | **Trillen** | `01 2F 98 00 00 00 00 00 00 00 00 00`: revisie 01, 8 DRV2625-effecten (47 = tril, 0x98 = 240 ms pauze), u16 loop, herhaalbyte | Eigen (getest 27-11), noop | **Pulse** (bevestigingstrilling, tikfeedback, batterij 5%) |
| 20 / 0x14 | ABORT_HISTORICAL_TRANSMITS | Lopende historie-overdracht afbreken | ? | Eigen, W4 | Gezien (elk uur) |
| 22 / 0x16 | SEND_HISTORICAL_DATA | Historie-burst starten | `00` | Eigen, noop | **Pulse** |
| 23 / 0x17 | HISTORICAL_DATA_RESULT | Burst bevestigen (ack met trim). Schuift de wis-pointer op, waarna die data niet meer naar de Whoop-cloud gaat | `01` + 8 bytes trim uit END | Eigen, noop | ⚠ Alleen **Pulse** met "Whoop-app vervangen" aan. Verder geblokkeerd |
| 26 / 0x1A | GET_BATTERY_LEVEL | Batterij opvragen | ? | W4 | Bekend. Pulse leest de batterij via de standaard-characteristic 2A19 |
| 29 / 0x1D | REBOOT_STRAP | Band herstarten | | W4 | ⚠ Gevaarlijk |
| 32 / 0x20 | POWER_CYCLE_STRAP | Band uit en aan | | W4 | ⚠ Gevaarlijk |
| 33 / 0x21 | SET_READ_POINTER | Leespointer van de historie zetten | | W4 | ⚠ Gevaarlijk (kan data overslaan) |
| 34 / 0x22 | GET_DATA_RANGE | Pointers van de historie opvragen | ? (antwoord: pointers, zie protocol) | Eigen, W4 | Gezien |
| 35 / 0x23 | GET_HELLO_HARVARD | Hello (oude vorm) | ? | W4 | Bekend. Op de 5.0 is 0x91 de hello |
| 36–38 / 0x24–0x26 | START/LOAD/PROCESS_FIRMWARE | Firmware laden | | W4 | ⚠ Gevaarlijk |
| 39–44 / 0x27–0x2C | SET/GET LED_DRIVE, TIA_GAIN, BIAS_OFFSET | Optische sensor afstellen | | W4 | ⚠ Gevaarlijk (SET), GET Bekend |
| 45 / 0x2D | ENTER_BLE_DFU | Firmware-updatemodus | | W4 | ⚠ Gevaarlijk |
| 52–53 / 0x34–0x35 | SET/FORCE_DP_TYPE | Soort dataverwerking | | W4 | ⚠ Gevaarlijk |
| 63 / 0x3F | SEND_R10_R11_REALTIME | Realtime-R10/R11-data | ? | W4 | Bekend |
| **66 / 0x42** | SET_ALARM_TIME | **Wekker zetten** | `04 <id 1–8>` + u32 Unix + `00 00 2F 98 00×8 07 1E 00` (patroon, 7 herhalingen, 30 s) | Eigen (BT-log Whoop-app) | **Pulse** (wekkers 1–7, uitzetten = 1-1-2100) |
| 67 / 0x43 | GET_ALARM_TIME | Wekker uitlezen | `01` geeft resultaat 0 op de 5.0 | Eigen, W4 | Bekend (werkt niet in de 4.0-vorm) |
| 68 / 0x44 | RUN_ALARM | Wekker nu laten afgaan | `01` geeft resultaat 0 op de 5.0 | Eigen, W4 | Bekend (werkt niet in de 4.0-vorm) |
| 69 / 0x45 | DISABLE_ALARM | Wekker uit | `01` geeft resultaat 0 op de 5.0 | Eigen, W4 | Gezien (bij verbinden) |
| 76–77 / 0x4C–0x4D | GET/SET_ADVERTISING_NAME | Bluetooth-naam | | W4 | Bekend (SET niet doen) |
| 79 / 0x4F | RUN_HAPTICS_PATTERN | Trilpatroon (Whoop 4-vorm) | `02 03 00 00 00` werkt **niet** op de 5.0 | Eigen, W4 | Werkt niet |
| 80 / 0x50 | GET_ALL_HAPTICS_PATTERN | Trilpatronen opvragen | ? | W4 | Bekend |
| 81 / 0x51 | START_RAW_DATA | Ruwe sensordata aan | `01` | Eigen, W4 | Dev |
| 82 / 0x52 | STOP_RAW_DATA | Ruwe sensordata uit | `01` | Eigen, W4 | Dev |
| 83 / 0x53 | VERIFY_FIRMWARE_IMAGE | Firmware controleren | | W4 | ⚠ Gevaarlijk (firmware) |
| 84 / 0x54 | GET_BODY_LOCATION_AND_STATUS | Band om of af, pols | ? | W4 | Bekend (handig voor "band zit niet goed") |
| 96–97 / 0x60–0x61 | ENTER/EXIT_HIGH_FREQ_SYNC | Snelle sync-modus | ? | W4 | Bekend |
| 98 / 0x62 | GET_EXTENDED_BATTERY_INFO | Batterij-details (spanning, temperatuur) | ? | W4 | Bekend |
| 99 / 0x63 | RESET_FUEL_GAUGE | Batterijmeter resetten | | W4 | ⚠ Gevaarlijk |
| 100 / 0x64 | CALIBRATE_CAPSENSE | Huiddetectie kalibreren | | W4 | ⚠ Gevaarlijk |
| 105 / 0x69 | TOGGLE_IMU_MODE_HISTORICAL | IMU in de historie | ? | W4 | Bekend |
| 106 / 0x6A | TOGGLE_IMU_MODE | Live bewegingsdata (type 0x2B) | `01 01` | Eigen, W4 | Dev |
| 107–108 / 0x6B–0x6C | ENABLE_OPTICAL_DATA / TOGGLE_OPTICAL_MODE | Optische ruwe data | ? | W4 | Bekend |
| 115 / 0x73 | START_DEVICE_CONFIG_KEY_EXCHANGE | Configuratie uitwisselen | ? | Eigen, W4 | Gezien (elk uur) |
| 116 / 0x74 | SEND_NEXT_DEVICE_CONFIG | Volgende config-waarde | ? | Eigen, W4 | Gezien |
| 117 / 0x75 | START_FF_KEY_EXCHANGE | Feature-flags uitwisselen | ? | Eigen, W4 | Gezien |
| 118 / 0x76 | SEND_NEXT_FF | Volgende feature-flag (tekst) | ? | Eigen, W4 | Gezien |
| 119–120 / 0x77–0x78 | SET_DEVICE_CONFIG_VALUE / SET_FF_VALUE | Config of flag zetten | ? | Eigen, W4 | Gezien. ⚠ Zelf niet zetten (een flagwijziging herstartte de signaalverwerking) |
| 121 / 0x79 | GET_DEVICE_CONFIG_VALUE | Config-waarde lezen | ? | W4 | Bekend |
| 122 / 0x7A | STOP_HAPTICS | Trillen stoppen | ? | W4 | Bekend |
| 123 / 0x7B | SELECT_WRIST | Pols links of rechts | ? | W4 | Bekend |
| 141 / 0x8D | ? | Onderdeel van de verbindingsreeks van de Whoop-app | ? | Eigen | Gezien |
| 145 / 0x91 | GET_HELLO | Hello. Antwoord met o.a. serienummer en versies | `01` | Eigen, noop | Dev |
| 146 / 0x92 | ? | Bij verbinden | ? | Eigen | Gezien |
| 155–158 / 0x9B–0x9E | ? | Nieuw na opnieuw pairen (resultaat 1) | ? | Eigen | Gezien. Onbekend |

Waar W4 een nummer noemt dat hierboven ontbreekt, is het op de 5.0 niet gezien. Behandel zo'n nummer als onbekend en verstuur het niet.

## Wat de band stuurt

### Pakkettypes (byte @8)

| Type | Characteristic | Inhoud | Pulse |
|---|---|---|---|
| 0x24 | 0003 | Antwoord op een commando: cmd @10, seq @11, resultaat @12, body @13 | Gebruikt |
| 0x28 | 0005 | Live HR/RR (na cmd 3): tijd @10, HR @16, RR in 1/1024 s | Gebruikt |
| 0x2B | 0005 | Live IMU 100 Hz (na cmd 106), zelfde indeling als R21 | Gebruikt (Verkenner, autodetectie) |
| 0x2F | 0005 | Historisch record, soort @9 (zie hieronder) | Gebruikt |
| 0x30 | 0004/0005 | Event: id u16 @10, tijd u32 @12 | Deels |
| 0x31 | 0005 | Burststatus: START (1), END (2, met trim), COMPLETE (3) | Gebruikt (sync) |
| 0x32 | 0005 | Firmware-tekstlog vanaf byte 21 (o.a. "Double tap detected, displaying …") | Gebruikt (dubbeltik, wekker) |
| 2A37 / 2A19 | standaard | Hartslag en batterij % | Gebruikt |

### Historische records (0x2F, soort @9)

| Soort | Grootte / ritme | Inhoud | Pulse |
|---|---|---|---|
| R18 (0x12) | 124 B, 1/s | HR, RR (ms), stappen @61, huidtemp @73, beweging, SpO2? @106 | Gebruikt (scores, slaap, stappen) |
| R20 (0x14) | 2140 B, 1/s | Ruwe optische data (vermoedelijk PPG) | Niet geduid |
| R21 (0x15) | 1244 B, 1/s | Ruwe IMU 100 Hz (acc + gyro) | Gebruikt (beweging) |
| R26 (0x1A) | 88 B, ~1/15 s | Golfvorm. Staat uit via flag `disable_pip_r26_packets` | Niet gebruikt |

### Events (0x30, id @10)

| Id | Naam (W4) | Op de 5.0 |
|---|---|---|
| 3 | BATTERY_LEVEL | Gezien |
| 7 / 8 | CHARGING_ON / OFF | Bekend (W4) |
| 9 / 10 | WRIST_ON / OFF | Bekend (W4) |
| 14 (0x0E) | DOUBLE_TAP | Gezien (Pulse gebruikt het firmwarelog voor tikken) |
| 15 | BOOT | Bekend (W4) |
| 22 | BATTERY_PACK_REMOVED | Gezien in het log |
| 29 | STRAP_CONDITION_REPORT | Gezien |
| 56 (0x38) | STRAP_DRIVEN_ALARM_SET | Gezien: wekker ingesteld |
| 57 (0x39) | STRAP_DRIVEN_ALARM_EXECUTED | Gezien: wekker gaat af |
| 60 (0x3C) | HAPTICS_FIRED | Gezien: trillen start |
| 63 | EXTENDED_BATTERY_INFORMATION | Gezien |
| 100 (0x64) | HAPTICS_TERMINATED | Gezien: trillen gestopt (`01 02 00 00` = door gebruiker) |
| 110, 123 | ? | Gezien, onbekend |

De band stuurt oude events later opnieuw, dus ontdubbelen op tijd.

## Veilig gebruik
- Pulse verstuurt alleen 3, 19, 22, 66 en (met "Whoop-app vervangen") 23. De Verkenner kan daarnaast 81, 82, 106 en 145.
- Verstuur nooit iets uit de categorie ⚠: herstarten, wissen, firmware, kalibratie, pointers of flags zetten.
- Dit overzicht is nergens op de band uitgeprobeerd.
