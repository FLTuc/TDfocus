# TDfocus - réglages par défaut et normalisation.

function Get-TdDefaultSettings {
    [ordered]@{
        theme             = 'system'     # system | light | dark
        timerMode         = 'countdown'  # countdown | countup
        autoStartNext     = $true        # la suivante démarre après validation si le minuteur tournait
        chimeEveryMin     = 0            # carillon périodique : 0 = désactivé
        checkInWithChime  = $true        # point de contrôle « toujours sur ta tâche ? » à chaque carillon
        landingMinutes    = 2            # signal d'atterrissage N minutes avant la fin : 0 = désactivé
        morningReview     = $true        # revue du matin des tâches restées d'hier
        ambient           = 'none'       # none | white | pink | brown | rain | chimes
        ambientVolume     = 0.35
        chimeVolume       = 0.45
        effectsVolume     = 0.6
        completionSound   = $true
        timeUpSignal      = $true        # tintement doux (une fois) quand le temps prévu est écoulé
        confetti          = $true
        notifications     = $true        # bulle Windows discrète quand la fenêtre est cachée
        autostart         = $true        # lancement automatique à l'ouverture de session Windows
        startMinimized    = $false       # au démarrage de Windows : réduit dans la zone de notification
        closeToTray       = $true        # la croix réduit TDfocus au lieu de le quitter
        compactTopmost    = $true        # le mode compact reste au premier plan
        defaultMinutes    = 25
        showEstimateHints = $true
        icsUrl            = ''
        todoistToken      = ''
        notionToken       = ''
        notionDatabaseId  = ''
        categories        = @(Get-TdDefaultCategories)
        window            = $null
    }
}

function ConvertTo-TdSettings {
    param($InputObject)
    $settings = Get-TdDefaultSettings
    if ($null -eq $InputObject) { return $settings }
    foreach ($key in @($settings.Keys)) {
        $value = Get-TdValue $InputObject $key
        if ($null -eq $value) { continue }
        $default = $settings[$key]
        if ($default -is [bool]) { $settings[$key] = [bool]$value }
        elseif ($default -is [double]) { $settings[$key] = [Math]::Min(1.0, [Math]::Max(0.0, [double]$value)) }
        elseif ($default -is [int]) { $settings[$key] = [int]$value }
        else { $settings[$key] = $value }
    }
    if (@('system', 'light', 'dark') -notcontains $settings.theme) { $settings.theme = 'system' }
    if (@('countdown', 'countup') -notcontains $settings.timerMode) { $settings.timerMode = 'countdown' }
    if (@('none', 'white', 'pink', 'brown', 'rain', 'chimes') -notcontains $settings.ambient) { $settings.ambient = 'none' }
    if ($settings.defaultMinutes -lt 1) { $settings.defaultMinutes = 25 }
    if ($settings.landingMinutes -lt 0 -or $settings.landingMinutes -gt 15) { $settings.landingMinutes = 2 }
    $cats = foreach ($c in @($settings.categories)) {
        $id = ConvertTo-TdNullableString (Get-TdValue $c 'id')
        if (-not $id) { continue }
        [pscustomobject][ordered]@{
            id    = $id
            name  = [string](Get-TdValue $c 'name')
            emoji = [string](Get-TdValue $c 'emoji')
            color = [string](Get-TdValue $c 'color')
        }
    }
    $cats = @($cats)
    if ($cats.Count -eq 0) { $cats = @(Get-TdDefaultCategories) }
    $settings.categories = $cats
    $settings
}

function Get-TdCategory {
    param($Settings, [string]$Id)
    if (-not $Id) { return $null }
    foreach ($c in $Settings.categories) { if ($c.id -eq $Id) { return $c } }
    $null
}
