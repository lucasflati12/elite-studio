@echo off
setlocal
echo Installazione di Elite Studio per Windows...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Windows\setup.ps1"
if errorlevel 1 (
  echo Installazione non riuscita. Leggi il messaggio sopra.
  pause
  exit /b 1
)
start "Elite Studio" "%~dp0Elite Studio.exe"
