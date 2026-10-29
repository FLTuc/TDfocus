<#
.SYNOPSIS
    TDfocus : une seule tâche à la fois, l'heure de fin toujours sous les yeux.

.DESCRIPTION
    Minuteur séquentiel pensé pour le TDAH (cécité temporelle, dispersion, surcharge).
    Application de bureau Windows écrite en PowerShell (WPF), 100 % locale, sans droits
    administrateur. Se lance automatiquement à l'ouverture de session (clé HKCU\...\Run).

.PARAMETER Startup
    Lancement automatique à l'ouverture de session Windows.

.PARAMETER HideConsole
    Masque la fenêtre de console de PowerShell (utilisé par les raccourcis et le démarrage).

.PARAMETER SmokeTest
    Test d'interface automatisé (intégration continue) : construit la fenêtre, joue un scénario
    puis enregistre des captures dans le dossier -Screenshot.
#>
[CmdletBinding()]
param(
    [switch]$Startup,
    [switch]$HideConsole,
    [switch]$SmokeTest,
    [string]$Screenshot
)

$script:TdVersion = '1.0.0'

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Write-Error "TDfocus est une application Windows (WPF). Le cœur logique peut toutefois être testé ailleurs : voir tests\."
    exit 1
}

# WPF exige un thread STA : on se relance si besoin (PowerShell 5.1 et 7 sont STA par défaut).
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($name in @('Startup', 'HideConsole', 'SmokeTest')) { if ($PSBoundParameters[$name]) { $relaunch += "-$name" } }
    if ($Screenshot) { $relaunch += @('-Screenshot', ('"{0}"' -f $Screenshot)) }
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $relaunch -WindowStyle Hidden
    return
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing

. (Join-Path $PSScriptRoot 'TDfocus.Core.ps1')
foreach ($part in @('Audio\Synth', 'Audio\Player', 'Platform\Windows', 'Platform\Integrations', 'UI\Theme', 'UI\Helpers', 'UI\App', 'UI\Rows', 'UI\Drawers', 'UI\Tray')) {
    . (Join-Path $PSScriptRoot "$part.ps1")
}

$instance = $null
if (-not $SmokeTest) {
    $instance = Enter-TdSingleInstance
    if (-not $instance) { return }   # déjà ouvert : l'autre instance vient d'être affichée
}
if ($HideConsole) { Hide-TdConsole }

$exitCode = 0
try {
    $app = [System.Windows.Application]::Current
    if (-not $app) { $app = New-Object System.Windows.Application }
    $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    $app.Add_DispatcherUnhandledException({
            param($s, $e)
            Write-TdLog ('Erreur inattendue : ' + $e.Exception.ToString())
            $e.Handled = $true
        })
    # Fermeture de session ou arrêt de Windows : on enregistre et on quitte, sans jamais bloquer.
    $app.Add_SessionEnding({
            if ($script:Td) {
                $script:Td.Quitting = $true
                Stop-TdApp
            }
        })

    Initialize-TdApp -SourceRoot $PSScriptRoot -ScriptPath $PSCommandPath
    $script:Td.Instance = $instance
    $settings = $script:Td.Data.settings

    Initialize-TdAudio -SynthPath (Join-Path $PSScriptRoot 'Audio\Synth.ps1')
    Set-TdAmbient -Name $settings.ambient -Volume $settings.ambientVolume

    # Position mémorisée, si elle est encore visible à l'écran.
    $bounds = $settings.window
    if ($bounds -and -not $SmokeTest) {
        $left = [double](Get-TdValue $bounds 'left'); $top = [double](Get-TdValue $bounds 'top')
        $width = [double](Get-TdValue $bounds 'width'); $height = [double](Get-TdValue $bounds 'height')
        $screen = [System.Windows.SystemParameters]
        if ($width -ge 440 -and $height -ge 560 -and $left -ge $screen::VirtualScreenLeft -and $top -ge $screen::VirtualScreenTop -and
            ($left + 100) -le ($screen::VirtualScreenLeft + $screen::VirtualScreenWidth) -and ($top + 100) -le ($screen::VirtualScreenTop + $screen::VirtualScreenHeight)) {
            $w = $script:Td.Window
            $w.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
            $w.Left = $left; $w.Top = $top; $w.Width = $width; $w.Height = $height
        }
    }

    Initialize-TdTray
    if (-not $SmokeTest) { [void](Set-TdAutostart -Enabled ([bool]$settings.autostart) -ScriptPath $PSCommandPath) }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
            Invoke-TdTick
            if ($global:Error.Count -gt 0) {
                foreach ($err in @($global:Error)) { Write-TdLog ('Erreur : ' + $err.ToString() + ' ' + $err.ScriptStackTrace) }
                $global:Error.Clear()
            }
        })
    $script:Td.Timer = $timer

    if ($SmokeTest) {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\Gui.Smoke.ps1')
        Invoke-TdSmokeTest -OutputDirectory $Screenshot
    }
    else {
        $timer.Start()
        $showWindow = -not ($Startup -and $settings.startMinimized -and $script:Td.Tray)
        if ($showWindow) { $script:Td.Window.Show() }
        $global:Error.Clear()
        $ErrorActionPreference = 'Continue'
        [void]$app.Run()
    }
}
catch {
    $exitCode = 1
    $details = $_.Exception.ToString() + [Environment]::NewLine + $_.ScriptStackTrace
    Write-TdLog ('Échec : ' + $details)
    if ($SmokeTest) {
        Write-Host $details
    }
    else {
        [void][System.Windows.MessageBox]::Show(
            "TDfocus n'a pas pu démarrer :`n$($_.Exception.Message)`n`nDétails dans : $(Get-TdDataPath 'tdfocus.log')",
            'TDfocus', 'OK', 'Warning')
    }
}
finally {
    Exit-TdSingleInstance $instance
}
if ($SmokeTest) { exit $exitCode }
