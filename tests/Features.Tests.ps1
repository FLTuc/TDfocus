# Les variables préparées dans BeforeEach sont utilisées dans les blocs It (portée Pester).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\TDfocus.Core.ps1')
    function At([int]$Hour, [int]$Minute = 0, [int]$Second = 0, [int]$DayOffset = 0) {
        ConvertFrom-TdLocalDate ([DateTime]::new(2026, 10, 29, $Hour, $Minute, $Second).AddDays($DayOffset))
    }
    $script:Min = 60000L
}

Describe 'Sous-étapes' {
    BeforeEach {
        $state = New-TdState
        $task = New-TdTask -Title 'Rapport' -Minutes 60 -Steps @('Ouvrir le fichier', 'Faire le plan', 'Écrire l''intro') -NowMs (At 9)
        Add-TdTask -State $state -Task $task -NowMs (At 9)
    }
    It 'crée des étapes à partir de titres' {
        $task.steps.Count | Should -Be 3
        $task.steps[0].done | Should -BeFalse
        (Get-TdCurrentStep $task).title | Should -Be 'Ouvrir le fichier'
    }
    It 'coche l''étape en cours puis passe à la suivante' {
        (Complete-TdStep -State $state).title | Should -Be 'Ouvrir le fichier'
        $p = Get-TdStepProgress $task
        $p.done | Should -Be 1
        $p.index | Should -Be 2
        $p.current.title | Should -Be 'Faire le plan'
    }
    It 'annule la dernière étape cochée' {
        Complete-TdStep -State $state | Out-Null
        Complete-TdStep -State $state | Out-Null
        (Undo-TdStep -State $state).title | Should -Be 'Faire le plan'
        (Get-TdCurrentStep $task).title | Should -Be 'Faire le plan'
    }
    It 'signale quand toutes les étapes sont faites' {
        1..3 | ForEach-Object { Complete-TdStep -State $state | Out-Null }
        Get-TdCurrentStep $task | Should -BeNullOrEmpty
        Complete-TdStep -State $state | Should -BeNullOrEmpty
        (Get-TdStepProgress $task).done | Should -Be 3
    }
    It 'lit les étapes depuis un texte (lignes, puces, cases, « ; »)' {
        $items = ConvertFrom-TdStepsText "- [ ] Un`n[x] Deux`n3. Trois`n`n☐ Quatre"
        ($items | ForEach-Object title) -join '|' | Should -Be 'Un|Deux|Trois|Quatre'
        $items[1].done | Should -BeTrue
        (ConvertFrom-TdStepsText 'a; b ;c').Count | Should -Be 3
    }
    It 'modifie les étapes en gardant celles inchangées' {
        Complete-TdStep -State $state | Out-Null
        $firstId = $task.steps[0].id
        Update-TdTask -State $state -Id $task.id -Changes @{ stepsText = (ConvertTo-TdStepsText $task) + "`nRelire" } | Out-Null
        $task.steps.Count | Should -Be 4
        $task.steps[0].id | Should -Be $firstId
        $task.steps[0].done | Should -BeTrue
        $task.steps[3].title | Should -Be 'Relire'
    }
    It 'conserve les étapes sur le disque et dans les routines' {
        $copy = ConvertTo-TdTask ($task | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
        $copy.steps.Count | Should -Be 3
        $copy.steps[2].title | Should -Be 'Écrire l''intro'
        $tpl = New-TdTemplateFromTasks -Name 'R' -Tasks @($task)
        $back = ConvertTo-TdTasksFromTemplate -Template $tpl
        $back[0].steps.Count | Should -Be 3
        $back[0].steps[0].done | Should -BeFalse
        $one = ConvertTo-TdTask ((New-TdTask -Title 'Solo' -Steps @('Seule') | ConvertTo-Json -Depth 6) | ConvertFrom-Json)
        $one.steps.Count | Should -Be 1
    }
    It 'propose des étapes dans les routines intégrées' {
        $morning = Get-TdBuiltInTemplates | Where-Object id -eq 'builtin-morning'
        (ConvertTo-TdTasksFromTemplate -Template $morning | Where-Object { $_.steps.Count -gt 0 }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Compteur de pause' {
    It 'mesure la pause en cours et s''efface à la reprise' {
        $state = New-TdState
        $t = New-TdTask -Title 'A' -Minutes 25
        Add-TdTask -State $state -Task $t -NowMs (At 9)
        Get-TdPausedMs $t (At 9) | Should -BeNullOrEmpty
        Start-TdTimer $state (At 9)
        Suspend-TdTimer $state (At 9 10)
        Get-TdPausedMs $t (At 9 22) | Should -Be (12 * $Min)
        Format-TdPausedFor (12 * $Min) | Should -Be 'depuis 12 min'
        Format-TdPausedFor 40000 | Should -Be 'depuis 40 s'
        Start-TdTimer $state (At 9 22)
        Get-TdPausedMs $t (At 9 30) | Should -BeNullOrEmpty
    }
    It 'une tâche qui n''est plus en tête n''est plus « en pause »' {
        $state = New-TdState
        $a = New-TdTask -Title 'A'; $b = New-TdTask -Title 'B'
        Add-TdTask -State $state -Task $a -NowMs (At 9); Add-TdTask -State $state -Task $b -NowMs (At 9)
        Start-TdTimer $state (At 9); Suspend-TdTimer $state (At 9 5)
        Move-TdTask -State $state -From 1 -To 0 -NowMs (At 9 6)
        $a.pausedAt | Should -BeNullOrEmpty
    }
    It 'un PC éteint laisse une pause datée de la fermeture' {
        $state = New-TdState
        $t = New-TdTask -Title 'A'
        Add-TdTask -State $state -Task $t -NowMs (At 9)
        Start-TdTimer $state (At 9)
        $state.lastSeenMs = At 9 20
        Repair-TdStaleTimer -State $state -NowMs (At 18) | Out-Null
        Get-TdPausedMs $t (At 18) | Should -Be ((At 18) - (At 9 20))
    }
}

Describe 'Signaux : atterrissage, fin du temps, carillon' {
    BeforeEach {
        $state = New-TdState
        $settings = Get-TdDefaultSettings
        $settings.landingMinutes = 2
        $settings.chimeEveryMin = 10
        $memory = New-TdSignalMemory
        $t = New-TdTask -Title 'A' -Minutes 25
        Add-TdTask -State $state -Task $t -NowMs (At 9)
        Start-TdTimer $state (At 9)
    }
    It 'reste silencieux en début de tâche' {
        Get-TdSignals -State $state -Settings $settings -NowMs (At 9 1) -Memory $memory | Should -BeNullOrEmpty
    }
    It 'sonne le carillon toutes les 10 minutes' {
        Get-TdSignals -State $state -Settings $settings -NowMs (At 9 1) -Memory $memory | Out-Null
        Get-TdSignals -State $state -Settings $settings -NowMs (At 9 10 1) -Memory $memory | Should -Be 'chime'
        Get-TdSignals -State $state -Settings $settings -NowMs (At 9 12) -Memory $memory | Should -BeNullOrEmpty
    }
    It 'annonce l''atterrissage une seule fois, 2 minutes avant la fin' {
        Get-TdSignals -State $state -Settings $settings -NowMs (At 9 22) -Memory $memory | Should -Not -Contain 'landing'
        Get-TdSignals -State $state -Settings $settings -NowMs (At 9 23 1) -Memory $memory | Should -Contain 'landing'
        Get-TdSignals -State $state -Settings $settings -NowMs (At 9 24) -Memory $memory | Should -Not -Contain 'landing'
    }
    It 'annonce la fin du temps une seule fois, puis se réarme si on ajoute du temps' {
        Get-TdSignals -State $state -Settings $settings -NowMs (At 9 25 1) -Memory $memory | Should -Contain 'timeup'
        Get-TdSignals -State $state -Settings $settings -NowMs (At 9 26) -Memory $memory | Should -Not -Contain 'timeup'
        Add-TdPlannedTime -State $state -DeltaMs (5 * $Min)
        Get-TdSignals -State $state -Settings $settings -NowMs (At 9 28 30) -Memory $memory | Should -Contain 'landing'
        Get-TdSignals -State $state -Settings $settings -NowMs (At 9 30 1) -Memory $memory | Should -Contain 'timeup'
    }
    It 'ne dit rien quand le minuteur est en pause ou l''atterrissage désactivé' {
        $settings.landingMinutes = 0
        Get-TdSignals -State $state -Settings $settings -NowMs (At 9 23 30) -Memory $memory | Should -Not -Contain 'landing'
        Suspend-TdTimer $state (At 9 24)
        Get-TdSignals -State $state -Settings $settings -NowMs (At 9 40) -Memory $memory | Should -BeNullOrEmpty
    }
    It 'ne rejoue pas au démarrage un signal déjà passé' {
        Initialize-TdSignalMemory -State $state -Settings $settings -NowMs (At 9 26) -Memory $memory
        Get-TdSignals -State $state -Settings $settings -NowMs (At 9 26) -Memory $memory | Should -Not -Contain 'timeup'
    }
}

Describe 'Revue du matin' {
    BeforeEach {
        $state = New-TdState
        $a = New-TdTask -Title 'A' -NowMs (At 9)
        $b = New-TdTask -Title 'B' -NowMs (At 9)
        $c = New-TdTask -Title 'C' -NowMs (At 9)
        foreach ($t in @($a, $b, $c)) { Add-TdTask -State $state -Task $t -NowMs (At 9) }
        [void](Invoke-TdDayRollover -State $state -NowMs (At 9))
    }
    It 'rien à revoir le jour même' {
        (Get-TdReviewTasks $state).Count | Should -Be 0
    }
    It 'propose le lendemain les tâches restées d''hier' {
        $r = Invoke-TdDayRollover -State $state -NowMs (At 8 0 0 1)
        $r.newDay | Should -BeTrue
        (Get-TdReviewTasks $state | ForEach-Object title) -join '' | Should -Be 'ABC'
    }
    It 'garde, reporte à demain ou abandonne' {
        [void](Invoke-TdDayRollover -State $state -NowMs (At 8 0 0 1))
        Resolve-TdReview -State $state -Id $a.id -Decision keep -NowMs (At 8 0 0 1) | Out-Null
        Resolve-TdReview -State $state -Id $b.id -Decision tomorrow -NowMs (At 8 0 0 1) | Out-Null
        Resolve-TdReview -State $state -Id $c.id -Decision drop -NowMs (At 8 0 0 1) | Out-Null
        (Get-TdReviewTasks $state).Count | Should -Be 0
        ($state.tasks | ForEach-Object title) -join '' | Should -Be 'A'
        $state.parked.Count | Should -Be 1
        $state.parked[0].deferUntil | Should -Be ((ConvertTo-TdLocalDate (At 8 0 0 2)).ToString('yyyy-MM-dd'))
    }
    It 'les tâches reportées reviennent le jour prévu, et dans la revue' {
        [void](Invoke-TdDayRollover -State $state -NowMs (At 8 0 0 1))
        Resolve-TdReview -State $state -Id $b.id -Decision tomorrow -NowMs (At 8 0 0 1) | Out-Null
        Clear-TdReview $state
        $r = Invoke-TdDayRollover -State $state -NowMs (At 8 0 0 2)
        $r.returned | Should -Be 1
        $state.parked.Count | Should -Be 0
        $state.tasks.title | Should -Contain 'B'
        (Get-TdReviewTasks $state).title | Should -Contain 'B'
    }
    It 'ramène une tâche reportée à la demande' {
        [void](Invoke-TdDayRollover -State $state -NowMs (At 8 0 0 1))
        Resolve-TdReview -State $state -Id $b.id -Decision tomorrow | Out-Null
        Restore-TdParked -State $state -All | Should -Be 1
        $state.tasks.title | Should -Contain 'B'
        $state.tasks[$state.tasks.Count - 1].deferUntil | Should -BeNullOrEmpty
    }
    It 'ignore les tâches déjà terminées entre-temps' {
        [void](Invoke-TdDayRollover -State $state -NowMs (At 8 0 0 1))
        Complete-TdTask -State $state -NowMs (At 8 5 0 1) | Out-Null
        (Get-TdReviewTasks $state | ForEach-Object title) -join '' | Should -Be 'BC'
    }
}

Describe 'Points de contrôle' {
    It 'résume la journée sans jugement' {
        $list = @(
            (New-TdCheckIn -TaskId 'x' -Answer focused -NowMs (At 9)),
            (New-TdCheckIn -TaskId 'x' -Answer drifted -NowMs (At 10)),
            (New-TdCheckIn -TaskId 'x' -Answer missed -NowMs (At 11)),
            (New-TdCheckIn -TaskId 'x' -Answer focused -NowMs (At 9 0 0 -1))
        )
        $s = Get-TdCheckInSummary -CheckIns $list -NowMs (At 12)
        $s.total | Should -Be 3
        $s.focused | Should -Be 1
        $s.drifted | Should -Be 1
        (Limit-TdCheckIns -CheckIns $list -NowMs (At 12 0 0 200)).Count | Should -Be 0
    }
}

Describe 'Persistance des nouveautés' {
    BeforeAll {
        $script:OldData = $env:TDFOCUS_DATA
        $env:TDFOCUS_DATA = Join-Path ([IO.Path]::GetTempPath()) ("tdfocus-feat-" + [guid]::NewGuid().ToString('N'))
    }
    AfterAll {
        Remove-Item -LiteralPath $env:TDFOCUS_DATA -Recurse -Force -ErrorAction SilentlyContinue
        $env:TDFOCUS_DATA = $script:OldData
    }
    It 'relit étapes, pause, tâches reportées, revue et points de contrôle' {
        $state = New-TdState
        $a = New-TdTask -Title 'A' -Steps @('un', 'deux') -NowMs (At 9)
        $b = New-TdTask -Title 'B' -NowMs (At 9)
        Add-TdTask -State $state -Task $a -NowMs (At 9); Add-TdTask -State $state -Task $b -NowMs (At 9)
        Start-TdTimer $state (At 9); Suspend-TdTimer $state (At 9 3)
        Complete-TdStep -State $state | Out-Null
        $state.review.Add($a.id)
        [void](Resolve-TdReview -State $state -Id $b.id -Decision tomorrow -NowMs (At 9 5))
        Save-TdState $state
        Save-TdCheckIns @(New-TdCheckIn -TaskId $a.id -Answer focused -NowMs (At 9 4))
        $data = Import-TdData
        $t = $data.state.tasks[0]
        $t.steps.Count | Should -Be 2
        $t.steps[0].done | Should -BeTrue
        $t.pausedAt | Should -Be (At 9 3)
        $data.state.parked.Count | Should -Be 1
        $data.state.parked[0].title | Should -Be 'B'
        $data.state.review | Should -Contain $a.id
        $data.checkins.Count | Should -Be 1
        $data.checkins[0].answer | Should -Be 'focused'
    }
}
