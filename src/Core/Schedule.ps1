# TDfocus - calcul prédictif et ancrage temporel.
#
# L'heure de fin de chaque tâche est projetée à partir de l'heure courante :
#   tâche en cours  : maintenant + temps restant (0 si dépassement : la fin glisse avec l'horloge)
#   tâches suivantes: fin de la précédente + durée prévue
#   créneau figé    : ne commence pas avant son heure (temps libre avant) ; s'il est
#                     dépassé, le retard est signalé.
# Tout dépassement ou toute pause repousse donc instantanément la fin de journée.

function Get-TdSchedule {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][long]$NowMs)
    $items = [System.Collections.Generic.List[object]]::new()
    $cursor = $NowMs
    $totalRemaining = [long]0
    for ($i = 0; $i -lt $State.tasks.Count; $i++) {
        $task = $State.tasks[$i]
        $gap = [long]0
        $late = [long]0
        $fixedMs = $null
        $inProgress = ($i -eq 0) -and (Test-TdTaskStarted $task)
        if ($task.fixedStart -and -not $inProgress) {
            $fixedMs = ConvertFrom-TdClockText -Clock $task.fixedStart -DayMs $NowMs
            if ($null -ne $fixedMs) {
                if ($fixedMs -gt $cursor) {
                    $gap = $fixedMs - $cursor
                    $cursor = $fixedMs
                }
                elseif (($cursor - $fixedMs) -ge 60000) {
                    $late = $cursor - $fixedMs
                }
            }
        }
        $remaining = [Math]::Max([long]0, [long]$task.plannedMs - (Get-TdElapsedMs $task $NowMs))
        $start = $cursor
        $end = $cursor + $remaining
        $items.Add([pscustomobject][ordered]@{
                id          = $task.id
                index       = $i
                startMs     = [long]$start
                endMs       = [long]$end
                remainingMs = [long]$remaining
                gapMs       = [long]$gap
                lateMs      = [long]$late
                fixedMs     = $fixedMs
            })
        $cursor = $end
        $totalRemaining += $remaining
    }
    [pscustomobject][ordered]@{
        items       = $items.ToArray()
        endMs       = [long]$cursor
        remainingMs = [long]$totalRemaining
        count       = $State.tasks.Count
    }
}

function Get-TdFixedInsertIndex {
    # Place un créneau figé avant la première tâche qui serait encore en cours à son
    # heure de début. Ne déloge jamais la tâche en cours (index >= 1).
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Clock,
        [Parameter(Mandatory)][long]$NowMs
    )
    $count = $State.tasks.Count
    if ($count -eq 0) { return 0 }
    $fixedMs = ConvertFrom-TdClockText -Clock $Clock -DayMs $NowMs
    if ($null -eq $fixedMs) { return $count }
    $schedule = Get-TdSchedule -State $State -NowMs $NowMs
    for ($i = 1; $i -lt $count; $i++) {
        if ($schedule.items[$i].endMs -gt $fixedMs) { return $i }
    }
    $count
}

function Update-TdPlanBaseline {
    # Mémorise la fin prévue après une modification volontaire du plan. Le décalage
    # affiché ensuite mesure l'effet des dépassements et des pauses.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][long]$NowMs)
    if ($State.tasks.Count -eq 0) {
        $State.planEndMs = $null
        return
    }
    $State.planEndMs = (Get-TdSchedule -State $State -NowMs $NowMs).endMs
}

function Get-TdDriftMs {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Schedule)
    if ($null -eq $State.planEndMs -or $Schedule.count -eq 0) { return [long]0 }
    [long]$Schedule.endMs - [long]$State.planEndMs
}
