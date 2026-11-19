@echo off
setlocal
set "ELITE_PY=%LOCALAPPDATA%\EliteStudioWindows\venv\Scripts\python.exe"
if not exist "%ELITE_PY%" (
  echo Elite Studio needs its Windows dependencies. Running setup...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Windows\setup.ps1"
  if errorlevel 1 (
    pause
    exit /b 1
  )
)
"%ELITE_PY%" "%~dp0Windows\launcher.py" %*
if errorlevel 1 pause
