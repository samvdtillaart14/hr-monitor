@echo off
REM Start een lokale webserver zodat Web Bluetooth werkt (file:// werkt niet)
cd /d "%~dp0"
start "" http://localhost:8000/index.html
python -m http.server 8000 2>nul || py -m http.server 8000
