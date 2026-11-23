#!/bin/sh
# Kopieert de testbare app-bestanden (alleen Foundation, geen UI/Bluetooth) naar het testpakket.
# Draai dit vóór `swift test`; CI doet het automatisch. Nieuwe logica? Zet het bestand in deze lijst.
set -e
cd "$(dirname "$0")"
rm -rf Sources/AppCore/App
mkdir -p Sources/AppCore/App
for f in WhoopParser BandLog HistorySync DayStore ScoreModel UserProfile Recorder RawLogger SafeFile FileSplitter ZipExport Backup MorningSummary; do
  cp "../HRMonitor/$f.swift" Sources/AppCore/App/
done
