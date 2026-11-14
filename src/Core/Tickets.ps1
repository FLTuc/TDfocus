# TDfocus - cockpit : les « tickets », lus directement dans la liste TDfocus.
#
# Il n'y a pas de liste de tickets à part, ni de lien avec un outil de ticketing : un ticket est
# une action de ta liste TDfocus, saisie à la main comme d'habitude. Comptent comme tickets
# toutes les actions, sauf :
#   - les blocs projet (ils comptent du côté « projets » de la jauge) ;
#   - les pauses (catégorie « Pause »).
#
# Ce fichier lit la liste (compter, trier) et ajoute deux gestes propres au helpdesk :
# escalader un ticket (il attend quelqu'un d'autre) et noter qu'on l'a relancé.
#
#   ouverts              actions de la file du jour (state.tasks), sauf celles à relancer
#   fermés aujourd'hui   actions validées aujourd'hui (state.done)
#   à relancer           actions escaladées (champ waitingSince) : mises de côté jusqu'au jour de
#                        la relance (state.parked), puis de retour dans la file ce jour-là

function Test-TdTicketTask {
    # Vrai si cette tâche compte comme un ticket : ni bloc projet, ni pause.
    param([Parameter(Mandatory)]$Task)
    (-not $Task.projectId) -and ($Task.categoryId -ne 'pause')
}

function Get-TdCurrentTicket {
    # La tâche en cours de TDfocus, si c'est un ticket. Sinon $null (bloc projet, pause, liste vide).
    param([Parameter(Mandatory)]$State)
    $task = Get-TdCurrentTask $State
    if ($task -and (Test-TdTicketTask $task)) { return $task }
    $null
}

function Find-TdParkedTask {
    # Cherche une tâche mise de côté (reportée ou escaladée). Renvoie @{ task ; index } ou $null.
    param([Parameter(Mandatory)]$State, [string]$Id)
    for ($i = 0; $i -lt $State.parked.Count; $i++) {
        if ($State.parked[$i].id -eq $Id) { return [pscustomobject]@{ task = $State.parked[$i]; index = $i } }
    }
    $null
}

# ---------------------------------------------------------------- listes et compteurs

function Test-TdTicketFollowUpDue {
    # Vrai si ce ticket escaladé est à relancer aujourd'hui : son jour est arrivé, ou il est déjà revenu dans la file.
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][long]$NowMs)
    if ($null -eq $Task.waitingSince) { return $false }
    if (-not $Task.deferUntil) { return $true }
    [string]::CompareOrdinal([string]$Task.deferUntil, (Get-TdDayKey $NowMs)) -le 0
}

function Get-TdTicketList {
    # Les tickets d'une tuile, dans l'ordre où on les affiche :
    #   open      les ouverts, dans l'ordre de ta liste TDfocus
    #   closed    les fermés d'aujourd'hui : le dernier fermé en premier
    #   waiting   les escaladés : ceux à relancer aujourd'hui d'abord, puis par date de relance
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][ValidateSet('open', 'closed', 'waiting')][string]$Kind, [long]$NowMs = (Get-TdNowMs))
    $today = Get-TdDayKey $NowMs
    switch ($Kind) {
        'open' {
            $list = $State.tasks | Where-Object { (Test-TdTicketTask $_) -and $null -eq $_.waitingSince }
        }
        'closed' {
            $list = $State.done | Where-Object { (Test-TdTicketTask $_) -and $null -ne $_.completedAt -and (Get-TdDayKey ([long]$_.completedAt)) -eq $today } |
                Sort-Object -Property @{ Expression = { [long]$_.completedAt }; Descending = $true }, id
        }
        'waiting' {
            $back = @($State.tasks | Where-Object { (Test-TdTicketTask $_) -and $null -ne $_.waitingSince })
            $aside = @($State.parked | Where-Object { (Test-TdTicketTask $_) -and $null -ne $_.waitingSince } |
                    Sort-Object -Property @{ Expression = { [string]$_.deferUntil } }, @{ Expression = { [long]$_.waitingSince } }, id)
            $list = $back + $aside
        }
    }
    @($list)
}

function Get-TdTicketCounts {
    # Les chiffres des tuiles et de la bulle.
    param([Parameter(Mandatory)]$State, [long]$NowMs = (Get-TdNowMs))
    $counts = [ordered]@{ open = 0; urgent = 0; closedToday = 0; waiting = 0; followUpDue = 0 }
    foreach ($task in @(Get-TdTicketList -State $State -Kind open -NowMs $NowMs)) {
        $counts.open++
        if ($task.urgent) { $counts.urgent++ }
    }
    $counts.closedToday = @(Get-TdTicketList -State $State -Kind closed -NowMs $NowMs).Count
    foreach ($task in @(Get-TdTicketList -State $State -Kind waiting -NowMs $NowMs)) {
        $counts.waiting++
        if (Test-TdTicketFollowUpDue -Task $task -NowMs $NowMs) { $counts.followUpDue++ }
    }
    [pscustomobject]$counts
}

# ---------------------------------------------------------------- limite de temps d'un ticket (30 min par défaut)

function Get-TdTicketProgress {
    # Avancement du minuteur vers la limite : de 0 à 1.
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][long]$NowMs, [double]$Minutes = 30)
    if ($Minutes -le 0) { return 1.0 }
    [Math]::Min(1.0, (Get-TdElapsedMs $Task $NowMs) / ($Minutes * 60000))
}

function Test-TdTicketOverTime {
    # Vrai quand le temps passé sur le ticket a atteint la limite.
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][long]$NowMs, [double]$Minutes = 30)
    (Get-TdElapsedMs $Task $NowMs) -ge ($Minutes * 60000)
}

function Test-TdLimitCrossed {
    # Vrai au moment précis où le temps passé franchit la limite (entre deux mesures) :
    # c'est ce qui déclenche l'alerte, une seule fois.
    param([long]$BeforeMs, [long]$AfterMs, [double]$Minutes = 30)
    $limit = $Minutes * 60000
    ($BeforeMs -lt $limit) -and ($AfterMs -ge $limit)
}

# ---------------------------------------------------------------- escalader et relancer

function Get-TdNextWorkdayKey {
    # Le prochain jour ouvré (du lundi au vendredi) après aujourd'hui : « 2026-11-16 ».
    param([long]$NowMs = (Get-TdNowMs))
    $date = (ConvertTo-TdLocalDate $NowMs).Date.AddDays(1)
    while ($date.DayOfWeek -eq [DayOfWeek]::Saturday -or $date.DayOfWeek -eq [DayOfWeek]::Sunday) { $date = $date.AddDays(1) }
    $date.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-TdFollowUp {
    # Quand relancer, en clair : « à relancer aujourd'hui », « relance demain », « relance lun. 16 ».
    param([string]$DateKey, [long]$NowMs = (Get-TdNowMs))
    $days = Get-TdDaysLeft -DateKey $DateKey -NowMs $NowMs
    if ($null -eq $days -or $days -le 0) { return "à relancer aujourd'hui" }
    if ($days -eq 1) { return 'relance demain' }
    'relance ' + (Format-TdDayLabel $DateKey)
}

function Set-TdTicketEscalated {
    # Escalade : le ticket attend quelqu'un d'autre. Il quitte la file du jour et reviendra tout
    # seul le prochain jour ouvré, marqué « à relancer ».
    # -KeepRunning : si son minuteur tournait, la tâche suivante démarre (comme après une validation).
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][long]$NowMs, [switch]$KeepRunning)
    $found = Find-TdTask $State $Id
    if (-not $found -or $found.list -ne 'tasks') { return $null }
    $task = $found.task
    $wasRunning = ($found.index -eq 0) -and ($null -ne $task.runningSince)
    Stop-TdTaskClock $task $NowMs
    $State.tasks.RemoveAt($found.index)
    [void]$State.review.Remove([string]$task.id)
    $task.pausedAt = $null
    if ($null -eq $task.waitingSince) { $task.waitingSince = $NowMs }
    $task.deferUntil = Get-TdNextWorkdayKey $NowMs
    $State.parked.Add($task)
    if ($wasRunning -and $KeepRunning -and $State.tasks.Count -gt 0) { Start-TdTaskClock $State.tasks[0] $NowMs }
    $task
}

function Set-TdTicketFollowUp {
    # « Relancé » : la relance est faite. Le ticket attend de nouveau, jusqu'au prochain jour ouvré.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][long]$NowMs, [switch]$KeepRunning)
    $aside = Find-TdParkedTask $State $Id
    if ($aside) {
        if ($null -eq $aside.task.waitingSince) { return $null }
        $aside.task.deferUntil = Get-TdNextWorkdayKey $NowMs
        return $aside.task
    }
    # Il était revenu dans la file : il repart de côté.
    $found = Find-TdTask $State $Id
    if (-not $found -or $found.list -ne 'tasks' -or $null -eq $found.task.waitingSince) { return $null }
    Set-TdTicketEscalated -State $State -Id $Id -NowMs $NowMs -KeepRunning:$KeepRunning
}

function Restore-TdTicket {
    # Ramène un ticket escaladé dans la file du jour, à la place voulue (0 = tâche en cours).
    # Sert à « Reprendre » et à annuler une escalade. -Keep garde la marque « à relancer ».
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Id, [int]$Index = 0, [switch]$Keep, [long]$NowMs = (Get-TdNowMs))
    $aside = Find-TdParkedTask $State $Id
    if ($aside) {
        $State.parked.RemoveAt($aside.index)
        $aside.task.deferUntil = $null
        $State.tasks.Insert([Math]::Max(0, [Math]::Min($Index, $State.tasks.Count)), $aside.task)
    }
    $found = Find-TdTask $State $Id
    if (-not $found -or $found.list -ne 'tasks') { return $null }
    if (-not $Keep) { $found.task.waitingSince = $null }
    Sync-TdState $State $NowMs
    $found.task
}

function Resume-TdTicket {
    # « Reprendre » : le ticket revient chez toi. Il n'est plus « à relancer », passe en tête de
    # file et son minuteur démarre.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][long]$NowMs)
    $task = Restore-TdTicket -State $State -Id $Id -Index $State.tasks.Count -NowMs $NowMs
    if (-not $task) { return $null }
    Start-TdTaskNow -State $State -Id $Id -NowMs $NowMs
    $task
}
