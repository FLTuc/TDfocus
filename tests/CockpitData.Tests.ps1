# Cockpit : projets, relances du jour, prochaine réunion, bloc projet, « Où j'en étais », récap (sans interface).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\TDfocus.Core.ps1')
    # Un vendredi à 10:00 (le 13 novembre 2026).
    $script:T0 = ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 13, 10, 0, 0))
    $script:Min = 60000
    $script:Day = 86400000
}

Describe 'Jours ouvrés' {
    It 'ne compte pas le week-end' {
        $monday = ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 16, 9, 0, 0))
        Get-TdWorkdaysBetween -FromMs $T0 -ToMs $T0 | Should -Be 0
        Get-TdWorkdaysBetween -FromMs $T0 -ToMs $monday | Should -Be 1
        Get-TdWorkdaysBetween -FromMs $T0 -ToMs ($monday + $Day) | Should -Be 2
        Get-TdWorkdaysBetween -FromMs ($T0 - 7 * $Day) -ToMs $T0 | Should -Be 5
        Get-TdWorkdaysBetween -FromMs $monday -ToMs $T0 | Should -Be 0
    }
}

Describe 'Projets vus par le cockpit' {
    BeforeEach {
        $projects = [System.Collections.Generic.List[object]]::new()
        $migration = New-TdProject -Name 'Migration messagerie' -Deadline '2026-11-19' -Steps @('Exporter les comptes', 'Pilote 50 utilisateurs', 'Bascule', 'Bilan') -NowMs ($T0 - 20 * $Day)
        $migration.steps[0].done = $true
        $migration.lastWorkedAt = $T0 - 1 * $Day
        $kb = New-TdProject -Name 'Base de connaissances' -Steps @('Plan', 'Rédaction', 'Relecture') -NowMs ($T0 - 20 * $Day)
        $kb.lastWorkedAt = $T0 - 10 * $Day
        $win = New-TdProject -Name 'Déploiement postes Win 11' -Deadline '2026-11-25' -Steps @('Lot 1', 'Lot 2', 'Lot 3', 'Lot 4', 'Lot 5') -NowMs ($T0 - 20 * $Day)
        foreach ($i in 0..3) { $win.steps[$i].done = $true }
        $win.lastWorkedAt = $T0 - 3 * $Day
        $old = New-TdProject -Name 'Archivage' -NowMs ($T0 - 20 * $Day)
        foreach ($p in @($migration, $kb, $win, $old)) { [void](Add-TdProject -Projects $projects -Project $p) }
        $state = New-TdState
    }

    It 'donne l''avancement, le prochain jalon et l''échéance' {
        $list = @(Get-TdCockpitProjects -Projects $projects -State $state -NowMs $T0)
        # Le 4e projet est « en attente » dans TDfocus (3 en cours au plus) : il n'apparaît pas.
        $list.Count | Should -Be 3
        $list[0].name | Should -Be 'Migration messagerie'
        $list[0].percent | Should -Be 25
        $list[0].nextStep | Should -Be 'Pilote 50 utilisateurs'
        $list[0].deadlineText | Should -Be 'J-6'
        $list[0].stale | Should -BeFalse
        $list[0].alertText | Should -Be ''
        $list[0].detailText | Should -Be 'Jalon : Pilote 50 utilisateurs · J-6'
    }
    It 'signale un projet qui n''a pas bougé depuis 2 jours ouvrés' {
        $list = @(Get-TdCockpitProjects -Projects $projects -State $state -NowMs $T0)
        $list[2].percent | Should -Be 80
        $list[2].idleDays | Should -Be 3
        $list[2].stale | Should -BeTrue
        $list[2].alertText | Should -Be 'Pas bougé depuis 3 jours'
        $list[2].detailText | Should -Be 'Jalon : Lot 5 · J-12'
    }
    It 'ne signale pas un projet sur lequel on a travaillé aujourd''hui, même sans bloc validé' {
        $block = New-TdProjectBlockTask -Project $projects[2] -NowMs $T0
        [void](Add-TdTask -State $state -Task $block -NowMs $T0)
        Start-TdTimer $state ($T0 - 5 * $Min)
        @(Get-TdCockpitProjects -Projects $projects -State $state -NowMs $T0)[2].stale | Should -BeFalse
        Get-TdProjectTodayMs -State $state -ProjectId $projects[2].id -NowMs $T0 | Should -Be (5 * $Min)
    }
    It 'affiche « bloqué : en attente de… » à la place, et prévoit la relance' {
        Set-TdProjectBlocked -Project $projects[1] -Reason '  la validation   RSSI ' -NowMs $T0
        $projects[1].blockedBy | Should -Be 'la validation RSSI'
        $projects[1].followUpOn | Should -Be '2026-11-16'
        $item = @(Get-TdCockpitProjects -Projects $projects -State $state -NowMs $T0)[1]
        $item.blocked | Should -BeTrue
        $item.stale | Should -BeFalse
        $item.detailText | Should -Be 'Bloqué : en attente de la validation RSSI'
        # Débloquer : un texte vide.
        Set-TdProjectBlocked -Project $projects[1] -Reason '' -NowMs $T0
        $projects[1].followUpOn | Should -BeNullOrEmpty
        @(Get-TdCockpitProjects -Projects $projects -State $state -NowMs $T0)[1].blocked | Should -BeFalse
    }
    It 'garde le blocage à l''enregistrement, et abrège les échéances' {
        Set-TdProjectBlocked -Project $projects[1] -Reason 'le prestataire' -NowMs $T0
        $back = ConvertTo-TdProject (ConvertTo-Json -InputObject $projects[1] -Depth 6 | ConvertFrom-Json)
        $back.blockedBy | Should -Be 'le prestataire'
        $back.followUpOn | Should -Be '2026-11-16'
        (ConvertTo-TdProject @{ name = 'Ancien' }).blockedBy | Should -Be ''
        Format-TdDeadlineShort 6 | Should -Be 'J-6'
        Format-TdDeadlineShort 0 | Should -Be 'J-0'
        Format-TdDeadlineShort -2 | Should -Be 'J+2'
        Format-TdDeadlineShort $null | Should -Be ''
    }
}

Describe 'Relances du jour et prochaine réunion' {
    BeforeEach {
        $state = New-TdState
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'INC-4790 logs utilisateur' -NowMs $T0) -NowMs $T0)
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'INC-4801 VPN' -NowMs $T0) -NowMs $T0)
        $projects = [System.Collections.Generic.List[object]]::new()
        $p = New-TdProject -Name 'Migration' -NowMs $T0
        [void](Add-TdProject -Projects $projects -Project $p)
        $monday = ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 16, 9, 0, 0))
    }

    It 'mélange tickets escaladés et projets bloqués, le jour où la relance est due' {
        [void](Set-TdTicketEscalated -State $state -Id $state.tasks[0].id -NowMs $T0)
        Set-TdProjectBlocked -Project $p -Reason 'le prestataire' -NowMs $T0
        @(Get-TdFollowUps -State $state -Projects $projects -NowMs $T0).Count | Should -Be 0
        $due = @(Get-TdFollowUps -State $state -Projects $projects -NowMs $monday)
        $due.Count | Should -Be 2
        $due[0].kind | Should -Be 'ticket'
        $due[0].text | Should -Be 'INC-4790 logs utilisateur'
        $due[1].kind | Should -Be 'project'
        $due[1].text | Should -Be 'Migration · relancer : le prestataire'
        # « Relancé » sur le projet : la relance est repoussée au prochain jour ouvré.
        Set-TdProjectFollowUp -Project $p -NowMs $monday
        $p.followUpOn | Should -Be '2026-11-17'
        @(Get-TdFollowUps -State $state -Projects $projects -NowMs $monday).Count | Should -Be 1
    }
    It 'trouve la prochaine action à heure fixe, hors blocs projet' {
        Get-TdNextMeeting -State $state -NowMs $T0 | Should -BeNullOrEmpty
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'Point d''équipe' -Minutes 30 -FixedStart '15:30' -NowMs $T0) -NowMs $T0)
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'Comité' -Minutes 30 -FixedStart '11:00' -NowMs $T0) -NowMs $T0)
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'Passée' -Minutes 30 -FixedStart '09:00' -NowMs $T0) -NowMs $T0)
        $block = New-TdProjectBlockTask -Project $p -NowMs $T0
        $block.fixedStart = '10:30'
        [void](Add-TdTask -State $state -Task $block -NowMs $T0)
        $next = Get-TdNextMeeting -State $state -NowMs $T0
        $next.text | Should -Be '11:00 · Comité'
        $next.delay | Should -Be 'dans 1 h'
        (Get-TdNextMeeting -State $state -NowMs ($T0 + 62 * $Min)).text | Should -Be '15:30 · Point d''équipe'
        Format-TdDelay -Ms (58 * $Min) | Should -Be 'dans 58 min'
        Format-TdDelay -Ms (65 * $Min) | Should -Be 'dans 1 h 05'
    }
}

Describe 'Bloc projet' {
    BeforeEach {
        $state = New-TdState
        $projects = [System.Collections.Generic.List[object]]::new()
        $p = New-TdProject -Name 'Migration messagerie' -Steps @('Exporter la liste', 'Créer le groupe pilote', 'Planifier la bascule') -NowMs $T0
        Set-TdProjectBreadcrumb -Project $p -Text 'export fait, reste à vérifier les alias' -NowMs $T0
        [void](Add-TdProject -Projects $projects -Project $p)
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'INC-1' -NowMs $T0) -NowMs $T0)
        $block = New-TdProjectBlockTask -Project $p -Minutes 90 -NowMs $T0
        $block.fixedStart = '14:00'
        [void](Add-TdTask -State $state -Task $block -NowMs $T0)
        $at14 = ConvertFrom-TdLocalDate ([DateTime]::new(2026, 11, 13, 14, 0, 0))
    }

    It 'n''existe que si la tâche en cours de TDfocus est un bloc projet' {
        Get-TdProjectBlockInfo -State $state -Projects $projects -NowMs $T0 | Should -BeNullOrEmpty
        Start-TdTaskNow -State $state -Id $block.id -NowMs $at14
        $info = Get-TdProjectBlockInfo -State $state -Projects $projects -NowMs ($at14 + 38 * $Min)
        $info.name | Should -Be 'Migration messagerie'
        $info.slotText | Should -Be '14:00 – 15:30'
        $info.remainingText | Should -Be 'Reste 52 min'
        $info.running | Should -BeTrue
        $info.currentStep.title | Should -Be 'Exporter la liste'
        $info.breadcrumb | Should -Be 'export fait, reste à vérifier les alias'
        [Math]::Round($info.ratio, 2) | Should -Be 0.42
        (Get-TdProjectBlockInfo -State $state -Projects $projects -NowMs ($at14 + 95 * $Min)).remainingText | Should -Be 'Dépassé de 5 min'
    }
    It 'affiche la durée quand le bloc n''a pas d''heure fixe' {
        $block.fixedStart = $null
        Start-TdTaskNow -State $state -Id $block.id -NowMs $T0
        (Get-TdProjectBlockInfo -State $state -Projects $projects -NowMs $T0).slotText | Should -Be '1 h 30'
        Format-TdBlockSlot -Task $block -NowMs $T0 | Should -Be '1 h 30'
    }
    It 'repère le bloc planifié dont l''heure est arrivée' {
        Get-TdDueProjectBlock -State $state -NowMs $T0 | Should -BeNullOrEmpty
        (Get-TdDueProjectBlock -State $state -NowMs ($at14 + 1 * $Min)).id | Should -Be $block.id
        Get-TdDueProjectBlock -State $state -NowMs ($at14 + 91 * $Min) | Should -BeNullOrEmpty
        # Une fois démarré, il n'est plus « à commencer ».
        Start-TdTaskNow -State $state -Id $block.id -NowMs ($at14 + 1 * $Min)
        Get-TdDueProjectBlock -State $state -NowMs ($at14 + 2 * $Min) | Should -BeNullOrEmpty
    }
}

Describe '« Où j''en étais » et « Récap du jour »' {
    BeforeEach {
        $state = New-TdState
        $projects = [System.Collections.Generic.List[object]]::new()
        $p = New-TdProject -Name 'Migration' -NowMs $T0
        Set-TdProjectBreadcrumb -Project $p -Text 'reste à vérifier les alias' -NowMs $T0
        [void](Add-TdProject -Projects $projects -Project $p)
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'INC-1 VPN' -Steps @('Lire les logs', 'Rappeler') -Note 'Voir avec Paul' -NowMs $T0) -NowMs $T0)
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'INC-2 Imprimante' -NowMs $T0) -NowMs $T0)
        [void](Add-TdTask -State $state -Task (New-TdTask -Title 'INC-3 Accès' -NowMs $T0) -NowMs $T0)
    }

    It 'rappelle la tâche en cours, son étape, sa note et la note de reprise des projets' {
        Start-TdTimer $state $T0
        Suspend-TdTimer $state ($T0 + 12 * $Min)
        $lines = @(Get-TdWhereWasI -State $state -Projects $projects -NowMs ($T0 + 20 * $Min))
        $lines[0].title | Should -Be 'En cours : INC-1 VPN'
        $lines[0].text | Should -Be 'en pause depuis 8 min, 12 min passées'
        ($lines | Where-Object { $_.title -eq 'Étape' }).text | Should -Be 'Lire les logs'
        ($lines | Where-Object { $_.title -eq 'Note' }).text | Should -Be 'Voir avec Paul'
        ($lines | Where-Object { $_.title -eq 'Projet Migration' }).text | Should -Be 'reste à vérifier les alias'
        @(Get-TdWhereWasI -State (New-TdState) -Projects @() -NowMs $T0)[0].title | Should -Be 'Rien en cours'
        # Pas de « 0 s » ni de « 0 min » : une tâche à peine touchée est simplement « en pause ».
        $fresh = New-TdState
        [void](Add-TdTask -State $fresh -Task (New-TdTask -Title 'INC-9' -NowMs $T0) -NowMs $T0)
        @(Get-TdWhereWasI -State $fresh -Projects @() -NowMs $T0)[0].text | Should -Be 'pas encore commencée'
        Start-TdTimer $fresh $T0
        @(Get-TdWhereWasI -State $fresh -Projects @() -NowMs ($T0 + 5000))[0].text | Should -Be 'minuteur en marche'
        Suspend-TdTimer $fresh ($T0 + 5000)
        @(Get-TdWhereWasI -State $fresh -Projects @() -NowMs ($T0 + 6000))[0].text | Should -Be 'en pause'
    }
    It 'résume la journée : fermés, temps, escaladés, reste à faire' {
        Start-TdTimer $state $T0
        [void](Complete-TdTask -State $state -NowMs ($T0 + 40 * $Min))
        [void](Set-TdTicketEscalated -State $state -Id $state.tasks[0].id -NowMs ($T0 + 41 * $Min))
        $block = New-TdProjectBlockTask -Project $p -NowMs $T0
        $block.days['2026-11-13'] = 25 * $Min
        [void](Add-TdTask -State $state -Task $block -NowMs $T0)
        $lines = @(Get-TdDayRecap -State $state -Projects $projects -NowMs ($T0 + 60 * $Min))
        $lines[0].title | Should -Be 'Tickets fermés : 1'
        $lines[0].text | Should -Be 'INC-1 VPN'
        $lines[1].text | Should -Be 'Tickets 40 min · Projets 25 min'
        ($lines | Where-Object { $_.title -eq 'Projet Migration' }).text | Should -Be "25 min aujourd'hui"
        ($lines | Where-Object { $_.title -like 'Escaladés*' }).text | Should -Be 'INC-2 Imprimante'
        $lines[$lines.Count - 1].text | Should -Be '1 ouvert · 1 à relancer'
    }
}
