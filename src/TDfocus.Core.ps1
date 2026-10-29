# TDfocus - chargement du cœur logique (sans interface), partagé par l'application et les tests.

$coreDir = Join-Path $PSScriptRoot 'Core'
foreach ($file in @('Time', 'Tasks', 'Schedule', 'QuickInput', 'Templates', 'Settings', 'Stats', 'Import', 'Notes', 'Review', 'Signals', 'CheckIns')) {
    . (Join-Path $coreDir "$file.ps1")
}
. (Join-Path $PSScriptRoot 'Storage.ps1')
