$ErrorActionPreference = 'Stop'
$projectFolder = Split-Path -Parent $PSScriptRoot
$desktopFolder = [Environment]::GetFolderPath('DesktopDirectory')
$executable = Join-Path $projectFolder 'Elite Studio.exe'
$shortcutShell = New-Object -ComObject WScript.Shell
$shortcut = $shortcutShell.CreateShortcut((Join-Path $desktopFolder 'Elite Studio - Windows.lnk'))
$shortcut.TargetPath = $executable
$shortcut.WorkingDirectory = $projectFolder
$shortcut.Description = 'Elite Studio - editor video'
$shortcut.IconLocation = Join-Path $projectFolder 'Resources\EliteStudio.ico'
$shortcut.Save()
$extensionKey = 'HKCU:\Software\Classes\.elitestudio'
$currentAssociation = if (Test-Path -LiteralPath $extensionKey) { (Get-Item -LiteralPath $extensionKey).GetValue('') } else { $null }
if (-not $currentAssociation -or $currentAssociation -eq 'EliteStudio.Project') {
    New-Item -Path $extensionKey -Force | Out-Null
    Set-Item -LiteralPath $extensionKey -Value 'EliteStudio.Project'
    $commandKey = 'HKCU:\Software\Classes\EliteStudio.Project\shell\open\command'
    New-Item -Path $commandKey -Force | Out-Null
    Set-Item -LiteralPath $commandKey -Value ('"{0}" "%1"' -f $executable)
    $iconKey = 'HKCU:\Software\Classes\EliteStudio.Project\DefaultIcon'
    New-Item -Path $iconKey -Force | Out-Null
    Set-Item -LiteralPath $iconKey -Value ('"{0}",0' -f $executable)
}
Write-Host 'Collegamento Desktop aggiornato. Puoi aprire Elite Studio.exe.'
