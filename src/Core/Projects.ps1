# TDfocus - projets au long cours et actions du quotidien (le « run »).
#
# Deux logiques différentes, pensées pour le fonctionnement TDAH :
#   - Quotidien : des actions récurrentes ajoutées toutes seules les jours prévus, sans
#     décision à prendre. Ce qui n'est pas fait ne s'accumule pas : l'action revient
#     simplement le prochain jour prévu (pas de dette, pas de culpabilité).
#   - Projets : ils restent hors de la liste du jour (pas de surcharge) mais pas hors de vue.
#     Au plus 3 en cours (moins de dispersion), découpés en petits pas, avancés par blocs de
#     temps courts, avec une note « où j'en étais » pour reprendre sans effort et le
#     « pourquoi » sous les yeux. Un seul rappel doux par jour pour le projet qui attend.

$script:TdMaxActiveProjects = 3
$script:TdDayNames = @('lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim')

# ---------------------------------------------------------------- dates

function ConvertTo-TdDateKey {
    # Échéance saisie librement : 2026-12-15, 15/12/2026, 15/12 (prochaine occurrence), 15.12.
    param([string]$Text, [long]$NowMs = (Get-TdNowMs))
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $today = (ConvertTo-TdLocalDate $NowMs).Date
    try {
        if ($t -match '^(\d{4})-(\d{1,2})-(\d{1,2})$') { $date = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]) }
        elseif ($t -match '^(\d{1,2})[/.](\d{1,2})[/.](\d{2,4})$') {
            $year = [int]$Matches[3]
            if ($year -lt 100) { $year += 2000 }
            $date = [datetime]::new($year, [int]$Matches[2], [int]$Matches[1])
        }
        elseif ($t -match '^(\d{1,2})[/.](\d{1,2})$') {
            $date = [datetime]::new($today.Year, [int]$Matches[2], [int]$Matches[1])
            if ($date -lt $today) { $date = $date.AddYears(1) }
        }
        else { return $null }
    }
    catch { return $null }
    $date.ToString('yyyy-MM-dd', $inv)
}

function Get-TdDaysBetween {
    # Nombre de jours calendaires entre deux instants (heure locale).
    param([long]$FromMs, [long]$ToMs)
    [int]((ConvertTo-TdLocalDate $ToMs).Date - (ConvertTo-TdLocalDate $FromMs).Date).TotalDays
}

function Get-TdDaysLeft {
    param([string]$DateKey, [long]$NowMs = (Get-TdNowMs))
    if (-not $DateKey) { return $null }
    $date = [datetime]::ParseExact($DateKey, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    [int]($date - (ConvertTo-TdLocalDate $NowMs).Date).TotalDays
}

function Format-TdDaysLeft {
    # Échéance en langage courant : la cécité temporelle rend « le 15/12 » abstrait.
    param($Days)
    if ($null -eq $Days) { return '' }
    $d = [int]$Days
    if ($d -lt 0) { return 'échéance passée : on ajuste la date ?' }
    if ($d -eq 0) { return "échéance aujourd'hui" }
    if ($d -eq 1) { return 'échéance demain' }
    if ($d -lt 14) { return "échéance dans $d jours" }
    if ($d -lt 60) { return 'échéance dans {0} semaines' -f [int][Math]::Floor($d / 7) }
    'échéance dans {0} mois' -f [int][Math]::Round($d / 30.0)
}

function Format-TdIdle {
    # Depuis quand le projet attend, sans reproche.
    param($Days, [switch]$NeverWorked)
    if ($NeverWorked) { return 'pas encore commencé' }
    $d = [int]$Days
    if ($d -le 0) { return "avancé aujourd'hui" }
    if ($d -eq 1) { return 'dernier pas hier' }
    "dernier pas il y a $d jours"
}

# ---------------------------------------------------------------- projets

function ConvertTo-TdProject {
    param([Parameter(Mandatory)]$InputObject)
    $id = ConvertTo-TdNullableString (Get-TdValue $InputObject 'id')
    if (-not $id) { $id = New-TdId }
    $status = [string](Get-TdValue $InputObject 'status')
    if (@('active', 'paused', 'done') -notcontains $status) { $status = 'active' }
    $block = [int](Get-TdValue $InputObject 'blockMinutes')
    if ($block -lt 5) { $block = 25 }
    $emoji = ConvertTo-TdNullableString (Get-TdValue $InputObject 'emoji')
    if (-not $emoji) { $emoji = [char]::ConvertFromUtf32(0x1F331) }
    $deadline = ConvertTo-TdNullableString (Get-TdValue $InputObject 'deadline')
    if ($deadline -and $deadline -notmatch '^\d{4}-\d{2}-\d{2}$') { $deadline = $null }
    $invested = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'investedMs')
    if ($null -eq $invested -or $invested -lt 0) { $invested = 0 }
    $created = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'createdAt')
    if ($null -eq $created) { $created = 0 }
    [pscustomobject][ordered]@{
        id           = $id
        name         = ([string](Get-TdValue $InputObject 'name')).Trim()
        emoji        = $emoji
        why          = ([string](Get-TdValue $InputObject 'why')).Trim()
        status       = $status
        deadline     = $deadline
        blockMinutes = $block
        steps        = ConvertTo-TdSteps (Get-TdValue $InputObject 'steps')
        breadcrumb   = ([string](Get-TdValue $InputObject 'breadcrumb')).Trim()
        breadcrumbAt = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'breadcrumbAt')
        createdAt    = [long]$created
        lastWorkedAt = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'lastWorkedAt')
        investedMs   = [long]$invested
        sessions     = [int](Get-TdValue $InputObject 'sessions')
        doneAt       = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'doneAt')
    }
}

function New-TdProject {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Why = '',
        [string]$Deadline,
        [string]$Emoji,
        [int]$BlockMinutes = 25,
        [string[]]$Steps = @(),
        [long]$NowMs = (Get-TdNowMs)
    )
    ConvertTo-TdProject @{
        name = $Name; why = $Why; deadline = $Deadline; emoji = $Emoji; blockMinutes = $BlockMinutes
        steps = @($Steps); createdAt = $NowMs; status = 'active'
    }
}

function Find-TdProject {
    param([AllowNull()][AllowEmptyCollection()]$Projects, [string]$Id)
    if (-not $Id) { return $null }
    foreach ($p in @($Projects)) { if ($p -and $p.id -eq $Id) { return $p } }
    $null
}

function Get-TdActiveProjects {
    param([AllowNull()][AllowEmptyCollection()]$Projects)
    $Projects | Where-Object { $_ -and $_.status -eq 'active' }
}

function Add-TdProject {
    # Ajoute un projet. Au-delà de 3 projets en cours, il est rangé « en attente » :
    # avancer peu de choses à la fois évite la dispersion. Renvoie le statut obtenu.
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Projects, [Parameter(Mandatory)]$Project)
    if (@(Get-TdActiveProjects $Projects).Count -ge $script:TdMaxActiveProjects) { $Project.status = 'paused' }
    $Projects.Add($Project)
    $Project.status
}

function Set-TdProjectStatus {
    # active (en cours), paused (en attente, sans culpabilité), done (terminé).
    # Faux si l'on veut reprendre un 4e projet : il faut d'abord en mettre un en attente.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]$Projects,
        [Parameter(Mandatory)]$Project,
        [Parameter(Mandatory)][ValidateSet('active', 'paused', 'done')][string]$Status,
        [long]$NowMs = (Get-TdNowMs)
    )
    if ($Status -eq 'active' -and $Project.status -ne 'active' -and @(Get-TdActiveProjects $Projects).Count -ge $script:TdMaxActiveProjects) { return $false }
    $Project.status = $Status
    if ($Status -eq 'done') { $Project.doneAt = $NowMs } else { $Project.doneAt = $null }
    $true
}

function Add-TdProjectStep {
    # Un « pas » : la prochaine action concrète et courte (« ouvrir le devis », pas « la cuisine »).
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)][string]$Title)
    $step = @(ConvertTo-TdSteps @($Title))[0]
    if (-not $step) { return $null }
    $Project.steps = @(@($Project.steps) + $step | Where-Object { $_ })
    $step
}

function Set-TdProjectStepDone {
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)][string]$StepId, [bool]$Done = $true)
    foreach ($s in @($Project.steps)) { if ($s -and $s.id -eq $StepId) { $s.done = $Done; return $s } }
    $null
}

function Remove-TdProjectStep {
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)][string]$StepId)
    $Project.steps = @(@($Project.steps) | Where-Object { $_ -and $_.id -ne $StepId })
}

function Get-TdProjectPendingSteps {
    param([Parameter(Mandatory)]$Project, [int]$Count = 3)
    @($Project.steps) | Where-Object { $_ -and -not $_.done } | Select-Object -First $Count
}

function Get-TdProjectProgress {
    param([Parameter(Mandatory)]$Project)
    $steps = @(@($Project.steps) | Where-Object { $_ })
    [pscustomobject]@{ total = $steps.Count; done = @($steps | Where-Object { $_.done }).Count }
}

function Set-TdProjectBreadcrumb {
    # « Où j'en étais » : la mémoire de travail confiée à l'outil, pour reprendre sans effort.
    param([Parameter(Mandatory)]$Project, [string]$Text, [long]$NowMs = (Get-TdNowMs))
    $Project.breadcrumb = ([string]$Text).Trim()
    $Project.breadcrumbAt = $NowMs
}

function New-TdProjectBlockTask {
    # Un bloc de temps court pour le projet, avec ses 3 prochains pas comme sous-étapes :
    # on voit le prochain geste, jamais le projet entier.
    param([Parameter(Mandatory)]$Project, [double]$Minutes, [long]$NowMs = (Get-TdNowMs))
    if (-not $Minutes) { $Minutes = $Project.blockMinutes }
    $task = New-TdTask -Title $Project.name -Minutes $Minutes -Source 'project' -NowMs $NowMs
    $task.steps = ConvertTo-TdSteps @(Get-TdProjectPendingSteps $Project 3 | ForEach-Object { @{ id = $_.id; title = $_.title; done = $false } })
    $task.projectId = $Project.id
    $task
}

function Sync-TdProjectFromTask {
    # Reporte sur le projet les pas cochés pendant le bloc.
    param([AllowNull()][AllowEmptyCollection()]$Projects, [Parameter(Mandatory)]$Task)
    $project = Find-TdProject $Projects $Task.projectId
    if (-not $project) { return $null }
    $byId = @{}
    foreach ($s in @($project.steps)) { if ($s) { $byId[$s.id] = $s } }
    foreach ($s in @($Task.steps)) { if ($s -and $byId.ContainsKey($s.id)) { $byId[$s.id].done = [bool]$s.done } }
    $project
}

function Complete-TdProjectBlock {
    # Bloc terminé : pas cochés, temps investi et date du dernier pas mis à jour.
    param([AllowNull()][AllowEmptyCollection()]$Projects, [Parameter(Mandatory)]$Task, [long]$NowMs = (Get-TdNowMs))
    $project = Sync-TdProjectFromTask $Projects $Task
    if (-not $project) { return $null }
    $project.investedMs = [long]$project.investedMs + [long]$Task.elapsedMs
    $project.sessions = [int]$project.sessions + 1
    $project.lastWorkedAt = $NowMs
    $project
}

function Undo-TdProjectBlock {
    param([AllowNull()][AllowEmptyCollection()]$Projects, [Parameter(Mandatory)]$Task)
    $project = Find-TdProject $Projects $Task.projectId
    if (-not $project) { return $null }
    $project.investedMs = [Math]::Max([long]0, [long]$project.investedMs - [long]$Task.elapsedMs)
    $project.sessions = [Math]::Max(0, [int]$project.sessions - 1)
    $project
}

function Test-TdProjectPlannedToday {
    # Un bloc de ce projet (ou de n'importe quel projet sans -ProjectId) est-il prévu ou fait aujourd'hui ?
    param([Parameter(Mandatory)]$State, [string]$ProjectId)
    foreach ($t in @($State.tasks) + @($State.done)) {
        if ($t -and $t.projectId -and (-not $ProjectId -or $t.projectId -eq $ProjectId)) { return $true }
    }
    $false
}

function Get-TdProjectNudge {
    # Rappel doux : le projet en cours dont l'échéance approche, sinon celui qui attend
    # depuis le plus longtemps. Seulement si aucun bloc projet n'est prévu ni fait
    # aujourd'hui, et une seule fois par jour (« pas aujourd'hui » le fait taire).
    param([AllowNull()][AllowEmptyCollection()]$Projects, [Parameter(Mandatory)]$State, [long]$NowMs = (Get-TdNowMs))
    if ($State.nudgeOff -eq (Get-TdDayKey $NowMs)) { return $null }
    if (Test-TdProjectPlannedToday -State $State) { return $null }
    $best = $null
    $bestScore = [double]::NegativeInfinity
    foreach ($p in @(Get-TdActiveProjects $Projects)) {
        $since = $p.lastWorkedAt
        if ($null -eq $since) { $since = $p.createdAt }
        $idle = [Math]::Max(0, (Get-TdDaysBetween -FromMs $since -ToMs $NowMs))
        $left = Get-TdDaysLeft $p.deadline $NowMs
        $score = [double]$idle
        if ($null -ne $left -and $left -le 14) { $score = 1000 - $left }
        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = [pscustomobject]@{ project = $p; idleDays = $idle; daysLeft = $left; neverWorked = ($null -eq $p.lastWorkedAt) }
        }
    }
    $best
}

function Get-TdNudgeText {
    # Formulation du rappel : une invitation, jamais un reproche.
    param([Parameter(Mandatory)]$Nudge)
    $name = $Nudge.project.name
    if ($null -ne $Nudge.daysLeft -and $Nudge.daysLeft -le 14) { return '« {0} » : {1}. Un petit bloc aujourd''hui ?' -f $name, (Format-TdDaysLeft $Nudge.daysLeft) }
    if ($Nudge.neverWorked) { return '« {0} » n''a pas encore démarré. Un premier petit pas aujourd''hui ?' -f $name }
    if ($Nudge.idleDays -le 1) { return '« {0} » : un petit pas aujourd''hui aussi ?' -f $name }
    '« {0} » attend depuis {1} jours. Un petit pas aujourd''hui ?' -f $name, $Nudge.idleDays
}

function Get-TdProjectSummary {
    # « 3/8 pas · 2 h 30 investies · dernier pas hier · échéance dans 3 semaines »
    param([Parameter(Mandatory)]$Project, [long]$NowMs = (Get-TdNowMs))
    $parts = @()
    $progress = Get-TdProjectProgress $Project
    if ($progress.total -gt 0) { $parts += '{0}/{1} pas' -f $progress.done, $progress.total }
    if ($Project.investedMs -ge 60000) { $parts += '{0} investies' -f (Format-TdDurationMs $Project.investedMs) }
    if ($Project.status -ne 'done') {
        $since = $Project.lastWorkedAt
        if ($null -eq $since) { $parts += Format-TdIdle -NeverWorked }
        else { $parts += Format-TdIdle ([Math]::Max(0, (Get-TdDaysBetween -FromMs $since -ToMs $NowMs))) }
        if ($Project.deadline) { $parts += Format-TdDaysLeft (Get-TdDaysLeft $Project.deadline $NowMs) }
    }
    $parts -join ' · '
}

# ---------------------------------------------------------------- actions du quotidien

function ConvertTo-TdDailyAction {
    param([Parameter(Mandatory)]$InputObject)
    $id = ConvertTo-TdNullableString (Get-TdValue $InputObject 'id')
    if (-not $id) { $id = New-TdId }
    $minutes = [double](Get-TdValue $InputObject 'minutes')
    if ($minutes -lt 1) { $minutes = 10 }
    $days = @(@(Get-TdValue $InputObject 'days') | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 1 -and $_ -le 7 } | Sort-Object -Unique)
    if ($days.Count -eq 0) { $days = @(1, 2, 3, 4, 5, 6, 7) }
    $active = Get-TdValue $InputObject 'active'
    if ($null -eq $active) { $active = $true }
    $steps = @(@(Get-TdValue $InputObject 'steps') | Where-Object { $_ } | ForEach-Object {
            if ($_ -is [string]) { $_ } else { [string](Get-TdValue $_ 'title') }
        } | Where-Object { $_ })
    [pscustomobject][ordered]@{
        id         = $id
        title      = ([string](Get-TdValue $InputObject 'title')).Trim()
        minutes    = $minutes
        days       = $days
        fixedStart = ConvertTo-TdClockText (ConvertTo-TdNullableString (Get-TdValue $InputObject 'fixedStart'))
        categoryId = ConvertTo-TdNullableString (Get-TdValue $InputObject 'categoryId')
        steps      = $steps
        active     = [bool]$active
    }
}

function New-TdDailyAction {
    param(
        [Parameter(Mandatory)][string]$Title,
        [double]$Minutes = 10,
        [int[]]$Days = @(1, 2, 3, 4, 5, 6, 7),
        [string]$FixedStart,
        [string]$CategoryId,
        [string[]]$Steps = @()
    )
    ConvertTo-TdDailyAction @{ title = $Title; minutes = $Minutes; days = @($Days); fixedStart = $FixedStart; categoryId = $CategoryId; steps = @($Steps) }
}

function Get-TdIsoDayOfWeek {
    # 1 = lundi … 7 = dimanche
    param([long]$NowMs = (Get-TdNowMs))
    $d = [int](ConvertTo-TdLocalDate $NowMs).DayOfWeek
    if ($d -eq 0) { return 7 }
    $d
}

function ConvertFrom-TdDaysText {
    # « tous les jours », « en semaine », « lun-ven », « week-end », « lun mer ven », « mar,jeu ».
    # Renvoie les jours (1 = lundi) ou $null si le texte n'est pas compris.
    param([string]$Text)
    $t = ([string]$Text).Trim().ToLowerInvariant()
    if (-not $t -or $t -match '^(tous les jours|chaque jour|quotidien|tlj|tous)$') { return , @(1, 2, 3, 4, 5, 6, 7) }
    if ($t -match '^(en semaine|semaine|jours ouvrés|jours ouvres|ouvrés|ouvres)$') { return , @(1, 2, 3, 4, 5) }
    if ($t -match '^(week-?end|we|le week-?end)$') { return , @(6, 7) }
    $index = @{}
    for ($i = 0; $i -lt 7; $i++) { $index[$script:TdDayNames[$i]] = $i + 1 }
    $days = [System.Collections.Generic.List[int]]::new()
    foreach ($part in ($t -split '[\s,;]+' | Where-Object { $_ })) {
        if ($part -match '^([a-zé]{3})[a-zé]*-([a-zé]{3})[a-zé]*$') {
            if (-not $index.ContainsKey($Matches[1]) -or -not $index.ContainsKey($Matches[2])) { return $null }
            $a = $index[$Matches[1]]
            $b = $index[$Matches[2]]
            if ($b -lt $a) { return $null }
            for ($d = $a; $d -le $b; $d++) { $days.Add($d) }
        }
        elseif ($part.Length -ge 3 -and $index.ContainsKey($part.Substring(0, 3))) { $days.Add($index[$part.Substring(0, 3)]) }
        else { return $null }
    }
    , @($days | Sort-Object -Unique)
}

function Format-TdDays {
    param([int[]]$Days)
    $set = @($Days | Sort-Object -Unique)
    if ($set.Count -eq 7) { return 'tous les jours' }
    if (($set -join ',') -eq '1,2,3,4,5') { return 'en semaine' }
    if (($set -join ',') -eq '6,7') { return 'le week-end' }
    ($set | ForEach-Object { $script:TdDayNames[$_ - 1] }) -join ', '
}

function Test-TdDailyDue {
    param([Parameter(Mandatory)]$Action, [long]$NowMs = (Get-TdNowMs))
    $Action.active -and (@($Action.days) -contains (Get-TdIsoDayOfWeek $NowMs))
}

function Sync-TdDailyTasks {
    # Ajoute dans la file les actions du quotidien prévues aujourd'hui, une seule fois par jour :
    # une action supprimée ou faite aujourd'hui ne revient pas avant le prochain jour prévu.
    # Renvoie le nombre de tâches ajoutées.
    param([Parameter(Mandatory)]$State, [AllowNull()][AllowEmptyCollection()]$Daily, [long]$NowMs = (Get-TdNowMs))
    $today = Get-TdDayKey $NowMs
    if ($State.dailyKey -ne $today) {
        $State.dailyKey = $today
        $State.dailyMade.Clear()
    }
    $added = 0
    foreach ($action in @($Daily)) {
        if (-not $action -or -not (Test-TdDailyDue $action $NowMs) -or $State.dailyMade.Contains([string]$action.id)) { continue }
        $State.dailyMade.Add([string]$action.id)
        if (@($State.tasks | Where-Object { $_.dailyId -eq $action.id }).Count -gt 0) { continue }
        $task = New-TdTask -Title $action.title -Minutes $action.minutes -CategoryId $action.categoryId -FixedStart $action.fixedStart -Steps @($action.steps) -Source 'daily' -NowMs $NowMs
        $task.dailyId = $action.id
        Add-TdTask -State $State -Task $task -NowMs $NowMs
        $added++
    }
    $added
}
