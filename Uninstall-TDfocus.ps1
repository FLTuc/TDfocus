<#
.SYNOPSIS
    Désinstalle TDfocus (utilisateur courant, sans droits administrateur).

.DESCRIPTION
    Retire le lancement automatique, les raccourcis et le dossier d'installation.
    Les données (liste, historique, notes) sont conservées, sauf avec -RemoveData.
#>
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\TDfocus'),
    [switch]$RemoveData
)

$ErrorActionPreference = 'Stop'

$running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'TDfocus\.ps1' -and $_.ProcessId -ne $PID }
foreach ($p in $running) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
Remove-ItemProperty -Path $runKey -Name 'TDfocus' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name 'TDfocus' -ErrorAction SilentlyContinue
Write-Host '  Lancement automatique retiré.'

foreach ($folder in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))) {
    $link = Join-Path $folder 'TDfocus.lnk'
    if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force; Write-Host "  Raccourci supprimé : $link" }
}

$sounds = Join-Path $env:LOCALAPPDATA 'TDfocus'
if (Test-Path -LiteralPath $sounds) { Remove-Item -LiteralPath $sounds -Recurse -Force -ErrorAction SilentlyContinue }

$data = $env:TDFOCUS_DATA
if (-not $data) { $data = Join-Path $env:APPDATA 'TDfocus' }
if ($RemoveData) {
    if (Test-Path -LiteralPath $data) { Remove-Item -LiteralPath $data -Recurse -Force; Write-Host "  Données supprimées : $data" }
}
else {
    Write-Host "  Données conservées dans $data (utiliser -RemoveData pour les effacer)."
}

if (Test-Path -LiteralPath $Destination) {
    # Le script peut être lancé depuis le dossier d'installation : suppression différée.
    $quoted = $Destination.Replace("'", "''")
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
        "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$quoted' -Recurse -Force -ErrorAction SilentlyContinue"
    )
    Write-Host "  Dossier d'installation supprimé : $Destination"
}
Write-Host ''
Write-Host '  TDfocus est désinstallé.' -ForegroundColor Green
