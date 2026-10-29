# TDfocus (terminal) - rendu des écrans. Fonctions pures : état -> lignes de texte (ANSI).
# Chaque écran renvoie exactement $Height lignes, aucune ne dépassant $Width colonnes.

function ConvertTo-TdRgb {
    param([string]$Hex)
    if ($Hex -notmatch '^#?([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$') { return $null }
    '{0};{1};{2}' -f [Convert]::ToInt32($Matches[1], 16), [Convert]::ToInt32($Matches[2], 16), [Convert]::ToInt32($Matches[3], 16)
}

function Format-TdTuiCategoryDot {
    param($Category)
    $dot = [string][char]0x25CF
    if (-not $Category) { return (Format-TdTui -Text ([string][char]0x00B7) -Color 'muted') }
    $rgb = ConvertTo-TdRgb $Category.color
    if (-not $rgb -or $script:TdTuiNoColor) { return $dot }
    '{0}[38;2;{1}m{2}{0}[0m' -f $script:TdEsc, $rgb, $dot
}

function Get-TdTuiRule {
    param([int]$Width)
    Format-TdTui -Text ([string][char]0x2500 * [Math]::Max(0, $Width)) -Color 'rule'
}

function Complete-TdTuiLines {
    # Ajuste à $Height lignes (complète ou coupe).
    param([System.Collections.Generic.List[string]]$Lines, [int]$Height)
    while ($Lines.Count -lt $Height) { $Lines.Add('') }
    if ($Lines.Count -gt $Height) { $Lines.RemoveRange($Height, $Lines.Count - $Height) }
    , $Lines.ToArray()
}

function Get-TdTuiHeader {
    param([long]$NowMs, [int]$Width, [string]$Subtitle)
    $state = $script:Tui.Data.state
    $left = ' ' + (Format-TdTui -Text 'TDfocus' -Color 'accent' -Bold) + '  ' + (Format-TdTui -Text (Format-TdClock $NowMs) -Color 'muted')
    if ($Subtitle) { $left += '  ' + (Format-TdTui -Text $Subtitle -Color 'title' -Bold) }
    $schedule = Get-TdSchedule -State $state -NowMs $NowMs
    $right = Format-TdTui -Text 'Aucune tâche prévue' -Color 'muted'
    if ($schedule.count -gt 0) {
        $right = (Format-TdTui -Text 'Fin de la liste ' -Color 'muted') + (Format-TdTui -Text (Format-TdClock $schedule.endMs) -Color 'accent' -Bold)
        $drift = [long][Math]::Round((Get-TdDriftMs -State $state -Schedule $schedule) / 60000)
        if ($drift -ge 1) { $right += '  ' + (Format-TdTui -Text "+$drift min" -Color 'overtime') }
        elseif ($drift -le -1) { $right += '  ' + (Format-TdTui -Text "$drift min" -Color 'success') }
    }
    Join-TdTuiColumns -Left $left -Right ($right + ' ') -Width $Width
}

function Get-TdTuiFocusLines {
    param([long]$NowMs, [int]$Width, [int]$Height, $Schedule)
    $lines = [System.Collections.Generic.List[string]]::new()
    $state = $script:Tui.Data.state
    $settings = $script:Tui.Data.settings
    $current = Get-TdCurrentTask $state
    $inner = $Width - 4
    if (-not $current) {
        $lines.Add('')
        if ($state.done.Count -gt 0) {
            $focus = [long]0
            foreach ($t in $state.done) { $focus += [long]$t.elapsedMs }
            $lines.Add('  ' + (Format-TdTui -Text 'Liste terminée !' -Color 'success' -Bold))
            $lines.Add('  ' + (Limit-TdTuiText -Text ("{0} tâche(s) terminée(s) aujourd'hui, {1} de concentration. Prends une vraie pause." -f $state.done.Count, (Format-TdDurationMs $focus)) -Width $inner))
        }
        else {
            $lines.Add('  ' + (Format-TdTui -Text "Qu'est-ce qui compte maintenant ?" -Color 'title' -Bold))
            $lines.Add('  ' + (Format-TdTui -Text (Limit-TdTuiText -Text 'Appuie sur [a] pour ajouter une tâche avec sa durée, ou [r] pour charger une routine.' -Width $inner) -Color 'muted'))
        }
        $lines.Add('')
        return , $lines.ToArray()
    }

    $running = $null -ne $current.runningSince
    $elapsed = Get-TdElapsedMs $current $NowMs
    $remaining = [long]$current.plannedMs - $elapsed
    $overtime = $remaining -lt 0
    $pausedMs = Get-TdPausedMs $current $NowMs

    # Catégorie et état (avec le compteur de pause)
    $category = Get-TdCategory $settings $current.categoryId
    $stateText = 'Pas encore commencée'
    $stateColor = 'muted'
    if ($running) { $stateText = 'En cours'; $stateColor = 'success' }
    elseif ($null -ne $pausedMs) { $stateText = 'En pause ' + (Format-TdPausedFor $pausedMs); $stateColor = 'accent' }
    elseif ($elapsed -gt 0) { $stateText = 'En pause' }
    $catName = ''
    if ($category) { $catName = $category.name + ' · ' }
    $lines.Add('  ' + (Format-TdTuiCategoryDot $category) + ' ' + (Format-TdTui -Text $catName -Color 'muted') + (Format-TdTui -Text $stateText -Color $stateColor))
    $lines.Add('  ' + (Format-TdTui -Text (Limit-TdTuiText -Text $current.title -Width $inner) -Color 'title' -Bold))

    # Minuteur
    if ($settings.timerMode -eq 'countup') { $timer = Format-TdTimer $elapsed; $label = 'écoulé sur ' + (Format-TdDurationMs $current.plannedMs); $fraction = $elapsed / [double][Math]::Max(1, $current.plannedMs) }
    elseif ($overtime) { $timer = '+' + (Format-TdTimer (-$remaining)); $label = 'temps additionnel'; $fraction = 1.0 }
    else { $timer = Format-TdCountdown $remaining; $label = 'restant'; $fraction = $remaining / [double][Math]::Max(1, $current.plannedMs) }
    $timerColor = 'title'
    $barColor = 'accent'
    if ($overtime) { $timerColor = 'overtime'; $barColor = 'overtime' }
    $big = (Get-TdBigTextWidth $timer) + 6 -le $Width -and $Height -ge 22
    $lines.Add('')
    if ($big) {
        foreach ($row in (Get-TdBigText $timer)) { $lines.Add('    ' + (Format-TdTui -Text $row -Color $timerColor)) }
    }
    else {
        $lines.Add('    ' + (Format-TdTui -Text $timer -Color $timerColor -Bold) + '  ' + (Format-TdTui -Text $label -Color 'muted'))
    }
    $lines.Add('')

    $item = $Schedule.items[0]
    $meta = '{0} · fin {1} · prévu {2}' -f $label, (Format-TdClock $item.endMs), (Format-TdDurationMs $current.plannedMs)
    if ($item.gapMs -ge 60000 -and -not $running) { $meta = 'créneau à {0} (dans {1}) · prévu {2}' -f $current.fixedStart, (Format-TdDurationMs $item.gapMs), (Format-TdDurationMs $current.plannedMs) }
    $barWidth = [Math]::Max(10, [Math]::Min(36, $Width - 46))
    $lines.Add('  ' + (Get-TdProgressBar -Fraction $fraction -Width $barWidth -Color $barColor) + '  ' + (Format-TdTui -Text (Limit-TdTuiText -Text $meta -Width ($Width - $barWidth - 5)) -Color 'muted'))

    # Étape en cours
    $progress = Get-TdStepProgress $current
    if ($progress.total -gt 0) {
        if ($progress.current) {
            $dots = ''
            if ($progress.total -le 12) { $dots = '  ' + ([string][char]0x25CF * $progress.done) + ([string][char]0x25CB * ($progress.total - $progress.done)) }
            $head = 'ÉTAPE {0}/{1}  ' -f $progress.index, $progress.total
            $hint = '[s] étape faite'
            $room = $Width - 4 - (Get-TdTextWidth $head) - (Get-TdTextWidth $dots) - $hint.Length - 2
            $left = '  ' + (Format-TdTui -Text $head -Color 'accent' -Bold) + (Format-TdTui -Text (Limit-TdTuiText -Text $progress.current.title -Width $room) -Color 'title') + (Format-TdTui -Text $dots -Color 'accent')
            $lines.Add((Join-TdTuiColumns -Left $left -Right ((Format-TdTui -Text $hint -Color 'muted') + ' ') -Width $Width))
        }
        else {
            $lines.Add('  ' + (Format-TdTui -Text ('ÉTAPES TERMINÉES {0}/{0}  ' -f $progress.total) -Color 'accent' -Bold) + (Format-TdTui -Text 'Tout est fait : [Entrée] pour valider la tâche.' -Color 'success'))
        }
    }

    # Atterrissage / dépassement
    $window = [long]$settings.landingMinutes * 60000
    if ($running -and $window -gt 0 -and $remaining -gt 0 -and $remaining -le $window -and [long]$current.plannedMs -gt $window + 60000) {
        $lines.Add('  ' + (Format-TdTui -Text (Limit-TdTuiText -Text "Atterrissage : encore $(Format-TdCountdown $remaining). Termine ta phrase et note où tu t'arrêtes." -Width $inner) -Color 'accent' -Bold))
    }
    if ($overtime) {
        $lines.Add('  ' + (Format-TdTui -Text (Limit-TdTuiText -Text "Temps additionnel : la fin de la liste glisse à $(Format-TdClock $Schedule.endMs). Aucune urgence, valide quand c'est bon." -Width $inner) -Color 'overtime'))
    }
    , $lines.ToArray()
}

function Get-TdTuiListLines {
    param([long]$NowMs, [int]$Width, [int]$MaxLines, $Schedule)
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($MaxLines -le 0) { return , $lines.ToArray() }
    $state = $script:Tui.Data.state
    $settings = $script:Tui.Data.settings
    $count = $state.tasks.Count
    $upcoming = [Math]::Max(0, $count - 1)
    $rest = [long]0
    for ($i = 1; $i -lt $count; $i++) { $rest += [long]$Schedule.items[$i].remainingMs }
    if ($upcoming -gt 0) { $head = 'ENSUITE · {0} TÂCHE{1} · {2}' -f $upcoming, $(if ($upcoming -gt 1) { 'S' } else { '' }), (Format-TdDurationMs $rest).ToUpperInvariant() }
    else { $head = 'ENSUITE' }
    $lines.Add('  ' + (Format-TdTui -Text $head -Color 'muted' -Bold))

    # Lignes de la file (avec le temps libre avant les créneaux figés)
    $rows = [System.Collections.Generic.List[object]]::new()
    for ($i = 1; $i -lt $count; $i++) {
        $task = $state.tasks[$i]
        $item = $Schedule.items[$i]
        if ($item.gapMs -ge 60000) {
            $rows.Add(@{ index = -1; text = '      ' + (Format-TdTui -Text ('temps libre · {0} avant {1}' -f (Format-TdDurationMs $item.gapMs), $task.fixedStart) -Color 'muted' -Dim) })
        }
        $selected = $script:Tui.Sel -eq $i
        $marker = ' '
        if ($selected) { $marker = Format-TdTui -Text ([string][char]0x203A) -Color 'accent' -Bold }
        $extra = @()
        if ($task.fixedStart) {
            if ($item.lateMs -gt 0) { $extra += 'créneau {0}, décalé de {1}' -f $task.fixedStart, (Format-TdDurationMs $item.lateMs) }
            else { $extra += '@' + $task.fixedStart }
        }
        $progress = Get-TdStepProgress $task
        if ($progress.total -gt 0) { $extra += 'étapes {0}/{1}' -f $progress.done, $progress.total }
        $right = (Format-TdDurationMs $task.plannedMs).PadLeft(7) + '  ' + (Format-TdTui -Text ([string][char]0x2192) -Color 'muted') + ' ' + (Format-TdTui -Text (Format-TdClock $item.endMs) -Bold) + ' '
        $extraText = ''
        if ($extra.Count -gt 0) { $extraText = '  ' + ($extra -join ' · ') }
        $room = $Width - 6 - (Get-TdTextWidth $right) - 2
        $title = Limit-TdTuiText -Text $task.title -Width $room
        $extraRoom = $room - (Get-TdTextWidth $title)
        $extraText = Limit-TdTuiText -Text $extraText -Width $extraRoom
        $titleColor = ''
        if ($selected) { $titleColor = 'title' }
        $left = '  ' + $marker + ' ' + (Format-TdTuiCategoryDot (Get-TdCategory $settings $task.categoryId)) + ' ' + (Format-TdTui -Text $title -Color $titleColor -Bold:$selected)
        if ($extraText) {
            $extraColor = 'muted'
            if ($item.lateMs -gt 0) { $extraColor = 'overtime' }
            $left += Format-TdTui -Text $extraText -Color $extraColor
        }
        $rows.Add(@{ index = $i; text = (Join-TdTuiColumns -Left $left -Right $right -Width $Width) })
    }
    $footer = [System.Collections.Generic.List[string]]::new()
    if ($upcoming -eq 0) {
        $msg = "Rien d'autre pour l'instant. C'est très bien comme ça."
        if ($count -eq 0) { $msg = 'La file est vide.' }
        $rows.Add(@{ index = -1; text = '    ' + (Format-TdTui -Text $msg -Color 'muted') })
    }
    if ($state.parked.Count -gt 0) {
        $footer.Add('  ' + (Format-TdTui -Text ('{0} tâche(s) reportée(s) à demain · [R] ramener aujourd''hui' -f $state.parked.Count) -Color 'muted'))
    }
    if ($state.done.Count -gt 0) {
        $focus = [long]0
        foreach ($t in $state.done) { $focus += [long]$t.elapsedMs }
        $footer.Add('  ' + (Format-TdTui -Text ([string][char]0x2713) -Color 'success') + ' ' + (Format-TdTui -Text ("Terminé aujourd'hui : {0} · {1} de focus · [z] annuler la dernière" -f $state.done.Count, (Format-TdDurationMs $focus)) -Color 'muted'))
    }

    # Défilement : la ligne sélectionnée reste visible.
    $room = $MaxLines - 1 - $footer.Count
    if ($room -lt 1) { $room = 1 }
    $start = 0
    if ($rows.Count -gt $room) {
        $selRow = 0
        for ($r = 0; $r -lt $rows.Count; $r++) { if ($rows[$r].index -eq $script:Tui.Sel) { $selRow = $r } }
        $start = [Math]::Max(0, [Math]::Min($selRow - [int]($room / 2), $rows.Count - $room))
    }
    $end = [Math]::Min($rows.Count, $start + $room)
    for ($r = $start; $r -lt $end; $r++) { $lines.Add($rows[$r].text) }
    if ($end -lt $rows.Count -and $lines.Count -gt 1) {
        $lines[$lines.Count - 1] = '      ' + (Format-TdTui -Text ('… et {0} de plus (↑/↓)' -f ($rows.Count - $end + 1)) -Color 'muted')
    }
    foreach ($f in $footer) { if ($lines.Count -lt $MaxLines) { $lines.Add($f) } }
    , $lines.ToArray()
}

function Get-TdTuiStatusLine {
    # Ligne de saisie, point de contrôle ou message éphémère.
    param([long]$NowMs, [int]$Width)
    $tui = $script:Tui
    $state = $tui.Data.state
    if ($tui.Prompt) {
        $label = Format-TdTui -Text ($tui.Prompt.Label + ' ' + [char]0x203A + ' ') -Color 'accent' -Bold
        $hint = ''
        if ($tui.Prompt.Hint) { $hint = Format-TdTui -Text ($tui.Prompt.Hint + ' ') -Color 'muted' }
        $room = $Width - 3 - (Get-TdTextWidth $label) - 1
        $text = $tui.Prompt.Text
        # Garde la fin visible quand le texte est long.
        while ((Get-TdTextWidth $text) -gt $room -and $text.Length -gt 0) { $text = $text.Substring(1) }
        $line = '  ' + $label + $text + (Format-TdTui -Text ([string][char]0x2588) -Color 'accent')
        if ($hint -and (Get-TdTextWidth $line) + (Get-TdTextWidth $hint) + 2 -le $Width) { return (Join-TdTuiColumns -Left $line -Right $hint -Width $Width) }
        return $line
    }
    if ($tui.CheckIn) {
        $current = Get-TdCurrentTask $state
        $title = ''
        if ($current) { $title = $current.title }
        # Le titre se raccourcit, puis les réponses, pour que les deux touches restent visibles.
        $answers = '[o] oui, je suis dessus   [g] je me suis égaré·e'
        $room = $Width - 23 - (Get-TdTextWidth $answers)
        if ($room -lt (Get-TdTextWidth $title)) {
            $answers = '[o] oui   [g] égaré·e'
            $room = $Width - 23 - (Get-TdTextWidth $answers)
        }
        $question = 'Toujours sur « {0} » ?' -f (Limit-TdTuiText -Text $title -Width $room)
        if ($room -lt 6) { $question = 'Toujours dessus ?'; $answers = '[o] oui [g] égaré·e' }
        return '  ' + (Format-TdTui -Text $question -Color 'success' -Bold) + '  ' + (Format-TdTui -Text $answers -Color 'title')
    }
    if ($tui.Message -and $NowMs -lt $tui.Message.Until) {
        $color = 'title'
        if ($tui.Message.Color) { $color = $tui.Message.Color }
        $suffix = ''
        if ($tui.Message.Hint) { $suffix = '   ' + $tui.Message.Hint }
        return '  ' + (Format-TdTui -Text (Limit-TdTuiText -Text ($tui.Message.Text + $suffix) -Width ($Width - 3)) -Color $color)
    }
    ''
}

function Get-TdTuiKeysLine {
    param([int]$Width)
    $tui = $script:Tui
    $text = switch ($tui.Mode) {
        'review' { '↑↓ choisir · [g] garder · [d] demain · [a] abandonner · [G] tout garder · Échap : garder le reste' }
        'routines' { '[1-9] charger une routine · Échap retour' }
        'notes' { '↑↓ choisir · [Entrée] en faire une tâche · [x] supprimer · [n] noter · Échap retour' }
        'settings' { '↑↓ choisir · [Entrée]/[Espace] changer · ←/→ régler · Échap retour' }
        'stats' { 'Échap retour' }
        'help' { 'Échap retour' }
        default {
            if ($tui.Prompt) { '[Entrée] valider · Échap annuler · Ctrl+U effacer' }
            else { 'Espace démarrer/pause · Entrée terminer · s étape · a ajouter · l plus tard · +/− 1 min · n note · r routines · o réglages · ? aide · q quitter' }
        }
    }
    ' ' + (Format-TdTui -Text (Limit-TdTuiText -Text $text -Width ($Width - 2)) -Color 'muted')
}

function Get-TdTuiMainFrame {
    param([long]$NowMs, [int]$Width, [int]$Height)
    $lines = [System.Collections.Generic.List[string]]::new()
    $schedule = Get-TdSchedule -State $script:Tui.Data.state -NowMs $NowMs
    $lines.Add((Get-TdTuiHeader -NowMs $NowMs -Width $Width))
    $lines.Add((Get-TdTuiRule $Width))
    foreach ($l in (Get-TdTuiFocusLines -NowMs $NowMs -Width $Width -Height $Height -Schedule $schedule)) { $lines.Add($l) }
    $lines.Add((Get-TdTuiRule $Width))
    $maxList = $Height - $lines.Count - 3
    foreach ($l in (Get-TdTuiListLines -NowMs $NowMs -Width $Width -MaxLines $maxList -Schedule $schedule)) { $lines.Add($l) }
    $body = Complete-TdTuiLines -Lines $lines -Height ($Height - 3)
    $all = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $body) { $all.Add($l) }
    $all.Add((Get-TdTuiRule $Width))
    $all.Add((Get-TdTuiStatusLine -NowMs $NowMs -Width $Width))
    $all.Add((Get-TdTuiKeysLine -Width $Width))
    , $all.ToArray()
}

function Get-TdTuiPage {
    # Écran secondaire : en-tête, titre, lignes, pied.
    param([long]$NowMs, [int]$Width, [int]$Height, [string]$Title, [string[]]$Body)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((Get-TdTuiHeader -NowMs $NowMs -Width $Width -Subtitle $Title))
    $lines.Add((Get-TdTuiRule $Width))
    foreach ($l in $Body) { $lines.Add($l) }
    $body = Complete-TdTuiLines -Lines $lines -Height ($Height - 3)
    $all = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $body) { $all.Add($l) }
    $all.Add((Get-TdTuiRule $Width))
    $all.Add((Get-TdTuiStatusLine -NowMs $NowMs -Width $Width))
    $all.Add((Get-TdTuiKeysLine -Width $Width))
    , $all.ToArray()
}

function Get-TdTuiSelectableLines {
    # Liste avec curseur « › » et défilement.
    param([string[]]$Items, [int]$Selected, [int]$MaxLines)
    $out = [System.Collections.Generic.List[string]]::new()
    if ($MaxLines -lt 1) { return , $out.ToArray() }
    $start = 0
    if ($Items.Count -gt $MaxLines) { $start = [Math]::Max(0, [Math]::Min($Selected - [int]($MaxLines / 2), $Items.Count - $MaxLines)) }
    $end = [Math]::Min($Items.Count, $start + $MaxLines)
    for ($i = $start; $i -lt $end; $i++) {
        if ($i -eq $Selected) { $out.Add('  ' + (Format-TdTui -Text ([string][char]0x203A) -Color 'accent' -Bold) + ' ' + $Items[$i]) }
        else { $out.Add('    ' + $Items[$i]) }
    }
    , $out.ToArray()
}

function Get-TdTuiReviewFrame {
    param([long]$NowMs, [int]$Width, [int]$Height)
    $state = $script:Tui.Data.state
    $settings = $script:Tui.Data.settings
    $tasks = @(Get-TdReviewTasks $state)
    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add('')
    $body.Add('  ' + (Format-TdTui -Text "Nouvelle journée ! Voici ce qui reste d'hier." -Color 'title' -Bold))
    $body.Add('  ' + (Format-TdTui -Text (Limit-TdTuiText -Text 'Pour chaque tâche : la garder pour aujourd''hui, la reporter à demain, ou l''abandonner. Abandonner est un choix tout à fait valable.' -Width ($Width - 4)) -Color 'muted'))
    $body.Add('')
    $items = @(foreach ($t in $tasks) {
        $meta = @('prévu ' + (Format-TdDurationMs $t.plannedMs))
        $cat = Get-TdCategory $settings $t.categoryId
        if ($cat) { $meta += $cat.name }
        $p = Get-TdStepProgress $t
        if ($p.total -gt 0) { $meta += 'étapes {0}/{1}' -f $p.done, $p.total }
        if ($t.fixedStart) { $meta += "créneau d'hier à $($t.fixedStart)" }
        $metaText = '  ' + ($meta -join ' · ')
        $title = Limit-TdTuiText -Text $t.title -Width ($Width - 8 - [Math]::Min(40, $metaText.Length))
        (Format-TdTuiCategoryDot $cat) + ' ' + (Format-TdTui -Text $title -Color 'title') + (Format-TdTui -Text (Limit-TdTuiText -Text $metaText -Width ($Width - 8 - (Get-TdTextWidth $title))) -Color 'muted')
    })
    if ($tasks.Count -eq 0) { $body.Add('    ' + (Format-TdTui -Text 'Tout est trié. Belle journée !' -Color 'success')) }
    foreach ($l in (Get-TdTuiSelectableLines -Items @($items) -Selected $script:Tui.ListSel -MaxLines ($Height - 10))) { $body.Add($l) }
    Get-TdTuiPage -NowMs $NowMs -Width $Width -Height $Height -Title 'Revue du matin' -Body $body.ToArray()
}

function Get-TdTuiHelpFrame {
    param([long]$NowMs, [int]$Width, [int]$Height)
    $keys = @(
        @('Espace', 'démarrer / mettre en pause'), @('Entrée', 'valider la tâche en cours'),
        @('s / S', 'étape faite / revenir à l''étape précédente'), @('a', 'ajouter une tâche (« Emails 15 », « Réunion 30 @14h »)'),
        @('e / p', 'modifier la tâche choisie / ses sous-étapes'), @('+ / −', 'ajouter / retirer 1 minute'),
        @('] / [', 'ajouter / retirer 5 minutes'), @('l', 'reporter la tâche en cours en fin de liste'),
        @('↑ / ↓', 'choisir une tâche dans la liste'), @('K / J', 'monter / descendre la tâche choisie'),
        @('d / v / x', 'commencer maintenant / marquer faite / supprimer la tâche choisie'),
        @('z', 'annuler la dernière action'), @('n / N', 'note rapide / bloc-notes'),
        @('r / t / o', 'routines / statistiques / réglages'), @('m', 'compte à rebours ou progressif'),
        @('R', 'ramener les tâches reportées'), @('q', 'quitter (le minuteur continue de compter)')
    )
    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add('')
    foreach ($k in $keys) { $body.Add('  ' + (Format-TdTui -Text $k[0].PadRight(12) -Color 'accent' -Bold) + (Limit-TdTuiText -Text $k[1] -Width ($Width - 16))) }
    Get-TdTuiPage -NowMs $NowMs -Width $Width -Height $Height -Title 'Aide' -Body $body.ToArray()
}

function Get-TdTuiRoutinesFrame {
    param([long]$NowMs, [int]$Width, [int]$Height)
    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add('')
    $body.Add('  ' + (Format-TdTui -Text 'Les tâches de la routine s''ajoutent à la fin de ta liste.' -Color 'muted'))
    $body.Add('')
    $n = 0
    foreach ($tpl in (Get-TdTuiTemplates)) {
        $n++
        if ($n -gt 9) { break }
        $total = 0.0
        foreach ($it in $tpl.items) { $total += [double]$it.minutes }
        $line = '{0}  {1} · {2} tâche(s) · {3}' -f $n, $tpl.name, @($tpl.items).Count, (Format-TdMinutes $total)
        $body.Add('  ' + (Format-TdTui -Text ([string]$n) -Color 'accent' -Bold) + (Limit-TdTuiText -Text $line.Substring(1) -Width ($Width - 4)))
    }
    $body.Add('')
    $body.Add('  ' + (Format-TdTui -Text 'Pour enregistrer la liste actuelle comme routine : [s] puis son nom.' -Color 'muted'))
    Get-TdTuiPage -NowMs $NowMs -Width $Width -Height $Height -Title 'Routines' -Body $body.ToArray()
}

function Get-TdTuiStatsFrame {
    param([long]$NowMs, [int]$Width, [int]$Height)
    $stats = Get-TdStats -History $script:Tui.Data.history -NowMs $NowMs
    $checks = Get-TdCheckInSummary -CheckIns $script:Tui.Data.checkins -NowMs $NowMs
    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add('')
    $body.Add('  ' + (Format-TdTui -Text ("Aujourd'hui : {0} tâche(s) terminée(s) · {1} de concentration" -f $stats.todayCount, (Format-TdDurationMs $stats.todayFocusMs)) -Color 'title' -Bold))
    if ($checks.total -gt 0) {
        $body.Add('  ' + (Format-TdTui -Text ('Points de contrôle : {0} · {1} fois concentré·e · {2} recentrage(s). Chaque recentrage compte.' -f $checks.total, $checks.focused, $checks.drifted) -Color 'muted'))
    }
    $body.Add('')
    $body.Add('  ' + (Format-TdTui -Text '7 DERNIERS JOURS' -Color 'muted' -Bold) + '   ' + (Format-TdTui -Text '█ estimé' -Color 'success') + '  ' + (Format-TdTui -Text '█ réel' -Color 'accent'))
    $max = 1.0
    foreach ($d in $stats.days) { $max = [Math]::Max($max, [Math]::Max($d.estimateMs, $d.actualMs)) }
    $barWidth = [Math]::Max(10, [Math]::Min(30, $Width - 50))
    foreach ($d in $stats.days) {
        $e = [int][Math]::Round($barWidth * $d.estimateMs / $max)
        $a = [int][Math]::Round($barWidth * $d.actualMs / $max)
        $label = $d.label.PadRight(8)
        $body.Add('  ' + $label + (Format-TdTui -Text ([string][char]0x2588 * $e) -Color 'success') + (' ' * ($barWidth - $e + 1)) + (Format-TdTui -Text ('estimé ' + (Format-TdDurationMs $d.estimateMs)) -Color 'muted'))
        $body.Add('  ' + (' ' * 8) + (Format-TdTui -Text ([string][char]0x2588 * $a) -Color 'accent') + (' ' * ($barWidth - $a + 1)) + (Format-TdTui -Text ('réel ' + (Format-TdDurationMs $d.actualMs)) -Color 'muted'))
    }
    $body.Add('')
    if ($stats.sampleCount -ge 3) {
        $ratio = [double]$stats.medianRatio
        if ($ratio -ge 1.1) { $msg = 'En général, tes tâches prennent {0:0.0#}× le temps estimé : prévois une marge.' -f $ratio }
        elseif ($ratio -le 0.9) { $msg = 'Tu termines souvent plus vite que prévu ({0:0.0#}×).' -f $ratio }
        else { $msg = 'Tes estimations sont justes (×{0:0.0#} en médiane).' -f $ratio }
        $body.Add('  ' + (Limit-TdTuiText -Text $msg -Width ($Width - 4)))
    }
    else {
        $body.Add('  ' + (Format-TdTui -Text 'Encore quelques tâches chronométrées pour voir comment tu estimes tes durées.' -Color 'muted'))
    }
    $body.Add('  ' + (Format-TdTui -Text 'Ces chiffres servent à mieux te connaître, jamais à te juger.' -Color 'muted'))
    Get-TdTuiPage -NowMs $NowMs -Width $Width -Height $Height -Title 'Estimé vs réel' -Body $body.ToArray()
}

function Get-TdTuiNotesFrame {
    param([long]$NowMs, [int]$Width, [int]$Height)
    $notes = $script:Tui.Data.notes
    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add('')
    $body.Add('  ' + (Format-TdTui -Text 'Parking à idées : dépose une pensée parasite et reviens à ta tâche.' -Color 'muted'))
    $body.Add('')
    $items = @(for ($i = $notes.Count - 1; $i -ge 0; $i--) {
        $n = $notes[$i]
        $meta = '  ' + (Format-TdClock $n.createdAt)
        if ($n.context) { $meta += ' · pendant « {0} »' -f $n.context }
        $text = Limit-TdTuiText -Text (($n.text -split '\r?\n')[0]) -Width ($Width - 10 - [Math]::Min(30, $meta.Length))
        $text + (Format-TdTui -Text (Limit-TdTuiText -Text $meta -Width ($Width - 8 - (Get-TdTextWidth $text))) -Color 'muted')
    })
    if ($notes.Count -eq 0) { $body.Add('    ' + (Format-TdTui -Text 'Aucune note pour l''instant. [n] pour noter.' -Color 'muted')) }
    foreach ($l in (Get-TdTuiSelectableLines -Items @($items) -Selected $script:Tui.ListSel -MaxLines ($Height - 9))) { $body.Add($l) }
    Get-TdTuiPage -NowMs $NowMs -Width $Width -Height $Height -Title 'Bloc-notes' -Body $body.ToArray()
}

function Get-TdTuiSettingsFrame {
    param([long]$NowMs, [int]$Width, [int]$Height)
    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add('')
    $pad = [Math]::Max(14, [Math]::Min(42, $Width - 26))
    $items = @(foreach ($row in (Get-TdTuiSettingRows)) {
        (Limit-TdTuiText -Text $row.label -Width ($pad - 2)).PadRight($pad) + (Format-TdTui -Text $row.value -Color 'accent' -Bold)
    })
    foreach ($l in (Get-TdTuiSelectableLines -Items @($items) -Selected $script:Tui.ListSel -MaxLines ($Height - 9))) { $body.Add($l) }
    $body.Add('')
    $player = 'aucun lecteur audio trouvé (installe pipewire ou pulseaudio-utils pour entendre les sons)'
    if ($script:TdTuiAudio -and $script:TdTuiAudio.Player) { $player = 'lecteur audio : ' + $script:TdTuiAudio.Player }
    $body.Add('  ' + (Format-TdTui -Text (Limit-TdTuiText -Text $player -Width ($Width - 4)) -Color 'muted'))
    $body.Add('  ' + (Format-TdTui -Text (Limit-TdTuiText -Text ('Données : ' + (Get-TdDataDirectory)) -Width ($Width - 4)) -Color 'muted'))
    Get-TdTuiPage -NowMs $NowMs -Width $Width -Height $Height -Title 'Réglages' -Body $body.ToArray()
}

function Get-TdTuiFrame {
    param([long]$NowMs, [int]$Width, [int]$Height)
    $Width = [Math]::Max(40, $Width)
    $Height = [Math]::Max(12, $Height)
    $frame = switch ($script:Tui.Mode) {
        'review' { Get-TdTuiReviewFrame -NowMs $NowMs -Width $Width -Height $Height }
        'help' { Get-TdTuiHelpFrame -NowMs $NowMs -Width $Width -Height $Height }
        'routines' { Get-TdTuiRoutinesFrame -NowMs $NowMs -Width $Width -Height $Height }
        'stats' { Get-TdTuiStatsFrame -NowMs $NowMs -Width $Width -Height $Height }
        'notes' { Get-TdTuiNotesFrame -NowMs $NowMs -Width $Width -Height $Height }
        'settings' { Get-TdTuiSettingsFrame -NowMs $NowMs -Width $Width -Height $Height }
        default { Get-TdTuiMainFrame -NowMs $NowMs -Width $Width -Height $Height }
    }
    , @(foreach ($line in $frame) { Limit-TdTuiLine -Line $line -Width $Width })
}
