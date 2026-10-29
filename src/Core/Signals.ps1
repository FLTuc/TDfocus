# TDfocus - signaux doux pendant que le minuteur tourne :
#   landing : « atterrissage », quelques minutes avant la fin prévue, pour préparer la transition ;
#   timeup  : le temps prévu est écoulé (une seule fois, jamais une alarme) ;
#   chime   : carillon périodique (toutes les X minutes), suivi d'un point de contrôle.
# La mémoire évite de répéter un signal ; ajouter du temps réarme l'atterrissage et la fin.

function New-TdSignalMemory {
    @{ TimeUpKey = ''; LandingKey = ''; ChimeTaskId = ''; ChimeIndex = -1 }
}

function Get-TdSignalKey {
    param([Parameter(Mandatory)]$Task)
    '{0}|{1}' -f $Task.id, $Task.plannedMs
}

function Initialize-TdSignalMemory {
    # Au démarrage : ne pas rejouer un signal dont le moment est déjà passé.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][long]$NowMs, [Parameter(Mandatory)][hashtable]$Memory)
    $current = Get-TdCurrentTask $State
    if (-not $current) { return }
    $key = Get-TdSignalKey $current
    $remaining = Get-TdRemainingMs $current $NowMs
    if ($remaining -le 0) { $Memory.TimeUpKey = $key }
    if ($remaining -le [long]$Settings.landingMinutes * 60000) { $Memory.LandingKey = $key }
}

function Get-TdSignals {
    # Renvoie les signaux à émettre maintenant (aucun, un ou plusieurs) et met la mémoire à jour.
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][long]$NowMs,
        [Parameter(Mandatory)][hashtable]$Memory
    )
    $signals = [System.Collections.Generic.List[string]]::new()
    $current = Get-TdCurrentTask $State
    if (-not $current -or $null -eq $current.runningSince) { return }
    $elapsed = Get-TdElapsedMs $current $NowMs
    $remaining = [long]$current.plannedMs - $elapsed
    $key = Get-TdSignalKey $current

    if ($remaining -le 0) {
        if ($Memory.TimeUpKey -ne $key) {
            $Memory.TimeUpKey = $key
            $Memory.LandingKey = $key
            $signals.Add('timeup')
        }
    }
    else {
        $window = [long]$Settings.landingMinutes * 60000
        # Pas d'atterrissage pour une tâche plus courte que la fenêtre elle-même.
        if ($window -gt 0 -and $remaining -le $window -and [long]$current.plannedMs -gt $window + 60000 -and $Memory.LandingKey -ne $key) {
            $Memory.LandingKey = $key
            $signals.Add('landing')
        }
    }

    $every = [int]$Settings.chimeEveryMin
    if ($every -gt 0) {
        $index = [long][Math]::Floor($elapsed / ($every * 60000.0))
        if ($Memory.ChimeTaskId -ne $current.id) {
            $Memory.ChimeTaskId = $current.id
            $Memory.ChimeIndex = $index
        }
        elseif ($index -gt $Memory.ChimeIndex) {
            $Memory.ChimeIndex = $index
            $signals.Add('chime')
        }
    }
    $signals.ToArray()
}
