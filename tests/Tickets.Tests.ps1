# Cockpit, étape 2 : la couche de données des tickets (sans interface).
# Les variables préparées dans BeforeEach sont utilisées dans les blocs It (portée Pester).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\TDfocus.Core.ps1')
    # Un vendredi à 10:00 (le 13 novembre 2026), et des raccourcis pour avancer dans le temps.
    $script:T0 = ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 13, 10, 0, 0))
    $script:Min = 60000
}

Describe 'Magasin de tickets' {
    BeforeEach { $store = New-TdTicketStore }

    It 'est vide au départ, et un fichier absent donne un magasin vide' {
        $store.items.Count | Should -Be 0
        $store.currentId | Should -BeNullOrEmpty
        (ConvertTo-TdTicketStore $null).items.Count | Should -Be 0
    }
    It 'fait du premier ticket ajouté le ticket en cours, chrono à l''arrêt' {
        $a = New-TdTicket -Ref 'INC-1 VPN' -NowMs $T0
        $b = New-TdTicket -Ref 'INC-2 Imprimante' -NowMs ($T0 + $Min)
        Add-TdTicket -Store $store -Ticket $a
        Add-TdTicket -Store $store -Ticket $b
        $store.currentId | Should -Be $a.id
        (Get-TdCurrentTicket $store).runningSince | Should -BeNullOrEmpty
        (Get-TdTicketCounts -Store $store -NowMs $T0).open | Should -Be 2
    }
    It 'nettoie le libellé : une seule ligne, 80 caractères au plus' {
        (New-TdTicket -Ref "  INC-7 `r`n  écran   noir ").ref | Should -Be 'INC-7 écran noir'
        (New-TdTicket -Ref ('x' * 200)).ref.Length | Should -Be 80
    }
    It 'nomme un ticket sans libellé par son heure de création' {
        Get-TdTicketLabel (New-TdTicket -NowMs $T0) | Should -Be 'Ticket de 10:00'
        Get-TdTicketLabel (New-TdTicket -Ref 'INC-9' -NowMs $T0) | Should -Be 'INC-9'
    }
    It 'survit à un enregistrement en JSON (états, relance, temps par jour)' {
        $a = New-TdTicket -Ref 'INC-1' -Urgent -NowMs $T0
        $b = New-TdTicket -Ref 'INC-2' -NowMs $T0
        Add-TdTicket -Store $store -Ticket $a
        Add-TdTicket -Store $store -Ticket $b
        Start-TdTicket -Store $store -NowMs $T0
        Suspend-TdTicket -Store $store -NowMs ($T0 + 12 * $Min)
        [void](Set-TdTicketEscalated -Store $store -Id $b.id -NowMs ($T0 + 13 * $Min))

        $json = ConvertTo-Json -InputObject (ConvertTo-TdTicketStoreRecord $store) -Depth 12
        $back = ConvertTo-TdTicketStore ($json | ConvertFrom-Json)

        $back.items.Count | Should -Be 2
        $back.currentId | Should -Be $a.id
        $a2 = Find-TdTicket $back $a.id
        $a2.urgent | Should -BeTrue
        $a2.elapsedMs | Should -Be (12 * $Min)
        $a2.days['2026-11-13'] | Should -Be (12 * $Min)
        $b2 = Find-TdTicket $back $b.id
        $b2.status | Should -Be 'escalated'
        $b2.followUpOn | Should -Be '2026-11-16'
    }
    It 'répare un fichier abîmé' {
        $raw = '{"currentId":"zzz","items":[{"id":"a","status":"bizarre","runningSince":5,"followUpOn":"demain","days":"x"},{"id":"b","status":"closed","closedAt":1}]}' | ConvertFrom-Json
        $back = ConvertTo-TdTicketStore $raw
        $a = Find-TdTicket $back 'a'
        $a.status | Should -Be 'open'
        $a.followUpOn | Should -BeNullOrEmpty
        $a.days.Count | Should -Be 0
        # Le ticket désigné n'existe pas : le ticket ouvert devient le ticket en cours.
        $back.currentId | Should -Be 'a'
    }
    It 'ne laisse tourner que le chrono du ticket en cours' {
        $raw = '{"currentId":"a","items":[{"id":"a","runningSince":5},{"id":"b","runningSince":7}]}' | ConvertFrom-Json
        $back = ConvertTo-TdTicketStore $raw
        (Find-TdTicket $back 'a').runningSince | Should -Be 5
        (Find-TdTicket $back 'b').runningSince | Should -BeNullOrEmpty
    }
}

Describe 'Chrono d''un ticket' {
    BeforeEach {
        $store = New-TdTicketStore
        $a = New-TdTicket -Ref 'INC-1' -NowMs $T0
        $b = New-TdTicket -Ref 'INC-2' -NowMs $T0
        Add-TdTicket -Store $store -Ticket $a
        Add-TdTicket -Store $store -Ticket $b
    }

    It 'compte le temps entre Démarrer et Pause, puis reprend' {
        Start-TdTicket -Store $store -NowMs $T0
        Test-TdTicketRunning $store | Should -BeTrue
        Get-TdElapsedMs $a ($T0 + 5 * $Min) | Should -Be (5 * $Min)
        Suspend-TdTicket -Store $store -NowMs ($T0 + 5 * $Min)
        Test-TdTicketRunning $store | Should -BeFalse
        Get-TdElapsedMs $a ($T0 + 20 * $Min) | Should -Be (5 * $Min)
        Start-TdTicket -Store $store -NowMs ($T0 + 20 * $Min)
        Get-TdElapsedMs $a ($T0 + 22 * $Min) | Should -Be (7 * $Min)
    }
    It 'arrête le chrono du ticket précédent quand on en choisit un autre' {
        Start-TdTicket -Store $store -NowMs $T0
        (Select-TdTicket -Store $store -Id $b.id -NowMs ($T0 + 4 * $Min)).id | Should -Be $b.id
        $a.runningSince | Should -BeNullOrEmpty
        $a.elapsedMs | Should -Be (4 * $Min)
        $store.currentId | Should -Be $b.id
        $b.runningSince | Should -BeNullOrEmpty
    }
    It 'range le temps dans le bon jour, même à cheval sur minuit' {
        $late = ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 13, 23, 50, 0))
        Start-TdTicket -Store $store -NowMs $late
        Suspend-TdTicket -Store $store -NowMs ($late + 25 * $Min)
        $a.days['2026-11-13'] | Should -Be (10 * $Min)
        $a.days['2026-11-14'] | Should -Be (15 * $Min)
        $a.elapsedMs | Should -Be (25 * $Min)
    }
    It 'additionne le temps passé sur les tickets aujourd''hui, chrono en marche compris' {
        Start-TdTicket -Store $store -NowMs $T0
        [void](Select-TdTicket -Store $store -Id $b.id -NowMs ($T0 + 10 * $Min))
        Start-TdTicket -Store $store -NowMs ($T0 + 10 * $Min)
        Get-TdTicketTimeMs -Store $store -NowMs ($T0 + 16 * $Min) | Should -Be (16 * $Min)
        # Le lendemain matin, chrono arrêté la veille : le compteur du jour repart de zéro.
        Suspend-TdTicket -Store $store -NowMs ($T0 + 16 * $Min)
        Get-TdTicketTimeMs -Store $store -NowMs ($T0 + 24 * 60 * $Min) | Should -Be 0
    }
    It 'avance vers la limite de 30 min sans la dépasser' {
        Start-TdTicket -Store $store -NowMs $T0
        Get-TdTicketProgress -Ticket $a -NowMs ($T0 + 15 * $Min) | Should -Be 0.5
        Get-TdTicketProgress -Ticket $a -NowMs ($T0 + 45 * $Min) | Should -Be 1
        Get-TdTicketProgress -Ticket $a -NowMs ($T0 + 5 * $Min) -Minutes 10 | Should -Be 0.5
    }
    It 'donne l''alerte une seule fois, quand la limite est atteinte' {
        Start-TdTicket -Store $store -NowMs $T0
        Test-TdTicketAlert -Ticket $a -NowMs ($T0 + 29 * $Min) | Should -BeFalse
        Test-TdTicketOverTime -Ticket $a -NowMs ($T0 + 29 * $Min) | Should -BeFalse
        Test-TdTicketAlert -Ticket $a -NowMs ($T0 + 30 * $Min) | Should -BeTrue
        Test-TdTicketAlert -Ticket $a -NowMs ($T0 + 31 * $Min) | Should -BeFalse
        Test-TdTicketOverTime -Ticket $a -NowMs ($T0 + 31 * $Min) | Should -BeTrue
    }
    It 'arrête le chrono à la dernière heure connue si TDfocus est resté fermé longtemps' {
        Start-TdTicket -Store $store -NowMs $T0
        $seen = $T0 + 10 * $Min
        Repair-TdStaleTicket -Store $store -LastSeenMs $seen -NowMs ($T0 + 20 * $Min) | Should -BeNullOrEmpty
        Repair-TdStaleTicket -Store $store -LastSeenMs $seen -NowMs ($T0 + 180 * $Min) | Should -Be $seen
        $a.runningSince | Should -BeNullOrEmpty
        $a.elapsedMs | Should -Be (10 * $Min)
    }
}

Describe 'Un seul chrono à la fois (tâche TDfocus ou ticket)' {
    BeforeEach {
        $state = New-TdState
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'E-mails' -Minutes 15 -NowMs $T0))
        $store = New-TdTicketStore
        $ticket = New-TdTicket -Ref 'INC-1' -NowMs $T0
        Add-TdTicket -Store $store -Ticket $ticket
    }

    It 'met la tâche en pause quand un ticket démarre après elle' {
        Start-TdTimer $state $T0
        Start-TdTicket -Store $store -NowMs ($T0 + 20 * $Min)
        Sync-TdChronos -State $state -Store $store | Should -Be 'task'
        $task = Get-TdCurrentTask $state
        $task.runningSince | Should -BeNullOrEmpty
        $task.elapsedMs | Should -Be (20 * $Min)
        $task.pausedAt | Should -Be ($T0 + 20 * $Min)
        Test-TdTicketRunning $store | Should -BeTrue
    }
    It 'met le ticket en pause quand la tâche démarre après lui' {
        Start-TdTicket -Store $store -NowMs $T0
        Start-TdTimer $state ($T0 + 5 * $Min)
        Sync-TdChronos -State $state -Store $store | Should -Be 'ticket'
        Test-TdTicketRunning $store | Should -BeFalse
        $ticket.elapsedMs | Should -Be (5 * $Min)
        Test-TdRunning $state | Should -BeTrue
    }
    It 'ne touche à rien quand un seul chrono tourne' {
        Start-TdTimer $state $T0
        Sync-TdChronos -State $state -Store $store | Should -BeNullOrEmpty
        Test-TdRunning $state | Should -BeTrue
    }
}

Describe 'Fermer, escalader, relancer' {
    BeforeEach {
        $store = New-TdTicketStore
        $a = New-TdTicket -Ref 'INC-1' -NowMs $T0
        $b = New-TdTicket -Ref 'INC-2' -NowMs ($T0 + 1 * $Min)
        $c = New-TdTicket -Ref 'INC-3' -Urgent -NowMs ($T0 + 2 * $Min)
        foreach ($t in @($a, $b, $c)) { Add-TdTicket -Store $store -Ticket $t }
    }

    It 'ferme le ticket en cours : les tuiles changent et le prochain ticket (urgent d''abord) prend la place' {
        Start-TdTicket -Store $store -NowMs $T0
        $closed = Close-TdTicket -Store $store -Id $a.id -NowMs ($T0 + 18 * $Min)
        $closed.status | Should -Be 'closed'
        $closed.elapsedMs | Should -Be (18 * $Min)
        $closed.runningSince | Should -BeNullOrEmpty
        $counts = Get-TdTicketCounts -Store $store -NowMs ($T0 + 18 * $Min)
        $counts.open | Should -Be 2
        $counts.urgent | Should -Be 1
        $counts.closedToday | Should -Be 1
        $store.currentId | Should -Be $c.id
        Test-TdTicketRunning $store | Should -BeFalse
    }
    It 'ne compte plus le lendemain un ticket fermé la veille' {
        [void](Close-TdTicket -Store $store -Id $a.id -NowMs $T0)
        (Get-TdTicketCounts -Store $store -NowMs ($T0 + 24 * 60 * $Min)).closedToday | Should -Be 0
        @(Get-TdTicketList -Store $store -Kind closed -NowMs ($T0 + 24 * 60 * $Min)).Count | Should -Be 0
        @(Get-TdTicketList -Store $store -Kind closed -NowMs $T0).Count | Should -Be 1
    }
    It 'n''a plus de ticket en cours quand tout est fermé' {
        foreach ($t in @($a, $b, $c)) { [void](Close-TdTicket -Store $store -Id $t.id -NowMs $T0) }
        $store.currentId | Should -BeNullOrEmpty
        Get-TdCurrentTicket $store | Should -BeNullOrEmpty
        (Get-TdTicketCounts -Store $store -NowMs $T0).closedToday | Should -Be 3
    }
    It 'escalade : relance prévue le prochain jour ouvré (vendredi -> lundi)' {
        $t = Set-TdTicketEscalated -Store $store -Id $a.id -NowMs $T0
        $t.status | Should -Be 'escalated'
        $t.followUpOn | Should -Be '2026-11-16'
        $counts = Get-TdTicketCounts -Store $store -NowMs $T0
        $counts.open | Should -Be 2
        $counts.waiting | Should -Be 1
        $counts.followUpDue | Should -Be 0
        # Le lundi, la relance est due.
        $monday = ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 16, 9, 0, 0))
        (Get-TdTicketCounts -Store $store -NowMs $monday).followUpDue | Should -Be 1
        Test-TdTicketFollowUpDue -Ticket $t -NowMs $monday | Should -BeTrue
    }
    It 'repousse la relance au prochain jour ouvré quand on clique « Relancé »' {
        [void](Set-TdTicketEscalated -Store $store -Id $a.id -NowMs $T0)
        $monday = ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 16, 9, 0, 0))
        (Set-TdTicketFollowUp -Store $store -Id $a.id -NowMs $monday).followUpOn | Should -Be '2026-11-17'
        (Get-TdTicketCounts -Store $store -NowMs $monday).followUpDue | Should -Be 0
        # « Relancé » ne concerne que les tickets escaladés.
        Set-TdTicketFollowUp -Store $store -Id $b.id -NowMs $monday | Should -BeNullOrEmpty
    }
    It 'trouve le prochain jour ouvré' {
        Get-TdNextWorkdayKey $T0 | Should -Be '2026-11-16'
        Get-TdNextWorkdayKey (ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 16, 9, 0, 0))) | Should -Be '2026-11-17'
        Get-TdNextWorkdayKey (ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 14, 9, 0, 0))) | Should -Be '2026-11-16'
    }
    It 'dit en clair quand relancer' {
        Format-TdFollowUp -DateKey '2026-11-13' -NowMs $T0 | Should -Be "à relancer aujourd'hui"
        Format-TdFollowUp -DateKey '2026-11-10' -NowMs $T0 | Should -Be "à relancer aujourd'hui"
        Format-TdFollowUp -DateKey '2026-11-14' -NowMs $T0 | Should -Be 'relance demain'
        Format-TdFollowUp -DateKey '2026-11-16' -NowMs $T0 | Should -Match '^relance \S+ 16$'
    }
    It 'rouvre un ticket fermé ou escaladé' {
        [void](Close-TdTicket -Store $store -Id $a.id -NowMs $T0)
        [void](Set-TdTicketEscalated -Store $store -Id $b.id -NowMs $T0)
        (Restore-TdTicket -Store $store -Id $a.id).status | Should -Be 'open'
        $back = Restore-TdTicket -Store $store -Id $b.id
        $back.status | Should -Be 'open'
        $back.followUpOn | Should -BeNullOrEmpty
        $counts = Get-TdTicketCounts -Store $store -NowMs $T0
        $counts.open | Should -Be 3
        $counts.closedToday | Should -Be 0
        $counts.waiting | Should -Be 0
    }
    It 'supprime un ticket saisi par erreur, sans le compter comme fermé' {
        (Remove-TdTicket -Store $store -Id $a.id).id | Should -Be $a.id
        $counts = Get-TdTicketCounts -Store $store -NowMs $T0
        $counts.open | Should -Be 2
        $counts.closedToday | Should -Be 0
        $store.currentId | Should -Be $c.id
        Remove-TdTicket -Store $store -Id 'inconnu' | Should -BeNullOrEmpty
    }
    It 'liste les ouverts (urgents d''abord, puis les plus anciens) et les escaladés par date de relance' {
        (@(Get-TdTicketList -Store $store -Kind open -NowMs $T0) | ForEach-Object { $_.ref }) -join ',' | Should -Be 'INC-3,INC-1,INC-2'
        [void](Set-TdTicketEscalated -Store $store -Id $b.id -NowMs $T0)
        [void](Set-TdTicketEscalated -Store $store -Id $a.id -NowMs ($T0 - 3 * 24 * 60 * $Min))
        (@(Get-TdTicketList -Store $store -Kind waiting -NowMs $T0) | ForEach-Object { $_.ref }) -join ',' | Should -Be 'INC-1,INC-2'
    }
    It 'oublie les tickets fermés depuis plus de 90 jours, pas les autres' {
        [void](Close-TdTicket -Store $store -Id $a.id -NowMs $T0)
        [void](Close-TdTicket -Store $store -Id $b.id -NowMs ($T0 + 80 * 24 * 60 * $Min))
        Limit-TdTickets -Store $store -NowMs ($T0 + 100 * 24 * 60 * $Min) | Should -Be 1
        Find-TdTicket $store $a.id | Should -BeNullOrEmpty
        Find-TdTicket $store $b.id | Should -Not -BeNullOrEmpty
        Find-TdTicket $store $c.id | Should -Not -BeNullOrEmpty
    }
}

Describe 'Branchement futur sur un outil de ticketing' {
    It 'ajoute les tickets inconnus, met à jour les autres, sans doublon ni fermeture' {
        $store = New-TdTicketStore
        $items = @(
            @{ externalId = '4521'; ref = 'INC-4521 VPN impossible'; urgent = $true }
            @{ externalId = '4522'; ref = 'INC-4522 Imprimante' }
            @{ ref = 'sans identifiant : ignoré' }
        )
        Merge-TdExternalTickets -Store $store -Items $items -Source 'glpi' -NowMs $T0 | Should -Be 2
        $store.items.Count | Should -Be 2
        $store.items[0].source | Should -Be 'glpi'
        $store.items[0].urgent | Should -BeTrue
        [void](Close-TdTicket -Store $store -Id $store.items[1].id -NowMs $T0)

        $again = @(@{ externalId = '4521'; ref = 'INC-4521 VPN (compta)'; urgent = $false }, @{ externalId = '4522'; ref = 'INC-4522 Imprimante' })
        Merge-TdExternalTickets -Store $store -Items $again -Source 'glpi' -NowMs $T0 | Should -Be 0
        $store.items.Count | Should -Be 2
        $store.items[0].ref | Should -Be 'INC-4521 VPN (compta)'
        $store.items[0].urgent | Should -BeFalse
        $store.items[1].status | Should -Be 'closed'
        Merge-TdExternalTickets -Store $store -Items @() -Source 'glpi' | Should -Be 0
    }
}

Describe 'Stockage des tickets' {
    BeforeAll {
        $script:OldData = $env:TDFOCUS_DATA
        $env:TDFOCUS_DATA = Join-Path ([IO.Path]::GetTempPath()) ("tdfocus-tickets-" + [guid]::NewGuid().ToString('N'))
    }
    AfterAll {
        Remove-Item -LiteralPath $env:TDFOCUS_DATA -Recurse -Force -ErrorAction SilentlyContinue
        $env:TDFOCUS_DATA = $script:OldData
    }

    It 'démarre sans fichier tickets.json' {
        $data = Import-TdData
        $data.tickets.items.Count | Should -Be 0
    }
    It 'enregistre dans tickets.json et relit à l''identique' {
        $data = Import-TdData
        $t = New-TdTicket -Ref 'INC-1 VPN' -Urgent -NowMs $T0
        Add-TdTicket -Store $data.tickets -Ticket $t
        Start-TdTicket -Store $data.tickets -NowMs $T0
        Save-TdTickets $data.tickets
        Test-Path -LiteralPath (Join-Path $env:TDFOCUS_DATA 'tickets.json') | Should -BeTrue

        $back = (Import-TdData).tickets
        $back.items.Count | Should -Be 1
        $back.currentId | Should -Be $t.id
        $back.items[0].ref | Should -Be 'INC-1 VPN'
        $back.items[0].urgent | Should -BeTrue
        $back.items[0].runningSince | Should -Be $T0
    }
    It 'fait partie de la sauvegarde complète' {
        $data = Import-TdData
        $path = Join-Path $env:TDFOCUS_DATA 'backup.json'
        Export-TdBackup -Path $path -Data $data
        $restored = Import-TdBackup -Path $path
        $restored.tickets.items.Count | Should -Be 1
        $restored.tickets.items[0].ref | Should -Be 'INC-1 VPN'
    }
    It 'accepte une ancienne sauvegarde sans tickets' {
        $path = Join-Path $env:TDFOCUS_DATA 'old.json'
        Write-TdJsonFile $path ([ordered]@{ app = 'TDfocus'; version = 1 })
        (Import-TdBackup -Path $path).tickets.items.Count | Should -Be 0
    }
}

Describe 'Réglage de l''alerte' {
    It 'vaut 30 min par défaut et refuse les valeurs absurdes' {
        (ConvertTo-TdCockpitSettings $null).ticketAlertMinutes | Should -Be 30
        (ConvertTo-TdCockpitSettings @{ ticketAlertMinutes = 45 }).ticketAlertMinutes | Should -Be 45
        (ConvertTo-TdCockpitSettings @{ ticketAlertMinutes = 0 }).ticketAlertMinutes | Should -Be 30
        (ConvertTo-TdCockpitSettings @{ ticketAlertMinutes = 'abc' }).ticketAlertMinutes | Should -Be 30
        (ConvertTo-TdCockpitSettings @{ ticketAlertMinutes = 9999 }).ticketAlertMinutes | Should -Be 30
    }
}
