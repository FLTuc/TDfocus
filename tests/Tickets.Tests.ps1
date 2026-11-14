# Cockpit : les tickets sont les actions de la liste TDfocus (sans interface).
# Les variables préparées dans BeforeEach sont utilisées dans les blocs It (portée Pester).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\TDfocus.Core.ps1')
    # Un vendredi à 10:00 (le 13 novembre 2026), et un raccourci pour compter en minutes.
    $script:T0 = ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 13, 10, 0, 0))
    $script:Min = 60000

    function New-TestState {
        # Une liste TDfocus ordinaire : deux actions, un bloc projet, une pause.
        $state = New-TdState
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'INC-1 VPN' -Minutes 20 -NowMs $T0) -NowMs $T0)
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'INC-2 Imprimante' -Minutes 15 -NowMs $T0) -NowMs $T0)
        $block = New-TdTask -Title 'Migration messagerie' -Minutes 25 -NowMs $T0
        $block.projectId = 'p1'
        [void](Add-TdTask -State $state -Task $block -NowMs $T0)
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'Pause café' -Minutes 10 -CategoryId 'pause' -NowMs $T0) -NowMs $T0)
        $state
    }
}

Describe 'Saisie manuelle : urgence avec « !! »' {
    It 'reconnaît « !! » et le retire du titre, sans toucher à la durée ni à l''heure' {
        $p = ConvertFrom-TdQuickInput 'INC-4830 Imprimante RH 20 !!'
        $p.urgent | Should -BeTrue
        $p.title | Should -Be 'INC-4830 Imprimante RH'
        $p.minutes | Should -Be 20
        (ConvertFrom-TdQuickInput '!! Serveur en panne @14h').fixedStart | Should -Be '14:00'
        (ConvertFrom-TdQuickInput '!! Serveur en panne @14h').title | Should -Be 'Serveur en panne'
    }
    It 'laisse un seul point d''exclamation tranquille' {
        $p = ConvertFrom-TdQuickInput 'Fêter la mise en production ! 15'
        $p.urgent | Should -BeFalse
        $p.title | Should -Be 'Fêter la mise en production !'
        (ConvertFrom-TdQuickInput 'Répondre aux emails 15').urgent | Should -BeFalse
    }
    It 'place une action urgente juste après la tâche en cours' {
        $state = New-TestState
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'Urgent A' -Urgent -NowMs $T0) -NowMs $T0)
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'Urgent B' -Urgent -NowMs $T0) -NowMs $T0)
        ($state.tasks | ForEach-Object { $_.title }) -join ',' | Should -Be 'INC-1 VPN,Urgent A,Urgent B,INC-2 Imprimante,Migration messagerie,Pause café'
        $empty = New-TdState
        [void](Add-TdTask -State $empty -Task (New-TdTask -Title 'Seule' -Urgent -NowMs $T0) -NowMs $T0)
        $empty.tasks[0].title | Should -Be 'Seule'
    }
    It 'garde les nouvelles marques à l''enregistrement' {
        $task = New-TdTask -Title 'INC-9' -Urgent -NowMs $T0
        $task.waitingSince = $T0
        $task.days['2026-11-13'] = 5 * $Min
        $back = ConvertTo-TdTask (ConvertTo-Json -InputObject $task -Depth 6 | ConvertFrom-Json)
        $back.urgent | Should -BeTrue
        $back.waitingSince | Should -Be $T0
        $back.days['2026-11-13'] | Should -Be (5 * $Min)
        # Une tâche enregistrée avant cette version n'a aucune de ces marques.
        $old = ConvertTo-TdTask ('{"id":"a","title":"Ancienne","plannedMs":600000}' | ConvertFrom-Json)
        $old.urgent | Should -BeFalse
        $old.waitingSince | Should -BeNullOrEmpty
        $old.days.Count | Should -Be 0
    }
}

Describe 'Temps passé jour par jour sur une tâche' {
    BeforeEach { $state = New-TestState }

    It 'range le temps du minuteur dans le jour, à chaque pause' {
        Start-TdTimer $state $T0
        Suspend-TdTimer $state ($T0 + 12 * $Min)
        $state.tasks[0].days['2026-11-13'] | Should -Be (12 * $Min)
        Start-TdTimer $state ($T0 + 20 * $Min)
        Get-TdTaskTodayMs $state.tasks[0] ($T0 + 25 * $Min) | Should -Be (17 * $Min)
    }
    It 'coupe à minuit' {
        $late = ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 13, 23, 50, 0))
        Start-TdTimer $state $late
        Suspend-TdTimer $state ($late + 25 * $Min)
        $state.tasks[0].days['2026-11-13'] | Should -Be (10 * $Min)
        $state.tasks[0].days['2026-11-14'] | Should -Be (15 * $Min)
        $state.tasks[0].elapsedMs | Should -Be (25 * $Min)
        # Le lendemain, seul le temps du lendemain compte.
        Get-TdTaskTodayMs $state.tasks[0] ($late + 30 * $Min) | Should -Be (15 * $Min)
    }
    It 'compte aussi à la validation et à l''enchaînement' {
        Start-TdTimer $state $T0
        $done = Complete-TdTask -State $state -NowMs ($T0 + 8 * $Min) -KeepRunning
        $done.days['2026-11-13'] | Should -Be (8 * $Min)
        Get-TdTaskTodayMs $state.tasks[0] ($T0 + 11 * $Min) | Should -Be (3 * $Min)
    }
}

Describe 'Les tickets sont les actions de la liste TDfocus' {
    BeforeEach { $state = New-TestState }

    It 'compte toutes les actions, sauf les blocs projet et les pauses' {
        Test-TdTicketTask $state.tasks[0] | Should -BeTrue
        Test-TdTicketTask $state.tasks[2] | Should -BeFalse
        Test-TdTicketTask $state.tasks[3] | Should -BeFalse
        $counts = Get-TdTicketCounts -State $state -NowMs $T0
        $counts.open | Should -Be 2
        $counts.urgent | Should -Be 0
        $counts.closedToday | Should -Be 0
        $counts.waiting | Should -Be 0
    }
    It 'prend comme ticket en cours la tâche en cours de TDfocus, si c''en est un' {
        (Get-TdCurrentTicket $state).title | Should -Be 'INC-1 VPN'
        Start-TdTaskNow -State $state -Id $state.tasks[2].id -NowMs $T0
        Get-TdCurrentTicket $state | Should -BeNullOrEmpty
        Get-TdCurrentTicket (New-TdState) | Should -BeNullOrEmpty
    }
    It 'suit la liste : une validation dans TDfocus donne un ticket fermé aujourd''hui' {
        Start-TdTimer $state $T0
        [void](Complete-TdTask -State $state -NowMs ($T0 + 18 * $Min))
        $counts = Get-TdTicketCounts -State $state -NowMs ($T0 + 18 * $Min)
        $counts.open | Should -Be 1
        $counts.closedToday | Should -Be 1
        @(Get-TdTicketList -State $state -Kind closed -NowMs ($T0 + 18 * $Min))[0].title | Should -Be 'INC-1 VPN'
        # Un bloc projet validé ne compte pas comme ticket fermé.
        [void](Complete-TdTask -State $state -Id $state.tasks[1].id -NowMs ($T0 + 19 * $Min))
        (Get-TdTicketCounts -State $state -NowMs ($T0 + 19 * $Min)).closedToday | Should -Be 1
    }
    It 'compte les urgents et garde l''ordre de la liste' {
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'INC-3 Serveur' -Urgent -NowMs $T0) -NowMs $T0)
        (Get-TdTicketCounts -State $state -NowMs $T0).urgent | Should -Be 1
        (@(Get-TdTicketList -State $state -Kind open -NowMs $T0) | ForEach-Object { $_.title }) -join ',' | Should -Be 'INC-1 VPN,INC-3 Serveur,INC-2 Imprimante'
    }
}

Describe 'Limite de temps d''un ticket' {
    It 'avance vers 30 min sans dépasser, et signale le franchissement une seule fois' {
        $state = New-TestState
        Start-TdTimer $state $T0
        $task = $state.tasks[0]
        Get-TdTicketProgress -Task $task -NowMs ($T0 + 15 * $Min) | Should -Be 0.5
        Get-TdTicketProgress -Task $task -NowMs ($T0 + 45 * $Min) | Should -Be 1
        Get-TdTicketProgress -Task $task -NowMs ($T0 + 5 * $Min) -Minutes 10 | Should -Be 0.5
        Test-TdTicketOverTime -Task $task -NowMs ($T0 + 29 * $Min) | Should -BeFalse
        Test-TdTicketOverTime -Task $task -NowMs ($T0 + 30 * $Min) | Should -BeTrue
        Test-TdLimitCrossed -BeforeMs (29 * $Min) -AfterMs (29 * $Min + 500) | Should -BeFalse
        Test-TdLimitCrossed -BeforeMs (30 * $Min - 250) -AfterMs (30 * $Min) | Should -BeTrue
        Test-TdLimitCrossed -BeforeMs (30 * $Min) -AfterMs (30 * $Min + 250) | Should -BeFalse
        Test-TdLimitCrossed -BeforeMs (9 * $Min) -AfterMs (10 * $Min) -Minutes 10 | Should -BeTrue
    }
}

Describe 'Escalader et relancer' {
    BeforeEach { $state = New-TestState }

    It 'escalade : le ticket quitte la file et attend le prochain jour ouvré (vendredi -> lundi)' {
        Start-TdTimer $state $T0
        $task = Set-TdTicketEscalated -State $state -Id $state.tasks[0].id -NowMs ($T0 + 10 * $Min)
        $task.waitingSince | Should -Be ($T0 + 10 * $Min)
        $task.deferUntil | Should -Be '2026-11-16'
        $task.runningSince | Should -BeNullOrEmpty
        $task.elapsedMs | Should -Be (10 * $Min)
        $state.parked.Count | Should -Be 1
        $state.tasks[0].title | Should -Be 'INC-2 Imprimante'
        Test-TdRunning $state | Should -BeFalse
        $counts = Get-TdTicketCounts -State $state -NowMs ($T0 + 10 * $Min)
        $counts.open | Should -Be 1
        $counts.waiting | Should -Be 1
        $counts.followUpDue | Should -Be 0
    }
    It 'enchaîne sur la tâche suivante avec -KeepRunning' {
        Start-TdTimer $state $T0
        [void](Set-TdTicketEscalated -State $state -Id $state.tasks[0].id -NowMs ($T0 + 10 * $Min) -KeepRunning)
        Test-TdRunning $state | Should -BeTrue
        $state.tasks[0].runningSince | Should -Be ($T0 + 10 * $Min)
    }
    It 'revient tout seul dans la file le jour de la relance, marqué « à relancer »' {
        $id = $state.tasks[0].id
        [void](Set-TdTicketEscalated -State $state -Id $id -NowMs $T0)
        $state.dayKey = '2026-11-13'
        $monday = ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 16, 9, 0, 0))
        [void](Invoke-TdDayRollover -State $state -NowMs $monday)
        $found = Find-TdTask $state $id
        $found.list | Should -Be 'tasks'
        $found.task.waitingSince | Should -Be $T0
        $counts = Get-TdTicketCounts -State $state -NowMs $monday
        $counts.waiting | Should -Be 1
        $counts.followUpDue | Should -Be 1
        # Il compte dans « à relancer », pas dans « ouverts ».
        $counts.open | Should -Be 1
        @(Get-TdTicketList -State $state -Kind waiting -NowMs $monday)[0].id | Should -Be $id
    }
    It '« Relancé » repousse la relance au prochain jour ouvré, que le ticket soit de côté ou revenu' {
        $id = $state.tasks[0].id
        [void](Set-TdTicketEscalated -State $state -Id $id -NowMs $T0)
        $monday = ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 16, 9, 0, 0))
        (Set-TdTicketFollowUp -State $state -Id $id -NowMs $monday).deferUntil | Should -Be '2026-11-17'
        # Revenu dans la file le mardi, relancé de nouveau : il repart de côté, date d'escalade conservée.
        $state.dayKey = '2026-11-16'
        $tuesday = ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 17, 9, 0, 0))
        [void](Invoke-TdDayRollover -State $state -NowMs $tuesday)
        $task = Set-TdTicketFollowUp -State $state -Id $id -NowMs $tuesday
        $task.deferUntil | Should -Be '2026-11-18'
        $task.waitingSince | Should -Be $T0
        (Find-TdParkedTask $state $id).task.id | Should -Be $id
        # « Relancé » ne concerne que les tickets escaladés.
        Set-TdTicketFollowUp -State $state -Id $state.tasks[0].id -NowMs $tuesday | Should -BeNullOrEmpty
    }
    It '« Reprendre » : le ticket revient en tête de file, minuteur en marche, sans la marque' {
        $id = $state.tasks[0].id
        [void](Set-TdTicketEscalated -State $state -Id $id -NowMs $T0)
        Start-TdTimer $state ($T0 + 1 * $Min)
        $task = Resume-TdTicket -State $state -Id $id -NowMs ($T0 + 5 * $Min)
        $task.waitingSince | Should -BeNullOrEmpty
        $task.deferUntil | Should -BeNullOrEmpty
        $state.tasks[0].id | Should -Be $id
        $state.tasks[0].runningSince | Should -Be ($T0 + 5 * $Min)
        # Un seul minuteur : la tâche qui tournait s'est arrêtée, son temps est compté.
        $state.tasks[1].runningSince | Should -BeNullOrEmpty
        $state.tasks[1].elapsedMs | Should -Be (4 * $Min)
        $state.parked.Count | Should -Be 0
    }
    It 'annule une escalade : le ticket retrouve sa place' {
        $id = $state.tasks[0].id
        [void](Set-TdTicketEscalated -State $state -Id $id -NowMs $T0)
        $task = Restore-TdTicket -State $state -Id $id -Index 0 -NowMs $T0
        $task.waitingSince | Should -BeNullOrEmpty
        $state.tasks[0].id | Should -Be $id
        $state.parked.Count | Should -Be 0
        (Get-TdTicketCounts -State $state -NowMs $T0).open | Should -Be 2
        Restore-TdTicket -State $state -Id 'inconnu' | Should -BeNullOrEmpty
    }
    It 'trouve le prochain jour ouvré et dit en clair quand relancer' {
        Get-TdNextWorkdayKey $T0 | Should -Be '2026-11-16'
        Get-TdNextWorkdayKey (ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 16, 9, 0, 0))) | Should -Be '2026-11-17'
        Get-TdNextWorkdayKey (ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 14, 9, 0, 0))) | Should -Be '2026-11-16'
        Format-TdFollowUp -DateKey '2026-11-13' -NowMs $T0 | Should -Be "à relancer aujourd'hui"
        Format-TdFollowUp -DateKey '2026-11-10' -NowMs $T0 | Should -Be "à relancer aujourd'hui"
        Format-TdFollowUp -DateKey '' -NowMs $T0 | Should -Be "à relancer aujourd'hui"
        Format-TdFollowUp -DateKey '2026-11-14' -NowMs $T0 | Should -Be 'relance demain'
        Format-TdFollowUp -DateKey '2026-11-16' -NowMs $T0 | Should -Match '^relance \S+ 16$'
    }
    It 'survit à l''enregistrement de la liste' {
        $id = $state.tasks[0].id
        [void](Set-TdTicketEscalated -State $state -Id $id -NowMs $T0)
        $back = ConvertTo-TdState (ConvertTo-Json -InputObject (ConvertTo-TdStateRecord $state) -Depth 12 | ConvertFrom-Json)
        $counts = Get-TdTicketCounts -State $back -NowMs $T0
        $counts.waiting | Should -Be 1
        $counts.open | Should -Be 1
        (Find-TdParkedTask $back $id).task.deferUntil | Should -Be '2026-11-16'
    }
}

Describe 'Jauge « Équilibre du jour »' {
    BeforeEach {
        $state = New-TestState
        $ticket = $state.tasks[0]
        $block = $state.tasks[2]
        $pause = $state.tasks[3]
    }

    It 'est vide tant que rien n''est mesuré' {
        $b = Get-TdDayBalance -State $state -NowMs $T0
        $b.totalMs | Should -Be 0
        $b.ticketRatio | Should -BeNullOrEmpty
        $b.targetRatio | Should -Be 0.6
        $b.message | Should -Be ''
    }
    It 'sépare tickets et projets, sans compter les pauses ni les autres jours' {
        $ticket.days['2026-11-13'] = 40 * $Min
        $ticket.days['2026-11-12'] = 300 * $Min
        $block.days['2026-11-13'] = 20 * $Min
        $pause.days['2026-11-13'] = 15 * $Min
        $b = Get-TdDayBalance -State $state -NowMs $T0
        $b.ticketMs | Should -Be (40 * $Min)
        $b.projectMs | Should -Be (20 * $Min)
        $b.totalMs | Should -Be (60 * $Min)
        [Math]::Round($b.ticketRatio, 3) | Should -Be 0.667
        $b.behind | Should -BeNullOrEmpty
    }
    It 'compte le minuteur en marche et les tâches validées ou escaladées aujourd''hui' {
        Start-TdTimer $state $T0
        [void](Complete-TdTask -State $state -NowMs ($T0 + 10 * $Min))
        [void](Set-TdTicketEscalated -State $state -Id $state.tasks[0].id -NowMs ($T0 + 10 * $Min))
        $state.tasks[0].days['2026-11-13'] = 5 * $Min
        Start-TdTimer $state ($T0 + 10 * $Min)
        $b = Get-TdDayBalance -State $state -NowMs ($T0 + 16 * $Min)
        $b.ticketMs | Should -Be (10 * $Min)
        $b.projectMs | Should -Be (11 * $Min)
    }
    It 'prévient quand les projets passent derrière, avec le temps à rattraper' {
        # Exemple de la maquette : 2 h 40 de tickets, 1 h 05 de projets, objectif 60 / 40.
        $ticket.days['2026-11-13'] = 160 * $Min
        $block.days['2026-11-13'] = 65 * $Min
        $b = Get-TdDayBalance -State $state -NowMs $T0
        $b.behind | Should -Be 'projects'
        $b.catchUpMinutes | Should -Be 45
        $b.message | Should -Be 'Les projets passent derrière : un bloc de 45 min rééquilibrerait.'
    }
    It 'prévient quand les tickets passent derrière' {
        $ticket.days['2026-11-13'] = 20 * $Min
        $block.days['2026-11-13'] = 100 * $Min
        $b = Get-TdDayBalance -State $state -NowMs $T0
        $b.behind | Should -Be 'tickets'
        $b.catchUpMinutes | Should -BeGreaterThan 90
        $b.message | Should -Be 'Les tickets passent derrière : y revenir aiderait à rééquilibrer.'
        $block.days['2026-11-13'] = 40 * $Min
        (Get-TdDayBalance -State $state -NowMs $T0).message | Should -Be 'Les tickets passent derrière : 40 min de tickets rééquilibreraient.'
    }
    It 'se tait près de l''objectif, et avant 30 min de travail mesuré' {
        $ticket.days['2026-11-13'] = 65 * $Min
        $block.days['2026-11-13'] = 35 * $Min
        (Get-TdDayBalance -State $state -NowMs $T0).behind | Should -BeNullOrEmpty
        $ticket.days['2026-11-13'] = 25 * $Min
        $block.days['2026-11-13'] = 0
        $b = Get-TdDayBalance -State $state -NowMs $T0
        $b.ticketRatio | Should -Be 1
        $b.behind | Should -BeNullOrEmpty
    }
    It 'suit l''objectif réglé' {
        $ticket.days['2026-11-13'] = 160 * $Min
        $block.days['2026-11-13'] = 65 * $Min
        (Get-TdDayBalance -State $state -NowMs $T0 -TicketShare 70).behind | Should -BeNullOrEmpty
        (Get-TdDayBalance -State $state -NowMs $T0 -TicketShare 40).behind | Should -Be 'projects'
        Format-TdBalanceTarget -TicketShare 60 | Should -Be 'objectif 60 / 40'
        Format-TdBalanceTarget -TicketShare 75 | Should -Be 'objectif 75 / 25'
    }
}

Describe 'Réglages du cockpit : alerte et objectif' {
    It 'valent 30 min et 60 / 40 par défaut, et refusent les valeurs absurdes' {
        $s = ConvertTo-TdCockpitSettings $null
        $s.ticketAlertMinutes | Should -Be 30
        $s.ticketShare | Should -Be 60
        (ConvertTo-TdCockpitSettings @{ ticketAlertMinutes = 45; ticketShare = 70 }).ticketAlertMinutes | Should -Be 45
        (ConvertTo-TdCockpitSettings @{ ticketAlertMinutes = 45; ticketShare = 70 }).ticketShare | Should -Be 70
        (ConvertTo-TdCockpitSettings @{ ticketAlertMinutes = 0 }).ticketAlertMinutes | Should -Be 30
        (ConvertTo-TdCockpitSettings @{ ticketAlertMinutes = 'abc' }).ticketAlertMinutes | Should -Be 30
        (ConvertTo-TdCockpitSettings @{ ticketShare = 100 }).ticketShare | Should -Be 60
        (ConvertTo-TdCockpitSettings @{ ticketShare = 5 }).ticketShare | Should -Be 60
    }
}
