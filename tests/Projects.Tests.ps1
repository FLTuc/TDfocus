# Projets au long cours et actions du quotidien.
# Les variables préparées dans BeforeEach sont utilisées dans les blocs It (portée Pester).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\TDfocus.Core.ps1')
    # Jeudi 29 octobre 2026
    function At([int]$Hour, [int]$Minute = 0, [int]$DayOffset = 0) {
        ConvertFrom-TdLocalDate ([DateTime]::new(2026, 10, 29, $Hour, $Minute, 0).AddDays($DayOffset))
    }
    $script:Min = 60000L
}

Describe 'Projets' {
    BeforeEach {
        $projects = [System.Collections.Generic.List[object]]::new()
        $state = New-TdState
        $project = New-TdProject -Name 'Rénover la cuisine' -Why 'Cuisiner avec plaisir' -Steps @('Mesurer les murs', 'Choisir les couleurs', 'Acheter la peinture', 'Poncer') -NowMs (At 9 0 -10)
        [void](Add-TdProject -Projects $projects -Project $project)
    }

    It 'crée un projet en cours avec ses pas, son pourquoi et un bloc de 25 min' {
        $project.status | Should -Be 'active'
        $project.why | Should -Be 'Cuisiner avec plaisir'
        $project.blockMinutes | Should -Be 25
        (Get-TdProjectProgress $project).total | Should -Be 4
    }
    It 'limite à 3 projets en cours : le 4e est rangé en attente' {
        foreach ($n in 'B', 'C') { [void](Add-TdProject -Projects $projects -Project (New-TdProject -Name $n)) }
        Add-TdProject -Projects $projects -Project (New-TdProject -Name 'D') | Should -Be 'paused'
        @(Get-TdActiveProjects $projects).Count | Should -Be 3
        $d = $projects | Where-Object name -eq 'D'
        Set-TdProjectStatus -Projects $projects -Project $d -Status 'active' | Should -BeFalse
        Set-TdProjectStatus -Projects $projects -Project $project -Status 'paused' | Should -BeTrue
        Set-TdProjectStatus -Projects $projects -Project $d -Status 'active' | Should -BeTrue
    }
    It 'prépare un bloc de temps avec seulement les 3 prochains pas' {
        Set-TdProjectStepDone -Project $project -StepId $project.steps[0].id | Out-Null
        $task = New-TdProjectBlockTask -Project $project -NowMs (At 10)
        $task.title | Should -Be 'Rénover la cuisine'
        $task.plannedMs | Should -Be (25 * $Min)
        $task.projectId | Should -Be $project.id
        ($task.steps | ForEach-Object title) -join '|' | Should -Be 'Choisir les couleurs|Acheter la peinture|Poncer'
    }
    It 'reporte les pas cochés et le temps investi quand le bloc est terminé' {
        $task = New-TdProjectBlockTask -Project $project -NowMs (At 10)
        Add-TdTask -State $state -Task $task -NowMs (At 10)
        Start-TdTimer $state (At 10)
        Complete-TdStep -State $state | Out-Null
        $done = Complete-TdTask -State $state -NowMs (At 10 20)
        Complete-TdProjectBlock -Projects $projects -Task $done -NowMs (At 10 20) | Out-Null
        $project.steps[0].done | Should -BeTrue
        $project.steps[1].done | Should -BeFalse
        $project.investedMs | Should -Be (20 * $Min)
        $project.sessions | Should -Be 1
        $project.lastWorkedAt | Should -Be (At 10 20)
        Undo-TdProjectBlock -Projects $projects -Task $done | Out-Null
        $project.investedMs | Should -Be 0
        $project.sessions | Should -Be 0
    }
    It 'garde une note « où j''en étais »' {
        Set-TdProjectBreadcrumb -Project $project -Text '  Mur nord mesuré, reste la fenêtre  ' -NowMs (At 11)
        $project.breadcrumb | Should -Be 'Mur nord mesuré, reste la fenêtre'
        $project.breadcrumbAt | Should -Be (At 11)
    }
    It 'ajoute et retire des pas' {
        $step = Add-TdProjectStep -Project $project -Title 'Appeler le peintre'
        (Get-TdProjectProgress $project).total | Should -Be 5
        Remove-TdProjectStep -Project $project -StepId $step.id
        (Get-TdProjectProgress $project).total | Should -Be 4
    }
    It 'résume l''avancement sans reproche' {
        $project.investedMs = 150 * $Min
        $project.lastWorkedAt = At 18 0 -1
        $project.deadline = '2026-11-19'
        Set-TdProjectStepDone -Project $project -StepId $project.steps[0].id | Out-Null
        Get-TdProjectSummary -Project $project -NowMs (At 9) | Should -Be '1/4 pas · 2 h 30 investies · dernier pas hier · échéance dans 3 semaines'
    }
    It 'survit à l''enregistrement JSON' {
        $project.deadline = '2026-12-15'
        Set-TdProjectBreadcrumb -Project $project -Text 'Couleurs choisies' -NowMs (At 11)
        $copy = ConvertTo-TdProject (ConvertTo-Json -InputObject $project -Depth 6 | ConvertFrom-Json)
        $copy.name | Should -Be 'Rénover la cuisine'
        $copy.deadline | Should -Be '2026-12-15'
        $copy.breadcrumb | Should -Be 'Couleurs choisies'
        $copy.steps.Count | Should -Be 4
        $copy.steps[0].id | Should -Be $project.steps[0].id
    }
}

Describe 'Rappel doux du projet qui attend' {
    BeforeEach {
        $projects = [System.Collections.Generic.List[object]]::new()
        $state = New-TdState
        $old = New-TdProject -Name 'Écrire le mémoire' -NowMs (At 9 0 -20)
        $old.lastWorkedAt = At 9 0 -6
        $fresh = New-TdProject -Name 'Ranger le garage' -NowMs (At 9 0 -2)
        $fresh.lastWorkedAt = At 9 0 -1
        foreach ($p in $old, $fresh) { [void](Add-TdProject -Projects $projects -Project $p) }
    }
    It 'propose le projet qui attend depuis le plus longtemps' {
        $nudge = Get-TdProjectNudge -Projects $projects -State $state -NowMs (At 9)
        $nudge.project.name | Should -Be 'Écrire le mémoire'
        $nudge.idleDays | Should -Be 6
    }
    It 'formule le rappel comme une invitation' {
        $nudge = Get-TdProjectNudge -Projects $projects -State $state -NowMs (At 9)
        Get-TdNudgeText $nudge | Should -Be '« Écrire le mémoire » attend depuis 6 jours. Un petit pas aujourd''hui ?'
        $old.lastWorkedAt = $null
        Get-TdNudgeText (Get-TdProjectNudge -Projects $projects -State $state -NowMs (At 9)) | Should -Be '« Écrire le mémoire » n''a pas encore démarré. Un premier petit pas aujourd''hui ?'
    }
    It 'donne la priorité à une échéance proche' {
        $fresh.deadline = '2026-11-05'
        (Get-TdProjectNudge -Projects $projects -State $state -NowMs (At 9)).project.name | Should -Be 'Ranger le garage'
    }
    It 'se tait quand un bloc projet est déjà prévu aujourd''hui' {
        Add-TdTask -State $state -Task (New-TdProjectBlockTask -Project $fresh -NowMs (At 9)) -NowMs (At 9)
        Get-TdProjectNudge -Projects $projects -State $state -NowMs (At 9) | Should -BeNullOrEmpty
    }
    It 'se tait pour la journée après « pas aujourd''hui »' {
        $state.nudgeOff = Get-TdDayKey (At 9)
        Get-TdProjectNudge -Projects $projects -State $state -NowMs (At 15) | Should -BeNullOrEmpty
        Get-TdProjectNudge -Projects $projects -State $state -NowMs (At 9 0 1) | Should -Not -BeNullOrEmpty
    }
    It 'ignore les projets en attente ou terminés' {
        foreach ($p in $projects) { $p.status = 'paused' }
        Get-TdProjectNudge -Projects $projects -State $state -NowMs (At 9) | Should -BeNullOrEmpty
    }
}

Describe 'Dates des projets' {
    It 'comprend les échéances saisies librement' {
        ConvertTo-TdDateKey '15/12/2026' (At 9) | Should -Be '2026-12-15'
        ConvertTo-TdDateKey '2027-01-03' (At 9) | Should -Be '2027-01-03'
        ConvertTo-TdDateKey '15/12' (At 9) | Should -Be '2026-12-15'
        ConvertTo-TdDateKey '01/02' (At 9) | Should -Be '2027-02-01'
        ConvertTo-TdDateKey '31/02/2026' (At 9) | Should -BeNullOrEmpty
        ConvertTo-TdDateKey 'bientôt' (At 9) | Should -BeNullOrEmpty
    }
    It 'parle en jours, semaines ou mois' {
        Format-TdDaysLeft 0 | Should -Be "échéance aujourd'hui"
        Format-TdDaysLeft 1 | Should -Be 'échéance demain'
        Format-TdDaysLeft 9 | Should -Be 'échéance dans 9 jours'
        Format-TdDaysLeft 21 | Should -Be 'échéance dans 3 semaines'
        Format-TdDaysLeft 95 | Should -Be 'échéance dans 3 mois'
        Format-TdDaysLeft -2 | Should -Be 'échéance passée : on ajuste la date ?'
    }
}

Describe 'Actions du quotidien' {
    BeforeEach {
        $state = New-TdState
        $daily = [System.Collections.Generic.List[object]]::new()
        $dishes = New-TdDailyAction -Title 'Vaisselle' -Minutes 10
        $meds = New-TdDailyAction -Title 'Médicaments' -Minutes 2 -FixedStart '08:00'
        $sport = New-TdDailyAction -Title 'Sport' -Minutes 30 -Days @(6, 7)
        foreach ($a in $dishes, $meds, $sport) { $daily.Add($a) }
    }
    It 'comprend les jours en toutes lettres' {
        (ConvertFrom-TdDaysText '') -join ',' | Should -Be '1,2,3,4,5,6,7'
        (ConvertFrom-TdDaysText 'en semaine') -join ',' | Should -Be '1,2,3,4,5'
        (ConvertFrom-TdDaysText 'week-end') -join ',' | Should -Be '6,7'
        (ConvertFrom-TdDaysText 'lun-mer') -join ',' | Should -Be '1,2,3'
        (ConvertFrom-TdDaysText 'mardi, jeudi') -join ',' | Should -Be '2,4'
        ConvertFrom-TdDaysText 'parfois' | Should -BeNullOrEmpty
        Format-TdDays @(1, 3, 5) | Should -Be 'lun, mer, ven'
        Format-TdDays @(1, 2, 3, 4, 5) | Should -Be 'en semaine'
    }
    It 'ajoute les actions prévues aujourd''hui, une seule fois' {
        Sync-TdDailyTasks -State $state -Daily $daily -NowMs (At 7) | Should -Be 2
        # La vaisselle (07:00-07:10) passe avant les médicaments, calés à 08:00.
        ($state.tasks | ForEach-Object title) -join '|' | Should -Be 'Vaisselle|Médicaments'
        $state.tasks[0].dailyId | Should -Be $dishes.id
        Sync-TdDailyTasks -State $state -Daily $daily -NowMs (At 12) | Should -Be 0
        $state.tasks.Count | Should -Be 2
    }
    It 'ne fait pas revenir une action supprimée ou faite aujourd''hui' {
        Sync-TdDailyTasks -State $state -Daily $daily -NowMs (At 7) | Out-Null
        Remove-TdTask -State $state -Id ($state.tasks | Where-Object dailyId -eq $dishes.id).id -NowMs (At 8) | Out-Null
        Sync-TdDailyTasks -State $state -Daily $daily -NowMs (At 9) | Should -Be 0
        @($state.tasks | Where-Object dailyId -eq $dishes.id).Count | Should -Be 0
    }
    It 'ajoute dès aujourd''hui une action créée en cours de journée' {
        Sync-TdDailyTasks -State $state -Daily $daily -NowMs (At 7) | Out-Null
        $daily.Add((New-TdDailyAction -Title 'Arroser les plantes' -Minutes 5))
        Sync-TdDailyTasks -State $state -Daily $daily -NowMs (At 15) | Should -Be 1
    }
    It 'respecte les jours prévus et les actions en pause' {
        $dishes.active = $false
        Sync-TdDailyTasks -State $state -Daily $daily -NowMs (At 9 0 2) | Should -Be 2   # samedi : médicaments + sport
        ($state.tasks | ForEach-Object title) -contains 'Sport' | Should -BeTrue
        ($state.tasks | ForEach-Object title) -contains 'Vaisselle' | Should -BeFalse
    }
    It 'ne laisse pas s''accumuler les actions d''hier : elles reviennent, sans revue ni doublon' {
        Sync-TdDailyTasks -State $state -Daily $daily -NowMs (At 7) | Out-Null
        Add-TdTask -State $state -Task (New-TdTask -Title 'Rapport' -Minutes 30 -NowMs (At 7)) -NowMs (At 7)
        $state.dayKey = Get-TdDayKey (At 7)
        $result = Invoke-TdDayRollover -State $state -NowMs (At 7 0 1)
        $result.dailyCleared | Should -Be 2
        ($state.tasks | ForEach-Object title) -join '|' | Should -Be 'Rapport'
        $state.review.Count | Should -Be 1
        Sync-TdDailyTasks -State $state -Daily $daily -NowMs (At 7 0 1) | Should -Be 2
        @($state.tasks | Where-Object dailyId -eq $dishes.id).Count | Should -Be 1
    }
    It 'garde l''action du quotidien en cours au passage de minuit' {
        Sync-TdDailyTasks -State $state -Daily $daily -NowMs (At 23) | Out-Null
        Start-TdTimer $state (At 23 50)
        $state.dayKey = Get-TdDayKey (At 23)
        (Invoke-TdDayRollover -State $state -NowMs (At 0 5 1)).dailyCleared | Should -Be 1
        $state.tasks[0].title | Should -Be 'Vaisselle'
    }
    It 'modifie une action et sa tâche du jour pas encore commencée' {
        Sync-TdDailyTasks -State $state -Daily $daily -NowMs (At 7) | Out-Null
        ConvertTo-TdDailyActionText $meds | Should -Be 'Médicaments 2 @08:00'
        Set-TdDailyActionFromText -Action $meds -Text 'Point d''équipe 15 @9h30' | Should -BeTrue
        $meds.title | Should -Be 'Point d''équipe'
        $meds.minutes | Should -Be 15
        $meds.fixedStart | Should -Be '09:30'
        Update-TdDailyTaskToday -State $state -Action $meds | Should -BeTrue
        $task = $state.tasks | Where-Object dailyId -eq $meds.id
        $task.title | Should -Be 'Point d''équipe'
        $task.plannedMs | Should -Be (15 * $Min)
        Set-TdDailyActionFromText -Action $meds -Text '   ' | Should -BeFalse
    }
    It 'ne touche pas à une tâche du jour déjà commencée' {
        Sync-TdDailyTasks -State $state -Daily $daily -NowMs (At 7) | Out-Null
        Start-TdTimer $state (At 7)
        $first = $state.tasks[0]
        $action = $daily | Where-Object id -eq $first.dailyId
        [void](Set-TdDailyActionFromText -Action $action -Text 'Autre 20')
        Update-TdDailyTaskToday -State $state -Action $action | Should -BeFalse
        $first.title | Should -Not -Be 'Autre'
    }
    It 'survit à l''enregistrement JSON' {
        $copy = ConvertTo-TdDailyAction (ConvertTo-Json -InputObject $sport -Depth 5 | ConvertFrom-Json)
        $copy.days -join ',' | Should -Be '6,7'
        $copy.minutes | Should -Be 30
        $copy.active | Should -BeTrue
        $restored = ConvertTo-TdState (ConvertTo-Json -InputObject (ConvertTo-TdStateRecord $state) -Depth 8 | ConvertFrom-Json)
        $restored.dailyMade.Count | Should -Be 0
    }
    It 'conserve les liens projet et quotidien des tâches' {
        Sync-TdDailyTasks -State $state -Daily $daily -NowMs (At 7) | Out-Null
        $restored = ConvertTo-TdState (ConvertTo-Json -InputObject (ConvertTo-TdStateRecord $state) -Depth 8 | ConvertFrom-Json)
        $restored.tasks[0].dailyId | Should -Be $dishes.id
        $restored.dailyKey | Should -Be (Get-TdDayKey (At 7))
        $restored.dailyMade.Count | Should -Be 2
    }
}
