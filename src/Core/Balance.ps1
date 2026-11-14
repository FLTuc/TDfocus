# TDfocus - cockpit : la jauge « Équilibre du jour ».
#
# Elle compare le temps passé aujourd'hui :
#   - sur les tickets : toutes les actions de la liste TDfocus, sauf blocs projet et pauses ;
#   - sur les projets : les blocs projet.
# Puis elle le rapproche de l'objectif (60 % de tickets / 40 % de projets par défaut, réglable).
# Le temps vient du minuteur de TDfocus : chaque tâche garde son temps jour par jour (champ days).

$script:TdBalanceMinTotalMs = 1800000    # pas de message avant 30 min de travail mesuré
$script:TdBalanceTolerance = 0.10        # écart toléré avec l'objectif : 10 points
$script:TdBalanceMaxCatchUp = 90         # au-delà de 90 min à rattraper, on ne donne plus de chiffre

function Get-TdDayBalance {
    # Renvoie :
    #   ticketMs, projectMs, totalMs   temps d'aujourd'hui
    #   ticketRatio                    part des tickets (de 0 à 1), ou $null si rien n'est mesuré
    #   targetRatio                    part visée pour les tickets (0.6 pour « 60 / 40 »)
    #   behind                         'projects' ou 'tickets' si un côté passe derrière, sinon $null
    #   catchUpMinutes                 temps à passer sur ce côté pour revenir à l'objectif
    #   message                        la phrase à afficher (vide si tout va bien)
    param([Parameter(Mandatory)]$State, [long]$NowMs = (Get-TdNowMs), [int]$TicketShare = 60)
    $ticketMs = [long]0
    $projectMs = [long]0
    foreach ($list in @($State.tasks, $State.done, $State.parked)) {
        foreach ($task in $list) {
            $ms = Get-TdTaskTodayMs $task $NowMs
            if ($ms -le 0) { continue }
            if ($task.projectId) { $projectMs += $ms }
            elseif (Test-TdTicketTask $task) { $ticketMs += $ms }
        }
    }
    $total = $ticketMs + $projectMs
    $target = [Math]::Min(0.9, [Math]::Max(0.1, $TicketShare / 100.0))
    $ratio = $null
    if ($total -gt 0) { $ratio = $ticketMs / [double]$total }

    $behind = $null
    $needMs = 0.0
    if ($total -ge $script:TdBalanceMinTotalMs) {
        if (($ratio - $target) -gt $script:TdBalanceTolerance) {
            # Trop de tickets : combien de temps de projet faut-il ajouter pour revenir à l'objectif ?
            $behind = 'projects'
            $needMs = ((1 - $target) * $total - $projectMs) / $target
        }
        elseif (($target - $ratio) -gt $script:TdBalanceTolerance) {
            $behind = 'tickets'
            $needMs = ($target * $total - $ticketMs) / (1 - $target)
        }
    }
    $catchUp = 0
    $message = ''
    if ($behind) {
        $catchUp = [int]([Math]::Ceiling($needMs / 300000.0) * 5)    # arrondi aux 5 min supérieures
        if ($behind -eq 'projects') {
            $message = 'Les projets passent derrière : un bloc projet aiderait à rééquilibrer.'
            if ($catchUp -le $script:TdBalanceMaxCatchUp) { $message = 'Les projets passent derrière : un bloc de {0} rééquilibrerait.' -f (Format-TdMinutes $catchUp) }
        }
        else {
            $message = 'Les tickets passent derrière : y revenir aiderait à rééquilibrer.'
            if ($catchUp -le $script:TdBalanceMaxCatchUp) { $message = 'Les tickets passent derrière : {0} de tickets rééquilibreraient.' -f (Format-TdMinutes $catchUp) }
        }
    }
    [pscustomobject]@{
        ticketMs       = $ticketMs
        projectMs      = $projectMs
        totalMs        = $total
        ticketRatio    = $ratio
        targetRatio    = $target
        behind         = $behind
        catchUpMinutes = $catchUp
        message        = $message
    }
}

function Format-TdBalanceTarget {
    # « objectif 60 / 40 »
    param([int]$TicketShare = 60)
    'objectif {0} / {1}' -f $TicketShare, (100 - $TicketShare)
}
