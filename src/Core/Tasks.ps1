# TDfocus - modèle de tâches et moteur séquentiel.
#
# Principe : la liste « tasks » est la file d'attente ordonnée. La tâche en cours est
# toujours tasks[0]. Le temps passé est stocké sous forme d'horodatages
# (elapsedMs + runningSince) : le décompte reste juste même si l'application est
# fermée, mise en veille ou cachée, car tout est recalculé à partir de l'heure réelle.

$script:TdTaskFields = @(
    'id', 'title', 'plannedMs', 'estimateMs', 'categoryId', 'elapsedMs', 'runningSince',
    'startedAt', 'completedAt', 'fixedStart', 'note', 'source', 'externalId', 'createdAt',
    'steps', 'pausedAt', 'deferUntil'
)

function New-TdId {
    [guid]::NewGuid().ToString('N').Substring(0, 12)
}

function Get-TdValue {
    # Lit une propriété sur une hashtable ou un objet (JSON désérialisé).
    param($InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    $null
}

function ConvertTo-TdNullableLong {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    [long]$Value
}

function ConvertTo-TdNullableString {
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    if ($s.Trim() -eq '') { return $null }
    $s
}

function ConvertTo-TdSteps {
    # Sous-étapes : [{ id, title, done }]. Accepte aussi une simple liste de titres.
    param($InputObject)
    $steps = foreach ($item in @($InputObject)) {
        if ($null -eq $item) { continue }
        $done = $false
        $id = $null
        if ($item -is [string]) { $title = $item }
        else {
            $title = [string](Get-TdValue $item 'title')
            $done = [bool](Get-TdValue $item 'done')
            $id = ConvertTo-TdNullableString (Get-TdValue $item 'id')
        }
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        if (-not $id) { $id = New-TdId }
        [pscustomobject][ordered]@{ id = $id; title = $title.Trim(); done = $done }
    }
    , @($steps)
}

function ConvertTo-TdTask {
    # Construit une tâche complète (avec valeurs par défaut) à partir de n'importe quel objet.
    param([Parameter(Mandatory)]$InputObject)
    $planned = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'plannedMs')
    if ($null -eq $planned -or $planned -lt 60000) { $planned = 1500000 }
    $estimate = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'estimateMs')
    if ($null -eq $estimate -or $estimate -lt 60000) { $estimate = $planned }
    $elapsed = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'elapsedMs')
    if ($null -eq $elapsed -or $elapsed -lt 0) { $elapsed = 0 }
    $id = ConvertTo-TdNullableString (Get-TdValue $InputObject 'id')
    if (-not $id) { $id = New-TdId }
    $source = ConvertTo-TdNullableString (Get-TdValue $InputObject 'source')
    if (-not $source) { $source = 'manual' }
    $note = Get-TdValue $InputObject 'note'
    if ($null -eq $note) { $note = '' }
    $created = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'createdAt')
    if ($null -eq $created) { $created = 0 }

    [pscustomobject][ordered]@{
        id           = $id
        title        = [string](Get-TdValue $InputObject 'title')
        plannedMs    = [long]$planned
        estimateMs   = [long]$estimate
        categoryId   = ConvertTo-TdNullableString (Get-TdValue $InputObject 'categoryId')
        elapsedMs    = [long]$elapsed
        runningSince = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'runningSince')
        startedAt    = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'startedAt')
        completedAt  = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'completedAt')
        fixedStart   = ConvertTo-TdClockText (ConvertTo-TdNullableString (Get-TdValue $InputObject 'fixedStart'))
        note         = [string]$note
        source       = $source
        externalId   = ConvertTo-TdNullableString (Get-TdValue $InputObject 'externalId')
        createdAt    = [long]$created
        steps        = ConvertTo-TdSteps (Get-TdValue $InputObject 'steps')
        pausedAt     = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'pausedAt')
        deferUntil   = ConvertTo-TdNullableString (Get-TdValue $InputObject 'deferUntil')
    }
}

function New-TdTask {
    param(
        [Parameter(Mandatory)][string]$Title,
        [double]$Minutes = 25,
        [string]$CategoryId,
        [string]$FixedStart,
        [string]$Source = 'manual',
        [string]$ExternalId,
        [string]$Note = '',
        [string[]]$Steps = @(),
        [long]$NowMs = (Get-TdNowMs)
    )
    if ($Minutes -lt 1) { $Minutes = 1 }
    $ms = [long][Math]::Round($Minutes * 60000)
    ConvertTo-TdTask @{
        title      = $Title.Trim()
        plannedMs  = $ms
        estimateMs = $ms
        categoryId = $CategoryId
        fixedStart = $FixedStart
        source     = $Source
        externalId = $ExternalId
        note       = $Note
        createdAt  = $NowMs
        steps      = @($Steps)
    }
}

function New-TdState {
    @{
        version    = 1
        tasks      = [System.Collections.Generic.List[object]]::new()
        done       = [System.Collections.Generic.List[object]]::new()
        planEndMs  = $null
        lastSeenMs = [long]0
        dayKey     = $null
        parked     = [System.Collections.Generic.List[object]]::new()   # reportées à un autre jour
        review     = [System.Collections.Generic.List[string]]::new()   # revue du matin en attente
    }
}

function ConvertTo-TdState {
    param($InputObject)
    $state = New-TdState
    if ($null -eq $InputObject) { return $state }
    foreach ($t in @(Get-TdValue $InputObject 'tasks')) {
        if ($null -ne $t) { $state.tasks.Add((ConvertTo-TdTask $t)) }
    }
    foreach ($t in @(Get-TdValue $InputObject 'done')) {
        if ($null -ne $t) {
            $task = ConvertTo-TdTask $t
            $task.runningSince = $null
            $state.done.Add($task)
        }
    }
    foreach ($t in @(Get-TdValue $InputObject 'parked')) {
        if ($null -ne $t) {
            $task = ConvertTo-TdTask $t
            $task.runningSince = $null
            $state.parked.Add($task)
        }
    }
    foreach ($id in @(Get-TdValue $InputObject 'review')) {
        if ($id) { $state.review.Add([string]$id) }
    }
    $state.planEndMs = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'planEndMs')
    $lastSeen = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'lastSeenMs')
    if ($null -ne $lastSeen) { $state.lastSeenMs = $lastSeen }
    $state.dayKey = ConvertTo-TdNullableString (Get-TdValue $InputObject 'dayKey')
    $state
}

function Get-TdCurrentTask {
    param([Parameter(Mandatory)]$State)
    if ($State.tasks.Count -gt 0) { return $State.tasks[0] }
    $null
}

function Get-TdElapsedMs {
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][long]$NowMs)
    $elapsed = [long]$Task.elapsedMs
    if ($null -ne $Task.runningSince) {
        $elapsed += [Math]::Max([long]0, $NowMs - [long]$Task.runningSince)
    }
    $elapsed
}

function Get-TdRemainingMs {
    # Négatif = dépassement (temps additionnel).
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][long]$NowMs)
    [long]$Task.plannedMs - (Get-TdElapsedMs $Task $NowMs)
}

function Test-TdTaskStarted {
    param([Parameter(Mandatory)]$Task)
    ($null -ne $Task.runningSince) -or ([long]$Task.elapsedMs -gt 0)
}

function Test-TdRunning {
    param([Parameter(Mandatory)]$State)
    ($State.tasks.Count -gt 0) -and ($null -ne $State.tasks[0].runningSince)
}

function Stop-TdTaskClock {
    # Fige le temps écoulé d'une tâche (sans la terminer).
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][long]$NowMs)
    if ($null -ne $Task.runningSince) {
        $Task.elapsedMs = [long]$Task.elapsedMs + [Math]::Max([long]0, $NowMs - [long]$Task.runningSince)
        $Task.runningSince = $null
    }
}

function Start-TdTaskClock {
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][long]$NowMs)
    if ($null -eq $Task.runningSince) { $Task.runningSince = $NowMs }
    if ($null -eq $Task.startedAt) { $Task.startedAt = $NowMs }
    $Task.pausedAt = $null
}

function Sync-TdState {
    # Invariant : seule tasks[0] peut tourner. Si une autre tâche tournait (après un
    # glisser-déposer, un report, une annulation...), le chrono est transféré à tasks[0] :
    # la session continue sans interruption.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][long]$NowMs)
    $transfer = $false
    for ($i = 1; $i -lt $State.tasks.Count; $i++) {
        $t = $State.tasks[$i]
        if ($null -ne $t.runningSince) {
            Stop-TdTaskClock $t $NowMs
            $transfer = $true
        }
    }
    foreach ($t in $State.done) { $t.runningSince = $null; $t.pausedAt = $null }
    # Seule la tâche en cours peut être « en pause » : les autres sont simplement en attente.
    for ($i = 1; $i -lt $State.tasks.Count; $i++) { $State.tasks[$i].pausedAt = $null }
    if ($transfer -and $State.tasks.Count -gt 0) {
        Start-TdTaskClock $State.tasks[0] $NowMs
    }
}

function Find-TdTask {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Id)
    for ($i = 0; $i -lt $State.tasks.Count; $i++) {
        if ($State.tasks[$i].id -eq $Id) { return [pscustomobject]@{ task = $State.tasks[$i]; index = $i; list = 'tasks' } }
    }
    for ($i = 0; $i -lt $State.done.Count; $i++) {
        if ($State.done[$i].id -eq $Id) { return [pscustomobject]@{ task = $State.done[$i]; index = $i; list = 'done' } }
    }
    $null
}

function Start-TdTimer {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][long]$NowMs)
    $current = Get-TdCurrentTask $State
    if ($current) { Start-TdTaskClock $current $NowMs }
}

function Suspend-TdTimer {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][long]$NowMs)
    $current = Get-TdCurrentTask $State
    if ($current -and $null -ne $current.runningSince) {
        Stop-TdTaskClock $current $NowMs
        $current.pausedAt = $NowMs
    }
}

function Get-TdPausedMs {
    # Durée de la pause en cours (compteur de pause visible), ou $null.
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][long]$NowMs)
    if ($null -ne $Task.runningSince -or $null -eq $Task.pausedAt) { return $null }
    [Math]::Max([long]0, $NowMs - [long]$Task.pausedAt)
}

function Format-TdPausedFor {
    # « depuis 40 s », « depuis 12 min », « depuis 1 h 05 »
    param([Parameter(Mandatory)][long]$Ms)
    if ($Ms -lt 60000) { return 'depuis {0} s' -f [long][Math]::Floor($Ms / 1000) }
    'depuis ' + (Format-TdMinutes ([Math]::Floor($Ms / 60000)))
}

function Switch-TdTimer {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][long]$NowMs)
    if (Test-TdRunning $State) { Suspend-TdTimer $State $NowMs } else { Start-TdTimer $State $NowMs }
}

function Add-TdTask {
    # Ajoute une tâche. Une tâche à heure fixe (créneau figé) est insérée à sa place
    # chronologique sans jamais déloger la tâche en cours ; une tâche flottante va en fin de file.
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Task,
        [long]$NowMs = (Get-TdNowMs),
        [int]$Index = -1
    )
    if ($Index -lt 0) {
        if ($Task.fixedStart) { $Index = Get-TdFixedInsertIndex -State $State -Clock $Task.fixedStart -NowMs $NowMs }
        else { $Index = $State.tasks.Count }
    }
    if ($Index -gt $State.tasks.Count) { $Index = $State.tasks.Count }
    $State.tasks.Insert($Index, $Task)
    Sync-TdState $State $NowMs
}

function Remove-TdTask {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Id, [long]$NowMs = (Get-TdNowMs))
    $found = Find-TdTask $State $Id
    if (-not $found) { return $null }
    if ($found.list -eq 'done') {
        $State.done.RemoveAt($found.index)
        return $found.task
    }
    $wasRunning = ($found.index -eq 0) -and ($null -ne $found.task.runningSince)
    Stop-TdTaskClock $found.task $NowMs
    $State.tasks.RemoveAt($found.index)
    if ($wasRunning -and $State.tasks.Count -gt 0) { Start-TdTaskClock $State.tasks[0] $NowMs }
    $found.task
}

function Move-TdTask {
    # Déplace une tâche de la position From à la position To (index final).
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][int]$From,
        [Parameter(Mandatory)][int]$To,
        [long]$NowMs = (Get-TdNowMs)
    )
    $count = $State.tasks.Count
    if ($From -lt 0 -or $From -ge $count) { return }
    if ($To -lt 0) { $To = 0 }
    if ($To -ge $count) { $To = $count - 1 }
    if ($From -eq $To) { return }
    $item = $State.tasks[$From]
    $State.tasks.RemoveAt($From)
    $State.tasks.Insert($To, $item)
    Sync-TdState $State $NowMs
}

function Move-TdTaskToEnd {
    # « Plus tard » : reporter sans culpabiliser.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Id, [long]$NowMs = (Get-TdNowMs))
    $found = Find-TdTask $State $Id
    if ($found -and $found.list -eq 'tasks') {
        Move-TdTask -State $State -From $found.index -To ($State.tasks.Count - 1) -NowMs $NowMs
    }
}

function Start-TdTaskNow {
    # Place la tâche en tête et lance le minuteur.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Id, [long]$NowMs = (Get-TdNowMs))
    $found = Find-TdTask $State $Id
    if (-not $found -or $found.list -ne 'tasks') { return }
    if ($found.index -gt 0) { Move-TdTask -State $State -From $found.index -To 0 -NowMs $NowMs }
    Start-TdTimer $State $NowMs
}

function Complete-TdTask {
    # Validation manuelle d'une tâche. Si c'est la tâche en cours et que le minuteur
    # tournait, la suivante démarre automatiquement quand -KeepRunning est passé.
    param(
        [Parameter(Mandatory)]$State,
        [string]$Id,
        [long]$NowMs = (Get-TdNowMs),
        [switch]$KeepRunning
    )
    if ($State.tasks.Count -eq 0) { return $null }
    $index = 0
    if ($Id) {
        $found = Find-TdTask $State $Id
        if (-not $found -or $found.list -ne 'tasks') { return $null }
        $index = $found.index
    }
    $task = $State.tasks[$index]
    $wasRunning = ($index -eq 0) -and ($null -ne $task.runningSince)
    Stop-TdTaskClock $task $NowMs
    if ($null -eq $task.startedAt) { $task.startedAt = $NowMs }
    $task.completedAt = $NowMs
    $task.pausedAt = $null
    $State.tasks.RemoveAt($index)
    $State.done.Add($task)
    if ($wasRunning -and $KeepRunning -and $State.tasks.Count -gt 0) {
        Start-TdTaskClock $State.tasks[0] $NowMs
    }
    $task
}

function Undo-TdComplete {
    # Remet une tâche terminée en tête de file (elle redevient la tâche en cours).
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Id, [long]$NowMs = (Get-TdNowMs))
    $found = Find-TdTask $State $Id
    if (-not $found -or $found.list -ne 'done') { return $null }
    $task = $found.task
    $State.done.RemoveAt($found.index)
    $task.completedAt = $null
    $task.runningSince = $null
    # Déjà commencée : elle revient « en pause depuis… » (sauf si le chrono lui est transféré).
    if ([long]$task.elapsedMs -gt 0) { $task.pausedAt = $NowMs }
    $State.tasks.Insert(0, $task)
    Sync-TdState $State $NowMs
    $task
}

function Add-TdPlannedTime {
    # +1 / +5 / -1 / -5 min à la volée, sans casser la session. Minimum : 1 minute.
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][long]$DeltaMs,
        [string]$Id
    )
    $task = $null
    if ($Id) { $found = Find-TdTask $State $Id; if ($found) { $task = $found.task } }
    else { $task = Get-TdCurrentTask $State }
    if (-not $task) { return }
    $task.plannedMs = [Math]::Max([long]60000, [long]$task.plannedMs + $DeltaMs)
}

function Update-TdTask {
    # Modifie titre, durée (minutes), catégorie, heure fixe ou note.
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$Changes
    )
    $found = Find-TdTask $State $Id
    if (-not $found) { return $null }
    $task = $found.task
    if ($Changes.ContainsKey('title') -and -not [string]::IsNullOrWhiteSpace($Changes.title)) {
        $task.title = ([string]$Changes.title).Trim()
    }
    if ($Changes.ContainsKey('minutes')) {
        $minutes = [double]$Changes.minutes
        if ($minutes -lt 1) { $minutes = 1 }
        $ms = [long][Math]::Round($minutes * 60000)
        $task.plannedMs = $ms
        # Avant de commencer, l'estimation suit la durée prévue (utile aux statistiques).
        if (-not (Test-TdTaskStarted $task)) { $task.estimateMs = $ms }
    }
    if ($Changes.ContainsKey('categoryId')) { $task.categoryId = ConvertTo-TdNullableString $Changes.categoryId }
    if ($Changes.ContainsKey('fixedStart')) { $task.fixedStart = ConvertTo-TdClockText (ConvertTo-TdNullableString $Changes.fixedStart) }
    if ($Changes.ContainsKey('note')) { $task.note = [string]$Changes.note }
    if ($Changes.ContainsKey('stepsText')) { Set-TdTaskSteps -Task $task -Text ([string]$Changes.stepsText) }
    $task
}

# ---------------------------------------------------------------- sous-étapes

function Get-TdCurrentStep {
    param([Parameter(Mandatory)]$Task)
    foreach ($step in @($Task.steps)) { if ($step -and -not $step.done) { return $step } }
    $null
}

function Get-TdStepProgress {
    param([Parameter(Mandatory)]$Task)
    $steps = @($Task.steps | Where-Object { $null -ne $_ })
    $done = @($steps | Where-Object { $_.done }).Count
    [pscustomobject][ordered]@{
        total   = $steps.Count
        done    = $done
        current = Get-TdCurrentStep $Task
        index   = [Math]::Min($done + 1, $steps.Count)
    }
}

function Complete-TdStep {
    # Coche l'étape en cours de la tâche (par défaut la tâche en cours). Renvoie l'étape cochée.
    param([Parameter(Mandatory)]$State, [string]$TaskId)
    $task = Get-TdCurrentTask $State
    if ($TaskId) { $found = Find-TdTask $State $TaskId; $task = $null; if ($found) { $task = $found.task } }
    if (-not $task) { return $null }
    $step = Get-TdCurrentStep $task
    if ($step) { $step.done = $true }
    $step
}

function Undo-TdStep {
    # Décoche la dernière étape cochée.
    param([Parameter(Mandatory)]$State, [string]$TaskId)
    $task = Get-TdCurrentTask $State
    if ($TaskId) { $found = Find-TdTask $State $TaskId; $task = $null; if ($found) { $task = $found.task } }
    if (-not $task) { return $null }
    $last = $null
    foreach ($step in @($task.steps)) { if ($step -and $step.done) { $last = $step } }
    if ($last) { $last.done = $false }
    $last
}

function ConvertFrom-TdStepsText {
    # Une étape par ligne (ou séparées par « ; »). « [x] » ou « ✓ » en tête = déjà faite.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return , @() }
    $lines = $Text -split '\r?\n'
    if ($lines.Count -eq 1) { $lines = $Text -split ';' }
    $items = foreach ($raw in $lines) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        $done = $false
        if ($line -match '^(?:[-*+\u2022]\s*)?(?:\[[xX]\]|[\u2713\u2714\u2611\u2705])\s*(.*)$') { $done = $true; $line = $Matches[1] }
        $line = $line -replace '^(?:[-*+\u2022]|\d{1,2}[.)])\s+', ''
        $line = $line -replace '^(?:\[\s?\]|[\u2610\u25A1])\s*', ''
        $line = $line.Trim()
        if ($line) { [pscustomobject]@{ title = $line; done = $done } }
    }
    , @($items)
}

function ConvertTo-TdStepsText {
    param([Parameter(Mandatory)]$Task)
    $lines = foreach ($step in @($Task.steps)) {
        if (-not $step) { continue }
        if ($step.done) { '[x] ' + $step.title } else { $step.title }
    }
    @($lines) -join [Environment]::NewLine
}

function Set-TdTaskSteps {
    # Remplace les étapes à partir d'un texte, en gardant l'identifiant des étapes inchangées.
    param([Parameter(Mandatory)]$Task, [string]$Text)
    $previous = @{}
    foreach ($step in @($Task.steps)) { if ($step) { $previous[$step.title] = $step } }
    $steps = foreach ($item in (ConvertFrom-TdStepsText $Text)) {
        $id = $null
        if ($previous.ContainsKey($item.title)) { $id = $previous[$item.title].id }
        @{ id = $id; title = $item.title; done = $item.done }
    }
    $Task.steps = ConvertTo-TdSteps @($steps)
}

function Clear-TdPending {
    param([Parameter(Mandatory)]$State)
    $State.tasks.Clear()
    $State.planEndMs = $null
}

function New-TdHistoryEntry {
    param([Parameter(Mandatory)]$Task)
    $completed = [long]$Task.completedAt
    [pscustomobject][ordered]@{
        id          = $Task.id
        title       = $Task.title
        categoryId  = $Task.categoryId
        estimateMs  = [long]$Task.estimateMs
        plannedMs   = [long]$Task.plannedMs
        actualMs    = [long]$Task.elapsedMs
        completedAt = $completed
        dayKey      = Get-TdDayKey $completed
    }
}

function Invoke-TdDayRollover {
    # Nouvelle journée : les tâches terminées les jours précédents quittent la vue
    # « Terminé aujourd'hui » (elles restent dans l'historique). Les tâches non faites
    # restent dans la file : aucune perte, aucune culpabilisation. Les tâches reportées
    # dont le jour est arrivé reviennent, et tout ce qui reste d'hier est proposé à la
    # revue du matin.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][long]$NowMs)
    $today = Get-TdDayKey $NowMs
    $removed = 0
    for ($i = $State.done.Count - 1; $i -ge 0; $i--) {
        $completed = $State.done[$i].completedAt
        if ($null -eq $completed -or (Get-TdDayKey ([long]$completed)) -ne $today) {
            $State.done.RemoveAt($i)
            $removed++
        }
    }
    $returned = 0
    for ($i = 0; $i -lt $State.parked.Count; ) {
        $task = $State.parked[$i]
        if (-not $task.deferUntil -or [string]::CompareOrdinal($task.deferUntil, $today) -le 0) {
            $State.parked.RemoveAt($i)
            $task.deferUntil = $null
            $State.tasks.Add($task)
            $returned++
        }
        else { $i++ }
    }
    $newDay = $State.dayKey -and $State.dayKey -ne $today
    if ($newDay) {
        $State.review.Clear()
        foreach ($task in $State.tasks) { $State.review.Add([string]$task.id) }
    }
    $State.dayKey = $today
    [pscustomobject]@{ removed = $removed; returned = $returned; newDay = [bool]$newDay; review = $State.review.Count }
}

function Repair-TdStaleTimer {
    # Si l'application a été fermée longtemps (PC éteint...) alors qu'un minuteur
    # tournait, on le met en pause à l'heure où TDfocus a été vu pour la dernière fois.
    # Renvoie l'heure de pause appliquée, ou $null.
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][long]$NowMs,
        [long]$MaxGapMs = 1800000
    )
    if ($State.tasks.Count -eq 0) { return $null }
    $task = $State.tasks[0]
    if ($null -eq $task.runningSince) { return $null }
    $lastSeen = [long]$State.lastSeenMs
    if ($lastSeen -le 0 -or ($NowMs - $lastSeen) -le $MaxGapMs) { return $null }
    $stopAt = [Math]::Max([long]$task.runningSince, $lastSeen)
    Stop-TdTaskClock $task $stopAt
    $task.pausedAt = $stopAt
    $stopAt
}
