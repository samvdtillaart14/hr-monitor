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
- **0x22, 0x75, 0x76, 0x78, 0x8D:** worden door de Whoop-app gebruikt. 0x76 en 0x78 leveren feature-flags (tekst).

## Datapakketten
- **0x28 live HR/RR:** u32LE Unix-tijd @10, HR u8 @16, aantal RR @17, RR u16LE @18 in 1/1024 s.
- **0x2F historisch, layout @9:**
  - `0x12` (R18, 124 B, 1 per seconde): tijd u32LE @15, HR u8 @22, huidtemperatuur u16LE @73 / 100 °C. Gemeten waarden waren 31,4–31,95 °C.
  - `0x1A` (R26, 88 B): ruwe optische data, nog niet gedecodeerd.
- **0x31:** live status met tijd u32LE @11.
- **0x32:** firmware-tekstlog, tekst vanaf byte 21.

## Belangrijk
De Whoop-app op dezelfde iPhone deelt de BLE-verbinding. Zijn sync (hello → config → 0x22 → 0x16 → 0x17-acks) is daardoor passief mee te lezen.
