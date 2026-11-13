# TDfocus - cockpit flottant (helpdesk et projets) : calculs sans interface, testables partout.
#
# Étape 1 : où placer la bulle et le cockpit, quelle taille leur donner, et la date de l'en-tête.
# Une « zone » est la partie utilisable d'un écran (sans la barre des tâches), décrite par une
# table @{ Left ; Top ; Width ; Height } dans les unités de WPF.

$script:TdCockpitBubble = 100    # côté de la fenêtre de la bulle : 84 px de bulle + 8 px d'ombre autour
$script:TdCockpitWidth = 420     # largeur du cockpit ouvert
$script:TdCockpitHeight = 860    # hauteur du cockpit ouvert, si l'écran est assez grand
$script:TdCockpitEdge = 12       # marge gardée entre le cockpit et le bord de l'écran

function ConvertTo-TdCockpitNumber {
    # Nombre lu dans les réglages, ou $null s'il est absent ou illisible.
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    try { return [double]$Value } catch { return $null }
}

function ConvertTo-TdCockpitSettings {
    # Réglages du cockpit (dans settings.json) : affiché ou masqué, ouvert ou en bulle, place de la bulle.
    param($InputObject)
    $enabled = Get-TdValue $InputObject 'enabled'
    if ($null -eq $enabled) { $enabled = $true }    # la bulle est visible par défaut
    [ordered]@{
        enabled = [bool]$enabled
        open    = [bool](Get-TdValue $InputObject 'open')
        left    = ConvertTo-TdCockpitNumber (Get-TdValue $InputObject 'left')
        top     = ConvertTo-TdCockpitNumber (Get-TdValue $InputObject 'top')
    }
}

function Limit-TdCockpitPosition {
    # Ramène un rectangle dans la zone visible (écran débranché, résolution changée, bulle lâchée trop loin…).
    param([double]$Left, [double]$Top, [double]$Width, [double]$Height, [Parameter(Mandatory)]$Area)
    $maxLeft = [double]$Area.Left + [double]$Area.Width - $Width
    $maxTop = [double]$Area.Top + [double]$Area.Height - $Height
    @{
        Left = [Math]::Max([double]$Area.Left, [Math]::Min($Left, $maxLeft))
        Top  = [Math]::Max([double]$Area.Top, [Math]::Min($Top, $maxTop))
    }
}

function Get-TdCockpitDefaultPosition {
    # Première apparition de la bulle : en bas à droite, juste au-dessus de l'emplacement du mode compact.
    param([Parameter(Mandatory)]$Area)
    $size = $script:TdCockpitBubble
    Limit-TdCockpitPosition -Left ($Area.Left + $Area.Width - $size - 16) -Top ($Area.Top + $Area.Height - $size - 152) -Width $size -Height $size -Area $Area
}

function Get-TdCockpitPanelSize {
    # 420 × 860 quand l'écran le permet ; sinon la hauteur s'adapte et le contenu défile.
    param([Parameter(Mandatory)]$Area)
    $height = [Math]::Min([double]$script:TdCockpitHeight, [double]$Area.Height - 2 * $script:TdCockpitEdge)
    @{ Width = $script:TdCockpitWidth; Height = [Math]::Max(320.0, $height) }
}

function Get-TdCockpitAnchor {
    # Dans quel coin de l'écran se trouve la bulle ? Le cockpit s'ouvrira en gardant ce coin.
    param([double]$BubbleLeft, [double]$BubbleTop, [Parameter(Mandatory)]$Area)
    $half = $script:TdCockpitBubble / 2
    @{
        Right  = ($BubbleLeft + $half) -gt ($Area.Left + $Area.Width / 2)
        Bottom = ($BubbleTop + $half) -gt ($Area.Top + $Area.Height / 2)
    }
}

function Get-TdCockpitPanelPosition {
    # Place du cockpit quand on ouvre la bulle : il « sort » de la bulle, du même côté de l'écran.
    param(
        [double]$BubbleLeft, [double]$BubbleTop, [double]$PanelWidth, [double]$PanelHeight,
        [Parameter(Mandatory)]$Anchor, [Parameter(Mandatory)]$Area
    )
    $size = $script:TdCockpitBubble
    $left = $BubbleLeft
    if ($Anchor.Right) { $left = $BubbleLeft + $size - $PanelWidth }
    $top = $BubbleTop
    if ($Anchor.Bottom) { $top = $BubbleTop + $size - $PanelHeight }
    # Le cockpit garde une petite marge avec les bords de l'écran.
    $edge = $script:TdCockpitEdge
    $inner = @{ Left = $Area.Left + $edge; Top = $Area.Top + $edge; Width = $Area.Width - 2 * $edge; Height = $Area.Height - 2 * $edge }
    Limit-TdCockpitPosition -Left $left -Top $top -Width $PanelWidth -Height $PanelHeight -Area $inner
}

function Get-TdCockpitBubblePosition {
    # L'inverse : après avoir déplacé le cockpit, la bulle reviendra dans le même coin que lui.
    param(
        [double]$PanelLeft, [double]$PanelTop, [double]$PanelWidth, [double]$PanelHeight,
        [Parameter(Mandatory)]$Anchor, [Parameter(Mandatory)]$Area
    )
    $size = $script:TdCockpitBubble
    $left = $PanelLeft
    if ($Anchor.Right) { $left = $PanelLeft + $PanelWidth - $size }
    $top = $PanelTop
    if ($Anchor.Bottom) { $top = $PanelTop + $PanelHeight - $size }
    Limit-TdCockpitPosition -Left $left -Top $top -Width $size -Height $size -Area $Area
}

function Test-TdCockpitMoved {
    # Vrai si la fenêtre a vraiment été déplacée. Moins de 4 px : c'était un simple clic.
    param([double]$StartLeft, [double]$StartTop, [double]$EndLeft, [double]$EndTop)
    ([Math]::Abs($EndLeft - $StartLeft) -ge 4) -or ([Math]::Abs($EndTop - $StartTop) -ge 4)
}

function Format-TdCockpitDate {
    # « Ven. 13 nov. » pour l'en-tête du cockpit.
    param([Parameter(Mandatory)][long]$NowMs)
    $text = (ConvertTo-TdLocalDate $NowMs).ToString('ddd d MMM', $script:TdCulture)
    if ($text.Length -lt 2) { return $text }
    $text.Substring(0, 1).ToUpper($script:TdCulture) + $text.Substring(1)
}
