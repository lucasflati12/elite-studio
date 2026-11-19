@echo off
setlocal
echo Installazione o riparazione di Elite Studio per Windows...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Windows\setup.ps1"
if errorlevel 1 (
  echo Riparazione non riuscita. Controlla il messaggio sopra.
) else (
  echo Ora puoi aprire Start Elite Studio.bat.
)
pause
