# TDfocus - cockpit flottant (helpdesk et projets), étape 1 : la bulle et la fenêtre du cockpit.
#
# Deux petites fenêtres, indépendantes de la fenêtre principale et toujours au-dessus des autres :
#   - la bulle (au repos) : ronde, déplaçable ; un clic ouvre le cockpit ;
#   - le cockpit : en-tête avec la date et l'heure, bouton « réduire en bulle ».
# « Toujours au-dessus » = propriété Topmost des fenêtres WPF (voir les fichiers .xaml).
# Les calculs (positions, tailles) sont dans src\Core\Cockpit.ps1 ; ici, on ne fait qu'afficher.
#
# Tout est rangé dans $script:Td.Cockpit :
#   Bubble, Panel         les deux fenêtres
#   BubbleEls, PanelEls   leurs éléments nommés (x:Name dans le XAML)
#   Anchor                le coin de l'écran où se trouve la bulle (voir Get-TdCockpitAnchor)
#   Clock                 la dernière heure affichée (pour ne redessiner que si elle change)

function Initialize-TdCockpit {
    # Construit les deux fenêtres, sans les afficher. En cas de problème, TDfocus continue sans cockpit.
    try {
        $folder = Join-Path $script:Td.SourceRoot 'UI'
        $bubbleXaml = [System.IO.File]::ReadAllText((Join-Path $folder 'CockpitBubble.xaml'), [System.Text.Encoding]::UTF8)
        $panelXaml = [System.IO.File]::ReadAllText((Join-Path $folder 'CockpitPanel.xaml'), [System.Text.Encoding]::UTF8)
        $bubble = [System.Windows.Markup.XamlReader]::Parse($bubbleXaml)
        $panel = [System.Windows.Markup.XamlReader]::Parse($panelXaml)
        $font = Get-TdCockpitFont
        $bubble.FontFamily = $font
        $panel.FontFamily = $font
        $script:Td.Cockpit = @{
            Bubble    = $bubble
            Panel     = $panel
            BubbleEls = Get-TdNamedElements -Root $bubble -Xaml $bubbleXaml
            PanelEls  = Get-TdNamedElements -Root $panel -Xaml $panelXaml
            Anchor    = @{ Right = $true; Bottom = $true }
            Clock     = ''
        }
        Register-TdCockpitEvents
    }
    catch {
        $script:Td.Cockpit = $null
        Write-TdLog "Cockpit indisponible : $($_.Exception.Message)"
    }
}

function Get-TdCockpitFont {
    # La police Inter est fournie avec TDfocus (dossier assets\fonts) : rien à installer sur le PC.
    # Si elle manque, Windows utilise sa propre police (Segoe UI).
    $fallback = 'Segoe UI Variable Text, Segoe UI'
    $folder = Join-Path $script:Td.Assets 'fonts'
    if (Test-Path -LiteralPath (Join-Path $folder 'Inter-Regular.ttf')) {
        try {
            $base = New-Object System.Uri ($folder.TrimEnd('\') + '\')
            return New-Object System.Windows.Media.FontFamily $base, "./#Inter, $fallback"
        }
        catch { Write-TdLog "Police Inter illisible, police de Windows utilisée : $($_.Exception.Message)" }
    }
    New-Object System.Windows.Media.FontFamily $fallback
}

function Get-TdCockpitWorkArea {
    # Zone utilisable (sans la barre des tâches) de l'écran qui contient le point donné, en unités WPF.
    # Sans point (-Primary), ou en cas de doute : l'écran principal.
    param([double]$Left, [double]$Top, [switch]$Primary)
    $main = [System.Windows.SystemParameters]::WorkArea
    $area = @{ Left = $main.Left; Top = $main.Top; Width = $main.Width; Height = $main.Height }
    if ($Primary) { return $area }
    try {
        # Windows Forms compte en pixels, WPF en unités indépendantes du zoom de l'écran : on convertit.
        $scale = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width / [System.Windows.SystemParameters]::PrimaryScreenWidth
        if ($scale -gt 0) {
            $point = New-Object System.Drawing.Point ([int]($Left * $scale)), ([int]($Top * $scale))
            $work = [System.Windows.Forms.Screen]::FromPoint($point).WorkingArea
            $area = @{ Left = $work.Left / $scale; Top = $work.Top / $scale; Width = $work.Width / $scale; Height = $work.Height / $scale }
        }
    }
    catch { $null = $_ }
    $area
}

function Register-TdCockpitEvents {
    $ck = $script:Td.Cockpit
    $bubbleEls = $ck.BubbleEls
    $panelEls = $ck.PanelEls

    # La bulle n'apparaît pas dans Alt+Tab : elle ne doit pas encombrer la liste des fenêtres.
    $ck.Bubble.Add_SourceInitialized({ param($s, $e) Set-TdToolWindow -Window $s })

    # Bulle, à la souris : glisser pour déplacer, clic pour ouvrir.
    $bubbleEls.BubbleButton.Add_PreviewMouseLeftButtonDown({
            param($s, $e)
            Invoke-TdCockpitBubbleGesture
            $e.Handled = $true    # le bouton ne doit pas, en plus, déclencher son propre clic
        })
    # Bulle, au clavier (Entrée ou Espace).
    $bubbleEls.BubbleButton.Add_Click({ Open-TdCockpitPanel })

    # Clic droit sur la bulle : petit menu.
    $menu = New-Object System.Windows.Controls.ContextMenu
    $entries = @(
        @{ Text = 'Ouvrir le cockpit'; Action = { Open-TdCockpitPanel } }
        @{ Text = 'Ouvrir TDfocus'; Action = { if ($script:Td.Compact) { Set-TdCompactMode $false }; Show-TdWindow } }
        @{ Text = 'Masquer la bulle'; Action = { Hide-TdCockpit -Explain } }
    )
    foreach ($entry in $entries) {
        $item = New-Object System.Windows.Controls.MenuItem
        $item.Header = [string]$entry.Text
        $item.Add_Click($entry.Action)
        [void]$menu.Items.Add([System.Windows.Controls.MenuItem]$item)
    }
    $bubbleEls.BubbleButton.ContextMenu = $menu

    # Cockpit : on le déplace en le tenant par l'en-tête ; le bouton le réduit en bulle.
    $panelEls.Header.Add_MouseLeftButtonDown({ Invoke-TdCockpitPanelDrag })
    $panelEls.BtnReduce.Add_Click({ Close-TdCockpitPanel })

    # Alt+F4 ne détruit pas ces fenêtres tant que TDfocus tourne : le cockpit redevient une bulle.
    $ck.Panel.Add_Closing({
            param($s, $e)
            if ($script:Td.Quitting) { return }
            $e.Cancel = $true
            Close-TdCockpitPanel
        })
    $ck.Bubble.Add_Closing({
            param($s, $e)
            if (-not $script:Td.Quitting) { $e.Cancel = $true }
        })
}

# ---------------------------------------------------------------- afficher, ouvrir, réduire, masquer

function Show-TdCockpit {
    # Affiche le cockpit comme on l'avait laissé : en bulle, ou ouvert. -Open l'ouvre directement.
    param([switch]$Open)
    $ck = $script:Td.Cockpit
    if (-not $ck) { return }
    $settings = $script:Td.Data.settings.cockpit
    $settings.enabled = $true
    Set-TdCockpitBubbleHome
    if ($Open -or $settings.open) {
        Open-TdCockpitPanel
        return
    }
    $ck.Panel.Hide()
    $ck.Bubble.Show()
    Save-TdCockpitLayout
}

function Set-TdCockpitBubbleHome {
    # Place la bulle à son emplacement mémorisé (ramené dans l'écran si besoin), sinon dans le coin par défaut.
    $ck = $script:Td.Cockpit
    $settings = $script:Td.Data.settings.cockpit
    $bubble = $ck.Bubble
    if ($null -ne $settings.left -and $null -ne $settings.top) {
        $area = Get-TdCockpitWorkArea -Left ([double]$settings.left + $bubble.Width / 2) -Top ([double]$settings.top + $bubble.Height / 2)
        $position = Limit-TdCockpitPosition -Left ([double]$settings.left) -Top ([double]$settings.top) -Width $bubble.Width -Height $bubble.Height -Area $area
    }
    else {
        $position = Get-TdCockpitDefaultPosition -Area (Get-TdCockpitWorkArea -Primary)
    }
    $bubble.Left = $position.Left
    $bubble.Top = $position.Top
}

function Open-TdCockpitPanel {
    # Bulle -> cockpit : le cockpit s'ouvre dans le coin de l'écran où se trouve la bulle.
    $ck = $script:Td.Cockpit
    if (-not $ck) { return }
    $bubble = $ck.Bubble
    $panel = $ck.Panel
    if ([double]::IsNaN($bubble.Left) -or [double]::IsNaN($bubble.Top)) { Set-TdCockpitBubbleHome }   # bulle jamais affichée
    $area = Get-TdCockpitWorkArea -Left ($bubble.Left + $bubble.Width / 2) -Top ($bubble.Top + $bubble.Height / 2)
    $size = Get-TdCockpitPanelSize -Area $area
    $panel.Width = $size.Width
    $panel.Height = $size.Height
    $ck.Anchor = Get-TdCockpitAnchor -BubbleLeft $bubble.Left -BubbleTop $bubble.Top -Area $area
    $position = Get-TdCockpitPanelPosition -BubbleLeft $bubble.Left -BubbleTop $bubble.Top -PanelWidth $size.Width -PanelHeight $size.Height -Anchor $ck.Anchor -Area $area
    $panel.Left = $position.Left
    $panel.Top = $position.Top
    Update-TdCockpit -NowMs (Get-TdNowMs) -Force
    $bubble.Hide()
    $panel.Show()
    $script:Td.Data.settings.cockpit.enabled = $true
    $script:Td.Data.settings.cockpit.open = $true
    Save-TdCockpitLayout
}

function Close-TdCockpitPanel {
    # Cockpit -> bulle (« réduire en bulle »).
    $ck = $script:Td.Cockpit
    if (-not $ck) { return }
    $ck.Panel.Hide()
    $ck.Bubble.Show()
    $script:Td.Data.settings.cockpit.open = $false
    Save-TdCockpitLayout
}

function Hide-TdCockpit {
    # Masque la bulle et le cockpit. -Explain rappelle où les retrouver.
    param([switch]$Explain)
    $ck = $script:Td.Cockpit
    if (-not $ck) { return }
    $ck.Panel.Hide()
    $ck.Bubble.Hide()
    $script:Td.Data.settings.cockpit.enabled = $false
    $script:Td.Data.settings.cockpit.open = $false
    Save-TdCockpitLayout
    if ($Explain) { Show-TdTrayBalloon -Text 'Bulle masquée. Pour la retrouver : clic droit sur l''icône TDfocus près de l''horloge, puis « Cockpit ».' }
}

function Save-TdCockpitLayout {
    # Mémorise la place de la bulle (le cockpit s'ouvre toujours à partir d'elle).
    $ck = $script:Td.Cockpit
    $settings = $script:Td.Data.settings.cockpit
    if (-not [double]::IsNaN($ck.Bubble.Left) -and -not [double]::IsNaN($ck.Bubble.Top)) {
        $settings.left = [Math]::Round($ck.Bubble.Left)
        $settings.top = [Math]::Round($ck.Bubble.Top)
    }
    Save-TdSettingsNow
}

# ---------------------------------------------------------------- déplacer à la souris

function Invoke-TdCockpitBubbleGesture {
    # DragMove suit la souris et ne rend la main qu'au relâchement du bouton.
    $bubble = $script:Td.Cockpit.Bubble
    $startLeft = $bubble.Left
    $startTop = $bubble.Top
    if ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
        try { $bubble.DragMove() } catch { $null = $_ }
    }
    Complete-TdCockpitBubbleMove -StartLeft $startLeft -StartTop $startTop
}

function Complete-TdCockpitBubbleMove {
    # Après le geste : si la bulle n'a pas bougé, c'était un clic (on ouvre) ; sinon on mémorise sa place.
    param([double]$StartLeft, [double]$StartTop)
    $bubble = $script:Td.Cockpit.Bubble
    if (-not (Test-TdCockpitMoved -StartLeft $StartLeft -StartTop $StartTop -EndLeft $bubble.Left -EndTop $bubble.Top)) {
        $bubble.Left = $StartLeft
        $bubble.Top = $StartTop
        Open-TdCockpitPanel
        return
    }
    # La bulle reste entièrement visible, même lâchée au bord de l'écran.
    $area = Get-TdCockpitWorkArea -Left ($bubble.Left + $bubble.Width / 2) -Top ($bubble.Top + $bubble.Height / 2)
    $position = Limit-TdCockpitPosition -Left $bubble.Left -Top $bubble.Top -Width $bubble.Width -Height $bubble.Height -Area $area
    $bubble.Left = $position.Left
    $bubble.Top = $position.Top
    Save-TdCockpitLayout
}

function Invoke-TdCockpitPanelDrag {
    $panel = $script:Td.Cockpit.Panel
    $startLeft = $panel.Left
    $startTop = $panel.Top
    if ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
        try { $panel.DragMove() } catch { $null = $_ }
    }
    Complete-TdCockpitPanelMove -StartLeft $startLeft -StartTop $startTop
}

function Complete-TdCockpitPanelMove {
    # Après un déplacement du cockpit : il reste dans l'écran, et la bulle le suivra (même coin que lui).
    param([double]$StartLeft, [double]$StartTop)
    $ck = $script:Td.Cockpit
    $panel = $ck.Panel
    if (-not (Test-TdCockpitMoved -StartLeft $StartLeft -StartTop $StartTop -EndLeft $panel.Left -EndTop $panel.Top)) { return }
    $area = Get-TdCockpitWorkArea -Left ($panel.Left + $panel.Width / 2) -Top ($panel.Top + $panel.Height / 2)
    $position = Limit-TdCockpitPosition -Left $panel.Left -Top $panel.Top -Width $panel.Width -Height $panel.Height -Area $area
    $panel.Left = $position.Left
    $panel.Top = $position.Top
    $corner = Get-TdCockpitBubblePosition -PanelLeft $panel.Left -PanelTop $panel.Top -PanelWidth $panel.Width -PanelHeight $panel.Height -Anchor $ck.Anchor -Area $area
    $ck.Bubble.Left = $corner.Left
    $ck.Bubble.Top = $corner.Top
    Save-TdCockpitLayout
}

# ---------------------------------------------------------------- mise à jour (appelée par le minuteur de TDfocus)

function Update-TdCockpit {
    # Met à jour la date et l'heure de l'en-tête, seulement quand le cockpit est ouvert et que l'heure change.
    param([Parameter(Mandatory)][long]$NowMs, [switch]$Force)
    $ck = $script:Td.Cockpit
    if (-not $ck) { return }
    if (-not $Force -and -not $ck.Panel.IsVisible) { return }
    $clock = Format-TdClock $NowMs
    if (-not $Force -and $clock -eq $ck.Clock) { return }
    $ck.Clock = $clock
    $panelEls = $ck.PanelEls
    $panelEls.DateText.Text = Format-TdCockpitDate $NowMs
    $panelEls.TimeText.Text = [string][char]0x00B7 + ' ' + $clock
}
