# TDfocus - thèmes clair et sombre : tons doux, aucun rouge agressif.
# Le dépassement de temps utilise un ambre doux, jamais une couleur d'alerte.

$script:TdPalettes = @{
    light = [ordered]@{
        BgBrush           = '#F6F4FB'
        SurfaceBrush      = '#FFFFFF'
        SurfaceAltBrush   = '#EFECF7'
        LineBrush         = '#E4E0EE'
        TextBrush         = '#2E2A3B'
        MutedBrush        = '#6B6580'
        AccentBrush       = '#7464CC'
        AccentSoftBrush   = '#E8E4FB'
        AccentTextBrush   = '#FFFFFF'
        SuccessBrush      = '#86CFAD'
        SuccessSoftBrush  = '#DDF3E9'
        SuccessTextBrush  = '#12301F'
        OvertimeBrush     = '#A8692C'
        OvertimeSoftBrush = '#FBEBD9'
        TrackBrush        = '#ECE8F5'
        HoverBrush        = '#122E2A3B'
        ShadowBrush       = '#1A2E2A3B'
    }
    dark  = [ordered]@{
        BgBrush           = '#17161F'
        SurfaceBrush      = '#211F2B'
        SurfaceAltBrush   = '#2B2937'
        LineBrush         = '#363345'
        TextBrush         = '#ECEAF4'
        MutedBrush        = '#A6A1B8'
        AccentBrush       = '#A99BF0'
        AccentSoftBrush   = '#322D50'
        AccentTextBrush   = '#1A1630'
        SuccessBrush      = '#7FD1AC'
        SuccessSoftBrush  = '#1F3A2E'
        SuccessTextBrush  = '#0D2419'
        OvertimeBrush     = '#E9B97F'
        OvertimeSoftBrush = '#3A2F22'
        TrackBrush        = '#2F2C3D'
        HoverBrush        = '#16FFFFFF'
        ShadowBrush       = '#40000000'
    }
}

$script:TdConfettiColors = @('#B8ACF6', '#9FD8B5', '#F5C99B', '#F2B5C8', '#8FB8E8', '#E8D98F')

function ConvertTo-TdColor {
    param([Parameter(Mandatory)][string]$Hex)
    [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
}

function New-TdBrush {
    param([Parameter(Mandatory)][string]$Hex, [double]$Opacity = 1.0)
    $brush = New-Object System.Windows.Media.SolidColorBrush (ConvertTo-TdColor $Hex)
    if ($Opacity -lt 1.0) { $brush.Opacity = $Opacity }
    $brush.Freeze()
    $brush
}

function Test-TdDarkActive {
    param($Settings)
    switch ($Settings.theme) {
        'dark' { return $true }
        'light' { return $false }
    }
    Test-TdSystemDarkTheme
}

function Set-TdTheme {
    param([Parameter(Mandatory)]$Window, [Parameter(Mandatory)][bool]$Dark)
    $name = 'light'
    if ($Dark) { $name = 'dark' }
    $palette = $script:TdPalettes[$name]
    foreach ($key in $palette.Keys) {
        $Window.Resources[$key] = New-TdBrush $palette[$key]
    }
    Set-TdWindowDarkMode -Window $Window -Dark $Dark
}

function Get-TdCategoryBrush {
    # Fond doux d'une catégorie (sa couleur, très diluée).
    param($Category, [bool]$Dark)
    if (-not $Category -or -not $Category.color) { return $null }
    $opacity = 0.32
    if ($Dark) { $opacity = 0.22 }
    try { New-TdBrush $Category.color $opacity } catch { $null }
}
