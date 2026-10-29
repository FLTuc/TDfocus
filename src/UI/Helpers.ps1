# TDfocus - utilitaires d'interface WPF.
#
# Attention : PowerShell enveloppe dans un PSObject ce que renvoient New-Object et les
# fonctions. Les propriétés typées (Background, Child...) le déballent, mais pas les
# emplacements de type object (Content, Resources[...], Items.Add, données de glisser-
# déposer) : on y transtype donc explicitement vers le type WPF attendu.

$script:TdXmlns = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'

function ConvertFrom-TdXaml {
    # Analyse un fragment XAML. « {ns} » est remplacé par les espaces de noms WPF.
    param([Parameter(Mandatory)][string]$Xaml)
    [System.Windows.Markup.XamlReader]::Parse($Xaml.Replace('{ns}', $script:TdXmlns))
}

function Get-TdNamedElements {
    # Table nom -> élément pour tous les x:Name d'un XAML (hors modèles de contrôles).
    param([Parameter(Mandatory)]$Root, [Parameter(Mandatory)][string]$Xaml)
    $map = @{}
    foreach ($m in [regex]::Matches($Xaml, 'x:Name="([^"]+)"')) {
        $name = $m.Groups[1].Value
        if ($map.ContainsKey($name)) { continue }
        $element = $Root.FindName($name)
        if ($null -ne $element) { $map[$name] = $element }
    }
    $map
}

function Set-TdStyle {
    param([Parameter(Mandatory)]$Element, [Parameter(Mandatory)][string]$StyleKey)
    $Element.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, $StyleKey)
}

function Set-TdBrushRef {
    # Équivalent de {DynamicResource ...} en code.
    param([Parameter(Mandatory)]$Element, [Parameter(Mandatory)]$Property, [Parameter(Mandatory)][string]$Key)
    $Element.SetResourceReference($Property, $Key)
}

function New-TdText {
    param(
        [string]$Text = '',
        [double]$Size = 14,
        [string]$Brush = 'TextBrush',
        [switch]$Bold,
        [switch]$Wrap,
        [string]$Margin = '0',
        [string]$Font
    )
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $Size
    if ($Bold) { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
    if ($Wrap) { $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap }
    $tb.Margin = [System.Windows.Thickness](ConvertTo-TdThickness $Margin)
    if ($Font) { $tb.SetResourceReference([System.Windows.Controls.TextBlock]::FontFamilyProperty, $Font) }
    $tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $Brush)
    $tb
}

function ConvertTo-TdThickness {
    param([string]$Value)
    $parts = @($Value.Split(',') | ForEach-Object { [double]$_ })
    switch ($parts.Count) {
        1 { return New-Object System.Windows.Thickness $parts[0] }
        2 { return New-Object System.Windows.Thickness $parts[0], $parts[1], $parts[0], $parts[1] }
        default { return New-Object System.Windows.Thickness $parts[0], $parts[1], $parts[2], $parts[3] }
    }
}

function New-TdButton {
    param(
        $Content,
        [string]$Style = 'PillButton',
        [string]$ToolTip,
        [string]$Margin = '0',
        $Tag,
        [scriptblock]$OnClick
    )
    $b = New-Object System.Windows.Controls.Button
    if ($Content -is [System.Windows.UIElement]) { $b.Content = [System.Windows.UIElement]$Content }
    elseif ($null -ne $Content) { $b.Content = [string]$Content }
    Set-TdStyle $b $Style
    if ($ToolTip) { $b.ToolTip = $ToolTip }
    $b.Margin = [System.Windows.Thickness](ConvertTo-TdThickness $Margin)
    if ($null -ne $Tag) { $b.Tag = $Tag }
    if ($OnClick) { $b.Add_Click($OnClick) }
    $b
}

function New-TdChip {
    param(
        [Parameter(Mandatory)]$Content,
        [string]$Group,
        [bool]$Checked = $false,
        $Tag,
        [string]$ToolTip,
        [scriptblock]$OnClick
    )
    if ($Group) {
        $chip = New-Object System.Windows.Controls.RadioButton
        $chip.GroupName = $Group
    }
    else {
        $chip = New-Object System.Windows.Controls.Primitives.ToggleButton
    }
    $chip.Content = [string]$Content
    Set-TdStyle $chip 'Chip'
    $chip.IsChecked = $Checked
    if ($null -ne $Tag) { $chip.Tag = $Tag }
    if ($ToolTip) { $chip.ToolTip = $ToolTip }
    if ($OnClick) { $chip.Add_Click($OnClick) }
    $chip
}

function New-TdSwitch {
    param([Parameter(Mandatory)][string]$Label, [bool]$Checked, [string]$ToolTip, [scriptblock]$OnChange)
    $cb = New-Object System.Windows.Controls.CheckBox
    Set-TdStyle $cb 'Switch'
    $cb.Content = [System.Windows.UIElement](New-TdText -Text $Label -Wrap)
    $cb.IsChecked = $Checked
    if ($ToolTip) { $cb.ToolTip = $ToolTip }
    if ($OnChange) {
        $cb.Add_Checked($OnChange)
        $cb.Add_Unchecked($OnChange)
    }
    $cb
}

function New-TdTextBox {
    param([string]$Text = '', [string]$Margin = '0', [double]$Width = [double]::NaN, [switch]$Multiline)
    $box = New-Object System.Windows.Controls.TextBox
    Set-TdStyle $box 'Field'
    $box.Text = $Text
    $box.Margin = [System.Windows.Thickness](ConvertTo-TdThickness $Margin)
    if (-not [double]::IsNaN($Width)) { $box.Width = $Width }
    if ($Multiline) {
        $box.AcceptsReturn = $true
        $box.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $box.VerticalContentAlignment = [System.Windows.VerticalAlignment]::Top
        $box.MinHeight = 90
    }
    $box
}

function New-TdPanel {
    param([string]$Orientation = 'Vertical', [string]$Margin = '0', [switch]$Wrap)
    if ($Wrap) { $panel = New-Object System.Windows.Controls.WrapPanel }
    else {
        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Orientation = [System.Windows.Controls.Orientation]$Orientation
    }
    $panel.Margin = [System.Windows.Thickness](ConvertTo-TdThickness $Margin)
    $panel
}

function New-TdCard {
    param([string]$Margin = '0,0,0,10', [string]$Padding = '14')
    $card = New-Object System.Windows.Controls.Border
    $card.CornerRadius = New-Object System.Windows.CornerRadius 14
    $card.Padding = [System.Windows.Thickness](ConvertTo-TdThickness $Padding)
    $card.Margin = [System.Windows.Thickness](ConvertTo-TdThickness $Margin)
    $card.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'SurfaceAltBrush')
    $card
}

function Get-TdArcGeometry {
    # Arc de progression (0..1) démarrant en haut, dans le sens horaire.
    param([double]$Size, [double]$Thickness, [double]$Fraction)
    $radius = ($Size - $Thickness) / 2
    $center = $Size / 2
    if ($Fraction -le 0.0005) { return [System.Windows.Media.Geometry]::Empty }
    if ($Fraction -ge 0.9995) {
        return New-Object System.Windows.Media.EllipseGeometry (New-Object System.Windows.Point $center, $center), $radius, $radius
    }
    $angle = 2 * [Math]::PI * $Fraction
    $start = New-Object System.Windows.Point $center, ($center - $radius)
    $end = New-Object System.Windows.Point ($center + $radius * [Math]::Sin($angle)), ($center - $radius * [Math]::Cos($angle))
    $segment = New-Object System.Windows.Media.ArcSegment
    $segment.Point = $end
    $segment.Size = New-Object System.Windows.Size $radius, $radius
    $segment.SweepDirection = [System.Windows.Media.SweepDirection]::Clockwise
    $segment.IsLargeArc = ($Fraction -gt 0.5)
    $figure = New-Object System.Windows.Media.PathFigure
    $figure.StartPoint = $start
    $figure.IsClosed = $false
    [void]$figure.Segments.Add($segment)
    $geometry = New-Object System.Windows.Media.PathGeometry
    [void]$geometry.Figures.Add($figure)
    $geometry.Freeze()
    $geometry
}

function Show-TdToast {
    # Message éphémère, avec action facultative (ex. « Annuler »).
    # L'action reçoit -Data en paramètre (pas de fermeture : les fonctions du script restent visibles).
    param([Parameter(Mandatory)][string]$Text, [string]$ActionText, [scriptblock]$Action, $Data, [int]$Seconds = 6)
    $ui = $script:Td.Ui
    $ui.ToastText.Text = $Text
    $script:Td.ToastAction = $Action
    $script:Td.ToastData = $Data
    if ($ActionText -and $Action) {
        $ui.ToastAction.Content = $ActionText
        $ui.ToastAction.Visibility = 'Visible'
    }
    else {
        $ui.ToastAction.Visibility = 'Collapsed'
    }
    $ui.Toast.Visibility = 'Visible'
    $script:Td.ToastUntil = (Get-TdNowMs) + $Seconds * 1000
}

function Hide-TdToast {
    $script:Td.Ui.Toast.Visibility = 'Collapsed'
    $script:Td.ToastAction = $null
    $script:Td.ToastData = $null
    $script:Td.ToastUntil = 0
}

function Test-TdReducedMotion {
    try { return -not [System.Windows.SystemParameters]::ClientAreaAnimation } catch { return $false }
}

function Invoke-TdConfetti {
    # Micro-confettis sobres, depuis un élément d'origine.
    param($Origin)
    if (-not $script:Td.Data.settings.confetti -or (Test-TdReducedMotion)) { return }
    $layer = $script:Td.Ui.ConfettiLayer
    $x = $layer.ActualWidth / 2
    $y = $layer.ActualHeight / 3
    if ($Origin -and $Origin.IsVisible) {
        try {
            $p = $Origin.TranslatePoint((New-Object System.Windows.Point ($Origin.ActualWidth / 2), ($Origin.ActualHeight / 2)), $layer)
            $x = $p.X; $y = $p.Y
        }
        catch { $null = $_ }
    }
    $rnd = $script:Td.Random
    for ($i = 0; $i -lt 26; $i++) {
        if ($rnd.NextDouble() -lt 0.5) {
            $shape = New-Object System.Windows.Shapes.Ellipse
            $shape.Width = 7; $shape.Height = 7
        }
        else {
            $shape = New-Object System.Windows.Shapes.Rectangle
            $shape.Width = 5; $shape.Height = 10
            $shape.RadiusX = 1.5; $shape.RadiusY = 1.5
        }
        $shape.Fill = New-TdBrush $script:TdConfettiColors[$rnd.Next($script:TdConfettiColors.Count)]
        [System.Windows.Controls.Canvas]::SetLeft($shape, $x)
        [System.Windows.Controls.Canvas]::SetTop($shape, $y)
        $translate = New-Object System.Windows.Media.TranslateTransform
        $rotate = New-Object System.Windows.Media.RotateTransform
        $group = New-Object System.Windows.Media.TransformGroup
        $group.Children.Add($rotate)
        $group.Children.Add($translate)
        $shape.RenderTransform = $group
        [void]$layer.Children.Add($shape)

        $duration = 0.9 + 0.5 * $rnd.NextDouble()
        $dx = ($rnd.NextDouble() * 2 - 1) * 150
        $up = -60 - 90 * $rnd.NextDouble()
        $down = 80 + 120 * $rnd.NextDouble()

        $ax = New-Object System.Windows.Media.Animation.DoubleAnimation 0, $dx, ([System.Windows.Duration][TimeSpan]::FromSeconds($duration))
        $ease = New-Object System.Windows.Media.Animation.QuadraticEase
        $ease.EasingMode = 'EaseOut'
        $ax.EasingFunction = $ease

        $ay = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        $ay.Duration = [System.Windows.Duration][TimeSpan]::FromSeconds($duration)
        $k1 = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame $up, ([System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds($duration * 0.35)))
        $e1 = New-Object System.Windows.Media.Animation.QuadraticEase
        $e1.EasingMode = 'EaseOut'
        $k1.EasingFunction = $e1
        $k2 = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame $down, ([System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds($duration)))
        $e2 = New-Object System.Windows.Media.Animation.QuadraticEase
        $e2.EasingMode = 'EaseIn'
        $k2.EasingFunction = $e2
        [void]$ay.KeyFrames.Add($k1)
        [void]$ay.KeyFrames.Add($k2)

        $ar = New-Object System.Windows.Media.Animation.DoubleAnimation 0, (($rnd.NextDouble() * 2 - 1) * 400), ([System.Windows.Duration][TimeSpan]::FromSeconds($duration))
        $ao = New-Object System.Windows.Media.Animation.DoubleAnimation 1, 0, ([System.Windows.Duration][TimeSpan]::FromSeconds($duration * 0.45))
        $ao.BeginTime = [TimeSpan]::FromSeconds($duration * 0.55)

        $translate.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $ax)
        $translate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $ay)
        $rotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $ar)
        $shape.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $ao)
    }
    # Nettoyage différé (sans dépendre des événements d'animation).
    $script:Td.ConfettiCleanupAt = (Get-TdNowMs) + 2000
}
