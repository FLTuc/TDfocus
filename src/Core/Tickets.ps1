# TDfocus - tickets du helpdesk : la « couche de données » du cockpit.
#
# Tout ce que le cockpit sait des tickets passe par les fonctions de ce fichier :
#   ajouter    New-TdTicket, Add-TdTicket
#   traiter    Select-TdTicket, Start-TdTicket, Suspend-TdTicket
#   terminer   Close-TdTicket, Set-TdTicketEscalated, Set-TdTicketFollowUp, Restore-TdTicket, Remove-TdTicket
#   compter    Get-TdTicketCounts, Get-TdTicketList, Get-TdTicketTimeMs
#
# Aujourd'hui, les tickets sont saisis à la main et rangés dans le fichier tickets.json.
# Plus tard, un outil de ticketing (GLPI, Jira, ServiceNow…) pourra les fournir : il suffira de
# donner la liste lue dans son API à Merge-TdExternalTickets. L'affichage, lui, ne changera pas.
#
# Le « magasin » de tickets est une table :
#   @{ currentId = identifiant du ticket en cours (ou $null) ; items = liste de tous les tickets }
# Un ticket a un état : 'open' (ouvert), 'escalated' (escaladé, en attente de quelqu'un) ou 'closed' (fermé).
# Comme pour les tâches, le chrono est fait d'horodatages (elapsedMs + runningSince) :
# il reste juste même si TDfocus est fermé ou si le PC se met en veille.

$script:TdTicketStatuses = @('open', 'escalated', 'closed')
$script:TdTicketKeepDays = 90    # un ticket fermé depuis plus longtemps est oublié

# ---------------------------------------------------------------- lire et créer

function New-TdTicketStore {
    @{ currentId = $null; items = [System.Collections.Generic.List[object]]::new() }
}

function ConvertTo-TdTicket {
    # Construit un ticket complet (avec valeurs par défaut) à partir de n'importe quel objet.
    param([Parameter(Mandatory)]$InputObject)
    $id = ConvertTo-TdNullableString (Get-TdValue $InputObject 'id')
    if (-not $id) { $id = New-TdId }
    $status = [string](Get-TdValue $InputObject 'status')
    if ($script:TdTicketStatuses -notcontains $status) { $status = 'open' }
    $source = ConvertTo-TdNullableString (Get-TdValue $InputObject 'source')
    if (-not $source) { $source = 'manual' }
    $elapsed = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'elapsedMs')
    if ($null -eq $elapsed -or $elapsed -lt 0) { $elapsed = 0 }
    $created = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'createdAt')
    if ($null -eq $created) { $created = 0 }
    # Libellé : une seule ligne, 80 caractères au plus.
    $ref = ([string](Get-TdValue $InputObject 'ref') -replace '\s+', ' ').Trim()
    if ($ref.Length -gt 80) { $ref = $ref.Substring(0, 80) }
    $followUp = ConvertTo-TdNullableString (Get-TdValue $InputObject 'followUpOn')
    if ($followUp -and $followUp -notmatch '^\d{4}-\d{2}-\d{2}$') { $followUp = $null }
    # Temps passé jour par jour (« 2026-11-13 » -> millisecondes) : il servira à la jauge « Équilibre du jour ».
    $days = @{}
    $rawDays = Get-TdValue $InputObject 'days'
    if ($rawDays -is [System.Collections.IDictionary]) {
        foreach ($key in @($rawDays.Keys)) { if ("$key" -match '^\d{4}-\d{2}-\d{2}$') { $days["$key"] = [long]$rawDays[$key] } }
    }
    elseif ($rawDays -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $rawDays.PSObject.Properties) { if ($p.Name -match '^\d{4}-\d{2}-\d{2}$') { $days[$p.Name] = [long]$p.Value } }
    }

    [pscustomobject][ordered]@{
        id           = $id
        ref          = $ref                                   # numéro ou sujet ; peut rester vide
        status       = $status
        urgent       = [bool](Get-TdValue $InputObject 'urgent')
        source       = $source                                # 'manual', ou le nom de l'outil de ticketing
        externalId   = ConvertTo-TdNullableString (Get-TdValue $InputObject 'externalId')
        createdAt    = [long]$created
        closedAt     = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'closedAt')
        escalatedAt  = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'escalatedAt')
        followUpOn   = $followUp                              # jour de la prochaine relance (« 2026-11-16 »)
        elapsedMs    = [long]$elapsed
        runningSince = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'runningSince')
        days         = $days
        alertedAt    = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'alertedAt')   # alerte « 30 min » déjà donnée
    }
}

function New-TdTicket {
    param([string]$Ref = '', [switch]$Urgent, [string]$Source = 'manual', [string]$ExternalId, [long]$NowMs = (Get-TdNowMs))
    ConvertTo-TdTicket @{ ref = $Ref; urgent = [bool]$Urgent; source = $Source; externalId = $ExternalId; createdAt = $NowMs }
}

function Find-TdTicket {
    param([Parameter(Mandatory)]$Store, [string]$Id)
    foreach ($ticket in $Store.items) { if ($ticket.id -eq $Id) { return $ticket } }
    $null
}

function Get-TdCurrentTicket {
    param([Parameter(Mandatory)]$Store)
    if (-not $Store.currentId) { return $null }
    Find-TdTicket $Store ([string]$Store.currentId)
}

function ConvertTo-TdTicketStore {
    # Relit le contenu de tickets.json (ou d'une sauvegarde). Un fichier absent donne un magasin vide.
    param($InputObject)
    $store = New-TdTicketStore
    foreach ($item in @(Get-TdValue $InputObject 'items')) {
        if ($null -ne $item) { $store.items.Add((ConvertTo-TdTicket $item)) }
    }
    $store.currentId = ConvertTo-TdNullableString (Get-TdValue $InputObject 'currentId')
    Update-TdCurrentTicket $store
    # Seul le ticket en cours peut avoir un chrono en marche.
    foreach ($ticket in $store.items) { if ($ticket.id -ne $store.currentId) { $ticket.runningSince = $null } }
    $store
}

function ConvertTo-TdTicketStoreRecord {
    # Forme enregistrée du magasin (tickets.json et sauvegardes).
    param([Parameter(Mandatory)]$Store)
    [ordered]@{ version = 1; currentId = $Store.currentId; items = @($Store.items) }
}

function Get-TdTicketLabel {
    # Ce qu'on affiche pour un ticket : son libellé, ou « Ticket de 14:32 » s'il n'en a pas.
    param([Parameter(Mandatory)]$Ticket)
    if ($Ticket.ref) { return [string]$Ticket.ref }
    'Ticket de ' + (Format-TdClock ([long]$Ticket.createdAt))
}

# ---------------------------------------------------------------- listes et compteurs

function Test-TdTicketFollowUpDue {
    # Vrai si ce ticket escaladé est à relancer aujourd'hui (ou si sa relance est en retard).
    param([Parameter(Mandatory)]$Ticket, [Parameter(Mandatory)][long]$NowMs)
    if ($Ticket.status -ne 'escalated') { return $false }
    if (-not $Ticket.followUpOn) { return $true }
    [string]::CompareOrdinal([string]$Ticket.followUpOn, (Get-TdDayKey $NowMs)) -le 0
}

function Get-TdTicketList {
    # Les tickets d'une tuile, dans l'ordre où on les affiche :
    #   open      les ouverts : les urgents d'abord, puis les plus anciens
    #   closed    les fermés d'aujourd'hui : le dernier fermé en premier
    #   waiting   les escaladés : ceux à relancer aujourd'hui d'abord, puis par date de relance
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][ValidateSet('open', 'closed', 'waiting')][string]$Kind, [long]$NowMs = (Get-TdNowMs))
    $today = Get-TdDayKey $NowMs
    switch ($Kind) {
        'open' {
            $list = $Store.items | Where-Object { $_.status -eq 'open' } |
                Sort-Object -Property @{ Expression = { [int][bool]$_.urgent }; Descending = $true }, @{ Expression = { [long]$_.createdAt } }, id
        }
        'closed' {
            $list = $Store.items | Where-Object { $_.status -eq 'closed' -and $null -ne $_.closedAt -and (Get-TdDayKey ([long]$_.closedAt)) -eq $today } |
                Sort-Object -Property @{ Expression = { [long]$_.closedAt }; Descending = $true }, id
        }
        'waiting' {
            $list = $Store.items | Where-Object { $_.status -eq 'escalated' } |
                Sort-Object -Property @{ Expression = { [string]$_.followUpOn } }, @{ Expression = { [long]$_.escalatedAt } }, id
        }
    }
    @($list)
}

function Get-TdTicketCounts {
    # Les chiffres des tuiles et de la bulle.
    param([Parameter(Mandatory)]$Store, [long]$NowMs = (Get-TdNowMs))
    $today = Get-TdDayKey $NowMs
    $counts = [ordered]@{ open = 0; urgent = 0; closedToday = 0; waiting = 0; followUpDue = 0 }
    foreach ($ticket in $Store.items) {
        if ($ticket.status -eq 'open') {
            $counts.open++
            if ($ticket.urgent) { $counts.urgent++ }
        }
        elseif ($ticket.status -eq 'closed') {
            if ($null -ne $ticket.closedAt -and (Get-TdDayKey ([long]$ticket.closedAt)) -eq $today) { $counts.closedToday++ }
        }
        else {
            $counts.waiting++
            if (Test-TdTicketFollowUpDue $ticket $NowMs) { $counts.followUpDue++ }
        }
    }
    [pscustomobject]$counts
}

function Update-TdCurrentTicket {
    # Garde un ticket en cours valable : si celui désigné n'est plus ouvert, on prend le prochain
    # (un urgent d'abord, sinon le plus ancien). Aucun ticket ouvert : pas de ticket en cours.
    param([Parameter(Mandatory)]$Store)
    $current = Get-TdCurrentTicket $Store
    if ($current -and $current.status -eq 'open') { return }
    $next = @(Get-TdTicketList -Store $Store -Kind open)
    if ($next.Count -gt 0) { $Store.currentId = $next[0].id } else { $Store.currentId = $null }
}

# ---------------------------------------------------------------- chrono

function Add-TdTicketDayTime {
    # Range une période de travail dans le bon jour (coupée à minuit si elle chevauche deux jours).
    param([Parameter(Mandatory)]$Ticket, [long]$FromMs, [long]$ToMs)
    $cursor = $FromMs
    while ($cursor -lt $ToMs) {
        $midnight = ConvertFrom-TdLocalDate ((ConvertTo-TdLocalDate $cursor).Date.AddDays(1))
        $end = [Math]::Min($ToMs, [long]$midnight)
        if ($end -le $cursor) { break }
        $key = Get-TdDayKey $cursor
        $Ticket.days[$key] = [long]$Ticket.days[$key] + ($end - $cursor)
        $cursor = $end
    }
}

function Stop-TdTicketClock {
    # Fige le temps passé sur un ticket (sans le fermer).
    param([Parameter(Mandatory)]$Ticket, [Parameter(Mandatory)][long]$NowMs)
    if ($null -eq $Ticket.runningSince) { return }
    $from = [long]$Ticket.runningSince
    $to = [Math]::Max($from, $NowMs)
    $Ticket.elapsedMs = [long]$Ticket.elapsedMs + ($to - $from)
    Add-TdTicketDayTime -Ticket $Ticket -FromMs $from -ToMs $to
    $Ticket.runningSince = $null
}

function Test-TdTicketRunning {
    param([Parameter(Mandatory)]$Store)
    $ticket = Get-TdCurrentTicket $Store
    ($null -ne $ticket) -and ($null -ne $ticket.runningSince)
}

function Start-TdTicket {
    # Démarre (ou reprend) le chrono du ticket en cours.
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][long]$NowMs)
    $ticket = Get-TdCurrentTicket $Store
    if ($ticket -and $null -eq $ticket.runningSince) { $ticket.runningSince = $NowMs }
}

function Suspend-TdTicket {
    # Met en pause le chrono du ticket en cours.
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][long]$NowMs)
    $ticket = Get-TdCurrentTicket $Store
    if ($ticket) { Stop-TdTicketClock $ticket $NowMs }
}

function Select-TdTicket {
    # Choisit le ticket en cours parmi les ouverts. Le chrono du précédent s'arrête.
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][long]$NowMs)
    $ticket = Find-TdTicket $Store $Id
    if (-not $ticket -or $ticket.status -ne 'open') { return $null }
    $previous = Get-TdCurrentTicket $Store
    if ($previous -and $previous.id -ne $ticket.id) { Stop-TdTicketClock $previous $NowMs }
    $Store.currentId = $ticket.id
    $ticket
}

function Get-TdTicketTimeMs {
    # Temps passé sur les tickets aujourd'hui, tous tickets confondus (pour la jauge « Équilibre du jour »).
    param([Parameter(Mandatory)]$Store, [long]$NowMs = (Get-TdNowMs))
    $today = Get-TdDayKey $NowMs
    $dayStart = Get-TdDayStartMs $NowMs
    $total = [long]0
    foreach ($ticket in $Store.items) {
        $total += [long]$ticket.days[$today]
        if ($null -ne $ticket.runningSince) {
            $total += [Math]::Max([long]0, $NowMs - [Math]::Max([long]$ticket.runningSince, [long]$dayStart))
        }
    }
    $total
}

function Get-TdTicketProgress {
    # Avancement du chrono vers la limite (30 min par défaut) : de 0 à 1.
    param([Parameter(Mandatory)]$Ticket, [Parameter(Mandatory)][long]$NowMs, [double]$Minutes = 30)
    if ($Minutes -le 0) { return 1.0 }
    [Math]::Min(1.0, (Get-TdElapsedMs $Ticket $NowMs) / ($Minutes * 60000))
}

function Test-TdTicketOverTime {
    # Vrai quand le chrono du ticket a atteint la limite.
    param([Parameter(Mandatory)]$Ticket, [Parameter(Mandatory)][long]$NowMs, [double]$Minutes = 30)
    (Get-TdElapsedMs $Ticket $NowMs) -ge ($Minutes * 60000)
}

function Test-TdTicketAlert {
    # Vrai une seule fois par ticket : au moment où son chrono atteint la limite.
    # (On note l'heure dans alertedAt pour ne pas répéter le signal.)
    param([Parameter(Mandatory)]$Ticket, [Parameter(Mandatory)][long]$NowMs, [double]$Minutes = 30)
    if ($null -ne $Ticket.alertedAt) { return $false }
    if (-not (Test-TdTicketOverTime -Ticket $Ticket -NowMs $NowMs -Minutes $Minutes)) { return $false }
    $Ticket.alertedAt = $NowMs
    $true
}

function Repair-TdStaleTicket {
    # Si TDfocus a été fermé longtemps (PC éteint…) alors qu'un chrono de ticket tournait,
    # on l'arrête à l'heure où TDfocus a été vu pour la dernière fois. Renvoie cette heure, ou $null.
    param([Parameter(Mandatory)]$Store, [long]$LastSeenMs, [Parameter(Mandatory)][long]$NowMs, [long]$MaxGapMs = 1800000)
    $ticket = Get-TdCurrentTicket $Store
    if (-not $ticket -or $null -eq $ticket.runningSince) { return $null }
    if ($LastSeenMs -le 0 -or ($NowMs - $LastSeenMs) -le $MaxGapMs) { return $null }
    $stopAt = [Math]::Max([long]$ticket.runningSince, $LastSeenMs)
    Stop-TdTicketClock $ticket $stopAt
    $stopAt
}

function Sync-TdChronos {
    # Un seul chrono à la fois. Si la tâche TDfocus et un ticket tournent en même temps, celui qui a
    # démarré en dernier continue ; l'autre est mis en pause à cet instant précis (aucun temps compté deux fois).
    # Renvoie 'task' ou 'ticket' (ce qui vient d'être mis en pause), ou $null si rien n'a changé.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Store)
    $task = Get-TdCurrentTask $State
    $ticket = Get-TdCurrentTicket $Store
    if (-not $task -or -not $ticket) { return $null }
    if ($null -eq $task.runningSince -or $null -eq $ticket.runningSince) { return $null }
    if ([long]$ticket.runningSince -ge [long]$task.runningSince) {
        $at = [long]$ticket.runningSince
        Stop-TdTaskClock $task $at
        $task.pausedAt = $at
        return 'task'
    }
    Stop-TdTicketClock $ticket ([long]$task.runningSince)
    'ticket'
}

# ---------------------------------------------------------------- actions

function Add-TdTicket {
    # Ajoute un ticket. S'il n'y a aucun ticket en cours, il le devient (chrono à l'arrêt).
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Ticket)
    $Store.items.Add($Ticket)
    Update-TdCurrentTicket $Store
}

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

function Close-TdTicket {
    # Ferme un ticket : il compte dans « fermés aujourd'hui ». Le prochain ticket ouvert devient le ticket en cours.
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][long]$NowMs)
    $ticket = Find-TdTicket $Store $Id
    if (-not $ticket) { return $null }
    Stop-TdTicketClock $ticket $NowMs
    $ticket.status = 'closed'
    $ticket.closedAt = $NowMs
    $ticket.followUpOn = $null
    Update-TdCurrentTicket $Store
    $ticket
}

function Set-TdTicketEscalated {
    # Escalade : le ticket attend quelqu'un d'autre. Il quitte les « ouverts » et passe dans
    # « à relancer », avec une relance prévue le prochain jour ouvré.
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][long]$NowMs)
    $ticket = Find-TdTicket $Store $Id
    if (-not $ticket) { return $null }
    Stop-TdTicketClock $ticket $NowMs
    $ticket.status = 'escalated'
    $ticket.escalatedAt = $NowMs
    $ticket.closedAt = $null
    $ticket.followUpOn = Get-TdNextWorkdayKey $NowMs
    Update-TdCurrentTicket $Store
    $ticket
}

function Set-TdTicketFollowUp {
    # « Relancé » : la relance est faite ; la suivante est prévue le prochain jour ouvré.
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][long]$NowMs)
    $ticket = Find-TdTicket $Store $Id
    if (-not $ticket -or $ticket.status -ne 'escalated') { return $null }
    $ticket.followUpOn = Get-TdNextWorkdayKey $NowMs
    $ticket
}

function Restore-TdTicket {
    # Rouvre un ticket fermé ou escaladé (boutons « Rouvrir » et « Reprendre », ou annulation).
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$Id)
    $ticket = Find-TdTicket $Store $Id
    if (-not $ticket) { return $null }
    $ticket.status = 'open'
    $ticket.closedAt = $null
    $ticket.escalatedAt = $null
    $ticket.followUpOn = $null
    Update-TdCurrentTicket $Store
    $ticket
}

function Remove-TdTicket {
    # Supprime un ticket (saisi par erreur). Renvoie le ticket retiré, pour pouvoir annuler.
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$Id)
    $ticket = Find-TdTicket $Store $Id
    if (-not $ticket) { return $null }
    $ticket.runningSince = $null
    [void]$Store.items.Remove($ticket)
    Update-TdCurrentTicket $Store
    $ticket
}

function Limit-TdTickets {
    # Oublie les tickets fermés depuis plus de 90 jours. Renvoie le nombre de tickets retirés.
    param([Parameter(Mandatory)]$Store, [long]$NowMs = (Get-TdNowMs))
    $limit = $NowMs - [long]$script:TdTicketKeepDays * 86400000
    $removed = 0
    for ($i = $Store.items.Count - 1; $i -ge 0; $i--) {
        $ticket = $Store.items[$i]
        if ($ticket.status -eq 'closed' -and $null -ne $ticket.closedAt -and [long]$ticket.closedAt -lt $limit) {
            $Store.items.RemoveAt($i)
            $removed++
        }
    }
    $removed
}

# ---------------------------------------------------------------- branchement futur sur un outil de ticketing

function Merge-TdExternalTickets {
    # Point d'entrée pour l'API d'un outil de ticketing (rien ne l'appelle encore).
    #   -Items   liste d'objets @{ externalId = '4521' ; ref = 'INC-4521 VPN impossible' ; urgent = $false }
    #   -Source  nom de l'outil, par exemple 'glpi'
    # Un ticket inconnu est ajouté ; un ticket déjà connu est mis à jour (libellé, urgence).
    # Rien n'est fermé ni supprimé ici : c'est toi qui fermes tes tickets dans le cockpit.
    # Renvoie le nombre de tickets ajoutés.
    param([Parameter(Mandatory)]$Store, [AllowEmptyCollection()]$Items, [Parameter(Mandatory)][string]$Source, [long]$NowMs = (Get-TdNowMs))
    $added = 0
    foreach ($item in @($Items)) {
        $externalId = ConvertTo-TdNullableString (Get-TdValue $item 'externalId')
        if (-not $externalId) { continue }
        $known = $null
        foreach ($ticket in $Store.items) {
            if ($ticket.source -eq $Source -and $ticket.externalId -eq $externalId) { $known = $ticket; break }
        }
        if ($known) {
            $fresh = ConvertTo-TdTicket @{ ref = Get-TdValue $item 'ref' }
            if ($fresh.ref) { $known.ref = $fresh.ref }
            $known.urgent = [bool](Get-TdValue $item 'urgent')
            continue
        }
        $new = New-TdTicket -Ref ([string](Get-TdValue $item 'ref')) -Urgent:([bool](Get-TdValue $item 'urgent')) -Source $Source -ExternalId $externalId -NowMs $NowMs
        Add-TdTicket -Store $Store -Ticket $new
        $added++
    }
    $added
}
