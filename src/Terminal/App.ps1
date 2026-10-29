# TDfocus (terminal) - état, actions, clavier, minuteur et boucle d'affichage.

$script:Tui = $null

function Initialize-TdTui {
    param([Parameter(Mandatory)][string]$ScriptPath, $Data)
    if (-not $Data) { $Data = Import-TdData }
    $script:Tui = @{
        ScriptPath    = $ScriptPath
        Data          = $Data
        Mode          = 'main'
        Sel           = 0
        ListSel       = 0
        Prompt        = $null
        Message       = $null
        Undo          = $null
        CheckIn       = $null
        Signals       = New-TdSignalMemory
        Quit          = $false
        Dirty         = $true
        LastHeartbeat = [long]0
        LastFrame     = @()
        LastSize      = ''
    }
    $now = Get-TdNowMs
    $state = $Data.state
    $paused = Repair-TdStaleTimer -State $state -NowMs $now
    [void](Invoke-TdDayRollover -State $state -NowMs $now)
    Sync-TdState $state $now
    $Data.history = [System.Collections.Generic.List[object]]::new([object[]](Limit-TdHistory -History $Data.history -NowMs $now))
    $Data.checkins = [System.Collections.Generic.List[object]]::new([object[]](Limit-TdCheckIns -CheckIns $Data.checkins -NowMs $now))
    Initialize-TdSignalMemory -State $state -Settings $Data.settings -NowMs $now -Memory $script:Tui.Signals
    Save-TdTuiState
    Open-TdTuiReviewIfNeeded
    if ($null -ne $paused) { Show-TdTuiMessage -Text ("Minuteur mis en pause à {0}, quand TDfocus s'est fermé." -f (Format-TdClock $paused)) -Seconds 8 }
}

function Save-TdTuiState {
    try {
        $script:Tui.Data.state.lastSeenMs = Get-TdNowMs
        Save-TdState $script:Tui.Data.state
    }
    catch { Write-TdLog "Sauvegarde de la liste impossible : $($_.Exception.Message)" }
}

function Save-TdTuiSettings {
    try { Save-TdSettings $script:Tui.Data.settings } catch { Write-TdLog "Sauvegarde des réglages impossible : $($_.Exception.Message)" }
}

function Complete-TdTuiChange {
    param([switch]$Replan)
    $now = Get-TdNowMs
    $state = $script:Tui.Data.state
    Sync-TdState $state $now
    if ($Replan) { Update-TdPlanBaseline -State $state -NowMs $now }
    if ($script:Tui.Sel -ge $state.tasks.Count) { $script:Tui.Sel = [Math]::Max(0, $state.tasks.Count - 1) }
    Save-TdTuiState
    $script:Tui.Dirty = $true
}

function Show-TdTuiMessage {
    param([Parameter(Mandatory)][string]$Text, [int]$Seconds = 5, [string]$Color, [scriptblock]$Undo, $UndoData, [string]$Hint)
    if ($Undo) {
        $script:Tui.Undo = @{ Action = $Undo; Data = $UndoData }
        if (-not $Hint) { $Hint = '[z] annuler' }
    }
    $script:Tui.Message = @{ Text = $Text; Until = (Get-TdNowMs) + $Seconds * 1000; Color = $Color; Hint = $Hint }
    $script:Tui.Dirty = $true
}

function Invoke-TdTuiSoundIf {
    param([string]$Name, [double]$Volume)
    if (Get-Command Invoke-TdTuiSound -ErrorAction Ignore) { Invoke-TdTuiSound -Name $Name -Volume $Volume }
}

function Get-TdTuiSelectedTask {
    $state = $script:Tui.Data.state
    if ($state.tasks.Count -eq 0) { return $null }
    $state.tasks[[Math]::Min($script:Tui.Sel, $state.tasks.Count - 1)]
}

function Get-TdTuiTemplates {
    @(Get-TdBuiltInTemplates) + @($script:Tui.Data.templates)
}

# ---------------------------------------------------------------- actions

function Switch-TdTuiTimer {
    $state = $script:Tui.Data.state
    if (-not (Get-TdCurrentTask $state)) { Show-TdTuiMessage -Text 'Ajoute d''abord une tâche : [a].' -Color 'muted'; return }
    Switch-TdTimer -State $state -NowMs (Get-TdNowMs)
    Complete-TdTuiChange
}

function Complete-TdTuiTask {
    param([string]$Id)
    $state = $script:Tui.Data.state
    $settings = $script:Tui.Data.settings
    $done = Complete-TdTask -State $state -Id $Id -NowMs (Get-TdNowMs) -KeepRunning:([bool]$settings.autoStartNext)
    if (-not $done) { return }
    $script:Tui.Data.history.Add((New-TdHistoryEntry $done))
    try { Save-TdHistory $script:Tui.Data.history } catch { Write-TdLog "Historique non enregistré : $($_.Exception.Message)" }
    if ($settings.completionSound) { Invoke-TdTuiSoundIf -Name 'complete' -Volume $settings.effectsVolume }
    Complete-TdTuiChange
    $text = '{0} « {1} » terminée. Bravo !' -f [char]0x2713, $done.title
    if ($state.tasks.Count -eq 0) { $text = [string][char]0x2713 + ' Liste terminée. Bravo, tu peux souffler !' }
    Show-TdTuiMessage -Text $text -Color 'success' -Seconds 8 -UndoData @{ Id = $done.id } -Undo {
        param($d)
        $s = $script:Tui.Data.state
        if (Undo-TdComplete -State $s -Id $d.Id -NowMs (Get-TdNowMs)) {
            $h = $script:Tui.Data.history
            for ($i = $h.Count - 1; $i -ge 0; $i--) { if ($h[$i].id -eq $d.Id) { $h.RemoveAt($i) } }
            try { Save-TdHistory $h } catch { $null = $_ }
            Complete-TdTuiChange
            Show-TdTuiMessage -Text 'Validation annulée.' -Seconds 3
        }
    }
}

function Add-TdTuiTaskFromText {
    param([string]$Text)
    $parsed = ConvertFrom-TdQuickInput $Text
    if (-not $parsed.title) { return }
    $minutes = $parsed.minutes
    if (-not $minutes) { $minutes = $script:Tui.Data.settings.defaultMinutes }
    $now = Get-TdNowMs
    $task = New-TdTask -Title $parsed.title -Minutes ([double]$minutes) -FixedStart $parsed.fixedStart -NowMs $now
    Add-TdTask -State $script:Tui.Data.state -Task $task -NowMs $now
    Complete-TdTuiChange -Replan
    $fixed = ''
    if ($parsed.fixedStart) { $fixed = ', créneau à ' + $parsed.fixedStart }
    Show-TdTuiMessage -Text ('Ajoutée : « {0} » ({1}{2}).' -f $parsed.title, (Format-TdMinutes $minutes), $fixed) -Seconds 4
}

function Add-TdTuiTime {
    param([int]$Minutes)
    $state = $script:Tui.Data.state
    if (-not (Get-TdCurrentTask $state)) { return }
    Add-TdPlannedTime -State $state -DeltaMs ([long]$Minutes * 60000)
    Complete-TdTuiChange -Replan
}

function Move-TdTuiLater {
    $state = $script:Tui.Data.state
    $current = Get-TdCurrentTask $state
    if (-not $current -or $state.tasks.Count -lt 2) { Show-TdTuiMessage -Text "C'est la seule tâche : rien à reporter." -Color 'muted'; return }
    Move-TdTaskToEnd -State $state -Id $current.id -NowMs (Get-TdNowMs)
    Complete-TdTuiChange -Replan
    Show-TdTuiMessage -Text ('« {0} » reportée en fin de liste.' -f $current.title) -Seconds 4
}

function Complete-TdTuiStep {
    $state = $script:Tui.Data.state
    $current = Get-TdCurrentTask $state
    if (-not $current) { return }
    $step = Complete-TdStep -State $state
    if (-not $step) {
        if ((Get-TdStepProgress $current).total -eq 0) { Show-TdTuiMessage -Text 'Pas de sous-étapes : [p] pour en ajouter.' -Color 'muted' }
        return
    }
    $settings = $script:Tui.Data.settings
    if ($settings.completionSound) { Invoke-TdTuiSoundIf -Name 'complete' -Volume ($settings.effectsVolume * 0.5) }
    Complete-TdTuiChange
    if (Get-TdCurrentStep $current) { Show-TdTuiMessage -Text ('Étape faite : « {0} ».' -f $step.title) -Seconds 4 -Hint '[S] revenir' }
    else { Show-TdTuiMessage -Text 'Dernière étape faite ! [Entrée] pour valider la tâche.' -Color 'success' -Seconds 8 }
}

function Undo-TdTuiStep {
    if (Undo-TdStep -State $script:Tui.Data.state) { Complete-TdTuiChange }
}

function Remove-TdTuiSelected {
    $state = $script:Tui.Data.state
    $task = Get-TdTuiSelectedTask
    if (-not $task) { return }
    $index = (Find-TdTask $state $task.id).index
    [void](Remove-TdTask -State $state -Id $task.id -NowMs (Get-TdNowMs))
    Complete-TdTuiChange -Replan
    Show-TdTuiMessage -Text ('« {0} » supprimée.' -f $task.title) -UndoData @{ Task = $task; Index = $index } -Undo {
        param($d)
        $s = $script:Tui.Data.state
        $s.tasks.Insert([Math]::Min($d.Index, $s.tasks.Count), $d.Task)
        Complete-TdTuiChange -Replan
    }
}

function Move-TdTuiSelected {
    param([int]$Delta)
    $state = $script:Tui.Data.state
    $from = $script:Tui.Sel
    $to = $from + $Delta
    if ($from -lt 1 -or $to -lt 1 -or $to -ge $state.tasks.Count) { return }
    Move-TdTask -State $state -From $from -To $to -NowMs (Get-TdNowMs)
    $script:Tui.Sel = $to
    Complete-TdTuiChange -Replan
}

function Start-TdTuiSelectedNow {
    $task = Get-TdTuiSelectedTask
    if (-not $task) { return }
    Start-TdTaskNow -State $script:Tui.Data.state -Id $task.id -NowMs (Get-TdNowMs)
    $script:Tui.Sel = 0
    Complete-TdTuiChange -Replan
}

function Update-TdTuiTaskFromText {
    param([string]$Id, [string]$Text)
    $parsed = ConvertFrom-TdQuickInput $Text
    if (-not $parsed.title) { return }
    $changes = @{ title = $parsed.title; fixedStart = $parsed.fixedStart }
    if ($parsed.minutes) { $changes.minutes = $parsed.minutes }
    [void](Update-TdTask -State $script:Tui.Data.state -Id $Id -Changes $changes)
    Complete-TdTuiChange -Replan
}

function Format-TdTuiTaskText {
    param([Parameter(Mandatory)]$Task)
    $text = '{0} {1}min' -f $Task.title, [Math]::Round([long]$Task.plannedMs / 60000)
    if ($Task.fixedStart) { $text += ' @' + $Task.fixedStart }
    $text
}

function Open-TdTuiPrompt {
    param([Parameter(Mandatory)][string]$Label, [string]$Text = '', [string]$Hint, [Parameter(Mandatory)][scriptblock]$OnSubmit, $Data)
    $script:Tui.Prompt = @{ Label = $Label; Text = $Text; Hint = $Hint; OnSubmit = $OnSubmit; Data = $Data }
    $script:Tui.Dirty = $true
}

function Add-TdTuiNote {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $current = Get-TdCurrentTask $script:Tui.Data.state
    $context = $null
    if ($current) { $context = $current.title }
    $script:Tui.Data.notes.Add((New-TdNote -Text $Text -Context $context))
    try { Save-TdNotes $script:Tui.Data.notes } catch { $null = $_ }
    Show-TdTuiMessage -Text 'Noté. Retour à ta tâche !' -Seconds 3
}

function Convert-TdTuiNote {
    $notes = $script:Tui.Data.notes
    if ($notes.Count -eq 0) { return }
    $index = $notes.Count - 1 - $script:Tui.ListSel
    if ($index -lt 0 -or $index -ge $notes.Count) { return }
    $note = $notes[$index]
    $first = ($note.text -split '\r?\n')[0]
    $parsed = ConvertFrom-TdQuickInput $first
    $minutes = $parsed.minutes
    if (-not $minutes) { $minutes = $script:Tui.Data.settings.defaultMinutes }
    $title = $parsed.title
    if (-not $title) { $title = $first }
    $now = Get-TdNowMs
    $task = New-TdTask -Title $title -Minutes ([double]$minutes) -FixedStart $parsed.fixedStart -Note $note.text -Source 'note' -NowMs $now
    Add-TdTask -State $script:Tui.Data.state -Task $task -NowMs $now
    $notes.RemoveAt($index)
    try { Save-TdNotes $notes } catch { $null = $_ }
    $script:Tui.ListSel = [Math]::Max(0, [Math]::Min($script:Tui.ListSel, $notes.Count - 1))
    Complete-TdTuiChange -Replan
    Show-TdTuiMessage -Text ('« {0} » ajoutée à la liste.' -f $title) -Seconds 4
}

function Remove-TdTuiNote {
    $notes = $script:Tui.Data.notes
    $index = $notes.Count - 1 - $script:Tui.ListSel
    if ($index -lt 0 -or $index -ge $notes.Count) { return }
    $notes.RemoveAt($index)
    try { Save-TdNotes $notes } catch { $null = $_ }
    $script:Tui.ListSel = [Math]::Max(0, [Math]::Min($script:Tui.ListSel, $notes.Count - 1))
    $script:Tui.Dirty = $true
}

function Add-TdTuiTemplate {
    param([int]$Number)
    $templates = @(Get-TdTuiTemplates)
    if ($Number -lt 1 -or $Number -gt $templates.Count) { return }
    $tpl = $templates[$Number - 1]
    $now = Get-TdNowMs
    $state = $script:Tui.Data.state
    $ids = @()
    foreach ($t in (ConvertTo-TdTasksFromTemplate -Template $tpl -NowMs $now)) {
        Add-TdTask -State $state -Task $t -NowMs $now
        $ids += $t.id
    }
    $script:Tui.Mode = 'main'
    Complete-TdTuiChange -Replan
    Show-TdTuiMessage -Text ('Routine « {0} » ajoutée ({1} tâches).' -f $tpl.name, $ids.Count) -UndoData @{ Ids = $ids } -Undo {
        param($d)
        $s = $script:Tui.Data.state
        foreach ($id in $d.Ids) { [void](Remove-TdTask -State $s -Id $id -NowMs (Get-TdNowMs)) }
        Complete-TdTuiChange -Replan
    }
}

function Save-TdTuiCurrentAsTemplate {
    param([string]$Name)
    $state = $script:Tui.Data.state
    if ([string]::IsNullOrWhiteSpace($Name) -or $state.tasks.Count -eq 0) { return }
    $script:Tui.Data.templates.Add((New-TdTemplateFromTasks -Name $Name -Tasks @($state.tasks)))
    try { Save-TdTemplates $script:Tui.Data.templates } catch { $null = $_ }
    Show-TdTuiMessage -Text ('Routine « {0} » enregistrée.' -f $Name.Trim()) -Seconds 4
}

# ---------------------------------------------------------------- points de contrôle et revue

function Start-TdTuiCheckIn {
    param([long]$NowMs = (Get-TdNowMs))
    $current = Get-TdCurrentTask $script:Tui.Data.state
    if (-not $current) { return }
    if ($script:Tui.CheckIn) { Complete-TdTuiCheckIn -Answer 'missed' }
    $script:Tui.CheckIn = @{ TaskId = $current.id; Until = $NowMs + 90000 }
    if ($script:Tui.Data.settings.notifications -and (Get-Command Send-TdDesktopNotification -ErrorAction Ignore)) {
        Send-TdDesktopNotification -Message ('Toujours sur « {0} » ?' -f $current.title)
    }
    $script:Tui.Dirty = $true
}

function Complete-TdTuiCheckIn {
    param([Parameter(Mandatory)][ValidateSet('focused', 'drifted', 'missed')][string]$Answer)
    $checkIn = $script:Tui.CheckIn
    if (-not $checkIn) { return }
    $script:Tui.CheckIn = $null
    $script:Tui.Data.checkins.Add((New-TdCheckIn -TaskId $checkIn.TaskId -Answer $Answer))
    try { Save-TdCheckIns $script:Tui.Data.checkins } catch { $null = $_ }
    $current = Get-TdCurrentTask $script:Tui.Data.state
    switch ($Answer) {
        'focused' { Show-TdTuiMessage -Text 'Bien joué, continue comme ça.' -Color 'success' -Seconds 3 }
        'drifted' {
            $target = ''
            if ($current) {
                $target = $current.title
                $step = Get-TdCurrentStep $current
                if ($step) { $target = $step.title }
            }
            Show-TdTuiMessage -Text ("Pas grave, c'est fait pour ça. On reprend : « {0} »." -f $target) -Seconds 8 -Hint '[n] noter la distraction'
        }
    }
    $script:Tui.Dirty = $true
}

function Open-TdTuiReviewIfNeeded {
    $state = $script:Tui.Data.state
    if (-not $script:Tui.Data.settings.morningReview) {
        if ($state.review.Count -gt 0) { Clear-TdReview $state; Save-TdTuiState }
        return
    }
    if (@(Get-TdReviewTasks $state).Count -gt 0) {
        $script:Tui.Mode = 'review'
        $script:Tui.ListSel = 0
        $script:Tui.Dirty = $true
    }
}

function Resolve-TdTuiReview {
    param([Parameter(Mandatory)][string]$Decision)
    $state = $script:Tui.Data.state
    $tasks = @(Get-TdReviewTasks $state)
    if ($tasks.Count -eq 0) { $script:Tui.Mode = 'main'; return }
    $task = $tasks[[Math]::Min($script:Tui.ListSel, $tasks.Count - 1)]
    [void](Resolve-TdReview -State $state -Id $task.id -Decision $Decision -NowMs (Get-TdNowMs))
    Complete-TdTuiChange -Replan
    switch ($Decision) {
        'tomorrow' { Show-TdTuiMessage -Text ('« {0} » reportée à demain.' -f $task.title) -Seconds 4 }
        'drop' {
            Show-TdTuiMessage -Text ('« {0} » abandonnée. C''est un choix valable.' -f $task.title) -UndoData @{ Task = $task } -Undo {
                param($d)
                $script:Tui.Data.state.tasks.Add($d.Task)
                Complete-TdTuiChange -Replan
            }
        }
    }
    $left = @(Get-TdReviewTasks $state).Count
    if ($left -eq 0) {
        $script:Tui.Mode = 'main'
        if ($Decision -eq 'keep') { Show-TdTuiMessage -Text 'Revue terminée. Belle journée !' -Color 'success' -Seconds 4 }
    }
    else { $script:Tui.ListSel = [Math]::Min($script:Tui.ListSel, $left - 1) }
}

function Close-TdTuiReview {
    $state = $script:Tui.Data.state
    if ($state.review.Count -gt 0) { Clear-TdReview $state; Save-TdTuiState }
    $script:Tui.Mode = 'main'
    $script:Tui.Dirty = $true
}

# ---------------------------------------------------------------- réglages

$script:TdTuiAmbientNames = [ordered]@{ none = 'aucune'; white = 'bruit blanc'; pink = 'bruit rose'; brown = 'bruit brun'; rain = 'pluie douce'; chimes = "carillon d'ambiance" }

function Get-TdTuiSettingRows {
    $s = $script:Tui.Data.settings
    $yes = { param($v) if ($v) { 'oui' } else { 'non' } }
    $chime = 'désactivé'
    if ([int]$s.chimeEveryMin -gt 0) { $chime = "toutes les $($s.chimeEveryMin) min" }
    $landing = 'désactivé'
    if ([int]$s.landingMinutes -gt 0) { $landing = "$($s.landingMinutes) min avant la fin" }
    $mode = 'compte à rebours'
    if ($s.timerMode -eq 'countup') { $mode = 'compte progressif' }
    @(
        @{ key = 'timerMode'; label = 'Minuteur'; value = $mode }
        @{ key = 'autoStartNext'; label = 'Enchaîner la tâche suivante'; value = (& $yes $s.autoStartNext) }
        @{ key = 'chimeEveryMin'; label = 'Carillon périodique'; value = $chime }
        @{ key = 'checkInWithChime'; label = 'Point de contrôle au carillon'; value = (& $yes $s.checkInWithChime) }
        @{ key = 'landingMinutes'; label = 'Signal d''atterrissage'; value = $landing }
        @{ key = 'ambient'; label = 'Ambiance sonore'; value = $script:TdTuiAmbientNames[$s.ambient] }
        @{ key = 'ambientVolume'; label = 'Volume de l''ambiance'; value = ('{0:P0}' -f [double]$s.ambientVolume) }
        @{ key = 'effectsVolume'; label = 'Volume des effets'; value = ('{0:P0}' -f [double]$s.effectsVolume) }
        @{ key = 'completionSound'; label = 'Son de validation'; value = (& $yes $s.completionSound) }
        @{ key = 'timeUpSignal'; label = 'Tintement doux en fin de temps'; value = (& $yes $s.timeUpSignal) }
        @{ key = 'notifications'; label = 'Notifications de bureau'; value = (& $yes $s.notifications) }
        @{ key = 'morningReview'; label = 'Revue du matin'; value = (& $yes $s.morningReview) }
        @{ key = 'autostart'; label = 'Lancer à l''ouverture de session'; value = (& $yes $s.autostart) }
        @{ key = 'defaultMinutes'; label = 'Durée par défaut'; value = "$($s.defaultMinutes) min" }
    )
}

function Step-TdTuiSetting {
    # Change le réglage choisi ; $Direction = -1 / +1 pour les valeurs à plusieurs crans.
    param([int]$Direction = 1)
    $rows = @(Get-TdTuiSettingRows)
    $row = $rows[[Math]::Min($script:Tui.ListSel, $rows.Count - 1)]
    $s = $script:Tui.Data.settings
    $cycle = {
        param([object[]]$Values, $Current)
        $i = [Array]::IndexOf($Values, $Current)
        if ($i -lt 0) { $i = 0 }
        $Values[($i + $Direction + $Values.Count) % $Values.Count]
    }
    switch ($row.key) {
        'timerMode' { if ($s.timerMode -eq 'countdown') { $s.timerMode = 'countup' } else { $s.timerMode = 'countdown' } }
        'chimeEveryMin' { $s.chimeEveryMin = [int](& $cycle @(0, 5, 10, 15, 20, 30) ([int]$s.chimeEveryMin)); $script:Tui.Signals.ChimeTaskId = '' }
        'landingMinutes' { $s.landingMinutes = [int](& $cycle @(0, 1, 2, 5) ([int]$s.landingMinutes)); $script:Tui.Signals.LandingKey = '' }
        'ambient' {
            $s.ambient = [string](& $cycle @($script:TdTuiAmbientNames.Keys) $s.ambient)
            if (Get-Command Set-TdTuiAmbient -ErrorAction Ignore) { Set-TdTuiAmbient -Name $s.ambient -Volume $s.ambientVolume }
        }
        'ambientVolume' {
            $s.ambientVolume = [Math]::Round([Math]::Min(1.0, [Math]::Max(0.0, [double]$s.ambientVolume + 0.1 * $Direction)), 2)
            if (Get-Command Set-TdTuiAmbient -ErrorAction Ignore) { Set-TdTuiAmbient -Name $s.ambient -Volume $s.ambientVolume }
        }
        'effectsVolume' { $s.effectsVolume = [Math]::Round([Math]::Min(1.0, [Math]::Max(0.0, [double]$s.effectsVolume + 0.1 * $Direction)), 2) }
        'defaultMinutes' { $s.defaultMinutes = [int](& $cycle @(5, 15, 25, 45, 60) ([int]$s.defaultMinutes)) }
        'autostart' {
            $s.autostart = -not $s.autostart
            if ($IsLinux -and (Get-Command Set-TdLinuxAutostart -ErrorAction Ignore)) {
                if (-not (Set-TdLinuxAutostart -Enabled ([bool]$s.autostart) -ScriptPath $script:Tui.ScriptPath)) {
                    Show-TdTuiMessage -Text 'Impossible de modifier le démarrage automatique (voir tdfocus.log).' -Color 'overtime'
                }
            }
        }
        default { $s[$row.key] = -not $s[$row.key] }
    }
    Save-TdTuiSettings
    $script:Tui.Dirty = $true
}

# ---------------------------------------------------------------- clavier

function Invoke-TdTuiPromptKey {
    param([System.ConsoleKeyInfo]$Key)
    $prompt = $script:Tui.Prompt
    $ctrl = ($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
    switch ($Key.Key) {
        'Enter' {
            $script:Tui.Prompt = $null
            $text = $prompt.Text.Trim()
            if ($text) { & $prompt.OnSubmit $text $prompt.Data }
            return
        }
        'Escape' { $script:Tui.Prompt = $null; return }
        'Backspace' { if ($prompt.Text.Length -gt 0) { $prompt.Text = $prompt.Text.Substring(0, $prompt.Text.Length - 1) }; return }
    }
    if ($ctrl -and $Key.Key -eq 'U') { $prompt.Text = ''; return }
    if ($ctrl) { return }
    $ch = $Key.KeyChar
    if ([int]$ch -ge 32 -and -not [char]::IsControl($ch)) { $prompt.Text += [string]$ch }
}

function Invoke-TdTuiKey {
    param([Parameter(Mandatory)][System.ConsoleKeyInfo]$Key)
    $tui = $script:Tui
    $tui.Dirty = $true
    $ctrl = ($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
    $shift = ($Key.Modifiers -band [ConsoleModifiers]::Shift) -ne 0
    if ($ctrl -and $Key.Key -eq 'C') { $tui.Quit = $true; return }
    if ($tui.Prompt) { Invoke-TdTuiPromptKey $Key; return }
    $ch = [string]$Key.KeyChar

    # Point de contrôle : réponse en une touche.
    if ($tui.CheckIn -and $tui.Mode -eq 'main' -and ($ch -ceq 'o' -or $ch -ceq 'g')) {
        if ($ch -ceq 'o') { Complete-TdTuiCheckIn -Answer 'focused' } else { Complete-TdTuiCheckIn -Answer 'drifted' }
        return
    }

    switch ($tui.Mode) {
        'review' {
            $count = @(Get-TdReviewTasks $tui.Data.state).Count
            switch -CaseSensitive ($ch) {
                'g' { Resolve-TdTuiReview -Decision 'keep'; return }
                'd' { Resolve-TdTuiReview -Decision 'tomorrow'; return }
                'a' { Resolve-TdTuiReview -Decision 'drop'; return }
                'G' { Close-TdTuiReview; Show-TdTuiMessage -Text 'Revue terminée. Belle journée !' -Color 'success' -Seconds 4; return }
                'z' { if ($tui.Undo) { $u = $tui.Undo; $tui.Undo = $null; & $u.Action $u.Data }; return }
            }
            switch ($Key.Key) {
                'UpArrow' { $tui.ListSel = [Math]::Max(0, $tui.ListSel - 1) }
                'DownArrow' { $tui.ListSel = [Math]::Min([Math]::Max(0, $count - 1), $tui.ListSel + 1) }
                'Escape' { Close-TdTuiReview }
            }
            return
        }
        'routines' {
            if ($ch -match '^[1-9]$') { Add-TdTuiTemplate -Number ([int]$ch); return }
            if ($ch -ceq 's') {
                Open-TdTuiPrompt -Label 'Nom de la routine' -Hint 'enregistre toute la liste actuelle' -OnSubmit { param($text) Save-TdTuiCurrentAsTemplate -Name $text }
                return
            }
            if ($Key.Key -eq 'Escape' -or $ch -ceq 'q') { $tui.Mode = 'main' }
            return
        }
        'notes' {
            $count = $tui.Data.notes.Count
            switch ($Key.Key) {
                'UpArrow' { $tui.ListSel = [Math]::Max(0, $tui.ListSel - 1); return }
                'DownArrow' { $tui.ListSel = [Math]::Min([Math]::Max(0, $count - 1), $tui.ListSel + 1); return }
                'Enter' { Convert-TdTuiNote; return }
                'Escape' { $tui.Mode = 'main'; return }
                'Delete' { Remove-TdTuiNote; return }
            }
            switch -CaseSensitive ($ch) {
                'x' { Remove-TdTuiNote }
                'n' { Open-TdTuiPrompt -Label 'Note rapide' -OnSubmit { param($text) Add-TdTuiNote -Text $text } }
                'q' { $tui.Mode = 'main' }
            }
            return
        }
        'settings' {
            $count = @(Get-TdTuiSettingRows).Count
            switch ($Key.Key) {
                'UpArrow' { $tui.ListSel = [Math]::Max(0, $tui.ListSel - 1); return }
                'DownArrow' { $tui.ListSel = [Math]::Min($count - 1, $tui.ListSel + 1); return }
                'LeftArrow' { Step-TdTuiSetting -Direction -1; return }
                'RightArrow' { Step-TdTuiSetting -Direction 1; return }
                'Enter' { Step-TdTuiSetting -Direction 1; return }
                'Spacebar' { Step-TdTuiSetting -Direction 1; return }
                'Escape' { $tui.Mode = 'main'; return }
            }
            if ($ch -ceq 'q') { $tui.Mode = 'main' }
            return
        }
        { $_ -in @('help', 'stats') } {
            if ($Key.Key -eq 'Escape' -or $ch -ceq 'q' -or $ch -ceq '?') { $tui.Mode = 'main' }
            return
        }
    }

    # Écran principal
    switch ($Key.Key) {
        'Spacebar' { Switch-TdTuiTimer; return }
        'Enter' { Complete-TdTuiTask; return }
        'UpArrow' { if ($shift) { Move-TdTuiSelected -Delta -1 } else { $tui.Sel = [Math]::Max(0, $tui.Sel - 1) }; return }
        'DownArrow' { if ($shift) { Move-TdTuiSelected -Delta 1 } else { $tui.Sel = [Math]::Min([Math]::Max(0, $tui.Data.state.tasks.Count - 1), $tui.Sel + 1) }; return }
        'Delete' { Remove-TdTuiSelected; return }
        'Escape' { $tui.Sel = 0; $tui.Message = $null; return }
    }
    switch -CaseSensitive ($ch) {
        's' { Complete-TdTuiStep }
        'S' { Undo-TdTuiStep }
        'a' { Open-TdTuiPrompt -Label 'Nouvelle tâche' -Hint 'ex. Emails 15 · Rapport 1h30 · Réunion 30 @14h' -OnSubmit { param($text) Add-TdTuiTaskFromText -Text $text } }
        'e' {
            $task = Get-TdTuiSelectedTask
            if ($task) { Open-TdTuiPrompt -Label 'Modifier' -Text (Format-TdTuiTaskText $task) -Hint 'titre durée @heure' -Data $task.id -OnSubmit { param($text, $id) Update-TdTuiTaskFromText -Id $id -Text $text } }
        }
        'p' {
            $task = Get-TdTuiSelectedTask
            if ($task) {
                $steps = (@($task.steps) | Where-Object { $_ } | ForEach-Object { if ($_.done) { '[x] ' + $_.title } else { $_.title } }) -join ' ; '
                Open-TdTuiPrompt -Label 'Sous-étapes' -Text $steps -Hint 'séparées par ;' -Data $task.id -OnSubmit {
                    param($text, $id)
                    [void](Update-TdTask -State $script:Tui.Data.state -Id $id -Changes @{ stepsText = $text })
                    Complete-TdTuiChange
                }
            }
        }
        '+' { Add-TdTuiTime 1 }
        '=' { Add-TdTuiTime 1 }
        '-' { Add-TdTuiTime -1 }
        ']' { Add-TdTuiTime 5 }
        '[' { Add-TdTuiTime -5 }
        'l' { Move-TdTuiLater }
        'K' { Move-TdTuiSelected -Delta -1 }
        'J' { Move-TdTuiSelected -Delta 1 }
        'd' { Start-TdTuiSelectedNow }
        'v' { $task = Get-TdTuiSelectedTask; if ($task) { Complete-TdTuiTask -Id $task.id } }
        'x' { Remove-TdTuiSelected }
        'z' { if ($tui.Undo) { $u = $tui.Undo; $tui.Undo = $null; $tui.Message = $null; & $u.Action $u.Data } }
        'n' { Open-TdTuiPrompt -Label 'Note rapide' -Hint 'une pensée parasite ? note-la et reviens' -OnSubmit { param($text) Add-TdTuiNote -Text $text } }
        'N' { $tui.Mode = 'notes'; $tui.ListSel = 0 }
        'r' { $tui.Mode = 'routines' }
        't' { $tui.Mode = 'stats' }
        'o' { $tui.Mode = 'settings'; $tui.ListSel = 0 }
        '?' { $tui.Mode = 'help' }
        'h' { $tui.Mode = 'help' }
        'm' {
            $s = $tui.Data.settings
            if ($s.timerMode -eq 'countdown') { $s.timerMode = 'countup' } else { $s.timerMode = 'countdown' }
            Save-TdTuiSettings
        }
        'R' { if ((Restore-TdParked -State $tui.Data.state -All) -gt 0) { Complete-TdTuiChange -Replan } }
        'q' { $tui.Quit = $true }
    }
}

# ---------------------------------------------------------------- minuteur

function Invoke-TdTuiTick {
    param([long]$NowMs)
    $tui = $script:Tui
    $state = $tui.Data.state
    $settings = $tui.Data.settings
    if ((Get-TdDayKey $NowMs) -ne $state.dayKey) {
        [void](Invoke-TdDayRollover -State $state -NowMs $NowMs)
        Save-TdTuiState
        Open-TdTuiReviewIfNeeded
    }
    $current = Get-TdCurrentTask $state
    foreach ($signal in @(Get-TdSignals -State $state -Settings $settings -NowMs $NowMs -Memory $tui.Signals)) {
        switch ($signal) {
            'timeup' {
                if ($settings.timeUpSignal) { Invoke-TdTuiSoundIf -Name 'timeup' -Volume $settings.effectsVolume }
                if ($settings.notifications -and (Get-Command Send-TdDesktopNotification -ErrorAction Ignore)) {
                    Send-TdDesktopNotification -Message ("Le temps prévu pour « {0} » est écoulé. Continue tranquillement ou valide quand c'est bon." -f $current.title)
                }
            }
            'landing' { Invoke-TdTuiSoundIf -Name 'landing' -Volume $settings.effectsVolume }
            'chime' {
                Invoke-TdTuiSoundIf -Name 'chime' -Volume $settings.chimeVolume
                if ($settings.checkInWithChime) { Start-TdTuiCheckIn -NowMs $NowMs }
            }
        }
        $tui.Dirty = $true
    }
    $checkIn = $tui.CheckIn
    if ($checkIn -and ($NowMs -ge $checkIn.Until -or -not $current -or $current.id -ne $checkIn.TaskId)) { Complete-TdTuiCheckIn -Answer 'missed' }
    if ($NowMs - $tui.LastHeartbeat -ge 60000) { $tui.LastHeartbeat = $NowMs; Save-TdTuiState }
    if ($tui.Message -and $NowMs -ge $tui.Message.Until) { $tui.Message = $null; $tui.Undo = $null; $tui.Dirty = $true }
    if (Get-Command Update-TdTuiAudio -ErrorAction Ignore) { Update-TdTuiAudio }
}

# ---------------------------------------------------------------- affichage

function Write-TdTuiFrame {
    # N'écrit que les lignes qui ont changé (pas de scintillement).
    param([string[]]$Frame)
    $tui = $script:Tui
    $e = $script:TdEsc
    $builder = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Frame.Count; $i++) {
        $previous = $null
        if ($i -lt $tui.LastFrame.Count) { $previous = $tui.LastFrame[$i] }
        if ($previous -ceq $Frame[$i]) { continue }
        [void]$builder.Append("$e[$($i + 1);1H").Append($Frame[$i]).Append("$e[0m$e[K")
    }
    if ($builder.Length -gt 0) {
        [Console]::Out.Write($builder.ToString())
        [Console]::Out.Flush()
    }
    $tui.LastFrame = $Frame
}

function Start-TdTuiLoop {
    $tui = $script:Tui
    $e = $script:TdEsc
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::TreatControlCAsInput = $true
    [Console]::Out.Write("$e[?1049h$e[?25l$e[2J")
    $lastTick = [long]0
    $lastSecond = [long]-1
    try {
        while (-not $tui.Quit) {
            while ([Console]::KeyAvailable) { Invoke-TdTuiKey ([Console]::ReadKey($true)) }
            $now = Get-TdNowMs
            if ($now - $lastTick -ge 250) { Invoke-TdTuiTick -NowMs $now; $lastTick = $now }
            $size = '{0}x{1}' -f [Console]::WindowWidth, [Console]::WindowHeight
            if ($size -ne $tui.LastSize) {
                $tui.LastSize = $size
                $tui.LastFrame = @()
                [Console]::Out.Write("$e[2J")
                $tui.Dirty = $true
            }
            $second = [long][Math]::Floor($now / 1000)
            if ($tui.Dirty -or $second -ne $lastSecond) {
                $lastSecond = $second
                $tui.Dirty = $false
                # Une colonne de marge : écrire dans la dernière colonne fait défiler certains terminaux.
                Write-TdTuiFrame (Get-TdTuiFrame -NowMs $now -Width ([Console]::WindowWidth - 1) -Height ([Console]::WindowHeight))
            }
            Start-Sleep -Milliseconds 40
        }
    }
    finally {
        [Console]::Out.Write("$e[0m$e[?25h$e[?1049l")
        [Console]::TreatControlCAsInput = $false
        Save-TdTuiState
        if (Get-Command Stop-TdTuiAudio -ErrorAction Ignore) { Stop-TdTuiAudio }
    }
}
