@echo off
setlocal
set "ELITE_PY=%LOCALAPPDATA%\EliteStudioWindows\venv\Scripts\python.exe"
if not exist "%ELITE_PY%" (
  echo Runtime assente. Esegui Ripara Elite Studio.bat.
  pause
  exit /b 1
)
"%ELITE_PY%" "%~dp0Windows\diagnostics.py"
pause
