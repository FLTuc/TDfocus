# TDfocus - cockpit : ce qu'il lit dans TDfocus, en plus des tickets et de la jauge.
#
# Rien n'est saisi ailleurs que dans TDfocus. Le cockpit se contente de lire :
#   - les projets (panneau Projets de TDfocus) : avancement, prochain pas, échéance, blocage ;
#   - les relances du jour : tickets escaladés à relancer et projets bloqués à relancer ;
#   - la prochaine réunion : la prochaine action à heure fixe de la liste ;
#   - le bloc projet en cours : la tâche en cours de TDfocus, quand c'est un bloc projet ;
#   - de quoi répondre à « Où j'en étais » et faire le « Récap du jour ».

$script:TdStaleWorkdays = 2    # un projet qui n'a pas bougé depuis 2 jours ouvrés est signalé

# ---------------------------------------------------------------- jours ouvrés

function Get-TdWorkdaysBetween {
    # Nombre de jours ouvrés (du lundi au vendredi) écoulés entre deux instants : vendredi -> lundi = 1.
    param([long]$FromMs, [long]$ToMs)
    $day = (ConvertTo-TdLocalDate $FromMs).Date
    $end = (ConvertTo-TdLocalDate $ToMs).Date
    $count = 0
    while ($day -lt $end -and $count -lt 400) {
        $day = $day.AddDays(1)
        if ($day.DayOfWeek -ne [DayOfWeek]::Saturday -and $day.DayOfWeek -ne [DayOfWeek]::Sunday) { $count++ }
    }
    $count
}

# ---------------------------------------------------------------- projets

function Set-TdProjectBlocked {
    # « Bloqué : en attente de… ». Un texte vide débloque le projet. Bloqué, il sera à relancer le prochain jour ouvré.
    param([Parameter(Mandatory)]$Project, [string]$Reason, [long]$NowMs = (Get-TdNowMs))
    $text = ([string]$Reason -replace '\s+', ' ').Trim()
    $Project.blockedBy = $text
    if ($text) { $Project.followUpOn = Get-TdNextWorkdayKey $NowMs } else { $Project.followUpOn = $null }
}

function Set-TdProjectFollowUp {
    # « Relancé » : la relance est faite, la suivante est prévue le prochain jour ouvré.
    param([Parameter(Mandatory)]$Project, [long]$NowMs = (Get-TdNowMs))
    if ($Project.blockedBy) { $Project.followUpOn = Get-TdNextWorkdayKey $NowMs }
}

function Test-TdProjectFollowUpDue {
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)][long]$NowMs)
    if ($Project.status -ne 'active' -or -not $Project.blockedBy) { return $false }
    if (-not $Project.followUpOn) { return $true }
    [string]::CompareOrdinal([string]$Project.followUpOn, (Get-TdDayKey $NowMs)) -le 0
}

function Format-TdDeadlineShort {
    # Échéance en abrégé : « J-6 », « J-0 » le jour même, « J+2 » si elle est passée.
    param($Days)
    if ($null -eq $Days) { return '' }
    if ([int]$Days -ge 0) { return 'J-{0}' -f [int]$Days }
    'J+{0}' -f (-[int]$Days)
}

function Get-TdProjectTodayMs {
    # Temps passé aujourd'hui sur les blocs d'un projet.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$ProjectId, [Parameter(Mandatory)][long]$NowMs)
    $total = [long]0
    foreach ($list in @($State.tasks, $State.done, $State.parked)) {
        foreach ($task in $list) { if ($task.projectId -eq $ProjectId) { $total += Get-TdTaskTodayMs $task $NowMs } }
    }
    $total
}

function Get-TdCockpitProjects {
    # Les projets en cours, tels que le cockpit les affiche. Pour chacun :
    #   percent       avancement en % (pas faits / pas prévus), ou $null s'il n'a pas encore de pas
    #   nextStep      le prochain pas (le « jalon »)
    #   deadlineText  « J-6 », ou vide
    #   blocked       bloqué : en attente de quelqu'un (blockedBy)
    #   idleDays      jours ouvrés depuis le dernier bloc ; stale = pas bougé depuis 2 jours ouvrés
    #   alertText     la partie à mettre en couleur d'alerte ; detailText : le reste de la ligne
    param([AllowNull()][AllowEmptyCollection()]$Projects, [Parameter(Mandatory)]$State, [long]$NowMs = (Get-TdNowMs))
    foreach ($project in @(Get-TdActiveProjects $Projects)) {
        $progress = Get-TdProjectProgress $project
        $percent = $null
        if ($progress.total -gt 0) { $percent = [int][Math]::Round(100.0 * $progress.done / $progress.total) }
        $next = ''
        $pending = @(Get-TdProjectPendingSteps $project 1)
        if ($pending.Count -gt 0) { $next = [string]$pending[0].title }
        $deadline = Format-TdDeadlineShort (Get-TdDaysLeft $project.deadline $NowMs)
        $since = $project.lastWorkedAt
        if ($null -eq $since) { $since = $project.createdAt }
        $idle = Get-TdWorkdaysBetween -FromMs ([long]$since) -ToMs $NowMs
        if ((Get-TdProjectTodayMs -State $State -ProjectId $project.id -NowMs $NowMs) -gt 0) { $idle = 0 }
        $blocked = [bool]$project.blockedBy
        $stale = (-not $blocked) -and ($idle -ge $script:TdStaleWorkdays)

        $alert = ''
        $parts = @()
        if ($blocked) { $parts += 'Bloqué : en attente de ' + $project.blockedBy }
        else {
            if ($stale) { $alert = "Pas bougé depuis $idle jours" }
            if ($next) { $parts += 'Jalon : ' + $next } else { $parts += 'Prochain pas à définir' }
        }
        if ($deadline) { $parts += $deadline }
        [pscustomobject]@{
            id           = $project.id
            name         = $project.name
            percent      = $percent
            nextStep     = $next
            deadlineText = $deadline
            blocked      = $blocked
            idleDays     = $idle
            stale        = $stale
            alertText    = $alert
            detailText   = $parts -join (' ' + [char]0x00B7 + ' ')
        }
    }
}

# ---------------------------------------------------------------- relances du jour, prochaine réunion

function Get-TdFollowUps {
    # Les relances à faire aujourd'hui, tickets et projets mélangés. Chaque ligne : kind ('ticket' ou 'project'), id, text.
    param([Parameter(Mandatory)]$State, [AllowNull()][AllowEmptyCollection()]$Projects, [long]$NowMs = (Get-TdNowMs))
    foreach ($task in @(Get-TdTicketList -State $State -Kind waiting -NowMs $NowMs)) {
        if (Test-TdTicketFollowUpDue -Task $task -NowMs $NowMs) { [pscustomobject]@{ kind = 'ticket'; id = [string]$task.id; text = [string]$task.title } }
    }
    foreach ($project in @(Get-TdActiveProjects $Projects)) {
        if (Test-TdProjectFollowUpDue -Project $project -NowMs $NowMs) {
            [pscustomobject]@{ kind = 'project'; id = [string]$project.id; text = $project.name + ' ' + [char]0x00B7 + ' relancer : ' + $project.blockedBy }
        }
    }
}

function Format-TdDelay {
    # « dans 58 min », « dans 1 h 05 »
    param([Parameter(Mandatory)][long]$Ms)
    'dans ' + (Format-TdMinutes ([Math]::Max(1, [Math]::Ceiling($Ms / 60000.0))))
}

function Get-TdNextMeeting {
    # La prochaine réunion : la prochaine action à heure fixe de la liste (hors blocs projet et pauses).
    # Renvoie @{ task ; startMs ; text = « 15:30 · Point d'équipe » ; delay = « dans 58 min » }, ou $null.
    param([Parameter(Mandatory)]$State, [long]$NowMs = (Get-TdNowMs))
    $best = $null
    foreach ($task in $State.tasks) {
        if (-not $task.fixedStart -or -not (Test-TdTicketTask $task)) { continue }
        $start = ConvertFrom-TdClockText -Clock $task.fixedStart -DayMs $NowMs
        if ($null -eq $start -or [long]$start -le $NowMs) { continue }
        if (-not $best -or [long]$start -lt $best.startMs) {
            $best = [pscustomobject]@{
                task = $task; startMs = [long]$start
                text = $task.fixedStart + ' ' + [char]0x00B7 + ' ' + $task.title
                delay = Format-TdDelay -Ms ([long]$start - $NowMs)
            }
        }
    }
    $best
}

# ---------------------------------------------------------------- bloc projet

function Get-TdProjectBlockInfo {
    # Le bloc projet en cours : la tâche en cours de TDfocus, quand c'est un bloc projet (sinon $null).
    #   slotText        « 14:00 – 15:30 » si le bloc est planifié à heure fixe, sinon sa durée (« 25 min »)
    #   remainingText   « Reste 52 min », ou « Dépassé de 5 min »
    #   ratio           part du temps prévu déjà écoulée (de 0 à 1)
    param([Parameter(Mandatory)]$State, [AllowNull()][AllowEmptyCollection()]$Projects, [long]$NowMs = (Get-TdNowMs))
    $task = Get-TdCurrentTask $State
    if (-not $task -or -not $task.projectId) { return $null }
    $project = Find-TdProject $Projects $task.projectId
    $slot = Format-TdDurationMs $task.plannedMs
    if ($task.fixedStart) {
        $start = ConvertFrom-TdClockText -Clock $task.fixedStart -DayMs $NowMs
        $slot = $task.fixedStart + ' ' + [char]0x2013 + ' ' + (Format-TdClock ([long]$start + [long]$task.plannedMs))
    }
    $remaining = Get-TdRemainingMs $task $NowMs
    $text = 'Reste ' + (Format-TdMinutes ([Math]::Ceiling($remaining / 60000.0)))
    if ($remaining -lt 0) { $text = 'Dépassé de ' + (Format-TdMinutes ([Math]::Ceiling(-$remaining / 60000.0))) }
    $name = [string]$task.title
    $crumb = ''
    if ($project) { $name = $project.name; $crumb = [string]$project.breadcrumb }
    [pscustomobject]@{
        task          = $task
        project       = $project
        name          = $name
        slotText      = $slot
        remainingText = $text
        over          = ($remaining -lt 0)
        ratio         = [Math]::Min(1.0, [Math]::Max(0.0, (Get-TdElapsedMs $task $NowMs) / [double][Math]::Max([long]1, [long]$task.plannedMs)))
        running       = ($null -ne $task.runningSince)
        currentStep   = Get-TdCurrentStep $task
        breadcrumb    = $crumb
    }
}

function Get-TdDueProjectBlock {
    # Un bloc projet planifié à heure fixe dont l'heure est arrivée, et qui n'est pas encore la tâche en cours.
    # Renvoie la tâche (la plus ancienne si plusieurs), ou $null.
    param([Parameter(Mandatory)]$State, [long]$NowMs = (Get-TdNowMs))
    $best = $null
    $bestStart = [long]::MaxValue
    for ($i = 1; $i -lt $State.tasks.Count; $i++) {
        $task = $State.tasks[$i]
        if (-not $task.projectId -or -not $task.fixedStart) { continue }
        $start = ConvertFrom-TdClockText -Clock $task.fixedStart -DayMs $NowMs
        if ($null -eq $start) { continue }
        if ([long]$start -le $NowMs -and $NowMs -lt ([long]$start + [long]$task.plannedMs) -and [long]$start -lt $bestStart) {
            $best = $task
            $bestStart = [long]$start
        }
    }
    $best
}

# ---------------------------------------------------------------- « Où j'en étais » et « Récap du jour »

function Get-TdWhereWasI {
    # De quoi reprendre le fil après une interruption. Renvoie des lignes @{ title ; text }.
    param([Parameter(Mandatory)]$State, [AllowNull()][AllowEmptyCollection()]$Projects, [long]$NowMs = (Get-TdNowMs))
    $task = Get-TdCurrentTask $State
    if ($task) {
        $what = 'pas encore commencée'
        if ($null -ne $task.runningSince) { $what = 'minuteur en marche, ' + (Format-TdDurationMs (Get-TdElapsedMs $task $NowMs)) + ' passées' }
        elseif ([long]$task.elapsedMs -gt 0) {
            $what = 'en pause, ' + (Format-TdDurationMs $task.elapsedMs) + ' passées'
            $paused = Get-TdPausedMs $task $NowMs
            if ($null -ne $paused) { $what = 'en pause ' + (Format-TdPausedFor $paused) + ', ' + (Format-TdDurationMs $task.elapsedMs) + ' passées' }
        }
        [pscustomobject]@{ title = 'En cours : ' + $task.title; text = $what }
        $step = Get-TdCurrentStep $task
        if ($step) { [pscustomobject]@{ title = 'Étape'; text = [string]$step.title } }
        if ($task.note) { [pscustomobject]@{ title = 'Note'; text = [string]$task.note } }
    }
    else { [pscustomobject]@{ title = 'Rien en cours'; text = 'Ta liste TDfocus est vide.' } }
    $closed = @(Get-TdTicketList -State $State -Kind closed -NowMs $NowMs)
    if ($closed.Count -gt 0) {
        [pscustomobject]@{ title = 'Dernière action fermée'; text = $closed[0].title + ' (à ' + (Format-TdClock ([long]$closed[0].completedAt)) + ')' }
    }
    foreach ($project in @(Get-TdActiveProjects $Projects)) {
        if ($project.breadcrumb) { [pscustomobject]@{ title = 'Projet ' + $project.name; text = [string]$project.breadcrumb } }
    }
}

function Get-TdDayRecap {
    # Le récap du jour, en lignes @{ title ; text } : ce qui est fait, le temps, ce qui attend.
    param([Parameter(Mandatory)]$State, [AllowNull()][AllowEmptyCollection()]$Projects, [long]$NowMs = (Get-TdNowMs), [int]$TicketShare = 60)
    $dot = ' ' + [char]0x00B7 + ' '
    $counts = Get-TdTicketCounts -State $State -NowMs $NowMs
    $balance = Get-TdDayBalance -State $State -NowMs $NowMs -TicketShare $TicketShare
    $closed = @(Get-TdTicketList -State $State -Kind closed -NowMs $NowMs)
    $text = 'aucun pour l''instant'
    if ($closed.Count -gt 0) {
        $names = @($closed | Select-Object -First 5 | ForEach-Object { $_.title })
        $text = $names -join $dot
        if ($closed.Count -gt 5) { $text += $dot + ('et {0} de plus' -f ($closed.Count - 5)) }
    }
    [pscustomobject]@{ title = 'Tickets fermés : ' + $closed.Count; text = $text }
    [pscustomobject]@{ title = 'Temps mesuré'; text = 'Tickets ' + (Format-TdDurationMs $balance.ticketMs) + $dot + 'Projets ' + (Format-TdDurationMs $balance.projectMs) }
    foreach ($project in @(Get-TdActiveProjects $Projects)) {
        $ms = Get-TdProjectTodayMs -State $State -ProjectId $project.id -NowMs $NowMs
        if ($ms -ge 60000) { [pscustomobject]@{ title = 'Projet ' + $project.name; text = (Format-TdDurationMs $ms) + " aujourd'hui" } }
    }
    $today = Get-TdDayKey $NowMs
    $escalated = @($State.parked | Where-Object { $null -ne $_.waitingSince -and (Get-TdDayKey ([long]$_.waitingSince)) -eq $today })
    if ($escalated.Count -gt 0) { [pscustomobject]@{ title = 'Escaladés aujourd''hui : ' + $escalated.Count; text = (@($escalated | ForEach-Object { $_.title }) -join $dot) } }
    $rest = '{0} ouverts' -f $counts.open
    if ($counts.open -le 1) { $rest = '{0} ouvert' -f $counts.open }
    [pscustomobject]@{ title = 'Il reste'; text = $rest + $dot + ('{0} à relancer' -f $counts.waiting) }
}
