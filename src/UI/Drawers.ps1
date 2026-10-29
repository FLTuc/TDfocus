# TDfocus - panneau latéral : sons, routines, notes, statistiques, import, réglages.
# Un seul niveau : chaque bouton de l'en-tête ouvre directement son panneau.

$script:TdDrawerTitles = @{
    sounds    = 'Sons et carillons'
    templates = 'Routines'
    notes     = 'Bloc-notes'
    stats     = 'Estimé vs réel'
    import    = 'Importer la journée'
    settings  = 'Réglages'
}

# Couleurs du graphique (validées : séparation daltonisme, contraste, dans les deux thèmes).
$script:TdChartColors = @{
    light = @{ estimate = '#169C6D'; actual = '#6250D6' }
    dark  = @{ estimate = '#199E70'; actual = '#9085E9' }
}

function Show-TdDrawer {
    param([Parameter(Mandatory)][string]$Name, [switch]$Force)
    if ($script:Td.Drawer -eq $Name -and -not $Force) { Close-TdDrawer; return }
    if ($script:Td.Compact) { Set-TdCompactMode $false }
    if ($script:Td.FocusMode) { Set-TdFocusMode $false }
    $script:Td.Drawer = $Name
    $script:Td.Ui.DrawerTitle.Text = $script:TdDrawerTitles[$Name]
    $script:Td.Ui.Drawer.Visibility = 'Visible'
    Update-TdDrawer
    $script:Td.Ui.DrawerScroll.ScrollToTop()
}

function Close-TdDrawer {
    $script:Td.Drawer = $null
    $script:Td.Ui.Drawer.Visibility = 'Collapsed'
    $script:Td.Ui.DrawerContent.Content = $null
}

function Update-TdDrawer {
    $name = $script:Td.Drawer
    if (-not $name) { return }
    $panel = New-TdPanel
    switch ($name) {
        'sounds' { Build-TdSoundsPanel $panel }
        'templates' { Build-TdTemplatesPanel $panel }
        'notes' { Build-TdNotesPanel $panel }
        'stats' { Build-TdStatsPanel $panel }
        'import' { Build-TdImportPanel $panel }
        'settings' { Build-TdSettingsPanel $panel }
    }
    $script:Td.Ui.DrawerContent.Content = $panel
}

function Add-TdSection {
    param([Parameter(Mandatory)]$Panel, [Parameter(Mandatory)][string]$Title, [string]$Help)
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Title.ToUpperInvariant()
    Set-TdStyle $label 'SectionLabel'
    [void]$Panel.Children.Add($label)
    if ($Help) {
        $text = New-TdText -Text $Help -Size 13 -Brush 'MutedBrush' -Wrap -Margin '2,0,0,10'
        [void]$Panel.Children.Add($text)
    }
}

function New-TdSlider {
    param([double]$Value, [string]$ToolTip, [scriptblock]$OnChange)
    $slider = New-Object System.Windows.Controls.Slider
    $slider.Minimum = 0
    $slider.Maximum = 1
    $slider.Value = $Value
    $slider.SmallChange = 0.05
    $slider.LargeChange = 0.1
    $slider.Margin = New-Object System.Windows.Thickness 0, 4, 0, 8
    $slider.IsMoveToPointEnabled = $true
    if ($ToolTip) { $slider.ToolTip = $ToolTip }
    if ($OnChange) { $slider.Add_ValueChanged($OnChange) }
    $slider
}

function New-TdLabeledRow {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)]$Control)
    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = [System.Windows.GridLength]::Auto
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $grid.ColumnDefinitions.Add($c1)
    $grid.ColumnDefinitions.Add($c2)
    $text = New-TdText -Text $Label -Size 13 -Brush 'MutedBrush' -Margin '2,0,12,0'
    $text.VerticalAlignment = 'Center'
    $text.MinWidth = 64
    [void]$grid.Children.Add($text)
    [System.Windows.Controls.Grid]::SetColumn($Control, 1)
    [void]$grid.Children.Add($Control)
    $grid
}

# ---------------------------------------------------------------- sons

function Build-TdSoundsPanel {
    param($Panel)
    $settings = Get-TdSettings
    Add-TdSection $Panel 'Ambiance sonore' 'Pour masquer les bruits parasites. Les sons sont générés sur ton PC, la première fois seulement.'
    $wrap = New-TdPanel -Wrap
    $choices = [ordered]@{ none = 'Aucune'; white = 'Bruit blanc'; pink = 'Bruit rose'; brown = 'Bruit brun'; rain = 'Pluie douce'; chimes = "Carillon d'ambiance" }
    foreach ($key in $choices.Keys) {
        $chip = New-TdChip -Content $choices[$key] -Group 'ambient' -Checked ($settings.ambient -eq $key) -Tag $key -OnClick {
            $s = Get-TdSettings
            $s.ambient = [string]$this.Tag
            Save-TdSettingsNow
            Set-TdAmbient -Name $s.ambient -Volume $s.ambientVolume
            Update-TdDrawer
        }
        [void]$wrap.Children.Add($chip)
    }
    [void]$Panel.Children.Add($wrap)
    if ($script:TdAudio -and $script:TdAudio.MediaBroken) {
        [void]$Panel.Children.Add((New-TdText -Text 'Le lecteur multimédia de Windows est indisponible sur ce PC (édition « N » sans Media Feature Pack ?) : les ambiances sont désactivées, les effets restent audibles.' -Size 12 -Brush 'OvertimeBrush' -Wrap -Margin '2,0,0,6'))
    }
    elseif ($settings.ambient -ne 'none') {
        $status = Get-TdSoundStatus $settings.ambient
        $message = $null
        if ($status -eq 'preparing' -or $status -eq 'missing') { $message = 'Préparation du son… (quelques secondes, une seule fois)' }
        elseif ($status -eq 'failed') { $message = 'Ce son n''a pas pu être préparé. Le journal tdfocus.log contient le détail.' }
        if ($message) { [void]$Panel.Children.Add((New-TdText -Text $message -Size 12 -Brush 'AccentBrush' -Wrap -Margin '2,0,0,6')) }
    }
    [void]$Panel.Children.Add((New-TdLabeledRow 'Volume' (New-TdSlider -Value $settings.ambientVolume -ToolTip "Volume de l'ambiance" -OnChange {
                    $s = Get-TdSettings
                    $s.ambientVolume = [Math]::Round($this.Value, 2)
                    Set-TdAmbient -Name $s.ambient -Volume $s.ambientVolume
                    Request-TdSettingsSave
                })))

    Add-TdSection $Panel 'Carillon périodique' 'Un tintement discret toutes les X minutes pendant que le minuteur tourne : pour sortir de la rêverie et sentir le temps passer.'
    $wrap = New-TdPanel -Wrap
    foreach ($m in @(0, 5, 10, 15, 20, 30)) {
        $label = "$m min"
        if ($m -eq 0) { $label = 'Désactivé' }
        $chip = New-TdChip -Content $label -Group 'chime' -Checked ([int]$settings.chimeEveryMin -eq $m) -Tag $m -OnClick {
            $s = Get-TdSettings
            $s.chimeEveryMin = [int]$this.Tag
            $script:Td.ChimeTaskId = ''
            Save-TdSettingsNow
        }
        [void]$wrap.Children.Add($chip)
    }
    [void]$Panel.Children.Add($wrap)
    $row = New-TdPanel -Orientation Horizontal
    [void]$row.Children.Add((New-TdButton -Content 'Écouter' -Style 'PillButton' -Margin '0,0,8,0' -OnClick { Invoke-TdSoundEffect -Name 'chime' -Volume (Get-TdSettings).chimeVolume }))
    [void]$Panel.Children.Add($row)
    [void]$Panel.Children.Add((New-TdLabeledRow 'Volume' (New-TdSlider -Value $settings.chimeVolume -ToolTip 'Volume du carillon' -OnChange {
                    (Get-TdSettings).chimeVolume = [Math]::Round($this.Value, 2)
                    Request-TdSettingsSave
                })))

    Add-TdSection $Panel 'Effets'
    [void]$Panel.Children.Add((New-TdSwitch -Label 'Son de validation (petite récompense)' -Checked $settings.completionSound -OnChange {
                (Get-TdSettings).completionSound = [bool]$this.IsChecked
                Save-TdSettingsNow
            }))
    [void]$Panel.Children.Add((New-TdSwitch -Label 'Tintement doux quand le temps prévu est écoulé (jamais d''alarme)' -Checked $settings.timeUpSignal -OnChange {
                (Get-TdSettings).timeUpSignal = [bool]$this.IsChecked
                Save-TdSettingsNow
            }))
    $row = New-TdPanel -Orientation Horizontal -Margin '0,4,0,0'
    [void]$row.Children.Add((New-TdButton -Content 'Écouter la validation' -Margin '0,0,8,0' -OnClick { Invoke-TdSoundEffect -Name 'complete' -Volume (Get-TdSettings).effectsVolume }))
    [void]$row.Children.Add((New-TdButton -Content 'Écouter la fin de temps' -OnClick { Invoke-TdSoundEffect -Name 'timeup' -Volume (Get-TdSettings).effectsVolume }))
    [void]$Panel.Children.Add($row)
    [void]$Panel.Children.Add((New-TdLabeledRow 'Volume' (New-TdSlider -Value $settings.effectsVolume -ToolTip 'Volume des effets' -OnChange {
                    (Get-TdSettings).effectsVolume = [Math]::Round($this.Value, 2)
                    Request-TdSettingsSave
                })))
}

# ---------------------------------------------------------------- routines

function Get-TdAllTemplates {
    @(Get-TdBuiltInTemplates) + @($script:Td.Data.templates)
}

function Build-TdTemplatesPanel {
    param($Panel)
    Add-TdSection $Panel 'Charger en un clic' 'Les tâches de la routine s''ajoutent à la fin de ta liste.'
    foreach ($tpl in (Get-TdAllTemplates)) {
        $total = 0.0
        foreach ($it in $tpl.items) { $total += [double]$it.minutes }
        $grid = New-Object System.Windows.Controls.Grid
        foreach ($w in @('Auto', '*', 'Auto')) {
            $col = New-Object System.Windows.Controls.ColumnDefinition
            if ($w -eq 'Auto') { $col.Width = [System.Windows.GridLength]::Auto }
            $grid.ColumnDefinitions.Add($col)
        }
        $emoji = New-TdText -Text $tpl.emoji -Size 22 -Margin '0,0,12,0' -Font 'EmojiFont'
        $emoji.VerticalAlignment = 'Center'
        [void]$grid.Children.Add($emoji)
        $texts = New-TdPanel
        [void]$texts.Children.Add((New-TdText -Text $tpl.name -Bold))
        $plural = ''
        if (@($tpl.items).Count -gt 1) { $plural = 's' }
        [void]$texts.Children.Add((New-TdText -Text ('{0} tâche{1} · {2}' -f @($tpl.items).Count, $plural, (Format-TdMinutes $total)) -Size 12 -Brush 'MutedBrush'))
        $texts.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($texts, 1)
        [void]$grid.Children.Add($texts)
        if (-not $tpl.builtIn) {
            $del = New-TdButton -Content ([string][char]0xE74D) -Style 'SmallIconButton' -ToolTip 'Supprimer cette routine' -Tag $tpl.id -OnClick {
                param($s, $e)
                $id = [string]$this.Tag
                $list = $script:Td.Data.templates
                for ($i = $list.Count - 1; $i -ge 0; $i--) { if ($list[$i].id -eq $id) { $list.RemoveAt($i) } }
                Save-TdTemplates $list
                Update-TdDrawer
                $e.Handled = $true
            }
            [System.Windows.Controls.Grid]::SetColumn($del, 2)
            [void]$grid.Children.Add($del)
        }
        $card = New-TdButton -Content $grid -Style 'CardButton' -Margin '0,0,0,8' -Tag $tpl.id -ToolTip (($tpl.items | ForEach-Object { '• {0} ({1})' -f $_.title, (Format-TdMinutes $_.minutes) }) -join "`n") -OnClick {
            $id = [string]$this.Tag
            $tpl = Get-TdAllTemplates | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if ($tpl) { Add-TdTemplateNow $tpl }
        }
        [void]$Panel.Children.Add($card)
    }

    $state = Get-TdState
    Add-TdSection $Panel 'Enregistrer la liste actuelle' 'Toutes les tâches restantes (y compris celle en cours) deviennent une routine réutilisable.'
    $nameBox = New-TdTextBox -Margin '0,0,0,8'
    $nameBox.ToolTip = 'Nom de la routine'
    $script:Td.TemplateNameBox = $nameBox
    [void]$Panel.Children.Add($nameBox)
    $save = New-TdButton -Content 'Enregistrer comme routine' -Style 'PrimaryButton' -OnClick { Save-TdCurrentAsTemplate }
    $save.HorizontalAlignment = 'Left'
    $save.IsEnabled = $state.tasks.Count -gt 0
    $nameBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Save-TdCurrentAsTemplate; $e.Handled = $true } })
    [void]$Panel.Children.Add($save)
}

function Set-TdTemplateNameFocus {
    $box = $script:Td.TemplateNameBox
    if ($box) { $box.Focus() | Out-Null }
}

function Save-TdCurrentAsTemplate {
    $state = Get-TdState
    $name = $script:Td.TemplateNameBox.Text.Trim()
    if ($state.tasks.Count -eq 0) { return }
    if (-not $name) {
        Show-TdToast -Text 'Donne un nom à ta routine.'
        Set-TdTemplateNameFocus
        return
    }
    $tpl = New-TdTemplateFromTasks -Name $name -Tasks @($state.tasks)
    $script:Td.Data.templates.Add($tpl)
    Save-TdTemplates $script:Td.Data.templates
    Show-TdToast -Text ('Routine « {0} » enregistrée.' -f $name)
    Update-TdDrawer
}

# ---------------------------------------------------------------- notes

function Build-TdNotesPanel {
    param($Panel)
    Add-TdSection $Panel 'Parking à idées' 'Une pensée parasite ? Dépose-la ici et reviens à ta tâche. Tu t''en occuperas plus tard.'
    $box = New-TdTextBox -Multiline -Margin '0,0,0,8'
    $box.MinHeight = 70
    $box.ToolTip = 'Entrée pour noter · Maj+Entrée pour aller à la ligne'
    $script:Td.NoteCaptureBox = $box
    $box.Add_PreviewKeyDown({
            param($s, $e)
            $shift = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
            if ($e.Key -eq 'Return' -and -not $shift) { Add-TdNoteNow; $e.Handled = $true }
        })
    [void]$Panel.Children.Add($box)
    $add = New-TdButton -Content 'Noter' -Style 'PrimaryButton' -OnClick { Add-TdNoteNow }
    $add.HorizontalAlignment = 'Left'
    [void]$Panel.Children.Add($add)
    [void]$box.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, [Action] { try { $box.Focus() | Out-Null } catch { $null = $_ } }.GetNewClosure())

    $notes = $script:Td.Data.notes
    if ($notes.Count -eq 0) {
        [void]$Panel.Children.Add((New-TdText -Text 'Aucune note pour l''instant.' -Size 13 -Brush 'MutedBrush' -Margin '2,18,0,0'))
        return
    }
    Add-TdSection $Panel ('Notes ({0})' -f $notes.Count)
    for ($i = $notes.Count - 1; $i -ge 0; $i--) {
        $note = $notes[$i]
        $card = New-TdCard
        $stack = New-TdPanel
        [void]$stack.Children.Add((New-TdText -Text $note.text -Wrap))
        $meta = Format-TdClock $note.createdAt
        if ((Get-TdDayKey $note.createdAt) -ne (Get-TdDayKey (Get-TdNowMs))) {
            $meta = (ConvertTo-TdLocalDate $note.createdAt).ToString('dd/MM HH:mm')
        }
        if ($note.context) { $meta += ' · pendant « {0} »' -f (Limit-TdText $note.context 30) }
        [void]$stack.Children.Add((New-TdText -Text $meta -Size 12 -Brush 'MutedBrush' -Margin '0,4,0,6'))
        $actions = New-TdPanel -Orientation Horizontal
        [void]$actions.Children.Add((New-TdButton -Content 'En faire une tâche' -Style 'PillButton' -Margin '0,0,6,0' -Tag $note.id -OnClick { Convert-TdNoteToTask ([string]$this.Tag) }))
        [void]$actions.Children.Add((New-TdButton -Content 'Supprimer' -Style 'GhostButton' -Tag $note.id -OnClick { Remove-TdNoteNow ([string]$this.Tag) }))
        [void]$stack.Children.Add($actions)
        $card.Child = $stack
        [void]$Panel.Children.Add($card)
    }
}

function Add-TdNoteNow {
    $box = $script:Td.NoteCaptureBox
    $text = $box.Text.Trim()
    if (-not $text) { return }
    $current = Get-TdCurrentTask (Get-TdState)
    $context = $null
    if ($current) { $context = $current.title }
    $script:Td.Data.notes.Add((New-TdNote -Text $text -Context $context))
    Save-TdNotes $script:Td.Data.notes
    Update-TdDrawer
    Show-TdToast -Text 'Noté. Retour à ta tâche !' -Seconds 3
}

function Remove-TdNoteNow {
    param([Parameter(Mandatory)][string]$Id)
    $notes = $script:Td.Data.notes
    for ($i = $notes.Count - 1; $i -ge 0; $i--) { if ($notes[$i].id -eq $Id) { $notes.RemoveAt($i) } }
    Save-TdNotes $notes
    Update-TdDrawer
}

function Convert-TdNoteToTask {
    param([Parameter(Mandatory)][string]$Id)
    $note = $script:Td.Data.notes | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $note) { return }
    $firstLine = ($note.text -split '\r?\n')[0]
    $parsed = ConvertFrom-TdQuickInput $firstLine
    $minutes = $parsed.minutes
    if (-not $minutes) { $minutes = (Get-TdSettings).defaultMinutes }
    $title = $parsed.title
    if (-not $title) { $title = $firstLine }
    $now = Get-TdNowMs
    $task = New-TdTask -Title $title -Minutes ([double]$minutes) -FixedStart $parsed.fixedStart -Note $note.text -Source 'note' -NowMs $now
    Add-TdTask -State (Get-TdState) -Task $task -NowMs $now
    Remove-TdNoteNow $Id
    Complete-TdChange -Replan
    Show-TdToast -Text ('« {0} » ajoutée à la liste.' -f (Limit-TdText $title 40))
}

# ---------------------------------------------------------------- statistiques

function Build-TdStatsPanel {
    param($Panel)
    $stats = Get-TdStats -History $script:Td.Data.history -NowMs (Get-TdNowMs)
    $mode = 'light'
    if ($script:Td.DarkActive) { $mode = 'dark' }
    $colors = $script:TdChartColors[$mode]

    # Aujourd'hui (chiffres clés)
    $tiles = New-Object System.Windows.Controls.UniformGrid
    $tiles.Columns = 2
    $tiles.Margin = New-Object System.Windows.Thickness 0, 12, 0, 0
    foreach ($tile in @(
            @{ Value = [string]$stats.todayCount; Label = "tâches terminées aujourd'hui" },
            @{ Value = (Format-TdDurationMs $stats.todayFocusMs); Label = 'de concentration aujourd''hui' }
        )) {
        $card = New-TdCard -Margin '0,0,8,8'
        $stack = New-TdPanel
        [void]$stack.Children.Add((New-TdText -Text $tile.Value -Size 26 -Bold -Font 'DisplayFont'))
        [void]$stack.Children.Add((New-TdText -Text $tile.Label -Size 12 -Brush 'MutedBrush' -Wrap))
        $card.Child = $stack
        [void]$tiles.Children.Add($card)
    }
    [void]$Panel.Children.Add($tiles)

    Add-TdSection $Panel '7 derniers jours' 'Minutes estimées et minutes réellement passées, par jour.'
    # Légende (toujours présente avec deux séries) : l'identité ne repose pas que sur la couleur.
    $legend = New-TdPanel -Orientation Horizontal -Margin '2,0,0,10'
    foreach ($entry in @(@('Estimé', $colors.estimate), @('Réel', $colors.actual))) {
        $swatch = New-Object System.Windows.Controls.Border
        $swatch.Width = 12; $swatch.Height = 12
        $swatch.CornerRadius = New-Object System.Windows.CornerRadius 3
        $swatch.Background = New-TdBrush $entry[1]
        $swatch.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
        $swatch.VerticalAlignment = 'Center'
        [void]$legend.Children.Add($swatch)
        [void]$legend.Children.Add((New-TdText -Text $entry[0] -Size 12 -Margin '0,0,16,0'))
    }
    [void]$Panel.Children.Add($legend)
    [void]$Panel.Children.Add((New-TdWeekChart -Days $stats.days -Colors $colors))

    # Vue tableau (accessibilité) : les mêmes valeurs en texte.
    $table = New-TdPanel -Margin '0,10,0,0'
    foreach ($d in $stats.days) {
        if ($d.count -eq 0) { continue }
        $line = '{0} : {1} tâche(s) · estimé {2} · réel {3}' -f $d.label, $d.count, (Format-TdDurationMs $d.estimateMs), (Format-TdDurationMs $d.actualMs)
        [void]$table.Children.Add((New-TdText -Text $line -Size 12 -Brush 'MutedBrush'))
    }
    [void]$Panel.Children.Add($table)

    Add-TdSection $Panel 'Ta façon d''estimer' $null
    if ($stats.sampleCount -lt 3) {
        [void]$Panel.Children.Add((New-TdText -Text 'Encore quelques tâches chronométrées et TDfocus pourra te dire comment tu estimes tes durées. Pas de note, pas de jugement : juste un miroir.' -Size 13 -Brush 'MutedBrush' -Wrap))
    }
    else {
        $ratio = [double]$stats.medianRatio
        if ($ratio -ge 1.1) {
            $msg = 'En général, tes tâches prennent {0:0.0#}× le temps estimé. C''est très courant : prévois une marge, ou laisse TDfocus te suggérer des durées ajustées.' -f $ratio
        }
        elseif ($ratio -le 0.9) {
            $msg = 'Tu termines souvent plus vite que prévu ({0:0.0#}× le temps estimé). Tu peux viser un peu plus court.' -f $ratio
        }
        else {
            $msg = 'Tes estimations sont justes (×{0:0.0#} en médiane). Belle connaissance de toi !' -f $ratio
        }
        [void]$Panel.Children.Add((New-TdText -Text $msg -Size 14 -Wrap))
        if ($null -ne $stats.accuracy) {
            [void]$Panel.Children.Add((New-TdText -Text ('{0:P0} de tes tâches tombent à ±25 % de l''estimation (sur {1} tâches, 30 derniers jours).' -f $stats.accuracy, $stats.sampleCount) -Size 12 -Brush 'MutedBrush' -Wrap -Margin '0,6,0,0'))
        }
        if (@($stats.byCategory).Count -gt 0) {
            Add-TdSection $Panel 'Par catégorie'
            foreach ($c in $stats.byCategory) {
                $cat = Get-TdCategory (Get-TdSettings) $c.categoryId
                $name = 'Sans catégorie'
                if ($cat) { $name = '{0} {1}' -f $cat.emoji, $cat.name }
                [void]$Panel.Children.Add((New-TdText -Text ('{0} : ×{1:0.0#} ({2} tâches)' -f $name, [double]$c.ratio, $c.count) -Size 13 -Margin '2,0,0,4'))
            }
        }
    }
    [void]$Panel.Children.Add((New-TdText -Text 'Ces chiffres servent à mieux te connaître, jamais à te juger. Aucune série à perdre.' -Size 12 -Brush 'MutedBrush' -Wrap -Margin '2,18,0,0'))
}

function New-TdWeekChart {
    # Barres groupées : 2 px d'écart entre barres voisines, extrémités arrondies ancrées à la base,
    # une info-bulle par barre, une seule échelle.
    param([Parameter(Mandatory)]$Days, [Parameter(Mandatory)]$Colors)
    $height = 120.0
    $max = 1.0
    foreach ($d in $Days) { $max = [Math]::Max($max, [Math]::Max($d.estimateMs, $d.actualMs) / 60000.0) }
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Height = $height + 22
    foreach ($d in $Days) {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        $grid.ColumnDefinitions.Add($col)
    }
    $baseline = New-Object System.Windows.Controls.Border
    $baseline.Height = 1
    $baseline.VerticalAlignment = 'Top'
    $baseline.Margin = New-Object System.Windows.Thickness 0, $height, 0, 0
    $baseline.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'LineBrush')
    [System.Windows.Controls.Grid]::SetColumnSpan($baseline, $Days.Count)
    [void]$grid.Children.Add($baseline)
    for ($i = 0; $i -lt $Days.Count; $i++) {
        $d = $Days[$i]
        $bars = New-Object System.Windows.Controls.StackPanel
        $bars.Orientation = 'Horizontal'
        $bars.HorizontalAlignment = 'Center'
        $bars.VerticalAlignment = 'Top'
        $bars.Height = $height
        foreach ($serie in @(@('Estimé', $d.estimateMs, $Colors.estimate), @('Réel', $d.actualMs, $Colors.actual))) {
            $minutes = [double]$serie[1] / 60000.0
            $bar = New-Object System.Windows.Controls.Border
            $bar.Width = 12
            $bar.Height = [Math]::Max(0, [Math]::Round($height * $minutes / $max))
            if ($minutes -gt 0 -and $bar.Height -lt 3) { $bar.Height = 3 }
            $bar.VerticalAlignment = 'Bottom'
            $bar.CornerRadius = New-Object System.Windows.CornerRadius 4, 4, 0, 0
            $bar.Background = New-TdBrush $serie[2]
            $bar.Margin = New-Object System.Windows.Thickness 1, 0, 1, 0
            $bar.ToolTip = '{0} · {1} : {2} ({3} tâche(s))' -f $d.label, $serie[0], (Format-TdMinutes $minutes), $d.count
            [void]$bars.Children.Add($bar)
        }
        # Zone de survol plus large que les barres.
        $hit = New-Object System.Windows.Controls.Border
        $hit.Background = [System.Windows.Media.Brushes]::Transparent
        $hit.Height = $height
        $hit.VerticalAlignment = 'Top'
        $hit.ToolTip = '{0} : estimé {1} · réel {2} · {3} tâche(s)' -f $d.label, (Format-TdDurationMs $d.estimateMs), (Format-TdDurationMs $d.actualMs), $d.count
        $hit.Child = $bars
        [System.Windows.Controls.Grid]::SetColumn($hit, $i)
        [void]$grid.Children.Add($hit)
        $label = New-TdText -Text $d.label -Size 11 -Brush 'MutedBrush'
        $label.HorizontalAlignment = 'Center'
        $label.VerticalAlignment = 'Bottom'
        [System.Windows.Controls.Grid]::SetColumn($label, $i)
        [void]$grid.Children.Add($label)
    }
    $grid
}

# ---------------------------------------------------------------- import

function Build-TdImportPanel {
    param($Panel)
    $settings = Get-TdSettings
    if (@($script:Td.ImportItems).Count -gt 0) {
        Build-TdImportPreview $Panel
        return
    }
    if ($script:Td.ImportBusy) {
        [void]$Panel.Children.Add((New-TdText -Text 'Import en cours…' -Size 14 -Brush 'AccentBrush' -Margin '2,12,0,0'))
    }

    Add-TdSection $Panel 'Google Agenda / Outlook' 'Colle l''adresse secrète au format iCal (Google Agenda > Paramètres de l''agenda > « Adresse secrète au format iCal »), ou choisis un fichier .ics. Les événements du jour deviennent des créneaux figés.'
    $urlBox = New-TdTextBox -Text ([string]$settings.icsUrl) -Margin '0,0,0,8'
    $urlBox.ToolTip = 'https://calendar.google.com/calendar/ical/.../basic.ics'
    [void]$Panel.Children.Add($urlBox)
    $script:Td.ImportUrlBox = $urlBox
    $row = New-TdPanel -Orientation Horizontal
    [void]$row.Children.Add((New-TdButton -Content "Importer aujourd'hui" -Style 'PrimaryButton' -Margin '0,0,8,0' -OnClick { Start-TdIcsUrlImport }))
    [void]$row.Children.Add((New-TdButton -Content 'Fichier .ics…' -OnClick { Start-TdIcsFileImport }))
    [void]$Panel.Children.Add($row)

    Add-TdSection $Panel 'Todoist' 'Jeton d''API : Todoist > Paramètres > Intégrations > Développeur. Importe les tâches « aujourd''hui » et en retard (avec leur durée si elle est renseignée).'
    $todoist = New-Object System.Windows.Controls.PasswordBox
    Set-TdStyle $todoist 'SecretField'
    $todoist.Password = Unprotect-TdSecret $settings.todoistToken
    $todoist.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
    $script:Td.ImportTodoistBox = $todoist
    [void]$Panel.Children.Add($todoist)
    $btn = New-TdButton -Content 'Importer depuis Todoist' -Style 'PrimaryButton' -OnClick { Start-TdTodoistImport }
    $btn.HorizontalAlignment = 'Left'
    [void]$Panel.Children.Add($btn)

    Add-TdSection $Panel 'Notion' 'Crée une intégration interne (notion.so/my-integrations), partage ta base de tâches avec elle, puis colle le jeton et le lien ou l''identifiant de la base. Les cases cochées et statuts « Terminé » sont ignorés.'
    $notionToken = New-Object System.Windows.Controls.PasswordBox
    Set-TdStyle $notionToken 'SecretField'
    $notionToken.Password = Unprotect-TdSecret $settings.notionToken
    $notionToken.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
    $notionToken.ToolTip = 'Jeton de l''intégration (secret_… ou ntn_…)'
    $script:Td.ImportNotionTokenBox = $notionToken
    [void]$Panel.Children.Add($notionToken)
    $dbBox = New-TdTextBox -Text ([string]$settings.notionDatabaseId) -Margin '0,0,0,8'
    $dbBox.ToolTip = 'Lien ou identifiant de la base Notion'
    $script:Td.ImportNotionDbBox = $dbBox
    [void]$Panel.Children.Add($dbBox)
    $btn = New-TdButton -Content 'Importer depuis Notion' -Style 'PrimaryButton' -OnClick { Start-TdNotionImport }
    $btn.HorizontalAlignment = 'Left'
    [void]$Panel.Children.Add($btn)

    Add-TdSection $Panel 'Texte / copier-coller' 'Une tâche par ligne (listes Notion, Markdown, notes…). Durées et heures reconnues : « Rapport 45 min », « Appel 10 @14h ».'
    $textBox = New-TdTextBox -Multiline -Margin '0,0,0,8'
    $script:Td.ImportTextBox = $textBox
    [void]$Panel.Children.Add($textBox)
    $btn = New-TdButton -Content 'Analyser le texte' -Style 'PrimaryButton' -OnClick {
        $items = ConvertFrom-TdTextList -Content $script:Td.ImportTextBox.Text -DefaultMinutes (Get-TdSettings).defaultMinutes
        Show-TdImportPreview -Items $items -Source 'text' -Label 'texte'
    }
    $btn.HorizontalAlignment = 'Left'
    [void]$Panel.Children.Add($btn)
}

function Show-TdImportPreview {
    param([AllowEmptyCollection()]$Items, [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Label)
    $fresh = Select-TdNewImportItems -Items $Items -State (Get-TdState)
    if (@($fresh).Count -eq 0) {
        $script:Td.ImportItems = @()
        Show-TdToast -Text "Rien de nouveau à importer depuis $Label."
        Update-TdDrawer
        return
    }
    foreach ($it in $fresh) { $it | Add-Member -NotePropertyName source -NotePropertyValue $Source -Force }
    $script:Td.ImportItems = @($fresh)
    $script:Td.ImportLabel = $Label
    Update-TdDrawer
}

function Build-TdImportPreview {
    param($Panel)
    $items = @($script:Td.ImportItems)
    Add-TdSection $Panel ('Aperçu : {0} élément(s) depuis {1}' -f $items.Count, $script:Td.ImportLabel) 'Décoche ce que tu ne veux pas ajouter. Les créneaux à heure fixe se placent à leur heure dans la file.'
    $checks = @()
    foreach ($it in $items) {
        $desc = $it.title
        if ($it.allDay) { $desc += '  ·  journée entière' }
        else {
            $desc += '  ·  ' + (Format-TdMinutes ([double]$it.minutes))
            if ($it.fixedStart) { $desc += '  ·  ' + $it.fixedStart }
        }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = New-TdText -Text $desc -Wrap
        $cb.IsChecked = -not $it.allDay
        $cb.Margin = New-Object System.Windows.Thickness 0, 4, 0, 4
        $cb.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'TextBrush')
        $checks += $cb
        [void]$Panel.Children.Add($cb)
    }
    $script:Td.ImportChecks = $checks
    $row = New-TdPanel -Orientation Horizontal -Margin '0,12,0,0'
    [void]$row.Children.Add((New-TdButton -Content 'Ajouter la sélection' -Style 'PrimaryButton' -Margin '0,0,8,0' -OnClick { Complete-TdImport }))
    [void]$row.Children.Add((New-TdButton -Content 'Annuler' -Style 'GhostButton' -OnClick { $script:Td.ImportItems = @(); Update-TdDrawer }))
    [void]$Panel.Children.Add($row)
}

function Complete-TdImport {
    $items = @($script:Td.ImportItems)
    $checks = @($script:Td.ImportChecks)
    $now = Get-TdNowMs
    $state = Get-TdState
    $default = (Get-TdSettings).defaultMinutes
    $added = 0
    for ($i = 0; $i -lt $items.Count; $i++) {
        if (-not $checks[$i].IsChecked) { continue }
        $it = $items[$i]
        $minutes = $it.minutes
        if (-not $minutes) { $minutes = $default }
        $task = New-TdTask -Title $it.title -Minutes ([double]$minutes) -FixedStart $it.fixedStart -Source $it.source -ExternalId $it.externalId -NowMs $now
        Add-TdTask -State $state -Task $task -NowMs $now
        $added++
    }
    $script:Td.ImportItems = @()
    Complete-TdChange -Replan
    Update-TdDrawer
    Show-TdToast -Text ('{0} tâche(s) ajoutée(s).' -f $added)
}

function Start-TdIcsUrlImport {
    $url = $script:Td.ImportUrlBox.Text.Trim()
    if (-not $url) { Show-TdToast -Text 'Colle d''abord l''adresse iCal de ton agenda.'; return }
    $settings = Get-TdSettings
    $settings.icsUrl = $url
    Save-TdSettingsNow
    $script:Td.ImportBusy = $true
    Update-TdDrawer
    Start-TdBackgroundJob -Script $script:TdIcsFetchScript -Parameters @{ Url = $url } -OnDone {
        param($result, $errorText)
        $script:Td.ImportBusy = $false
        if ($errorText) { Show-TdToast -Text ('Agenda : ' + (Get-TdFriendlyNetworkError $errorText)) -Seconds 8; Update-TdDrawer; return }
        $content = [string](@($result) | Select-Object -First 1)
        Show-TdImportPreview -Items (ConvertFrom-TdIcs -Content $content -DayMs (Get-TdNowMs)) -Source 'calendar' -Label 'ton agenda'
    }
}

function Start-TdIcsFileImport {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Calendrier (*.ics)|*.ics|Tous les fichiers (*.*)|*.*'
    if (-not $dialog.ShowDialog($script:Td.Window)) { return }
    try {
        $content = [System.IO.File]::ReadAllText($dialog.FileName, [System.Text.Encoding]::UTF8)
        Show-TdImportPreview -Items (ConvertFrom-TdIcs -Content $content -DayMs (Get-TdNowMs)) -Source 'calendar' -Label ([System.IO.Path]::GetFileName($dialog.FileName))
    }
    catch { Show-TdToast -Text ('Fichier illisible : ' + $_.Exception.Message) -Seconds 8 }
}

function Start-TdTodoistImport {
    $token = $script:Td.ImportTodoistBox.Password.Trim()
    if (-not $token) { Show-TdToast -Text 'Colle d''abord ton jeton Todoist.'; return }
    $settings = Get-TdSettings
    $settings.todoistToken = Protect-TdSecret $token
    Save-TdSettingsNow
    $script:Td.ImportBusy = $true
    Update-TdDrawer
    Start-TdBackgroundJob -Script $script:TdTodoistFetchScript -Parameters @{ Token = $token } -OnDone {
        param($result, $errorText)
        $script:Td.ImportBusy = $false
        if ($errorText) { Show-TdToast -Text ('Todoist : ' + (Get-TdFriendlyNetworkError $errorText)) -Seconds 8; Update-TdDrawer; return }
        $tasks = @($result | ForEach-Object { $_ })
        Show-TdImportPreview -Items (ConvertFrom-TdTodoistTasks -Tasks $tasks -NowMs (Get-TdNowMs) -DefaultMinutes (Get-TdSettings).defaultMinutes) -Source 'todoist' -Label 'Todoist'
    }
}

function Start-TdNotionImport {
    $token = $script:Td.ImportNotionTokenBox.Password.Trim()
    $db = $script:Td.ImportNotionDbBox.Text.Trim()
    if (-not $token -or -not $db) { Show-TdToast -Text 'Il faut le jeton de l''intégration et le lien de la base Notion.'; return }
    $settings = Get-TdSettings
    $settings.notionToken = Protect-TdSecret $token
    $settings.notionDatabaseId = $db
    Save-TdSettingsNow
    $script:Td.ImportBusy = $true
    Update-TdDrawer
    Start-TdBackgroundJob -Script $script:TdNotionFetchScript -Parameters @{ Token = $token; DatabaseId = $db } -OnDone {
        param($result, $errorText)
        $script:Td.ImportBusy = $false
        if ($errorText) { Show-TdToast -Text ('Notion : ' + (Get-TdFriendlyNetworkError $errorText)) -Seconds 8; Update-TdDrawer; return }
        $pages = @($result | ForEach-Object { $_ })
        Show-TdImportPreview -Items (ConvertFrom-TdNotionPages -Pages $pages -NowMs (Get-TdNowMs) -DefaultMinutes (Get-TdSettings).defaultMinutes) -Source 'notion' -Label 'Notion'
    }
}

# ---------------------------------------------------------------- réglages

function Build-TdSettingsPanel {
    param($Panel)
    $settings = Get-TdSettings

    Add-TdSection $Panel 'Apparence'
    $wrap = New-TdPanel -Wrap
    foreach ($t in @(@('system', 'Comme Windows'), @('light', 'Clair'), @('dark', 'Sombre'))) {
        [void]$wrap.Children.Add((New-TdChip -Content $t[1] -Group 'theme' -Checked ($settings.theme -eq $t[0]) -Tag $t[0] -OnClick {
                    (Get-TdSettings).theme = [string]$this.Tag
                    Save-TdSettingsNow
                    Update-TdThemeNow
                    Update-TdView
                }))
    }
    [void]$Panel.Children.Add($wrap)

    Add-TdSection $Panel 'Minuteur'
    $wrap = New-TdPanel -Wrap
    foreach ($t in @(@('countdown', 'Compte à rebours'), @('countup', 'Compte progressif'))) {
        [void]$wrap.Children.Add((New-TdChip -Content $t[1] -Group 'timerMode' -Checked ($settings.timerMode -eq $t[0]) -Tag $t[0] -OnClick {
                    (Get-TdSettings).timerMode = [string]$this.Tag
                    Save-TdSettingsNow
                    Update-TdView
                }))
    }
    [void]$Panel.Children.Add($wrap)
    [void]$Panel.Children.Add((New-TdText -Text 'Le compte progressif affiche le temps écoulé : utile si le compte à rebours crée de l''anxiété.' -Size 12 -Brush 'MutedBrush' -Wrap -Margin '2,0,0,6'))
    [void]$Panel.Children.Add((New-TdSwitch -Label 'Enchaîner automatiquement la tâche suivante après validation' -Checked $settings.autoStartNext -OnChange {
                (Get-TdSettings).autoStartNext = [bool]$this.IsChecked
                Save-TdSettingsNow
            }))
    [void]$Panel.Children.Add((New-TdSwitch -Label 'Suggérer des durées d''après mon historique' -Checked $settings.showEstimateHints -OnChange {
                (Get-TdSettings).showEstimateHints = [bool]$this.IsChecked
                Save-TdSettingsNow
                Update-TdEstimateHint
            }))
    [void]$Panel.Children.Add((New-TdText -Text 'Durée proposée par défaut' -Size 13 -Brush 'MutedBrush' -Margin '2,8,0,6'))
    $wrap = New-TdPanel -Wrap
    foreach ($m in $script:TdPresetMinutes) {
        [void]$wrap.Children.Add((New-TdChip -Content "$m min" -Group 'defaultMinutes' -Checked ([int]$settings.defaultMinutes -eq $m) -Tag $m -OnClick {
                    (Get-TdSettings).defaultMinutes = [int]$this.Tag
                    Save-TdSettingsNow
                    Reset-TdAddBarSelection
                }))
    }
    [void]$Panel.Children.Add($wrap)

    Add-TdSection $Panel 'Démarrage de Windows' 'Sans droits administrateur : TDfocus s''inscrit seulement dans ta session (clé HKCU\…\Run).'
    [void]$Panel.Children.Add((New-TdSwitch -Label 'Lancer TDfocus à l''ouverture de session' -Checked $settings.autostart -OnChange {
                $s = Get-TdSettings
                $s.autostart = [bool]$this.IsChecked
                Save-TdSettingsNow
                if (-not (Set-TdAutostart -Enabled $s.autostart -ScriptPath $script:Td.ScriptPath)) {
                    Show-TdToast -Text 'Impossible de modifier le démarrage automatique (voir tdfocus.log).'
                }
                Update-TdDrawer
            }))
    if ($settings.autostart -and (Test-TdAutostartBlockedByUser)) {
        [void]$Panel.Children.Add((New-TdText -Text 'TDfocus est désactivé dans Paramètres > Applications > Démarrage : réactive-le là-bas pour qu''il se lance tout seul.' -Size 12 -Brush 'OvertimeBrush' -Wrap -Margin '2,0,0,6'))
    }
    [void]$Panel.Children.Add((New-TdSwitch -Label 'Au démarrage, rester discret dans la zone de notification' -Checked $settings.startMinimized -OnChange {
                (Get-TdSettings).startMinimized = [bool]$this.IsChecked
                Save-TdSettingsNow
            }))
    [void]$Panel.Children.Add((New-TdSwitch -Label 'La croix réduit TDfocus près de l''horloge (le minuteur continue)' -Checked $settings.closeToTray -OnChange {
                (Get-TdSettings).closeToTray = [bool]$this.IsChecked
                Save-TdSettingsNow
            }))

    Add-TdSection $Panel 'Confort'
    [void]$Panel.Children.Add((New-TdSwitch -Label 'Mode compact toujours au premier plan' -Checked $settings.compactTopmost -OnChange {
                (Get-TdSettings).compactTopmost = [bool]$this.IsChecked
                Save-TdSettingsNow
            }))
    [void]$Panel.Children.Add((New-TdSwitch -Label 'Micro-confettis à la validation' -Checked $settings.confetti -OnChange {
                (Get-TdSettings).confetti = [bool]$this.IsChecked
                Save-TdSettingsNow
            }))
    [void]$Panel.Children.Add((New-TdSwitch -Label 'Notifications discrètes quand la fenêtre est cachée' -Checked $settings.notifications -OnChange {
                (Get-TdSettings).notifications = [bool]$this.IsChecked
                Save-TdSettingsNow
            }))

    Add-TdSection $Panel 'Catégories' 'Une couleur douce et un émoji par contexte, sans sous-dossiers.'
    foreach ($cat in $settings.categories) { [void]$Panel.Children.Add((New-TdCategoryEditor $cat)) }
    [void]$Panel.Children.Add((New-TdButton -Content '+ Ajouter une catégorie' -Style 'GhostButton' -Margin '-6,0,0,0' -OnClick {
                $s = Get-TdSettings
                $palette = @('#8FB8E8', '#9FD8B5', '#F5C99B', '#C9B6EC', '#F2B5C8', '#E8D98F')
                $s.categories = @($s.categories) + @([pscustomobject][ordered]@{ id = 'cat-' + (New-TdId); name = 'Nouvelle'; emoji = [char]::ConvertFromUtf32(0x2B50); color = $palette[@($s.categories).Count % $palette.Count] })
                Save-TdSettingsNow
                Build-TdAddBarChips
                Update-TdDrawer
            }))

    Add-TdSection $Panel 'Données' 'Tout reste sur ce PC (hors ligne, sans compte).'
    $wrap = New-TdPanel -Wrap
    [void]$wrap.Children.Add((New-TdButton -Content 'Ouvrir le dossier' -Margin '0,0,8,8' -OnClick { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f (Get-TdDataDirectory)) }))
    [void]$wrap.Children.Add((New-TdButton -Content 'Exporter une sauvegarde…' -Margin '0,0,8,8' -OnClick { Export-TdBackupNow }))
    [void]$wrap.Children.Add((New-TdButton -Content 'Restaurer…' -Margin '0,0,8,8' -OnClick { Import-TdBackupNow }))
    [void]$Panel.Children.Add($wrap)

    Add-TdSection $Panel 'Raccourcis clavier'
    foreach ($line in @(
            'Espace : démarrer / pause',
            'Ctrl + Entrée : valider la tâche en cours',
            '+ / − : ajouter / retirer 1 minute',
            'L : reporter la tâche en fin de liste',
            'N ou Ctrl + N : nouvelle tâche',
            'F : mode focus · M : mode compact',
            'Échap : fermer / revenir'
        )) {
        [void]$Panel.Children.Add((New-TdText -Text $line -Size 13 -Margin '2,0,0,3'))
    }
    [void]$Panel.Children.Add((New-TdText -Text ('TDfocus {0} · 100 % local · PowerShell {1}' -f $script:TdVersion, $PSVersionTable.PSVersion) -Size 12 -Brush 'MutedBrush' -Margin '2,18,0,0'))
}

function New-TdCategoryEditor {
    param([Parameter(Mandatory)]$Category)
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Object System.Windows.Thickness 0, 0, 0, 6
    foreach ($w in @('Auto', 'Auto', '*', 'Auto')) {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        if ($w -eq 'Auto') { $col.Width = [System.Windows.GridLength]::Auto }
        $grid.ColumnDefinitions.Add($col)
    }
    $swatch = New-TdButton -Content '' -Style 'PillButton' -ToolTip 'Changer la couleur' -Tag $Category.id -OnClick {
        $s = Get-TdSettings
        $palette = @('#8FB8E8', '#9FD8B5', '#F5C99B', '#C9B6EC', '#F2B5C8', '#E8D98F', '#A9D6E5', '#D7C4A3')
        $cat = Get-TdCategory $s ([string]$this.Tag)
        $index = [Array]::IndexOf($palette, $cat.color)
        $cat.color = $palette[($index + 1) % $palette.Count]
        Save-TdSettingsNow
        Update-TdDrawer
        Update-TdView
    }
    $swatch.Width = 26; $swatch.Height = 26
    $swatch.Background = New-TdBrush $Category.color
    $swatch.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
    [void]$grid.Children.Add($swatch)

    $emoji = New-TdTextBox -Text $Category.emoji -Width 52
    $emoji.Tag = $Category.id
    $emoji.Padding = New-Object System.Windows.Thickness 8, 6, 8, 6
    $emoji.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI Emoji'
    $emoji.HorizontalContentAlignment = 'Center'
    $emoji.Add_LostFocus({ Update-TdCategoryField -Id ([string]$this.Tag) -Field 'emoji' -Value $this.Text })
    [System.Windows.Controls.Grid]::SetColumn($emoji, 1)
    [void]$grid.Children.Add($emoji)

    $name = New-TdTextBox -Text $Category.name -Margin '8,0,0,0'
    $name.Tag = $Category.id
    $name.Padding = New-Object System.Windows.Thickness 10, 6, 10, 6
    $name.Add_LostFocus({ Update-TdCategoryField -Id ([string]$this.Tag) -Field 'name' -Value $this.Text })
    [System.Windows.Controls.Grid]::SetColumn($name, 2)
    [void]$grid.Children.Add($name)

    $del = New-TdButton -Content ([string][char]0xE74D) -Style 'SmallIconButton' -ToolTip 'Supprimer la catégorie' -Margin '4,0,0,0' -Tag $Category.id -OnClick {
        $s = Get-TdSettings
        $id = [string]$this.Tag
        $s.categories = @($s.categories | Where-Object { $_.id -ne $id })
        Save-TdSettingsNow
        Build-TdAddBarChips
        Update-TdDrawer
        Update-TdView
    }
    [System.Windows.Controls.Grid]::SetColumn($del, 3)
    [void]$grid.Children.Add($del)
    $grid
}

function Update-TdCategoryField {
    param([string]$Id, [string]$Field, [string]$Value)
    $cat = Get-TdCategory (Get-TdSettings) $Id
    if (-not $cat -or [string]::IsNullOrWhiteSpace($Value) -or $cat.$Field -eq $Value.Trim()) { return }
    $cat.$Field = $Value.Trim()
    Save-TdSettingsNow
    Build-TdAddBarChips
    Update-TdView
}

function Export-TdBackupNow {
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter = 'Sauvegarde TDfocus (*.json)|*.json'
    $dialog.FileName = 'TDfocus-sauvegarde-{0:yyyy-MM-dd}.json' -f (Get-Date)
    if (-not $dialog.ShowDialog($script:Td.Window)) { return }
    try {
        Export-TdBackup -Path $dialog.FileName -Data $script:Td.Data
        Show-TdToast -Text 'Sauvegarde exportée (sans les jetons d''API).'
    }
    catch { Show-TdToast -Text ('Export impossible : ' + $_.Exception.Message) -Seconds 8 }
}

function Import-TdBackupNow {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Sauvegarde TDfocus (*.json)|*.json'
    if (-not $dialog.ShowDialog($script:Td.Window)) { return }
    try {
        $restored = Import-TdBackup -Path $dialog.FileName
        $current = $script:Td.Data.settings
        foreach ($k in @('todoistToken', 'notionToken', 'autostart')) { $restored.settings[$k] = $current[$k] }
        $script:Td.Data = $restored
        $now = Get-TdNowMs
        Sync-TdState $restored.state $now
        Save-TdStateNow
        Save-TdSettingsNow
        Save-TdHistoryNow
        Save-TdTemplates $restored.templates
        Save-TdNotes $restored.notes
        Update-TdThemeNow
        Build-TdAddBarChips
        Set-TdAmbient -Name $restored.settings.ambient -Volume $restored.settings.ambientVolume
        Update-TdView
        Update-TdDrawer
        Show-TdToast -Text 'Sauvegarde restaurée.'
    }
    catch { Show-TdToast -Text ('Restauration impossible : ' + $_.Exception.Message) -Seconds 8 }
}
