# HR Monitor: stand van zaken en verder op Bazzite
_Laatst bijgewerkt: 21-11-2026_

## Doel
Een gratis eigen iPhone-app die de hartslag van een (oude) **Whoop-band** via BLE uitleest en **ook met het scherm uit** blijft opnemen. Geen betaald Apple-account, geen App Store.

## Wat er al is
- **Repo:** https://github.com/samvdtillaart14/hr-monitor (public)
- **Webapp** (pc, Chrome/Edge, of iPhone via Bluefy): https://samvdtillaart14.github.io/hr-monitor/
  - Dashboard met hartslag, min/gem/max, RR, HRV (RMSSD 60 s), batterij en een grafiek van 5 min
  - Opname naar CSV, tabblad met ruwe BLE-data, installeerbaar als PWA
- **iPhone-app** (SwiftUI + CoreBluetooth, map `ios/`)
  - Opname loopt door op de achtergrond, CSV in de Bestanden-app, automatisch herverbinden
  - GitHub Actions bouwt de app automatisch → https://github.com/samvdtillaart14/hr-monitor/releases/download/latest/HRMonitor.ipa
- **Whoop:** zet *Heart Rate Broadcast* aan in de Whoop-app (standaard Heart Rate Service 0x180D) en sluit daarna de Whoop-app.

## Waar het vastloopt
- **Gedaan op Windows:** iTunes + iCloud (niet de Store-versie), AltServer, AltStore op de iPhone, Apple ID vertrouwd
- **iPhone draait iOS 27.0.1.** De app opent niet: *"Ontwikkelaarsmodus vereist"*.
- **Het probleem:** bij *Instellingen → Privacy en beveiliging* staat **geen schakelaar voor Ontwikkelaarsmodus**. Op iOS 27 verschijnt die pas als de iPhone aan een ontwikkelcomputer gekoppeld is. Apple doet dat officieel alleen via Xcode op een Mac.
- **xtool en AltStore lossen dit niet op.** Beide ondertekenen en installeren alleen apps.

## Volgende stap op Bazzite: de schakelaar zichtbaar maken
Met `idevicedevmodectl reveal` uit libimobiledevice (open source). **Niet getest op iOS 27.**

```bash
# 1. Container met recente libimobiledevice (Fedora heeft idevicedevmodectl)
distrobox create -n ios -i registry.fedoraproject.org/fedora:latest
distrobox enter ios
sudo dnf install -y libimobiledevice-utils usbmuxd

# 2. iPhone met kabel aansluiten, ontgrendelen, "Vertrouw" tikken
idevice_id -l            # moet een UDID tonen
# Niets te zien? Start usbmuxd in de container:
#   sudo usbmuxd -f -v &      (in een tweede terminal: distrobox enter ios)

idevicepair pair         # tik op de iPhone op "Vertrouw" en voer je code in
idevicedevmodectl list   # toont of devmode aan/uit staat
idevicedevmodectl reveal # maakt de schakelaar zichtbaar in Instellingen
```
3. Op de iPhone: *Instellingen → Privacy en beveiliging → Ontwikkelaarsmodus* → aan → **Herstart** → na het opstarten **Zet aan** + code.
4. Daarna kan dit op Windows of Bazzite: HR Monitor openen.
   - Staat HR Monitor nog niet op de iPhone: AltStore → *My Apps* → **+** → `HRMonitor.ipa`.
   - Op Bazzite kan het ook zonder AltStore: in de container `ideviceinstaller` werkt alleen met een ondertekende ipa. Gebruik daarom op Linux **xtool** of **AltServer-Linux** om te ondertekenen en te installeren.

Lukt `reveal` niet? Probeer `idevicedevmodectl enable`. Dat zet de modus direct aan en de iPhone herstart.

## Terugvalopties
1. **Sideloadly** (Windows, sideloadly.io): sleep de ipa erin, kies de iPhone met kabel en je Apple ID, klik Start.
2. **Bluefy** (gratis, App Store) + de webapp. Werkt zeker, maar het scherm moet aan blijven (*Automatisch slot → Nooit* tijdens de opname).

## Onderhoud na installatie
Met een gratis Apple ID verloopt de app na 7 dagen. AltStore vernieuwt hem automatisch als AltServer op de pc draait en de iPhone op hetzelfde wifi zit. Je kunt ook op *Refresh All* tikken.

## Later
- Meer Whoop-data (HRV-ruwdata, accelerometer, enz.) loopt via de eigen Whoop-service `61080001-…` (UUID niet geverifieerd). Neem eerst met het tabblad *Ruwe data* een log op (JSON-export) en laat Claude die decoderen.
- Het model (3.0, 4.0 of MG) is nog onbekend. Dat is nodig voor het eigen Whoop-protocol.

## Een nieuwe Claude-sessie starten
Plak dit bestand in een nieuwe chat met:
> "Lees dit en help me verder bij 'Volgende stap op Bazzite'."
