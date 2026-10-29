# TDfocus - application : état de l'interface, actions, rendu de la vue principale et minuteur.

$script:Td = $null
$script:TdPresetMinutes = @(5, 15, 25, 45, 60)

# ---------------------------------------------------------------- initialisation

function Initialize-TdApp {
    param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][string]$ScriptPath)
    $xaml = [System.IO.File]::ReadAllText((Join-Path $SourceRoot 'UI\MainWindow.xaml'), [System.Text.Encoding]::UTF8)
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $assets = Join-Path (Split-Path -Parent $SourceRoot) 'assets'
    $script:Td = @{
        SourceRoot        = $SourceRoot
        ScriptPath        = $ScriptPath
        Assets            = $assets
        Window            = $window
        Ui                = Get-TdNamedElements -Root $window -Xaml $xaml
        Data              = Import-TdData
        Random            = New-Object System.Random
        FocusMode         = $false
        Compact           = $false
        NormalBounds      = $null
        Drawer            = $null
        DoneExpanded      = $true
        EditingId         = $null
        NoteOpen          = $false
        AddMinutes        = $null
        AddCategory       = $null
        HintMinutes       = $null
        RowRefs           = @{}
        StructureKey      = ''
        TimeUpKey         = ''
        ChimeTaskId       = ''
        ChimeIndex        = -1
        LastHeartbeat     = 0
        LastThemeCheck    = 0
        LastMinuteKey     = ''
        DarkActive        = $false
        ToastAction       = $null
        ToastUntil        = 0
        ConfettiCleanupAt = 0
        Dragging          = $false
        DragStart         = $null
        DragId            = $null
        Jobs              = [System.Collections.Generic.List[object]]::new()
        ImportItems       = @()
        ImportChecks      = @()
        ImportBusy        = $false
        Quitting          = $false
        Instance          = $null
        Tray              = $null
        TrayHintShown     = $false
        NoteSaveAt        = 0
        SettingsSaveAt    = 0
        PendingRender     = $false
        PendingDrop       = $null
        ToastData         = $null
        Timer             = $null
        Stopped           = $false
    }
    $ui = $script:Td.Ui

    try {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri](Join-Path $assets 'TDfocus.ico'))
        $ui.LogoImage.Source = New-Object System.Windows.Media.Imaging.BitmapImage ([Uri](Join-Path $assets 'TDfocus.png'))
    }
    catch { Write-TdLog "Icône introuvable : $($_.Exception.Message)" }

    $now = Get-TdNowMs
    $state = $script:Td.Data.state
    $paused = Repair-TdStaleTimer -State $state -NowMs $now
    [void](Invoke-TdDayRollover -State $state -NowMs $now)
    Sync-TdState $state $now
    $script:Td.Data.history = [System.Collections.Generic.List[object]]::new([object[]](Limit-TdHistory -History $script:Td.Data.history -NowMs $now))
    $current = Get-TdCurrentTask $state
    if ($current -and (Get-TdRemainingMs $current $now) -le 0) { $script:Td.TimeUpKey = "$($current.id)|$($current.plannedMs)" }
    Save-TdStateNow

    Register-TdMainEvents
    Update-TdThemeNow
    Build-TdAddBarChips
    Update-TdView
    if ($null -ne $paused) {
        Show-TdToast -Text ("Minuteur mis en pause à {0}, quand TDfocus s'est fermé." -f (Format-TdClock $paused)) -Seconds 8
    }
}

function Save-TdStateNow {
    try {
        $script:Td.Data.state.lastSeenMs = Get-TdNowMs
        Save-TdState $script:Td.Data.state
    }
    catch { Write-TdLog "Sauvegarde de la liste impossible : $($_.Exception.Message)" }
}

function Save-TdSettingsNow {
    try {
        Save-TdSettings $script:Td.Data.settings
        $script:Td.SettingsSaveAt = 0
    }
    catch { Write-TdLog "Sauvegarde des réglages impossible : $($_.Exception.Message)" }
}

function Request-TdSettingsSave {
    # Pour les curseurs : sauvegarde groupée une seconde plus tard.
    $script:Td.SettingsSaveAt = (Get-TdNowMs) + 1000
}

function Save-TdHistoryNow {
    try { Save-TdHistory $script:Td.Data.history } catch { Write-TdLog "Sauvegarde de l'historique impossible : $($_.Exception.Message)" }
}

function Complete-TdChange {
    # À appeler après toute modification de la file. -Replan : nouveau plan de référence.
    param([switch]$Replan)
    $now = Get-TdNowMs
    $state = $script:Td.Data.state
    Sync-TdState $state $now
    if ($Replan) { Update-TdPlanBaseline -State $state -NowMs $now }
    Save-TdStateNow
    Update-TdView
}

# ---------------------------------------------------------------- thème

function Update-TdThemeNow {
    $dark = Test-TdDarkActive $script:Td.Data.settings
    $script:Td.DarkActive = $dark
    Set-TdTheme -Window $script:Td.Window -Dark $dark
    $icon = [string][char]0xE706
    if ($dark) { $icon = [string][char]0xE708 }
    $script:Td.Ui.BtnTheme.Content = $icon
    $script:Td.LastThemeCheck = Get-TdNowMs
}

function Switch-TdTheme {
    $settings = $script:Td.Data.settings
    if ($script:Td.DarkActive) { $settings.theme = 'light' } else { $settings.theme = 'dark' }
    Save-TdSettingsNow
    Update-TdThemeNow
    Update-TdView
    if ($script:Td.Drawer -eq 'settings') { Update-TdDrawer }
}

# ---------------------------------------------------------------- actions

function Get-TdSettings { $script:Td.Data.settings }
function Get-TdState { $script:Td.Data.state }

function Add-TdTaskFromInput {
    $ui = $script:Td.Ui
    $text = $ui.NewTaskBox.Text
    $parsed = ConvertFrom-TdQuickInput $text
    if (-not $parsed.title) {
        $ui.NewTaskBox.Focus() | Out-Null
        return
    }
    $settings = Get-TdSettings
    $minutes = $parsed.minutes
    if (-not $minutes) { $minutes = $script:Td.AddMinutes }
    if (-not $minutes) { $minutes = $settings.defaultMinutes }
    $fixed = $parsed.fixedStart
    $fixedText = $ui.FixedTimeBox.Text.Trim()
    if (-not $fixed -and $fixedText) {
        $fixed = ConvertTo-TdClockText $fixedText
        if (-not $fixed) {
            Show-TdToast -Text "Heure fixe non reconnue : utilise le format 14:30 (ou laisse vide)."
            $ui.FixedTimeBox.Focus() | Out-Null
            return
        }
    }
    $now = Get-TdNowMs
    $task = New-TdTask -Title $parsed.title -Minutes ([double]$minutes) -CategoryId $script:Td.AddCategory -FixedStart $fixed -NowMs $now
    Add-TdTask -State (Get-TdState) -Task $task -NowMs $now
    $ui.NewTaskBox.Text = ''
    $ui.FixedTimeBox.Text = ''
    $script:Td.HintMinutes = $null
    Reset-TdAddBarSelection
    Complete-TdChange -Replan
    $ui.NewTaskBox.Focus() | Out-Null
}

function Switch-TdTimerNow {
    $state = Get-TdState
    if (-not (Get-TdCurrentTask $state)) { return }
    Switch-TdTimer -State $state -NowMs (Get-TdNowMs)
    Complete-TdChange
}

function Complete-TdCurrentNow {
    param([string]$Id)
    $state = Get-TdState
    $settings = Get-TdSettings
    $now = Get-TdNowMs
    $isCurrent = (-not $Id) -or ($state.tasks.Count -gt 0 -and $state.tasks[0].id -eq $Id)
    $done = Complete-TdTask -State $state -Id $Id -NowMs $now -KeepRunning:([bool]$settings.autoStartNext)
    if (-not $done) { return }
    $script:Td.Data.history.Add((New-TdHistoryEntry $done))
    Save-TdHistoryNow
    if ($script:Td.EditingId -eq $done.id) { $script:Td.EditingId = $null }
    if ($isCurrent) { $script:Td.NoteOpen = $false }
    if ($settings.completionSound) { Invoke-TdSoundEffect -Name 'complete' -Volume $settings.effectsVolume }
    $origin = $null
    if ($isCurrent) {
        $origin = $script:Td.Ui.BtnDone
        if ($script:Td.Compact) { $origin = $script:Td.Ui.CompactDone }
    }
    Complete-TdChange
    Invoke-TdConfetti -Origin $origin
    $message = '« {0} » terminée. Bravo !' -f (Limit-TdText $done.title 40)
    if ($state.tasks.Count -eq 0) { $message = 'Liste terminée. Bravo, tu peux souffler !' }
    Show-TdToast -Text $message -ActionText 'Annuler' -Data @{ Id = $done.id } -Action {
        param($d)
        Undo-TdCompleteNow -Id $d.Id
    }
}

function Undo-TdCompleteNow {
    param([Parameter(Mandatory)][string]$Id)
    $restored = Undo-TdComplete -State (Get-TdState) -Id $Id -NowMs (Get-TdNowMs)
    if (-not $restored) { return }
    $history = $script:Td.Data.history
    for ($i = $history.Count - 1; $i -ge 0; $i--) { if ($history[$i].id -eq $Id) { $history.RemoveAt($i) } }
    Save-TdHistoryNow
    Hide-TdToast
    Complete-TdChange
}

function Add-TdTimeNow {
    param([Parameter(Mandatory)][int]$Minutes)
    $state = Get-TdState
    if (-not (Get-TdCurrentTask $state)) { return }
    Add-TdPlannedTime -State $state -DeltaMs ([long]$Minutes * 60000)
    Complete-TdChange -Replan
}

function Move-TdCurrentLater {
    $state = Get-TdState
    $current = Get-TdCurrentTask $state
    if (-not $current -or $state.tasks.Count -lt 2) {
        Show-TdToast -Text "C'est la seule tâche de la liste : rien à reporter."
        return
    }
    Move-TdTaskToEnd -State $state -Id $current.id -NowMs (Get-TdNowMs)
    $script:Td.NoteOpen = $false
    Complete-TdChange -Replan
    Show-TdToast -Text ('« {0} » reportée en fin de liste.' -f (Limit-TdText $current.title 40))
}

function Switch-TdTimerMode {
    $settings = Get-TdSettings
    if ($settings.timerMode -eq 'countdown') { $settings.timerMode = 'countup' } else { $settings.timerMode = 'countdown' }
    Save-TdSettingsNow
    Update-TdView
}

function Remove-TdTaskNow {
    param([Parameter(Mandatory)][string]$Id)
    $state = Get-TdState
    $found = Find-TdTask $state $Id
    if (-not $found) { return }
    $index = $found.index
    $list = $found.list
    $task = Remove-TdTask -State $state -Id $Id -NowMs (Get-TdNowMs)
    if ($script:Td.EditingId -eq $Id) { $script:Td.EditingId = $null }
    Complete-TdChange -Replan
    Show-TdToast -Text ('« {0} » supprimée.' -f (Limit-TdText $task.title 40)) -ActionText 'Annuler' -Data @{ Task = $task; Index = $index; List = $list } -Action {
        param($d)
        $s = $script:Td.Data.state
        if ($d.List -eq 'done') { $s.done.Insert([Math]::Min($d.Index, $s.done.Count), $d.Task) }
        else { $s.tasks.Insert([Math]::Min($d.Index, $s.tasks.Count), $d.Task) }
        Complete-TdChange -Replan
    }
}

function Clear-TdListNow {
    $state = Get-TdState
    if ($state.tasks.Count -eq 0) { return }
    Suspend-TdTimer -State $state -NowMs (Get-TdNowMs)
    $backup = @($state.tasks)
    Clear-TdPending -State $state
    $script:Td.EditingId = $null
    Complete-TdChange -Replan
    Show-TdToast -Text 'Liste effacée.' -ActionText 'Annuler' -Data @{ Tasks = $backup } -Action {
        param($d)
        $s = $script:Td.Data.state
        foreach ($t in $d.Tasks) { $s.tasks.Add($t) }
        Complete-TdChange -Replan
    }
}

function Start-TdTaskNowById {
    param([Parameter(Mandatory)][string]$Id)
    Start-TdTaskNow -State (Get-TdState) -Id $Id -NowMs (Get-TdNowMs)
    $script:Td.NoteOpen = $false
    Complete-TdChange -Replan
}

function Move-TdTaskRelative {
    param([Parameter(Mandatory)][string]$DraggedId, [string]$TargetId, [bool]$Before, [switch]$ToEnd, [switch]$ToFront)
    $state = Get-TdState
    $from = Find-TdTask $state $DraggedId
    if (-not $from -or $from.list -ne 'tasks') { return }
    if ($ToFront) { $to = 0 }
    elseif ($ToEnd -or -not $TargetId) { $to = $state.tasks.Count - 1 }
    else {
        $target = Find-TdTask $state $TargetId
        if (-not $target -or $target.list -ne 'tasks') { return }
        $to = $target.index
        if (-not $Before) { $to++ }
        if ($from.index -lt $to) { $to-- }
    }
    if ($to -eq $from.index) { return }
    Move-TdTask -State $state -From $from.index -To $to -NowMs (Get-TdNowMs)
    Complete-TdChange -Replan
}

function Add-TdTemplateNow {
    param([Parameter(Mandatory)]$Template)
    $now = Get-TdNowMs
    $state = Get-TdState
    $tasks = ConvertTo-TdTasksFromTemplate -Template $Template -NowMs $now
    $ids = @()
    foreach ($t in $tasks) {
        Add-TdTask -State $state -Task $t -NowMs $now
        $ids += $t.id
    }
    Complete-TdChange -Replan
    Show-TdToast -Text ('Routine « {0} » ajoutée ({1} tâches).' -f $Template.name, $ids.Count) -ActionText 'Annuler' -Data @{ Ids = $ids } -Action {
        param($d)
        $s = $script:Td.Data.state
        foreach ($id in $d.Ids) { [void](Remove-TdTask -State $s -Id $id -NowMs (Get-TdNowMs)) }
        Complete-TdChange -Replan
    }
}

function Limit-TdText {
    param([string]$Text, [int]$Max = 40)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    $Text.Substring(0, $Max - 1) + [char]0x2026
}

# ---------------------------------------------------------------- modes d'affichage

function Set-TdFocusMode {
    param([bool]$Enabled)
    $ui = $script:Td.Ui
    $script:Td.FocusMode = $Enabled
    $collapsed = [System.Windows.Visibility]::Collapsed
    $visible = [System.Windows.Visibility]::Visible
    if ($Enabled) {
        Close-TdDrawer
        $ui.AddBar.Visibility = $collapsed
        $ui.ListScroll.Visibility = $collapsed
        foreach ($name in @('BtnSounds', 'BtnTemplates', 'BtnStats', 'BtnImport', 'BtnSettings', 'BtnTheme')) { $ui[$name].Visibility = $collapsed }
        $ui.MainColumn.RowDefinitions[0].Height = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        $ui.MainColumn.RowDefinitions[2].Height = New-Object System.Windows.GridLength 0
        $ui.FocusCard.VerticalAlignment = 'Center'
        $ui.FocusCard.MaxWidth = 860
        $ui.MainColumn.Margin = New-Object System.Windows.Thickness 24, 8, 24, 40
        $ui.BtnFocusMode.Content = [string][char]0xE73F
        $ui.BtnFocusMode.ToolTip = 'Quitter le mode focus (Échap)'
    }
    else {
        $ui.AddBar.Visibility = $visible
        $ui.ListScroll.Visibility = $visible
        foreach ($name in @('BtnSounds', 'BtnTemplates', 'BtnStats', 'BtnImport', 'BtnSettings', 'BtnTheme')) { $ui[$name].Visibility = $visible }
        $ui.MainColumn.RowDefinitions[0].Height = [System.Windows.GridLength]::Auto
        $ui.MainColumn.RowDefinitions[2].Height = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        $ui.FocusCard.VerticalAlignment = 'Stretch'
        $ui.FocusCard.MaxWidth = [double]::PositiveInfinity
        $ui.MainColumn.Margin = New-Object System.Windows.Thickness 24, 8, 24, 0
        $ui.BtnFocusMode.Content = [string][char]0xE740
        $ui.BtnFocusMode.ToolTip = 'Mode focus (F)'
    }
    Update-TdResponsiveLayout
    Update-TdView
}

function Set-TdCompactMode {
    param([bool]$Enabled)
    $w = $script:Td.Window
    $ui = $script:Td.Ui
    if ($Enabled -eq $script:Td.Compact) { return }
    $script:Td.Compact = $Enabled
    if ($Enabled) {
        if ($w.WindowState -eq 'Maximized') { $w.WindowState = 'Normal' }
        $script:Td.NormalBounds = @{ Left = $w.Left; Top = $w.Top; Width = $w.Width; Height = $w.Height; MinWidth = $w.MinWidth; MinHeight = $w.MinHeight }
        Hide-TdToast
        $ui.MainRoot.Visibility = 'Collapsed'
        $ui.CompactRoot.Visibility = 'Visible'
        $w.MinWidth = 0; $w.MinHeight = 0
        $w.WindowStyle = 'ToolWindow'
        $w.ResizeMode = 'NoResize'
        $w.Width = 420; $w.Height = 112
        $area = [System.Windows.SystemParameters]::WorkArea
        $w.Left = $area.Right - $w.Width - 24
        $w.Top = $area.Bottom - $w.Height - 24
        $w.Topmost = [bool]$script:Td.Data.settings.compactTopmost
    }
    else {
        $b = $script:Td.NormalBounds
        $ui.CompactRoot.Visibility = 'Collapsed'
        $ui.MainRoot.Visibility = 'Visible'
        $w.Topmost = $false
        $w.WindowStyle = 'SingleBorderWindow'
        $w.ResizeMode = 'CanResize'
        if ($b) {
            $w.MinWidth = $b.MinWidth; $w.MinHeight = $b.MinHeight
            $w.Width = $b.Width; $w.Height = $b.Height
            $w.Left = $b.Left; $w.Top = $b.Top
        }
    }
    Update-TdView
}

function Show-TdWindow {
    $w = $script:Td.Window
    if (-not $w.IsVisible) { $w.Show() }
    if ($w.WindowState -eq 'Minimized') { $w.WindowState = 'Normal' }
    [void]$w.Activate()
    if (-not $w.Topmost) {
        $w.Topmost = $true
        $w.Topmost = $false
    }
}

# ---------------------------------------------------------------- rendu principal

function Update-TdView {
    if ($script:Td.Dragging) { $script:Td.PendingRender = $true; return }
    $now = Get-TdNowMs
    $schedule = Get-TdSchedule -State (Get-TdState) -NowMs $now
    Update-TdFocusCard -NowMs $now -Schedule $schedule
    Update-TdHeader -NowMs $now -Schedule $schedule
    Update-TdUpNext -NowMs $now -Schedule $schedule
    Update-TdDoneList
    Update-TdCompact -NowMs $now -Schedule $schedule
    Update-TdTrayMenu
    if ($script:Td.Drawer -eq 'stats') { Update-TdDrawer }
}

function Get-TdStructureKey {
    # Ce qui impose de reconstruire la liste (et pas seulement de mettre à jour les heures).
    param($Schedule)
    $state = Get-TdState
    $parts = foreach ($t in $state.tasks) { '{0}:{1}:{2}:{3}:{4}' -f $t.id, $t.title, $t.plannedMs, $t.categoryId, $t.fixedStart }
    $flags = foreach ($it in $Schedule.items) { '{0}{1}' -f [int]($it.gapMs -ge 60000), [int]($it.lateMs -gt 0) }
    ($parts -join '|') + '#' + ($flags -join '') + '#' + $script:Td.EditingId + '#' + $state.done.Count
}

function Update-TdFocusCard {
    param([long]$NowMs, $Schedule)
    $ui = $script:Td.Ui
    $state = Get-TdState
    $settings = Get-TdSettings
    $current = Get-TdCurrentTask $state
    if (-not $current) {
        $ui.FocusActive.Visibility = 'Collapsed'
        $ui.FocusEmpty.Visibility = 'Visible'
        if ($state.done.Count -gt 0) {
            $focusMs = [long]0
            foreach ($t in $state.done) { $focusMs += [long]$t.elapsedMs }
            $ui.EmptyEmoji.Text = [char]::ConvertFromUtf32(0x1F389)
            $ui.EmptyTitle.Text = 'Liste terminée !'
            $plural = ''
            if ($state.done.Count -gt 1) { $plural = 's' }
            $ui.EmptyText.Text = ("{0} tâche{1} terminée{1} aujourd'hui, {2} de concentration. Prends une vraie pause, tu l'as méritée." -f $state.done.Count, $plural, (Format-TdDurationMs $focusMs))
        }
        else {
            $ui.EmptyEmoji.Text = [char]::ConvertFromUtf32(0x1F331)
            $ui.EmptyTitle.Text = "Qu'est-ce qui compte maintenant ?"
            $ui.EmptyText.Text = 'Ajoute une première tâche avec sa durée, ou charge une routine. Une seule chose à la fois.'
        }
        $ui.BtnEmptyTemplates.Visibility = 'Visible'
        if ($script:Td.FocusMode) { $ui.BtnEmptyTemplates.Visibility = 'Collapsed' }
        return
    }
    $ui.FocusActive.Visibility = 'Visible'
    $ui.FocusEmpty.Visibility = 'Collapsed'

    $ui.CurrentTitle.Text = $current.title
    $category = Get-TdCategory $settings $current.categoryId
    if ($category) {
        $ui.CurrentCategory.Visibility = 'Visible'
        $ui.CurrentCategoryText.Text = '{0}  {1}' -f $category.emoji, $category.name
        $brush = Get-TdCategoryBrush $category $script:Td.DarkActive
        if ($brush) { $ui.CurrentCategory.Background = $brush }
    }
    else {
        $ui.CurrentCategory.Visibility = 'Collapsed'
    }

    $running = $null -ne $current.runningSince
    $elapsed = Get-TdElapsedMs $current $NowMs
    $remaining = [long]$current.plannedMs - $elapsed
    $overtime = $remaining -lt 0
    if ($running) { $ui.CurrentState.Text = 'En cours' }
    elseif ($elapsed -gt 0) { $ui.CurrentState.Text = 'En pause' }
    else { $ui.CurrentState.Text = 'Pas encore commencée' }

    $planned = [double][Math]::Max(1, $current.plannedMs)
    if ($settings.timerMode -eq 'countup') {
        $ui.TimerText.Text = Format-TdTimer $elapsed
        $ui.TimerSub.Text = 'sur ' + (Format-TdDurationMs $current.plannedMs)
        $fraction = [Math]::Min(1.0, $elapsed / $planned)
        $ui.TimerModeText.Text = 'Compte progressif'
    }
    else {
        if ($overtime) {
            $ui.TimerText.Text = '+' + (Format-TdTimer (-$remaining))
            $ui.TimerSub.Text = 'temps additionnel'
        }
        else {
            $ui.TimerText.Text = Format-TdCountdown $remaining
            $ui.TimerSub.Text = 'restant'
        }
        $fraction = [Math]::Max(0.0, $remaining / $planned)
        $ui.TimerModeText.Text = 'Compte à rebours'
    }
    if ($overtime) {
        $fraction = 1.0
        $ui.RingArc.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'OvertimeBrush')
        $ui.TimerText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'OvertimeBrush')
    }
    else {
        $ui.RingArc.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'AccentBrush')
        $ui.TimerText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextBrush')
    }
    $ui.RingArc.Data = Get-TdArcGeometry -Size $ui.RingHost.Width -Thickness 12 -Fraction $fraction

    # Ancrage temporel de la tâche
    $item = $null
    if ($Schedule.items.Count -gt 0) { $item = $Schedule.items[0] }
    $meta = 'Fin prévue à {0}  ·  prévu {1}' -f (Format-TdClock $item.endMs), (Format-TdDurationMs $current.plannedMs)
    if ($item.gapMs -ge 60000 -and -not $running) {
        $meta = 'Créneau à {0} (dans {1})  ·  prévu {2}' -f $current.fixedStart, (Format-TdDurationMs $item.gapMs), (Format-TdDurationMs $current.plannedMs)
    }
    $ui.CurrentMeta.Text = $meta
    if ($overtime) {
        $ui.OvertimeHint.Text = "Temps additionnel : la fin de la liste glisse à $(Format-TdClock $Schedule.endMs). Aucune urgence, valide quand c'est bon."
        $ui.OvertimeHint.Visibility = 'Visible'
    }
    else {
        $ui.OvertimeHint.Visibility = 'Collapsed'
    }
    if ($script:Td.FocusMode -and $state.tasks.Count -gt 1) {
        $next = $state.tasks[1]
        $ui.NextLine.Text = 'Ensuite : {0} ({1})  ·  liste finie à {2}' -f $next.title, (Format-TdDurationMs $next.plannedMs), (Format-TdClock $Schedule.endMs)
        $ui.NextLine.Visibility = 'Visible'
    }
    else {
        $ui.NextLine.Visibility = 'Collapsed'
    }

    if ($running) {
        $ui.StartPauseIcon.Text = [string][char]0xE769
        $ui.StartPauseText.Text = 'Pause'
    }
    else {
        $ui.StartPauseIcon.Text = [string][char]0xE768
        if ($elapsed -gt 0) { $ui.StartPauseText.Text = 'Reprendre' } else { $ui.StartPauseText.Text = 'Démarrer' }
    }
    $noteLabel = 'Note'
    if ($current.note) { $noteLabel = 'Note ' + [char]0x2022 }
    $ui.TaskNoteText.Text = $noteLabel
    if ($script:Td.NoteOpen) {
        $ui.TaskNoteBox.Visibility = 'Visible'
        if ($ui.TaskNoteBox.Tag -ne $current.id) {
            $ui.TaskNoteBox.Tag = $current.id
            $ui.TaskNoteBox.Text = $current.note
        }
    }
    else {
        $ui.TaskNoteBox.Visibility = 'Collapsed'
        $ui.TaskNoteBox.Tag = $null
    }
}

function Update-TdHeader {
    param([long]$NowMs, $Schedule)
    $ui = $script:Td.Ui
    $state = Get-TdState
    $ui.ClockText.Text = Format-TdClock $NowMs
    if ($Schedule.count -eq 0) {
        $ui.EndLabel.Text = 'Aucune tâche prévue'
        $ui.EndTime.Visibility = 'Collapsed'
        $ui.DriftBadge.Visibility = 'Collapsed'
        $ui.EndPill.ToolTip = $null
    }
    else {
        $ui.EndLabel.Text = 'Fin de la liste'
        $ui.EndTime.Text = Format-TdClock $Schedule.endMs
        $ui.EndTime.Visibility = 'Visible'
        $ui.EndPill.ToolTip = 'Heure à laquelle toute la liste sera terminée ({0} de travail restant). Recalculée en continu.' -f (Format-TdDurationMs $Schedule.remainingMs)
        $drift = Get-TdDriftMs -State $state -Schedule $Schedule
        $driftMin = [long][Math]::Round($drift / 60000)
        if ([Math]::Abs($driftMin) -ge 1) {
            $ui.DriftBadge.Visibility = 'Visible'
            if ($driftMin -gt 0) {
                $ui.DriftText.Text = '+{0} min' -f $driftMin
                $ui.DriftBadge.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'OvertimeSoftBrush')
                $ui.DriftText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'OvertimeBrush')
                $ui.DriftBadge.ToolTip = 'Décalage dû aux dépassements et aux pauses depuis ta dernière modification du plan.'
            }
            else {
                $ui.DriftText.Text = '{0} min' -f $driftMin
                $ui.DriftBadge.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'SuccessSoftBrush')
                $ui.DriftText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'SuccessTextBrush')
                $ui.DriftBadge.ToolTip = 'En avance sur ton plan.'
            }
        }
        else {
            $ui.DriftBadge.Visibility = 'Collapsed'
        }
    }

    # Titre de fenêtre et info-bulle de la zone de notification : le temps reste visible partout.
    $current = Get-TdCurrentTask $state
    $title = 'TDfocus'
    $tip = 'TDfocus'
    if ($current) {
        $remaining = Get-TdRemainingMs $current $NowMs
        if ($remaining -lt 0) { $clock = '+' + (Format-TdTimer (-$remaining)) } else { $clock = Format-TdCountdown $remaining }
        if ($null -ne $current.runningSince) {
            $title = '{0} · {1} — TDfocus' -f $clock, $current.title
            $tip = '{0} · {1}' -f $clock, $current.title
        }
        else {
            $title = '{0} (en pause) — TDfocus' -f $current.title
            $tip = 'En pause · {0}' -f $current.title
        }
    }
    if ($script:Td.Window.Title -ne $title) { $script:Td.Window.Title = $title }
    if ($script:Td.Tray) {
        $tip = Limit-TdText $tip 63
        if ($script:Td.Tray.Icon.Text -ne $tip) { $script:Td.Tray.Icon.Text = $tip }
    }
}

function Update-TdCompact {
    param([long]$NowMs, $Schedule)
    if (-not $script:Td.Compact) { return }
    $ui = $script:Td.Ui
    $state = Get-TdState
    $settings = Get-TdSettings
    $current = Get-TdCurrentTask $state
    if (-not $current) {
        $ui.CompactTitle.Text = 'Liste terminée'
        $ui.CompactTimer.Text = '—'
        $ui.CompactMeta.Text = ''
        $ui.CompactArc.Data = [System.Windows.Media.Geometry]::Empty
        return
    }
    $elapsed = Get-TdElapsedMs $current $NowMs
    $remaining = [long]$current.plannedMs - $elapsed
    $planned = [double][Math]::Max(1, $current.plannedMs)
    $ui.CompactTitle.Text = $current.title
    if ($settings.timerMode -eq 'countup') {
        $ui.CompactTimer.Text = Format-TdTimer $elapsed
        $fraction = [Math]::Min(1.0, $elapsed / $planned)
    }
    elseif ($remaining -lt 0) {
        $ui.CompactTimer.Text = '+' + (Format-TdTimer (-$remaining))
        $fraction = 1.0
    }
    else {
        $ui.CompactTimer.Text = Format-TdCountdown $remaining
        $fraction = [Math]::Max(0.0, $remaining / $planned)
    }
    if ($remaining -lt 0) { $key = 'OvertimeBrush' } else { $key = 'AccentBrush' }
    $ui.CompactArc.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, $key)
    $ui.CompactArc.Data = Get-TdArcGeometry -Size 54 -Thickness 5 -Fraction $fraction
    $ui.CompactMeta.Text = 'fin {0} · liste {1}' -f (Format-TdClock $Schedule.items[0].endMs), (Format-TdClock $Schedule.endMs)
    if ($null -ne $current.runningSince) { $ui.CompactStartPause.Content = [string][char]0xE769 } else { $ui.CompactStartPause.Content = [string][char]0xE768 }
}

# ---------------------------------------------------------------- saisie rapide

function Build-TdAddBarChips {
    $ui = $script:Td.Ui
    $settings = Get-TdSettings
    $ui.DurationChips.Children.Clear()
    foreach ($m in $script:TdPresetMinutes) {
        $chip = New-TdChip -Content "$m min" -Tag $m -ToolTip "Durée estimée : $m minutes" -OnClick {
            $minutes = [int]$this.Tag
            if ($this.IsChecked) {
                foreach ($c in $script:Td.Ui.DurationChips.Children) { if ($c -ne $this) { $c.IsChecked = $false } }
                $script:Td.AddMinutes = $minutes
            }
            else {
                $script:Td.AddMinutes = $null
            }
            $script:Td.HintMinutes = $null
            Update-TdEstimateHint
        }
        [void]$ui.DurationChips.Children.Add($chip)
    }
    $ui.CategoryChips.Children.Clear()
    foreach ($cat in $settings.categories) {
        $chip = New-TdChip -Content ('{0} {1}' -f $cat.emoji, $cat.name) -Tag $cat.id -ToolTip "Catégorie : $($cat.name)" -OnClick {
            if ($this.IsChecked) {
                foreach ($c in $script:Td.Ui.CategoryChips.Children) { if ($c -ne $this) { $c.IsChecked = $false } }
                $script:Td.AddCategory = [string]$this.Tag
            }
            else {
                $script:Td.AddCategory = $null
            }
            Update-TdEstimateHint
        }
        [void]$ui.CategoryChips.Children.Add($chip)
    }
    Reset-TdAddBarSelection
}

function Reset-TdAddBarSelection {
    $ui = $script:Td.Ui
    $default = [int](Get-TdSettings).defaultMinutes
    $script:Td.AddMinutes = $null
    foreach ($c in $ui.DurationChips.Children) {
        $c.IsChecked = ([int]$c.Tag -eq $default)
        if ($c.IsChecked) { $script:Td.AddMinutes = $default }
    }
    $script:Td.AddCategory = $null
    foreach ($c in $ui.CategoryChips.Children) { $c.IsChecked = $false }
    Update-TdEstimateHint
}

function Update-TdEstimateHint {
    $ui = $script:Td.Ui
    $settings = Get-TdSettings
    $ui.EstimateHint.Visibility = 'Collapsed'
    if (-not $settings.showEstimateHints) { return }
    $parsed = ConvertFrom-TdQuickInput $ui.NewTaskBox.Text
    if (-not $parsed.title) { return }
    $minutes = $parsed.minutes
    if (-not $minutes) { $minutes = $script:Td.AddMinutes }
    if (-not $minutes) { $minutes = $settings.defaultMinutes }
    $hint = Get-TdEstimateHint -History $script:Td.Data.history -Minutes ([double]$minutes) -CategoryId $script:Td.AddCategory -NowMs (Get-TdNowMs)
    if (-not $hint -or $hint.minutes -eq [int]$minutes) { return }
    $script:Td.HintMinutes = $hint.minutes
    $scope = 'tes tâches'
    if ($hint.scope -eq 'category') { $scope = 'cette catégorie' }
    $ui.EstimateHint.Text = ("{0} D'après ton historique pour {1}, cela prend plutôt ~{2} (×{3:0.0#}). Cliquer pour l'utiliser." -f [char]::ConvertFromUtf32(0x1F4A1), $scope, (Format-TdMinutes $hint.minutes), $hint.ratio)
    $ui.EstimateHint.Visibility = 'Visible'
}

function Use-TdEstimateHint {
    $minutes = $script:Td.HintMinutes
    if (-not $minutes) { return }
    $ui = $script:Td.Ui
    $parsed = ConvertFrom-TdQuickInput $ui.NewTaskBox.Text
    $title = $parsed.title
    if ($parsed.fixedStart) { $title += " @$($parsed.fixedStart)" }
    $ui.NewTaskBox.Text = '{0} {1}min' -f $title, $minutes
    $ui.NewTaskBox.CaretIndex = $ui.NewTaskBox.Text.Length
    foreach ($c in $ui.DurationChips.Children) { $c.IsChecked = $false }
    $script:Td.AddMinutes = $minutes
    $ui.EstimateHint.Visibility = 'Collapsed'
    $ui.NewTaskBox.Focus() | Out-Null
}

# ---------------------------------------------------------------- minuteur

function Invoke-TdTick {
    $now = Get-TdNowMs
    $state = Get-TdState
    $settings = Get-TdSettings

    # Changement de jour
    if ((Get-TdDayKey $now) -ne $state.dayKey) {
        [void](Invoke-TdDayRollover -State $state -NowMs $now)
        Save-TdStateNow
        Update-TdView
    }

    $current = Get-TdCurrentTask $state
    if ($current -and $null -ne $current.runningSince) {
        $elapsed = Get-TdElapsedMs $current $now
        $remaining = [long]$current.plannedMs - $elapsed
        # Fin du temps prévu : signal doux, une seule fois, jamais bloquant.
        $key = "$($current.id)|$($current.plannedMs)"
        if ($remaining -le 0 -and $script:Td.TimeUpKey -ne $key) {
            $script:Td.TimeUpKey = $key
            if ($settings.timeUpSignal) { Invoke-TdSoundEffect -Name 'timeup' -Volume $settings.effectsVolume }
            if ($settings.notifications -and -not $script:Td.Window.IsActive) {
                Show-TdTrayBalloon -Text ("Le temps prévu pour « {0} » est écoulé. Continue tranquillement ou valide quand c'est bon." -f (Limit-TdText $current.title 60))
            }
        }
        # Carillon périodique pour sortir de la rêverie.
        $every = [int]$settings.chimeEveryMin
        if ($every -gt 0) {
            $index = [long][Math]::Floor($elapsed / ($every * 60000.0))
            if ($script:Td.ChimeTaskId -ne $current.id) {
                $script:Td.ChimeTaskId = $current.id
                $script:Td.ChimeIndex = $index
            }
            elseif ($index -gt $script:Td.ChimeIndex) {
                $script:Td.ChimeIndex = $index
                Invoke-TdSoundEffect -Name 'chime' -Volume $settings.chimeVolume
            }
        }
    }

    $schedule = Get-TdSchedule -State $state -NowMs $now
    Update-TdFocusCard -NowMs $now -Schedule $schedule
    Update-TdHeader -NowMs $now -Schedule $schedule
    Update-TdCompact -NowMs $now -Schedule $schedule
    if (-not $script:Td.Dragging) {
        if ((Get-TdStructureKey $schedule) -ne $script:Td.StructureKey -and -not $script:Td.EditingId) {
            Update-TdUpNext -NowMs $now -Schedule $schedule
        }
        else {
            Update-TdRowTimes -Schedule $schedule
        }
    }

    # Sauvegardes différées et battement de cœur (sert à détecter un PC éteint).
    if ($script:Td.NoteSaveAt -gt 0 -and $now -ge $script:Td.NoteSaveAt) { $script:Td.NoteSaveAt = 0; Save-TdStateNow }
    if ($script:Td.SettingsSaveAt -gt 0 -and $now -ge $script:Td.SettingsSaveAt) { Save-TdSettingsNow }
    if ($now - $script:Td.LastHeartbeat -ge 60000) { $script:Td.LastHeartbeat = $now; Save-TdStateNow }
    if ($settings.theme -eq 'system' -and $now - $script:Td.LastThemeCheck -ge 30000) {
        $dark = Test-TdSystemDarkTheme
        $script:Td.LastThemeCheck = $now
        if ($dark -ne $script:Td.DarkActive) { Update-TdThemeNow; Update-TdView }
    }
    if ($script:Td.ToastUntil -gt 0 -and $now -ge $script:Td.ToastUntil) { Hide-TdToast }
    if ($script:Td.ConfettiCleanupAt -gt 0 -and $now -ge $script:Td.ConfettiCleanupAt) {
        $script:Td.ConfettiCleanupAt = 0
        $script:Td.Ui.ConfettiLayer.Children.Clear()
    }
    if ($script:Td.Instance -and $script:Td.Instance.ShowEvent.WaitOne(0)) {
        if ($script:Td.Compact) { Set-TdCompactMode $false }
        Show-TdWindow
    }
    Update-TdJobs
    $preparing = 0
    if ($script:TdAudio) { $preparing = $script:TdAudio.Jobs.Count }
    Update-TdAudio
    if ($script:TdAudio -and $script:TdAudio.Jobs.Count -lt $preparing -and $script:Td.Drawer -eq 'sounds') { Update-TdDrawer }
}

function Update-TdJobs {
    # Tâches réseau en arrière-plan (imports) : on récupère les résultats sur le fil de l'interface.
    $jobs = $script:Td.Jobs
    for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
        $job = $jobs[$i]
        if (-not $job.Handle.IsCompleted) { continue }
        $jobs.RemoveAt($i)
        $result = $null
        $errorText = $null
        try {
            $result = $job.PowerShell.EndInvoke($job.Handle)
            if ($job.PowerShell.Streams.Error.Count -gt 0) { $errorText = $job.PowerShell.Streams.Error[0].ToString() }
        }
        catch {
            $errorText = $_.Exception.InnerException.Message
            if (-not $errorText) { $errorText = $_.Exception.Message }
        }
        finally { $job.PowerShell.Dispose() }
        try { & $job.OnDone $result $errorText }
        catch { Write-TdLog "Fin de tâche d'arrière-plan : $($_.Exception.Message)" }
    }
}

function Start-TdBackgroundJob {
    param([Parameter(Mandatory)][string]$Script, [hashtable]$Parameters = @{}, [Parameter(Mandatory)][scriptblock]$OnDone)
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($Script)
    foreach ($k in $Parameters.Keys) { [void]$ps.AddParameter($k, $Parameters[$k]) }
    $script:Td.Jobs.Add(@{ PowerShell = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone })
}

# ---------------------------------------------------------------- événements

function Test-TdTypingTarget {
    # Vrai quand le clavier sert à autre chose qu'aux raccourcis (saisie, panneau latéral).
    $focused = [System.Windows.Input.Keyboard]::FocusedElement
    if (($focused -is [System.Windows.Controls.TextBox]) -or ($focused -is [System.Windows.Controls.PasswordBox])) { return $true }
    [bool]$script:Td.Ui.Drawer.IsKeyboardFocusWithin
}

function Register-TdMainEvents {
    $ui = $script:Td.Ui
    $w = $script:Td.Window

    $ui.BtnStartPause.Add_Click({ Switch-TdTimerNow })
    $ui.BtnDone.Add_Click({ Complete-TdCurrentNow })
    $ui.BtnPlus1.Add_Click({ Add-TdTimeNow 1 })
    $ui.BtnPlus5.Add_Click({ Add-TdTimeNow 5 })
    $ui.BtnMinus1.Add_Click({ Add-TdTimeNow -1 })
    $ui.BtnMinus5.Add_Click({ Add-TdTimeNow -5 })
    $ui.BtnLater.Add_Click({ Move-TdCurrentLater })
    $ui.BtnTimerMode.Add_Click({ Switch-TdTimerMode })
    $ui.BtnTaskNote.Add_Click({
            $script:Td.NoteOpen = -not $script:Td.NoteOpen
            Update-TdView
            if ($script:Td.NoteOpen) { $script:Td.Ui.TaskNoteBox.Focus() | Out-Null }
        })
    $ui.TaskNoteBox.Add_TextChanged({
            $id = $this.Tag
            if (-not $id) { return }
            $found = Find-TdTask (Get-TdState) ([string]$id)
            if ($found -and $found.task.note -ne $this.Text) {
                $found.task.note = $this.Text
                $script:Td.NoteSaveAt = (Get-TdNowMs) + 1000
            }
        })
    $ui.CurrentTitle.Add_MouseLeftButtonDown({
            param($s, $e)
            if ($e.ClickCount -ge 2) {
                $current = Get-TdCurrentTask (Get-TdState)
                if ($current) { Open-TdEditor $current.id }
            }
        })
    $ui.CurrentTitle.Cursor = [System.Windows.Input.Cursors]::Hand
    $ui.CurrentTitle.ToolTip = 'Double-clic pour modifier'

    $ui.BtnAdd.Add_Click({ Add-TdTaskFromInput })
    $ui.NewTaskBox.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq 'Return') { Add-TdTaskFromInput; $e.Handled = $true }
        })
    $ui.NewTaskBox.Add_TextChanged({
            $ui = $script:Td.Ui
            if ($ui.NewTaskBox.Text) { $ui.NewTaskPlaceholder.Visibility = 'Collapsed' } else { $ui.NewTaskPlaceholder.Visibility = 'Visible' }
            Update-TdEstimateHint
        })
    $ui.FixedTimeBox.Add_TextChanged({
            $ui = $script:Td.Ui
            if ($ui.FixedTimeBox.Text) { $ui.FixedTimePlaceholder.Visibility = 'Collapsed' } else { $ui.FixedTimePlaceholder.Visibility = 'Visible' }
        })
    $ui.FixedTimeBox.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq 'Return') { Add-TdTaskFromInput; $e.Handled = $true }
        })
    $ui.EstimateHint.Add_MouseLeftButtonUp({ Use-TdEstimateHint })

    $ui.BtnClearList.Add_Click({ Clear-TdListNow })
    $ui.BtnSaveAsTemplate.Add_Click({ Show-TdDrawer 'templates' -Force; Set-TdTemplateNameFocus })
    $ui.BtnEmptyTemplates.Add_Click({ Show-TdDrawer 'templates' -Force })
    $ui.BtnDoneToggle.Add_Click({
            $script:Td.DoneExpanded = -not $script:Td.DoneExpanded
            Update-TdDoneList
        })

    $ui.BtnSounds.Add_Click({ Show-TdDrawer 'sounds' })
    $ui.BtnTemplates.Add_Click({ Show-TdDrawer 'templates' })
    $ui.BtnNotes.Add_Click({ Show-TdDrawer 'notes' })
    $ui.BtnStats.Add_Click({ Show-TdDrawer 'stats' })
    $ui.BtnImport.Add_Click({ Show-TdDrawer 'import' })
    $ui.BtnSettings.Add_Click({ Show-TdDrawer 'settings' })
    $ui.BtnDrawerClose.Add_Click({ Close-TdDrawer })
    $ui.BtnTheme.Add_Click({ Switch-TdTheme })
    $ui.BtnFocusMode.Add_Click({ Set-TdFocusMode (-not $script:Td.FocusMode) })
    $ui.BtnCompact.Add_Click({ Set-TdCompactMode $true })

    $ui.CompactStartPause.Add_Click({ Switch-TdTimerNow })
    $ui.CompactDone.Add_Click({ Complete-TdCurrentNow })
    $ui.CompactExpand.Add_Click({ Set-TdCompactMode $false })
    $ui.CompactRoot.Add_MouseLeftButtonDown({
            param($s, $e)
            if ($e.OriginalSource -is [System.Windows.Controls.Primitives.ButtonBase]) { return }
            try { $script:Td.Window.DragMove() } catch { $null = $_ }
        })

    $ui.ToastAction.Add_Click({
            $action = $script:Td.ToastAction
            $data = $script:Td.ToastData
            Hide-TdToast
            if ($action) { & $action $data }
        })

    # Déposer une tâche sur la carte : elle devient la tâche en cours.
    $ui.FocusCard.Add_DragOver({
            param($s, $e)
            if ($e.Data.GetDataPresent('TDfocusTask')) { $e.Effects = 'Move' } else { $e.Effects = 'None' }
            $e.Handled = $true
        })
    $ui.FocusCard.Add_Drop({
            param($s, $e)
            if (-not $e.Data.GetDataPresent('TDfocusTask')) { return }
            $id = [string]$e.Data.GetData('TDfocusTask')
            $script:Td.PendingDrop = @{ Id = $id; Front = $true }
            $e.Handled = $true
        })
    $ui.UpNextList.AllowDrop = $true
    $ui.UpNextList.Background = [System.Windows.Media.Brushes]::Transparent
    $ui.UpNextList.Add_Drop({
            param($s, $e)
            if ($e.Handled -or -not $e.Data.GetDataPresent('TDfocusTask')) { return }
            $script:Td.PendingDrop = @{ Id = [string]$e.Data.GetData('TDfocusTask'); End = $true }
            $e.Handled = $true
        })

    $w.Add_PreviewKeyDown({
            param($s, $e)
            Invoke-TdShortcut $e
        })
    $w.Add_Closing({
            param($s, $e)
            if ($script:Td.Quitting) { return }
            if ($script:Td.Data.settings.closeToTray -and $script:Td.Tray) {
                $e.Cancel = $true
                $script:Td.Window.Hide()
                if (-not $script:Td.TrayHintShown) {
                    $script:Td.TrayHintShown = $true
                    Show-TdTrayBalloon -Text 'TDfocus continue en arrière-plan. Le minuteur tourne toujours : clique sur l''icône pour revenir.'
                }
                return
            }
            Stop-TdApp
        })
    $w.Add_SourceInitialized({ Update-TdThemeNow })
    $ui.MainColumn.Add_SizeChanged({ Update-TdResponsiveLayout })
    $w.Add_PreviewTextInput({
            param($s, $e)
            if (Test-TdTypingTarget) { return }
            switch ($e.Text) {
                '+' { Add-TdTimeNow 1; $e.Handled = $true }
                '-' { Add-TdTimeNow -1; $e.Handled = $true }
            }
        })
}

function Update-TdResponsiveLayout {
    $ui = $script:Td.Ui
    $narrow = $ui.MainColumn.ActualWidth -gt 0 -and $ui.MainColumn.ActualWidth -lt 640
    # Anneau : grand en mode focus, compact quand la carte s'empile (fenêtre étroite ou panneau ouvert).
    $ring = 210
    if ($script:Td.FocusMode) { $ring = 260 } elseif ($narrow) { $ring = 160 }
    if ($ui.RingHost.Width -ne $ring) {
        $ui.RingHost.Width = $ring
        $ui.RingHost.Height = $ring
        $ui.TimerText.FontSize = [Math]::Round($ring * 0.24)
    }
    if ($narrow) {
        [System.Windows.Controls.Grid]::SetColumn($ui.FocusDetails, 0)
        [System.Windows.Controls.Grid]::SetRow($ui.FocusDetails, 1)
        [System.Windows.Controls.Grid]::SetRow($ui.TaskNoteBox, 2)
        if ($ui.FocusActive.RowDefinitions.Count -lt 3) { $ui.FocusActive.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) }
        $ui.RingHost.Margin = New-Object System.Windows.Thickness 0, 0, 0, 16
        $ui.RingHost.HorizontalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumnSpan($ui.RingHost, 2)
        [System.Windows.Controls.Grid]::SetColumnSpan($ui.FocusDetails, 2)
    }
    else {
        [System.Windows.Controls.Grid]::SetColumn($ui.FocusDetails, 1)
        [System.Windows.Controls.Grid]::SetRow($ui.FocusDetails, 0)
        [System.Windows.Controls.Grid]::SetRow($ui.TaskNoteBox, 1)
        $ui.RingHost.Margin = New-Object System.Windows.Thickness 0, 0, 28, 0
        $ui.RingHost.HorizontalAlignment = 'Stretch'
        [System.Windows.Controls.Grid]::SetColumnSpan($ui.RingHost, 1)
        [System.Windows.Controls.Grid]::SetColumnSpan($ui.FocusDetails, 1)
    }
}

function Invoke-TdShortcut {
    param($e)
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $key = [string]$e.Key
    if ($ctrl -and $key -eq 'Return') { Complete-TdCurrentNow; $e.Handled = $true; return }
    if ($ctrl -and $key -eq 'N') { Show-TdAddBox; $e.Handled = $true; return }
    if ($key -eq 'Escape') {
        if ($script:Td.EditingId) { $script:Td.EditingId = $null; Update-TdView }
        elseif ($script:Td.Drawer) { Close-TdDrawer }
        elseif ($script:Td.Compact) { Set-TdCompactMode $false }
        elseif ($script:Td.FocusMode) { Set-TdFocusMode $false }
        else { return }
        $e.Handled = $true
        return
    }
    if (Test-TdTypingTarget) { return }
    switch ($key) {
        'Space' { Switch-TdTimerNow; $e.Handled = $true }
        'F' { Set-TdFocusMode (-not $script:Td.FocusMode); $e.Handled = $true }
        'M' { Set-TdCompactMode (-not $script:Td.Compact); $e.Handled = $true }
        'L' { Move-TdCurrentLater; $e.Handled = $true }
        'N' { Show-TdAddBox; $e.Handled = $true }
    }
}

function Show-TdAddBox {
    if ($script:Td.Compact) { Set-TdCompactMode $false }
    if ($script:Td.FocusMode) { Set-TdFocusMode $false }
    $script:Td.Ui.NewTaskBox.Focus() | Out-Null
}

function Stop-TdApp {
    if ($script:Td.Quitting -and $script:Td.Stopped) { return }
    $script:Td.Quitting = $true
    $script:Td.Stopped = $true
    try { Save-TdStateNow } catch { $null = $_ }
    if ($script:Td.SettingsSaveAt -gt 0) { Save-TdSettingsNow }
    try {
        $w = $script:Td.Window
        if (-not $script:Td.Compact -and $w.WindowState -eq 'Normal') {
            $script:Td.Data.settings.window = [ordered]@{ left = $w.Left; top = $w.Top; width = $w.Width; height = $w.Height }
            Save-TdSettingsNow
        }
    }
    catch { $null = $_ }
    if ($script:Td.Timer) { $script:Td.Timer.Stop() }
    Stop-TdAudio
    Remove-TdTray
    [System.Windows.Application]::Current.Shutdown()
}
