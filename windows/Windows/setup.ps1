$ErrorActionPreference = 'Stop'
$runtime = Join-Path $env:LOCALAPPDATA 'EliteStudioWindows\venv'
if (-not (Test-Path -LiteralPath (Join-Path $runtime 'Scripts\python.exe'))) {
    python -m venv $runtime
    if ($LASTEXITCODE -ne 0) { throw 'Python 3.10 or later is required.' }
}
& (Join-Path $runtime 'Scripts\python.exe') -m pip install -r (Join-Path $PSScriptRoot 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Could not install the Windows dependencies.' }
& (Join-Path $runtime 'Scripts\python.exe') -c "import sys; sys.path.insert(0,sys.argv[1]); from core import tool; print('FFmpeg:',tool('ffmpeg')); print('FFprobe:',tool('ffprobe'))" $PSScriptRoot
if ($LASTEXITCODE -ne 0) { throw 'FFmpeg non trovato. Installa FFmpeg, aggiungi la cartella bin al PATH e riprova.' }
& (Join-Path $PSScriptRoot 'install-shortcut.ps1')
Write-Host 'Setup complete. Double-click Start Elite Studio.bat.'
