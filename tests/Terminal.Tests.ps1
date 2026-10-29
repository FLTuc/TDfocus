# Version terminal (Linux) : texte, écrans, clavier, signaux et intégration XDG.
# Les variables préparées dans BeforeEach sont utilisées dans les blocs It (portée Pester).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    $script:SrcDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    . (Join-Path $script:SrcDir 'TDfocus.Core.ps1')
    foreach ($part in @('Platform/Linux', 'Terminal/Text', 'Terminal/Audio', 'Terminal/View', 'Terminal/App')) {
        . (Join-Path $script:SrcDir "$part.ps1")
    }
    $script:SavedData = $env:TDFOCUS_DATA
    $script:SavedXdg = $env:XDG_CONFIG_HOME
    $script:Min = 60000L

    function New-TestKey([string]$Name) {
        $special = @{
            Enter = @([char]13, [ConsoleKey]::Enter); Escape = @([char]27, [ConsoleKey]::Escape)
            Space = @([char]' ', [ConsoleKey]::Spacebar); Backspace = @([char]8, [ConsoleKey]::Backspace)
            Up = @([char]0, [ConsoleKey]::UpArrow); Down = @([char]0, [ConsoleKey]::DownArrow)
            Left = @([char]0, [ConsoleKey]::LeftArrow); Right = @([char]0, [ConsoleKey]::RightArrow)
            Delete = @([char]0, [ConsoleKey]::Delete)
        }
        if ($Name -eq 'CtrlC') { return [System.ConsoleKeyInfo]::new([char]3, [ConsoleKey]::C, $false, $false, $true) }
        if ($special.ContainsKey($Name)) { return [System.ConsoleKeyInfo]::new($special[$Name][0], $special[$Name][1], $false, $false, $false) }
        $ch = [char]$Name
        $key = [ConsoleKey]0
        if ([char]::IsLetterOrDigit($ch) -and [int]$ch -lt 128) { $key = [ConsoleKey][int][char]::ToUpperInvariant($ch) }
        [System.ConsoleKeyInfo]::new($ch, $key, [char]::IsUpper($ch), $false, $false)
    }
    function Send-TestKey([string[]]$Names) { foreach ($n in $Names) { Invoke-TdTuiKey (New-TestKey $n) } }
    function Send-TestText([string]$Text) {
        foreach ($ch in $Text.ToCharArray()) {
            if ($ch -eq ' ') { Send-TestKey 'Space' } else { Send-TestKey ([string]$ch) }
        }
    }
    function Initialize-TestTui {
        $env:TDFOCUS_DATA = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:XDG_CONFIG_HOME = Join-Path $env:TDFOCUS_DATA 'xdg'
        $data = Import-TdData
        $data.settings.notifications = $false
        Initialize-TdTui -ScriptPath (Join-Path $script:SrcDir 'TDfocus.Terminal.ps1') -Data $data
        $script:TdTuiNoColor = $true
        $script:Tui
    }
    function Add-TestTask([string]$Text) {
        Send-TestKey 'a'
        Send-TestText $Text
        Send-TestKey 'Enter'
    }
    function Get-TestScreen([int]$Width = 100, [int]$Height = 34) {
        (Get-TdTuiFrame -NowMs (Get-TdNowMs) -Width $Width -Height $Height | ForEach-Object { Remove-TdAnsi $_ }) -join "`n"
    }
}

AfterAll {
    $env:TDFOCUS_DATA = $script:SavedData
    $env:XDG_CONFIG_HOME = $script:SavedXdg
}

Describe 'Texte du terminal' {
    It 'mesure la largeur affichée (couleurs, accents, émojis, caractères combinants)' {
        Get-TdTextWidth 'abc' | Should -Be 3
        Get-TdTextWidth ("$([char]27)[1mabc$([char]27)[0m") | Should -Be 3
        Get-TdTextWidth 'Écrire' | Should -Be 6
        Get-TdTextWidth ([char]::ConvertFromUtf32(0x1F642)) | Should -Be 2
        Get-TdTextWidth ('e' + [char]0x0301) | Should -Be 1
    }
    It 'coupe un texte trop long avec des points de suspension' {
        $cut = Limit-TdTuiText -Text 'Bonjour tout le monde' -Width 8
        Get-TdTextWidth $cut | Should -Be 8
        $cut | Should -BeLike ('*' + [char]0x2026)
        Limit-TdTuiText -Text 'Court' -Width 8 | Should -Be 'Court'
    }
    It 'aligne deux colonnes sur la largeur demandée' {
        Get-TdTextWidth (Join-TdTuiColumns -Left 'gauche' -Right 'droite' -Width 30) | Should -Be 30
    }
    It 'dessine le minuteur en gros chiffres sur 5 lignes' {
        $rows = Get-TdBigText '12:34'
        $rows.Count | Should -Be 5
        ($rows | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual (Get-TdBigTextWidth '12:34')
    }
    It 'respecte NO_COLOR' {
        $script:TdTuiNoColor = $true
        Format-TdTui -Text 'x' -Color 'accent' -Bold | Should -Be 'x'
        $script:TdTuiNoColor = $false
        Format-TdTui -Text 'x' -Color 'accent' | Should -Match '\x1b\[38;2;'
        $script:TdTuiNoColor = $true
    }
}

Describe 'Écrans' {
    BeforeAll {
        $tui = Initialize-TestTui
        Add-TestTask 'Écrire le rapport trimestriel avec un titre vraiment très long pour tester la coupe 30'
        Add-TestTask 'Emails 10'
        Add-TestTask 'Réunion 30 @23h50'
        [void](Update-TdTask -State $tui.Data.state -Id $tui.Data.state.tasks[0].id -Changes @{ stepsText = 'Plan ; Brouillon ; Relecture' })
        Switch-TdTuiTimer
        $tui.Data.notes.Add((New-TdNote -Text 'Appeler le garage' -Context 'Rapport'))
        $tui.Message = $null
    }
    It 'l''écran <Mode> fait exactement <Height> lignes de <Width> colonnes au plus' -ForEach @(
        foreach ($mode in @('main', 'help', 'routines', 'stats', 'notes', 'settings', 'review')) {
            foreach ($size in @(@(40, 12), @(80, 24), @(132, 43))) { @{ Mode = $mode; Width = $size[0]; Height = $size[1] } }
        }
    ) {
        $script:Tui.Mode = $Mode
        $frame = Get-TdTuiFrame -NowMs (Get-TdNowMs) -Width $Width -Height $Height
        $script:Tui.Mode = 'main'
        $frame.Count | Should -Be $Height
        foreach ($line in $frame) { Get-TdTextWidth $line | Should -BeLessOrEqual $Width }
    }
    It 'affiche la tâche en cours, son étape et l''heure de fin de la liste' {
        $screen = Get-TestScreen
        $screen | Should -Match 'En cours'
        $screen | Should -Match 'ÉTAPE 1/3  Plan'
        $screen | Should -Match 'Fin de la liste \d\d:\d\d'
        $screen | Should -Match 'ENSUITE · 2 TÂCHES'
    }
    It 'reste lisible en couleurs' {
        $script:TdTuiNoColor = $false
        $frame = Get-TdTuiFrame -NowMs (Get-TdNowMs) -Width 80 -Height 24
        $script:TdTuiNoColor = $true
        ($frame -join '') | Should -Match '\x1b\[38;2;'
        foreach ($line in $frame) { Get-TdTextWidth $line | Should -BeLessOrEqual 80 }
    }
}

Describe 'Clavier et actions' {
    BeforeEach { $tui = Initialize-TestTui }

    It 'ajoute une tâche avec sa durée et son créneau' {
        Add-TestTask 'Emails 15'
        Add-TestTask 'Réunion 30 @23h55'
        $tui.Data.state.tasks.Count | Should -Be 2
        $tui.Data.state.tasks[0].title | Should -Be 'Emails'
        $tui.Data.state.tasks[0].plannedMs | Should -Be (15 * $Min)
        ($tui.Data.state.tasks | Where-Object title -eq 'Réunion').fixedStart | Should -Be '23:55'
        $tui.Prompt | Should -BeNullOrEmpty
    }
    It 'corrige la saisie (retour arrière) et annule avec Échap' {
        Send-TestKey 'a'
        Send-TestText 'Emaix'
        Send-TestKey 'Backspace'
        $tui.Prompt.Text | Should -Be 'Emai'
        Send-TestKey 'Escape'
        $tui.Prompt | Should -BeNullOrEmpty
        $tui.Data.state.tasks.Count | Should -Be 0
    }
    It 'démarre, met en pause et affiche depuis quand' {
        Add-TestTask 'Rapport 30'
        Send-TestKey 'Space'
        $tui.Data.state.tasks[0].runningSince | Should -Not -BeNullOrEmpty
        Send-TestKey 'Space'
        $tui.Data.state.tasks[0].pausedAt | Should -Not -BeNullOrEmpty
        Get-TestScreen | Should -Match 'En pause depuis'
    }
    It 'gère les sous-étapes (p, s, S)' {
        Add-TestTask 'Rapport 30'
        Send-TestKey 'p'
        Send-TestText 'Plan ; Brouillon'
        Send-TestKey 'Enter'
        $tui.Data.state.tasks[0].steps.Count | Should -Be 2
        Send-TestKey 's'
        (Get-TdCurrentStep $tui.Data.state.tasks[0]).title | Should -Be 'Brouillon'
        Send-TestKey 'S'
        (Get-TdCurrentStep $tui.Data.state.tasks[0]).title | Should -Be 'Plan'
        Send-TestKey 's', 's'
        $tui.Message.Text | Should -Match 'Dernière étape faite'
    }
    It 'valide la tâche, l''inscrit dans l''historique puis annule (z)' {
        Add-TestTask 'Rapport 30'
        Add-TestTask 'Emails 10'
        Send-TestKey 'Space', 'Enter'
        $tui.Data.state.done.Count | Should -Be 1
        $tui.Data.history.Count | Should -Be 1
        (Get-TdCurrentTask $tui.Data.state).title | Should -Be 'Emails'
        $tui.Data.state.tasks[0].runningSince | Should -Not -BeNullOrEmpty
        Send-TestKey 'z'
        $tui.Data.state.done.Count | Should -Be 0
        $tui.Data.history.Count | Should -Be 0
        (Get-TdCurrentTask $tui.Data.state).title | Should -Be 'Rapport'
    }
    It 'ajuste le temps prévu (+, -, ], [) sans descendre sous 1 min' {
        Add-TestTask 'Rapport 3'
        Send-TestKey '+', ']'
        $tui.Data.state.tasks[0].plannedMs | Should -Be (9 * $Min)
        Send-TestKey '[', '['
        $tui.Data.state.tasks[0].plannedMs | Should -Be (1 * $Min)
    }
    It 'choisit, déplace, reporte et supprime des tâches' {
        Add-TestTask 'A 5'
        Add-TestTask 'B 5'
        Add-TestTask 'C 5'
        Send-TestKey 'Down', 'Down', 'K'
        ($tui.Data.state.tasks | ForEach-Object title) -join '' | Should -Be 'ACB'
        $tui.Sel | Should -Be 1
        Send-TestKey 'J'
        ($tui.Data.state.tasks | ForEach-Object title) -join '' | Should -Be 'ABC'
        Send-TestKey 'Escape', 'l'
        ($tui.Data.state.tasks | ForEach-Object title) -join '' | Should -Be 'BCA'
        Send-TestKey 'Down', 'x'
        ($tui.Data.state.tasks | ForEach-Object title) -join '' | Should -Be 'BA'
        Send-TestKey 'z'
        ($tui.Data.state.tasks | ForEach-Object title) -join '' | Should -Be 'BCA'
        Send-TestKey 'Down', 'Down', 'd'
        (Get-TdCurrentTask $tui.Data.state).title | Should -Be 'A'
        $tui.Data.state.tasks[0].runningSince | Should -Not -BeNullOrEmpty
    }
    It 'charge une routine (r puis 1) et peut l''annuler' {
        Send-TestKey 'r', '1'
        $tui.Mode | Should -Be 'main'
        $count = $tui.Data.state.tasks.Count
        $count | Should -BeGreaterThan 1
        Send-TestKey 'z'
        $tui.Data.state.tasks.Count | Should -Be 0
    }
    It 'enregistre la liste comme routine' {
        Add-TestTask 'A 5'
        Send-TestKey 'r', 's'
        Send-TestText 'Ma routine'
        Send-TestKey 'Enter'
        $tui.Data.templates.Count | Should -Be 1
        $tui.Data.templates[0].name | Should -Be 'Ma routine'
    }
    It 'note une idée puis en fait une tâche depuis le bloc-notes' {
        Add-TestTask 'Rapport 30'
        Send-TestKey 'n'
        Send-TestText 'Appeler le garage 10'
        Send-TestKey 'Enter'
        $tui.Data.notes.Count | Should -Be 1
        $tui.Data.notes[0].context | Should -Be 'Rapport'
        Send-TestKey 'N', 'Enter'
        $tui.Data.notes.Count | Should -Be 0
        $tui.Data.state.tasks[1].title | Should -Be 'Appeler le garage'
        $tui.Data.state.tasks[1].plannedMs | Should -Be (10 * $Min)
    }
    It 'modifie les réglages et les enregistre' {
        Send-TestKey 'o', 'Down', 'Down', 'Enter'
        $tui.Data.settings.chimeEveryMin | Should -Be 5
        Send-TestKey 'Right'
        $tui.Data.settings.chimeEveryMin | Should -Be 10
        Send-TestKey 'Left', 'Left'
        $tui.Data.settings.chimeEveryMin | Should -Be 0
        Send-TestKey 'Down', 'Down', 'Space'
        $tui.Data.settings.landingMinutes | Should -Be 5
        (Read-TdJsonFile (Get-TdDataPath 'settings.json')).landingMinutes | Should -Be 5
        Send-TestKey 'q'
        $tui.Mode | Should -Be 'main'
    }
    It 'bascule compte à rebours / progressif (m)' {
        Send-TestKey 'm'
        $tui.Data.settings.timerMode | Should -Be 'countup'
        Send-TestKey 'm'
        $tui.Data.settings.timerMode | Should -Be 'countdown'
    }
    It 'ouvre et ferme l''aide et les statistiques' {
        Send-TestKey '?'
        $tui.Mode | Should -Be 'help'
        Send-TestKey 'Escape', 't'
        $tui.Mode | Should -Be 'stats'
        Send-TestKey 'q'
        $tui.Mode | Should -Be 'main'
    }
    It 'quitte avec q ou Ctrl+C' {
        Send-TestKey 'q'
        $tui.Quit | Should -BeTrue
        $tui.Quit = $false
        Send-TestKey 'CtrlC'
        $tui.Quit | Should -BeTrue
    }
    It 'enregistre la liste à chaque changement' {
        Add-TestTask 'Rapport 30'
        $saved = Read-TdJsonFile (Get-TdDataPath 'state.json')
        @($saved.tasks)[0].title | Should -Be 'Rapport'
    }
}

Describe 'Minuteur : signaux, points de contrôle, revue du matin' {
    BeforeEach {
        $tui = Initialize-TestTui
        $tui.Data.settings.chimeEveryMin = 5
        $now = Get-TdNowMs
        $task = New-TdTask -Title 'Rapport' -Minutes 30 -NowMs $now
        Add-TdTask -State $tui.Data.state -Task $task -NowMs $now
        Start-TdTimer $tui.Data.state $now
        Invoke-TdTuiTick -NowMs ($now + 1000)
    }
    It 'pose la question au carillon et enregistre « oui »' {
        Invoke-TdTuiTick -NowMs ($now + 5 * $Min + 1000)
        $tui.CheckIn | Should -Not -BeNullOrEmpty
        Get-TestScreen | Should -Match 'Toujours sur « Rapport » \?'
        Send-TestKey 'o'
        $tui.CheckIn | Should -BeNullOrEmpty
        $tui.Data.checkins.Count | Should -Be 1
        $tui.Data.checkins[0].answer | Should -Be 'focused'
    }
    It 'propose de noter la distraction après « je me suis égaré·e »' {
        Invoke-TdTuiTick -NowMs ($now + 5 * $Min + 1000)
        Send-TestKey 'g'
        $tui.Data.checkins[0].answer | Should -Be 'drifted'
        $tui.Message.Hint | Should -Match 'noter la distraction'
    }
    It 'compte la question sans réponse au bout de 90 s' {
        Invoke-TdTuiTick -NowMs ($now + 5 * $Min + 1000)
        Invoke-TdTuiTick -NowMs ($now + 5 * $Min + 92000)
        $tui.CheckIn | Should -BeNullOrEmpty
        $tui.Data.checkins[0].answer | Should -Be 'missed'
    }
    It 'pas de point de contrôle quand l''option est désactivée' {
        $tui.Data.settings.checkInWithChime = $false
        Invoke-TdTuiTick -NowMs ($now + 5 * $Min + 1000)
        $tui.CheckIn | Should -BeNullOrEmpty
    }
    It 'émet l''atterrissage puis la fin du temps une seule fois' {
        Invoke-TdTuiTick -NowMs ($now + 28 * $Min + 1000)
        $tui.Signals.LandingKey | Should -Not -BeNullOrEmpty
        Invoke-TdTuiTick -NowMs ($now + 30 * $Min + 1000)
        $tui.Signals.TimeUpKey | Should -Be $tui.Signals.LandingKey
        Get-TestScreen | Should -Not -Match 'Atterrissage'
    }
    It 'ouvre la revue du matin au changement de jour' {
        $tui.Data.state.dayKey = '2000-01-01'
        Invoke-TdTuiTick -NowMs (Get-TdNowMs)
        $tui.Mode | Should -Be 'review'
        Get-TestScreen | Should -Match 'Nouvelle journée'
        Send-TestKey 'd'
        $tui.Data.state.parked.Count | Should -Be 1
        $tui.Mode | Should -Be 'main'
        Get-TestScreen | Should -Match '1 tâche\(s\) reportée\(s\) à demain'
        Send-TestKey 'R'
        $tui.Data.state.parked.Count | Should -Be 0
    }
    It 'ne montre pas la revue quand elle est désactivée' {
        $tui.Data.settings.morningReview = $false
        $tui.Data.state.dayKey = '2000-01-01'
        Invoke-TdTuiTick -NowMs (Get-TdNowMs)
        $tui.Mode | Should -Be 'main'
        $tui.Data.state.review.Count | Should -Be 0
    }
}

Describe 'Intégration Linux (XDG, sans root)' {
    BeforeEach {
        $env:XDG_CONFIG_HOME = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:ScriptPath = Join-Path $script:SrcDir 'TDfocus.Terminal.ps1'
    }
    It 'écrit une entrée de bureau valide, avec des guillemets si besoin' {
        $entry = New-TdDesktopEntry -Command @('/home/moi/mes apps/pwsh', '-File', '/opt/td/TDfocus.Terminal.ps1', '-Startup') -Icon '/opt/td/TDfocus.png' -Autostart
        $entry | Should -Match '(?m)^\[Desktop Entry\]$'
        $entry | Should -Match '(?m)^Exec="/home/moi/mes apps/pwsh" -File /opt/td/TDfocus\.Terminal\.ps1 -Startup$'
        $entry | Should -Match '(?m)^X-GNOME-Autostart-enabled=true$'
        $entry | Should -Match '(?m)^Icon=/opt/td/TDfocus\.png$'
    }
    It 'active puis désactive le lancement à l''ouverture de session' {
        Set-TdLinuxAutostart -Enabled $true -ScriptPath $script:ScriptPath | Should -BeTrue
        $path = Get-TdLinuxAutostartPath
        $path | Should -BeLike "$($env:XDG_CONFIG_HOME)*"
        Test-Path $path | Should -BeTrue
        Get-Content -Raw $path | Should -Match '-Startup'
        Set-TdLinuxAutostart -Enabled $false -ScriptPath $script:ScriptPath | Should -BeTrue
        Test-Path $path | Should -BeFalse
    }
    It 'transmet -Startup au lanceur' {
        $command = Get-TdLinuxLauncherCommand -ScriptPath $script:ScriptPath
        $command[-1] | Should -Be '-Startup'
    }
}
