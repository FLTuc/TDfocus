BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\TDfocus.Core.ps1')
    function At([int]$Hour, [int]$Minute = 0, [int]$Second = 0) {
        ConvertFrom-TdLocalDate ([DateTime]::new(2026, 10, 29, $Hour, $Minute, $Second))
    }
    $script:Min = 60000L
}

Describe 'Formatage du temps' {
    It 'formate un minuteur' {
        Format-TdTimer 0 | Should -Be '00:00'
        Format-TdTimer 65000 | Should -Be '01:05'
        Format-TdTimer 3723000 | Should -Be '1:02:03'
        Format-TdTimer -65000 | Should -Be '01:05'
    }
    It 'arrondit le compte à rebours à la seconde supérieure' {
        Format-TdCountdown 59001 | Should -Be '01:00'
        Format-TdCountdown 1 | Should -Be '00:01'
        Format-TdCountdown 0 | Should -Be '00:00'
        Format-TdCountdown -5000 | Should -Be '00:00'
    }
    It 'formate des durées en minutes' {
        Format-TdMinutes 25 | Should -Be '25 min'
        Format-TdMinutes 60 | Should -Be '1 h'
        Format-TdMinutes 95 | Should -Be '1 h 35'
    }
    It 'affiche une heure locale HH:mm' {
        Format-TdClock (At 14 5) | Should -Be '14:05'
    }
    It 'normalise les heures saisies' {
        ConvertTo-TdClockText '9h' | Should -Be '09:00'
        ConvertTo-TdClockText '14:30' | Should -Be '14:30'
        ConvertTo-TdClockText '9h5' | Should -Be '09:05'
        ConvertTo-TdClockText '25:00' | Should -BeNullOrEmpty
        ConvertTo-TdClockText 'abc' | Should -BeNullOrEmpty
        ConvertFrom-TdClockText -Clock '14:30' -DayMs (At 9) | Should -Be (At 14 30)
    }
}

Describe 'Saisie rapide' {
    It 'extrait une durée en fin de saisie' {
        $r = ConvertFrom-TdQuickInput 'Répondre aux emails 15'
        $r.title | Should -Be 'Répondre aux emails'
        $r.minutes | Should -Be 15
    }
    It 'comprend 25min, 1h30 et 2 h 15 min' {
        (ConvertFrom-TdQuickInput 'Lire 25min').minutes | Should -Be 25
        (ConvertFrom-TdQuickInput 'Rapport 1h30').minutes | Should -Be 90
        (ConvertFrom-TdQuickInput 'Sport 2 h 15 min').minutes | Should -Be 135
        (ConvertFrom-TdQuickInput 'Sport 2 heures').minutes | Should -Be 120
    }
    It 'extrait un créneau figé' {
        $r = ConvertFrom-TdQuickInput 'Appeler la banque 10min @14h'
        $r.title | Should -Be 'Appeler la banque'
        $r.minutes | Should -Be 10
        $r.fixedStart | Should -Be '14:00'
        $r = ConvertFrom-TdQuickInput "Réunion d'équipe à 9h30 45m"
        $r.title | Should -Be "Réunion d'équipe"
        $r.fixedStart | Should -Be '09:30'
        $r.minutes | Should -Be 45
    }
    It 'ne transforme pas tout nombre en durée' {
        $r = ConvertFrom-TdQuickInput 'Appeler 3 médecins'
        $r.title | Should -Be 'Appeler 3 médecins'
        $r.minutes | Should -BeNullOrEmpty
        (ConvertFrom-TdQuickInput '1984').minutes | Should -BeNullOrEmpty
        (ConvertFrom-TdQuickInput 'Préparer 10 hamburgers').title | Should -Be 'Préparer 10 hamburgers'
    }
    It 'ne prend pas une heure de la journée pour une durée' {
        $r = ConvertFrom-TdQuickInput 'Dentiste 14h30'
        $r.minutes | Should -BeNullOrEmpty
    }
}

Describe 'Moteur séquentiel' {
    BeforeEach {
        $state = New-TdState
        $a = New-TdTask -Title 'A' -Minutes 10 -NowMs (At 9)
        $b = New-TdTask -Title 'B' -Minutes 20 -NowMs (At 9)
        $c = New-TdTask -Title 'C' -Minutes 30 -NowMs (At 9)
        foreach ($t in @($a, $b, $c)) { Add-TdTask -State $state -Task $t -NowMs (At 9) }
    }

    It 'la tâche en cours est la première de la file' {
        (Get-TdCurrentTask $state).title | Should -Be 'A'
        Test-TdRunning $state | Should -BeFalse
    }

    It 'compte le temps à partir des horodatages (onglet fermé ou non)' {
        Start-TdTimer $state (At 9)
        Get-TdElapsedMs $a (At 9 4) | Should -Be (4 * $Min)
        Get-TdRemainingMs $a (At 9 4) | Should -Be (6 * $Min)
        Suspend-TdTimer $state (At 9 4)
        Get-TdElapsedMs $a (At 10) | Should -Be (4 * $Min)
        Start-TdTimer $state (At 10)
        Get-TdElapsedMs $a (At 10 1) | Should -Be (5 * $Min)
    }

    It 'passe en temps additionnel sans bloquer' {
        Start-TdTimer $state (At 9)
        Get-TdRemainingMs $a (At 9 12) | Should -Be (-2 * $Min)
        Test-TdRunning $state | Should -BeTrue
    }

    It 'valide la tâche et enchaîne la suivante si le minuteur tournait' {
        Start-TdTimer $state (At 9)
        $done = Complete-TdTask -State $state -NowMs (At 9 8) -KeepRunning
        $done.title | Should -Be 'A'
        $done.elapsedMs | Should -Be (8 * $Min)
        $state.done.Count | Should -Be 1
        (Get-TdCurrentTask $state).title | Should -Be 'B'
        $b.runningSince | Should -Be (At 9 8)
    }

    It 'peut valider sans enchaîner automatiquement' {
        Start-TdTimer $state (At 9)
        Complete-TdTask -State $state -NowMs (At 9 8) | Out-Null
        Test-TdRunning $state | Should -BeFalse
    }

    It 'transfère le chrono quand on réordonne par glisser-déposer' {
        Start-TdTimer $state (At 9)
        Move-TdTask -State $state -From 2 -To 0 -NowMs (At 9 3)
        (Get-TdCurrentTask $state).title | Should -Be 'C'
        $c.runningSince | Should -Be (At 9 3)
        $a.runningSince | Should -BeNullOrEmpty
        $a.elapsedMs | Should -Be (3 * $Min)
        ($state.tasks | ForEach-Object title) -join '' | Should -Be 'CAB'
    }

    It 'reporte une tâche en fin de liste (« Plus tard »)' {
        Move-TdTaskToEnd -State $state -Id $a.id -NowMs (At 9)
        ($state.tasks | ForEach-Object title) -join '' | Should -Be 'BCA'
    }

    It 'démarre une tâche choisie immédiatement' {
        Start-TdTaskNow -State $state -Id $b.id -NowMs (At 9 1)
        (Get-TdCurrentTask $state).title | Should -Be 'B'
        Test-TdRunning $state | Should -BeTrue
    }

    It 'supprimer la tâche en cours laisse la session continuer' {
        Start-TdTimer $state (At 9)
        Remove-TdTask -State $state -Id $a.id -NowMs (At 9 2) | Out-Null
        (Get-TdCurrentTask $state).title | Should -Be 'B'
        Test-TdRunning $state | Should -BeTrue
    }

    It 'annule une validation' {
        Complete-TdTask -State $state -NowMs (At 9 5) | Out-Null
        Undo-TdComplete -State $state -Id $a.id -NowMs (At 9 6) | Out-Null
        (Get-TdCurrentTask $state).title | Should -Be 'A'
        $a.completedAt | Should -BeNullOrEmpty
        $state.done.Count | Should -Be 0
    }

    It 'ajoute ou retire du temps à la volée (minimum 1 min)' {
        Add-TdPlannedTime -State $state -DeltaMs (5 * $Min)
        $a.plannedMs | Should -Be (15 * $Min)
        $a.estimateMs | Should -Be (10 * $Min)
        Add-TdPlannedTime -State $state -DeltaMs (-60 * $Min)
        $a.plannedMs | Should -Be $Min
    }

    It "met à jour l'estimation seulement avant le démarrage" {
        Update-TdTask -State $state -Id $b.id -Changes @{ minutes = 40; title = ' B2 ' } | Out-Null
        $b.plannedMs | Should -Be (40 * $Min)
        $b.estimateMs | Should -Be (40 * $Min)
        $b.title | Should -Be 'B2'
        Start-TdTimer $state (At 9)
        Update-TdTask -State $state -Id $a.id -Changes @{ minutes = 12 } | Out-Null
        $a.plannedMs | Should -Be (12 * $Min)
        $a.estimateMs | Should -Be (10 * $Min)
    }

    It 'garde les tâches non faites au changement de jour, sans culpabiliser' {
        Complete-TdTask -State $state -NowMs (At 9 5) | Out-Null
        $next = (At 9) + 24L * 3600 * 1000
        Invoke-TdDayRollover -State $state -NowMs $next | Should -Be 1
        $state.done.Count | Should -Be 0
        $state.tasks.Count | Should -Be 2
    }

    It 'met en pause un minuteur resté actif pendant que le PC était éteint' {
        Start-TdTimer $state (At 9)
        $state.lastSeenMs = At 9 20
        $stopAt = Repair-TdStaleTimer -State $state -NowMs (At 18)
        $stopAt | Should -Be (At 9 20)
        Test-TdRunning $state | Should -BeFalse
        $a.elapsedMs | Should -Be (20 * $Min)
    }

    It 'ne touche pas un minuteur après une courte fermeture' {
        Start-TdTimer $state (At 9)
        $state.lastSeenMs = At 9 20
        Repair-TdStaleTimer -State $state -NowMs (At 9 25) | Should -BeNullOrEmpty
        Test-TdRunning $state | Should -BeTrue
    }
}

Describe 'Calcul prédictif' {
    BeforeEach {
        $state = New-TdState
        $a = New-TdTask -Title 'A' -Minutes 10 -NowMs (At 9)
        $b = New-TdTask -Title 'B' -Minutes 20 -NowMs (At 9)
        foreach ($t in @($a, $b)) { Add-TdTask -State $state -Task $t -NowMs (At 9) }
    }

    It "projette l'heure de fin de chaque tâche et de la liste" {
        $s = Get-TdSchedule -State $state -NowMs (At 9)
        $s.items[0].endMs | Should -Be (At 9 10)
        $s.items[1].endMs | Should -Be (At 9 30)
        $s.endMs | Should -Be (At 9 30)
        $s.remainingMs | Should -Be (30 * $Min)
    }

    It 'repousse la fin quand la tâche en cours déborde' {
        Start-TdTimer $state (At 9)
        $s = Get-TdSchedule -State $state -NowMs (At 9 15)
        $s.items[0].endMs | Should -Be (At 9 15)
        $s.endMs | Should -Be (At 9 35)
    }

    It 'repousse la fin pendant une pause' {
        Start-TdTimer $state (At 9)
        Suspend-TdTimer $state (At 9 5)
        $s = Get-TdSchedule -State $state -NowMs (At 9 20)
        $s.endMs | Should -Be (At 9 45)
    }

    It 'mesure le décalage depuis la dernière modification du plan' {
        Update-TdPlanBaseline -State $state -NowMs (At 9)
        Start-TdTimer $state (At 9)
        $s = Get-TdSchedule -State $state -NowMs (At 9 16)
        Get-TdDriftMs -State $state -Schedule $s | Should -Be (6 * $Min)
    }

    It 'respecte un créneau figé (temps libre avant)' {
        $fixed = New-TdTask -Title 'Réunion' -Minutes 30 -FixedStart '10:00' -NowMs (At 9)
        Add-TdTask -State $state -Task $fixed -NowMs (At 9)
        $s = Get-TdSchedule -State $state -NowMs (At 9)
        $s.items[2].gapMs | Should -Be (30 * $Min)
        $s.items[2].startMs | Should -Be (At 10)
        $s.endMs | Should -Be (At 10 30)
    }

    It 'signale un créneau figé en retard' {
        $fixed = New-TdTask -Title 'Réunion' -Minutes 30 -FixedStart '09:15' -NowMs (At 9)
        Add-TdTask -State $state -Task $fixed -NowMs (At 9) -Index 2
        $s = Get-TdSchedule -State $state -NowMs (At 9)
        $s.items[2].lateMs | Should -Be (15 * $Min)
    }

    It 'insère un créneau figé à sa place chronologique sans déloger la tâche en cours' {
        $fixed = New-TdTask -Title 'Réunion' -Minutes 30 -FixedStart '09:12' -NowMs (At 9)
        Add-TdTask -State $state -Task $fixed -NowMs (At 9)
        ($state.tasks | ForEach-Object title) -join ',' | Should -Be 'A,Réunion,B'
        $early = New-TdTask -Title 'Tôt' -Minutes 5 -FixedStart '09:01' -NowMs (At 9)
        Add-TdTask -State $state -Task $early -NowMs (At 9)
        $state.tasks[0].title | Should -Be 'A'
    }
}

Describe 'Routines' {
    It 'fournit les routines intégrées' {
        $t = Get-TdBuiltInTemplates
        $t.Count | Should -Be 3
        ($t | Where-Object id -eq 'builtin-morning').items.Count | Should -BeGreaterThan 2
    }
    It 'enregistre la liste actuelle et la recharge' {
        $tasks = @(
            (New-TdTask -Title 'Un' -Minutes 5 -CategoryId 'maison'),
            (New-TdTask -Title 'Deux' -Minutes 45)
        )
        $tpl = New-TdTemplateFromTasks -Name ' Ma routine ' -Tasks $tasks
        $tpl.name | Should -Be 'Ma routine'
        $tpl.items.Count | Should -Be 2
        $loaded = ConvertTo-TdTasksFromTemplate -Template $tpl
        $loaded.Count | Should -Be 2
        $loaded[0].categoryId | Should -Be 'maison'
        $loaded[1].plannedMs | Should -Be (45 * $Min)
        $loaded[0].id | Should -Not -Be $tasks[0].id
    }
}

Describe 'Statistiques' {
    BeforeAll {
        function New-Entry($Day, $Estimate, $Actual, $Cat = 'travail') {
            $completed = (At 12) - [long]$Day * 24 * 3600 * 1000
            [pscustomobject]@{ id = New-TdId; title = 'x'; categoryId = $Cat; estimateMs = $Estimate * $Min; plannedMs = $Estimate * $Min; actualMs = $Actual * $Min; completedAt = $completed; dayKey = Get-TdDayKey $completed }
        }
    }
    It 'calcule la médiane' {
        Get-TdMedian @(1, 3, 2) | Should -Be 2
        Get-TdMedian @(1, 2, 3, 4) | Should -Be 2.5
        Get-TdMedian @() | Should -BeNullOrEmpty
    }
    It "résume l'estimation vs le réel" {
        $history = @(
            (New-Entry 0 10 15), (New-Entry 0 20 30), (New-Entry 1 10 10), (New-Entry 2 30 45 'maison'), (New-Entry 10 10 20)
        )
        $s = Get-TdStats -History $history -NowMs (At 13)
        $s.todayCount | Should -Be 2
        $s.todayFocusMs | Should -Be (45 * $Min)
        $s.days.Count | Should -Be 7
        $s.days[6].count | Should -Be 2
        $s.sampleCount | Should -Be 5
        $s.medianRatio | Should -Be 1.5
        ($s.byCategory | Where-Object categoryId -eq 'maison').ratio | Should -Be 1.5
    }
    It 'propose une estimation ajustée avec assez de recul' {
        $history = 1..6 | ForEach-Object { New-Entry 1 10 13 }
        $hint = Get-TdEstimateHint -History $history -Minutes 20 -CategoryId 'travail' -NowMs (At 13)
        $hint.minutes | Should -Be 26
        $hint.scope | Should -Be 'category'
        Get-TdEstimateHint -History @($history[0]) -Minutes 20 -NowMs (At 13) | Should -BeNullOrEmpty
    }
    It "gère un historique vide" {
        $s = Get-TdStats -History @() -NowMs (At 13)
        $s.todayCount | Should -Be 0
        $s.medianRatio | Should -BeNullOrEmpty
    }
}

Describe 'Réglages' {
    It 'complète et borne les réglages' {
        $s = ConvertTo-TdSettings ([pscustomobject]@{ theme = 'neon'; ambientVolume = 4; chimeEveryMin = 10; autostart = $false })
        $s.theme | Should -Be 'system'
        $s.ambientVolume | Should -Be 1
        $s.chimeEveryMin | Should -Be 10
        $s.autostart | Should -BeFalse
        $s.categories.Count | Should -Be 6
        (Get-TdCategory $s 'pause').name | Should -Be 'Pause'
    }
}

Describe 'Stockage local' {
    BeforeAll {
        $script:OldData = $env:TDFOCUS_DATA
        $env:TDFOCUS_DATA = Join-Path ([IO.Path]::GetTempPath()) ("tdfocus-test-" + [guid]::NewGuid().ToString('N'))
    }
    AfterAll {
        Remove-Item -LiteralPath $env:TDFOCUS_DATA -Recurse -Force -ErrorAction SilentlyContinue
        $env:TDFOCUS_DATA = $script:OldData
    }
    It 'relit fidèlement la file, les accents et les émojis' {
        $state = New-TdState
        $task = New-TdTask -Title 'Café ☕ et é-mails' -Minutes 15 -CategoryId 'pause' -FixedStart '14:00'
        Add-TdTask -State $state -Task $task -NowMs (At 9)
        Start-TdTimer $state (At 9)
        Save-TdState $state
        Save-TdState $state
        $data = Import-TdData
        $data.state.tasks.Count | Should -Be 1
        $t = $data.state.tasks[0]
        $t.title | Should -Be 'Café ☕ et é-mails'
        $t.runningSince | Should -Be (At 9)
        $t.fixedStart | Should -Be '14:00'
        $t.plannedMs | Should -Be (15 * $Min)
        Test-Path (Get-TdDataPath 'state.json.bak') | Should -BeTrue
    }
    It 'relit historique, routines et notes' {
        $now = At 9
        $task = New-TdTask -Title 'X' -Minutes 5
        $task.completedAt = $now
        $task.elapsedMs = 6 * $Min
        Save-TdHistory @(New-TdHistoryEntry $task)
        Save-TdTemplates @(New-TdTemplateFromTasks -Name 'R' -Tasks @($task))
        Save-TdNotes @(New-TdNote -Text 'Idée' -NowMs $now)
        $data = Import-TdData
        $data.history.Count | Should -Be 1
        $data.history[0].actualMs | Should -Be (6 * $Min)
        $data.templates.Count | Should -Be 1
        $data.templates[0].items.Count | Should -Be 1
        $data.notes[0].text | Should -Be 'Idée'
    }
    It 'exporte et réimporte une sauvegarde sans les jetons' {
        $data = Import-TdData
        $data.settings.todoistToken = 'secret'
        $path = Join-Path $env:TDFOCUS_DATA 'backup.json'
        Export-TdBackup -Path $path -Data $data
        (Get-Content -LiteralPath $path -Raw) | Should -Not -Match 'secret'
        $restored = Import-TdBackup -Path $path
        $restored.state.tasks.Count | Should -Be $data.state.tasks.Count
        $restored.templates.Count | Should -Be 1
    }
    It 'protège les jetons' {
        $stored = Protect-TdSecret 'abc123'
        $stored | Should -Not -Be 'abc123'
        Unprotect-TdSecret $stored | Should -Be 'abc123'
        Unprotect-TdSecret '' | Should -Be ''
    }
}
