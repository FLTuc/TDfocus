<#
.SYNOPSIS
    Installe TDfocus pour l'utilisateur courant, SANS droits administrateur.

.DESCRIPTION
    - copie l'application dans %LOCALAPPDATA%\Programs\TDfocus ;
    - crée un raccourci dans le menu Démarrer (et, sauf -NoDesktopShortcut, sur le Bureau) ;
    - inscrit le lancement automatique à l'ouverture de session (HKCU\...\Run) ;
    - lance TDfocus.
    Rien n'est écrit hors du profil de l'utilisateur. Pour désinstaller : Uninstall.cmd.
#>
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\TDfocus'),
    [switch]$NoDesktopShortcut,
    [switch]$NoAutostart,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
. (Join-Path $source 'src\Storage.ps1')
. (Join-Path $source 'src\Platform\Windows.ps1')

Write-Host ''
Write-Host '  TDfocus - installation (sans droits administrateur)' -ForegroundColor Magenta
Write-Host ''

# Une version déjà ouverte est fermée proprement avant la copie.
$running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'TDfocus\.ps1' -and $_.ProcessId -ne $PID }
foreach ($p in $running) {
    Write-Host "  Fermeture de TDfocus en cours d'exécution (PID $($p.ProcessId))…"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}

Write-Host "  Copie vers $Destination"
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
foreach ($item in @('src', 'assets')) {
    $target = Join-Path $Destination $item
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $source $item) -Destination $target -Recurse -Force
}
foreach ($file in @('Uninstall-TDfocus.ps1', 'Uninstall.cmd', 'README.md')) {
    $path = Join-Path $source $file
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $Destination -Force }
}
# Les fichiers téléchargés portent la « marque du Web » : on la retire de nos propres fichiers.
Get-ChildItem -LiteralPath $Destination -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

$appScript = Join-Path $Destination 'src\TDfocus.ps1'
$icon = Join-Path $Destination 'assets\TDfocus.ico'

function New-TdShortcut {
    param([string]$Path)
    try {
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($Path)
        $link.TargetPath = Get-TdPowerShellExe
        $link.Arguments = Get-TdLaunchArguments -ScriptPath $appScript
        $link.WorkingDirectory = $Destination
        $link.IconLocation = "$icon,0"
        $link.WindowStyle = 7
        $link.Description = 'TDfocus : une tâche à la fois, l''heure de fin sous les yeux'
        $link.Save()
        Write-Host "  Raccourci : $Path"
    }
    catch {
        Write-Warning "Raccourci non créé ($Path) : $($_.Exception.Message)"
    }
}

$programs = [Environment]::GetFolderPath('Programs')
New-TdShortcut -Path (Join-Path $programs 'TDfocus.lnk')
if (-not $NoDesktopShortcut) {
    New-TdShortcut -Path (Join-Path ([Environment]::GetFolderPath('Desktop')) 'TDfocus.lnk')
}

# Préférence enregistrée dans les réglages (l'application la respecte à chaque lancement).
$settingsPath = Get-TdDataPath 'settings.json'
$settings = $null
if (Test-Path -LiteralPath $settingsPath) { $settings = Read-TdJsonFile $settingsPath }
if ($null -eq $settings) { $settings = [pscustomobject]@{} }
$settings | Add-Member -NotePropertyName autostart -NotePropertyValue (-not $NoAutostart) -Force
Write-TdJsonFile $settingsPath $settings

if (Set-TdAutostart -Enabled (-not $NoAutostart) -ScriptPath $appScript) {
    if ($NoAutostart) { Write-Host '  Lancement automatique : désactivé' }
    else { Write-Host '  Lancement automatique à l''ouverture de session : activé (HKCU\...\Run)' }
}
else {
    Write-Warning 'Le lancement automatique n''a pas pu être configuré (voir tdfocus.log).'
}

Write-Host ''
Write-Host '  TDfocus est installé.' -ForegroundColor Green
Write-Host "  Données personnelles : $(Get-TdDataDirectory)"
Write-Host ''

if (-not $NoLaunch) {
    Start-Process -FilePath (Get-TdPowerShellExe) -ArgumentList (Get-TdLaunchArguments -ScriptPath $appScript) -WindowStyle Hidden
}
