# TDfocus - revue du matin : pour chaque tâche restée d'hier, garder, reporter à demain
# ou abandonner. Aucune culpabilité : abandonner une tâche est un choix légitime.

function Get-TdTomorrowKey {
    param([Parameter(Mandatory)][long]$NowMs)
    (ConvertTo-TdLocalDate $NowMs).Date.AddDays(1).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-TdReviewTasks {
    # Tâches encore à passer en revue, dans l'ordre de la file.
    param([Parameter(Mandatory)]$State)
    $pending = @{}
    foreach ($id in $State.review) { $pending[$id] = $true }
    $State.tasks | Where-Object { $pending.ContainsKey([string]$_.id) }
}

function Resolve-TdReview {
    # Decision : keep (aujourd'hui), tomorrow (reportée à demain), drop (abandonnée).
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('keep', 'tomorrow', 'drop')][string]$Decision,
        [long]$NowMs = (Get-TdNowMs)
    )
    [void]$State.review.Remove($Id)
    $found = Find-TdTask $State $Id
    if (-not $found -or $found.list -ne 'tasks') { return $null }
    $task = $found.task
    switch ($Decision) {
        'tomorrow' {
            [void](Remove-TdTask -State $State -Id $Id -NowMs $NowMs)
            $task.deferUntil = Get-TdTomorrowKey $NowMs
            $task.pausedAt = $null
            $State.parked.Add($task)
        }
        'drop' {
            [void](Remove-TdTask -State $State -Id $Id -NowMs $NowMs)
        }
    }
    $task
}

function Clear-TdReview {
    # « Tout garder »
    param([Parameter(Mandatory)]$State)
    $State.review.Clear()
}

function Restore-TdParked {
    # Ramène dans la file d'aujourd'hui une tâche reportée (ou toutes avec -All).
    param([Parameter(Mandatory)]$State, [string]$Id, [switch]$All)
    $restored = 0
    for ($i = $State.parked.Count - 1; $i -ge 0; $i--) {
        $task = $State.parked[$i]
        if ($All -or $task.id -eq $Id) {
            $State.parked.RemoveAt($i)
            $task.deferUntil = $null
            $State.tasks.Add($task)
            $restored++
        }
    }
    $restored
}
