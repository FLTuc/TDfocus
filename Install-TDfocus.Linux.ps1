#Requires -Version 7.0
<#
.SYNOPSIS
    Installe TDfocus pour Linux dans le dossier personnel, SANS droits root.

.DESCRIPTION
    Appelé par install-linux.sh (qui fournit PowerShell 7 si besoin) :
    - copie l'application dans ~/.local/share/TDfocus/app ;
    - crée la commande « tdfocus » dans ~/.local/bin ;
    - ajoute TDfocus au menu des applications ;
    - inscrit le lancement automatique à l'ouverture de session (~/.config/autostart) ;
    - lance TDfocus.
    Rien n'est écrit hors du dossier personnel. Pour désinstaller : sh uninstall-linux.sh.
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [string]$PwshPath = (Get-Process -Id $PID).Path,
    [switch]$InvariantGlobalization,
    [switch]$NoAutostart,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
. (Join-Path $source 'src/TDfocus.Core.ps1')
. (Join-Path $source 'src/Platform/Linux.ps1')

$dataHome = Get-TdXdgDataHome
if (-not $Destination) { $Destination = Join-Path $dataHome 'TDfocus/app' }
$Destination = [System.IO.Path]::GetFullPath($Destination)

if ($Destination -ne [System.IO.Path]::GetFullPath($source)) {
    Write-Host "  Copie vers $Destination"
    if (Test-Path -LiteralPath $Destination) {
        $ours = Test-Path -LiteralPath (Join-Path $Destination 'src/TDfocus.Terminal.ps1')
        $empty = -not (Get-ChildItem -LiteralPath $Destination -Force | Select-Object -First 1)
        if (-not $ours -and -not $empty) { throw "Le dossier $Destination existe déjà et ne contient pas TDfocus : choisis-en un autre avec -Destination." }
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in @('src', 'assets')) {
        Copy-Item -LiteralPath (Join-Path $source $item) -Destination (Join-Path $Destination $item) -Recurse -Force
    }
    foreach ($file in @('README.md', 'uninstall-linux.sh')) {
        $path = Join-Path $source $file
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $Destination -Force }
    }
}
$appScript = Join-Path $Destination 'src/TDfocus.Terminal.ps1'
$icon = Join-Path $Destination 'assets/TDfocus.png'

function Set-TdExecutable {
    param([Parameter(Mandatory)][string]$Path)
    try { [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute') }
    catch { & chmod 755 $Path }
}

function ConvertTo-TdShellQuoted {
    param([Parameter(Mandatory)][string]$Value)
    "'" + $Value.Replace("'", "'\''") + "'"
}

# Commande « tdfocus »
$bin = Join-Path (Join-Path $HOME '.local') 'bin'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
$wrapper = Join-Path $bin 'tdfocus'
$lines = @('#!/bin/sh', '# TDfocus - lanceur créé par l''installateur (sans droits root).')
if ($InvariantGlobalization) { $lines += 'export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1' }
$lines += 'exec {0} -NoLogo -NoProfile -File {1} "$@"' -f (ConvertTo-TdShellQuoted $PwshPath), (ConvertTo-TdShellQuoted $appScript)
[System.IO.File]::WriteAllText($wrapper, ($lines -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
Set-TdExecutable $wrapper
Write-Host "  Commande : $wrapper"

# Menu des applications
$apps = Join-Path $dataHome 'applications'
New-Item -ItemType Directory -Path $apps -Force | Out-Null
$menuEntry = Join-Path $apps 'tdfocus.desktop'
[System.IO.File]::WriteAllText($menuEntry, (New-TdDesktopEntry -Command @($wrapper) -Icon $icon), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  Menu des applications : $menuEntry"

# Lancement automatique (réglage conservé dans les données de TDfocus)
$settings = ConvertTo-TdSettings (Read-TdJsonFile (Get-TdDataPath 'settings.json'))
$settings.autostart = -not $NoAutostart
Save-TdSettings $settings
if (Set-TdLinuxAutostart -Enabled ([bool]$settings.autostart) -ScriptPath $appScript) {
    if ($settings.autostart) { Write-Host "  Lancement automatique : $(Get-TdLinuxAutostartPath)" }
}
else { Write-Host '  Lancement automatique non inscrit (voir tdfocus.log).' -ForegroundColor Yellow }

Write-Host ''
Write-Host '  TDfocus est installé.' -ForegroundColor Green
$inPath = @($env:PATH -split ':') -contains $bin
if ($inPath) { Write-Host '  Lance-le avec la commande : tdfocus' }
else {
    Write-Host "  Lance-le avec : $wrapper"
    Write-Host '  (ou ajoute ~/.local/bin à ton PATH pour taper simplement « tdfocus »)'
}
Write-Host '  Pour désinstaller : sh uninstall-linux.sh'
Write-Host ''

if (-not $NoLaunch -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
    & $PwshPath -NoLogo -NoProfile -File $appScript -InTerminal
}
