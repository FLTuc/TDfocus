#Requires -Version 7.0
<#
.SYNOPSIS
    TDfocus pour Linux : une seule tâche à la fois, l'heure de fin toujours sous les yeux.

.DESCRIPTION
    Version terminal de TDfocus (PowerShell 7), avec les mêmes données, réglages et
    fonctionnalités que la version Windows : minuteur, heure de fin prévue, sous-étapes,
    signal d'atterrissage, compteur de pause, points de contrôle au carillon, revue du matin,
    ambiances sonores, routines, notes et statistiques. Aucun droit root nécessaire.

.PARAMETER Startup
    Lancement automatique à l'ouverture de session (fichier ~/.config/autostart/tdfocus.desktop).

.PARAMETER InTerminal
    Ne pas chercher d'émulateur de terminal (utilisé lors de la relance dans un terminal).

.PARAMETER SmokeTest
    Test automatisé : affiche chaque écran une fois en texte brut puis quitte.
#>
[CmdletBinding()]
param(
    [switch]$Startup,
    [switch]$InTerminal,
    [switch]$SmokeTest,
    [int]$Width = 100,
    [int]$Height = 34
)

$script:TdVersion = '1.0.0'
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'TDfocus.Core.ps1')
foreach ($part in @('Audio/Synth', 'Platform/Linux', 'Terminal/Text', 'Terminal/Audio', 'Terminal/View', 'Terminal/App')) {
    . (Join-Path $PSScriptRoot "$part.ps1")
}

if ($SmokeTest) {
    # Rendu de tous les écrans sans terminal (intégration continue).
    $script:TdTuiNoColor = $true
    Initialize-TdTui -ScriptPath $PSCommandPath
    $now = Get-TdNowMs
    foreach ($mode in @('main', 'help', 'routines', 'stats', 'notes', 'settings', 'review')) {
        $script:Tui.Mode = $mode
        "===== $mode"
        Get-TdTuiFrame -NowMs $now -Width $Width -Height $Height
    }
    exit 0
}

# Lancé hors d'un terminal (ouverture de session, menu des applications) : on s'ouvre dans un.
if (-not $InTerminal -and ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) {
    $command = @((Get-Process -Id $PID).Path, '-NoLogo', '-NoProfile', '-File', $PSCommandPath, '-InTerminal')
    if ($Startup) { $command += '-Startup' }
    if (Start-TdInTerminal -Command $command) { exit 0 }
    Write-TdLog 'Impossible d''ouvrir un terminal (pas de session graphique, ou aucun émulateur de terminal utilisable) : définis la variable TERMINAL ou lance « tdfocus » dans un terminal.'
    Send-TdDesktopNotification -Message 'TDfocus a besoin d''un terminal : lance « tdfocus » dans ton terminal.'
    exit 1
}

# Une seule instance à la fois.
$mutex = [System.Threading.Mutex]::new($false, ('TDfocus-terminal-' + [Environment]::UserName))
$owned = $false
try { $owned = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $owned = $true }   # instance précédente arrêtée net
if (-not $owned) {
    $mutex.Dispose()
    Write-Host 'TDfocus est déjà ouvert dans un autre terminal.' -ForegroundColor Yellow
    if (-not $Startup) { Start-Sleep -Seconds 2 }
    exit 0
}

try {
    $data = Import-TdData
    if ($IsLinux) { [void](Set-TdLinuxAutostart -Enabled ([bool]$data.settings.autostart) -ScriptPath $PSCommandPath) }
    [void](Initialize-TdTuiAudio -SynthPath (Join-Path $PSScriptRoot 'Audio/Synth.ps1'))
    Set-TdTuiAmbient -Name $data.settings.ambient -Volume $data.settings.ambientVolume
    Initialize-TdTui -ScriptPath $PSCommandPath -Data $data
    [Console]::Out.Write("$([char]27)]0;TDfocus$([char]7)")
    Start-TdTuiLoop
}
catch {
    Write-TdLog "Erreur fatale (terminal) : $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    [Console]::Out.Write("$([char]27)[0m$([char]27)[?25h$([char]27)[?1049l")
    Write-Host "TDfocus s'est arrêté : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Détails dans $(Get-TdDataPath 'tdfocus.log')"
    exit 1
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
