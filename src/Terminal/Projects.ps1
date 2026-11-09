# TDfocus (terminal) - écrans « Projets » et « Quotidien » (touche P, Tab pour passer de l'un à l'autre).

function Save-TdTuiProjects {
    try { Save-TdProjects $script:Tui.Data.projects } catch { Write-TdLog "Sauvegarde des projets impossible : $($_.Exception.Message)" }
}

function Save-TdTuiDaily {
    try { Save-TdDaily $script:Tui.Data.daily } catch { Write-TdLog "Sauvegarde du quotidien impossible : $($_.Exception.Message)" }
}

function Get-TdTuiProjectList {
    # Ordre d'affichage : en cours, en attente, terminés.
    $all = @($script:Tui.Data.projects)
    @($all | Where-Object { $_.status -eq 'active' }) + @($all | Where-Object { $_.status -eq 'paused' }) + @($all | Where-Object { $_.status -eq 'done' })
}

function Get-TdTuiSelectedProject {
    $list = @(Get-TdTuiProjectList)
    if ($list.Count -eq 0) { return $null }
    $list[[Math]::Min($script:Tui.ListSel, $list.Count - 1)]
}

function Get-TdTuiSelectedDaily {
    $list = @($script:Tui.Data.daily)
    if ($list.Count -eq 0) { return $null }
    $list[[Math]::Min($script:Tui.ListSel, $list.Count - 1)]
}

# ---------------------------------------------------------------- actions : projets

function Add-TdTuiProjectFromText {
    # « nom ; pourquoi ; échéance » : seul le nom est obligatoire.
    param([string]$Text)
    $parts = @($Text -split ';' | ForEach-Object { $_.Trim() })
    $name = $parts[0]
    if (-not $name) { return }
    $now = Get-TdNowMs
    $why = ''
    if ($parts.Count -gt 1) { $why = $parts[1] }
    $deadline = $null
    if ($parts.Count -gt 2 -and $parts[2]) {
        $deadline = ConvertTo-TdDateKey $parts[2] $now
        if (-not $deadline) { Show-TdTuiMessage -Text 'Échéance non comprise (ex. 15/12) : ajoute-la plus tard avec [e].' -Color 'overtime' }
    }
    $project = New-TdProject -Name $name -Why $why -Deadline $deadline -NowMs $now
    $status = Add-TdProject -Projects $script:Tui.Data.projects -Project $project
    Save-TdTuiProjects
    $script:Tui.ListSel = [Array]::IndexOf(@(Get-TdTuiProjectList), $project)
    if ($status -eq 'paused') {
        Show-TdTuiMessage -Text ('« {0} » créé et rangé en attente : {1} projets sont déjà en cours.' -f $name, $script:TdMaxActiveProjects) -Seconds 8
    }
    # Enchaîner sur le premier pas tant que l'élan est là.
    Open-TdTuiPrompt -Label 'Premier pas' -Hint 'un geste concret de quelques minutes · Échap : plus tard' -Data $project.id -OnSubmit {
        param($text, $id)
        Add-TdTuiProjectStep -Id $id -Text $text
    }
}

function Add-TdTuiProjectStep {
    param([string]$Id, [string]$Text)
    $project = Find-TdProject $script:Tui.Data.projects $Id
    if (-not $project -or [string]::IsNullOrWhiteSpace($Text)) { return }
    [void](Add-TdProjectStep -Project $project -Title $Text)
    Save-TdTuiProjects
    Show-TdTuiMessage -Text ('Pas ajouté : « {0} ».' -f $Text.Trim()) -Seconds 4 -Hint '[s] un autre'
}

function Add-TdTuiProjectBlock {
    param([Parameter(Mandatory)]$Project)
    if ($Project.status -ne 'active') { Show-TdTuiMessage -Text 'Ce projet est en attente : [p] pour le reprendre.' -Color 'muted'; return }
    if (Test-TdProjectPlannedToday -State $script:Tui.Data.state -ProjectId $Project.id) {
        Show-TdTuiMessage -Text "Un bloc de ce projet est déjà dans ta journée." -Color 'muted'
        return
    }
    $now = Get-TdNowMs
    $task = New-TdProjectBlockTask -Project $Project -NowMs $now
    Add-TdTask -State $script:Tui.Data.state -Task $task -NowMs $now
    Complete-TdTuiChange -Replan
    Show-TdTuiMessage -Text ('Bloc de {0} pour « {1} » ajouté à ta journée.' -f (Format-TdMinutes $Project.blockMinutes), $Project.name) -UndoData @{ Id = $task.id } -Undo {
        param($d)
        [void](Remove-TdTask -State $script:Tui.Data.state -Id $d.Id -NowMs (Get-TdNowMs))
        Complete-TdTuiChange -Replan
    }
}

function Set-TdTuiProjectStatus {
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)][string]$Status)
    if (-not (Set-TdProjectStatus -Projects $script:Tui.Data.projects -Project $Project -Status $Status)) {
        Show-TdTuiMessage -Text ('{0} projets en cours, c''est déjà beaucoup : mets-en un en attente [p] pour reprendre celui-ci.' -f $script:TdMaxActiveProjects) -Color 'overtime' -Seconds 8
        return
    }
    Save-TdTuiProjects
    $script:Tui.ListSel = [Math]::Max(0, [Array]::IndexOf(@(Get-TdTuiProjectList), $Project))
    switch ($Status) {
        'done' { Show-TdTuiMessage -Text ('Projet « {0} » terminé ! Prends le temps de savourer.' -f $Project.name) -Color 'success' -Seconds 8 }
        'paused' { Show-TdTuiMessage -Text ('« {0} » en attente. Il t''attendra sans rien exiger.' -f $Project.name) -Seconds 5 }
        'active' { Show-TdTuiMessage -Text ('« {0} » repris.' -f $Project.name) -Seconds 4 }
    }
    $script:Tui.Dirty = $true
}

function Remove-TdTuiProject {
    param([Parameter(Mandatory)]$Project)
    $list = $script:Tui.Data.projects
    $index = $list.IndexOf($Project)
    if ($index -lt 0) { return }
    $list.RemoveAt($index)
    Save-TdTuiProjects
    $script:Tui.ListSel = [Math]::Max(0, [Math]::Min($script:Tui.ListSel, $list.Count - 1))
    Show-TdTuiMessage -Text ('Projet « {0} » supprimé.' -f $Project.name) -UndoData @{ Project = $Project; Index = $index } -Undo {
        param($d)
        $l = $script:Tui.Data.projects
        $l.Insert([Math]::Min($d.Index, $l.Count), $d.Project)
        Save-TdTuiProjects
        $script:Tui.Dirty = $true
    }
}

function Open-TdTuiBreadcrumbPrompt {
    # « Où j'en suis » : noter où l'on s'arrête pour reprendre sans effort.
    param([Parameter(Mandatory)]$Project)
    Open-TdTuiPrompt -Label "Où j'en suis" -Text $Project.breadcrumb -Hint 'où tu t''arrêtes et la suite prévue' -Data $Project.id -OnSubmit {
        param($text, $id)
        $p = Find-TdProject $script:Tui.Data.projects $id
        if (-not $p) { return }
        Set-TdProjectBreadcrumb -Project $p -Text $text
        Save-TdTuiProjects
        Show-TdTuiMessage -Text 'Noté. La reprise sera facile.' -Color 'success' -Seconds 4
    }
}

function Invoke-TdTuiProjectsKey {
    param([Parameter(Mandatory)][System.ConsoleKeyInfo]$Key)
    $tui = $script:Tui
    $ch = [string]$Key.KeyChar
    $count = @(Get-TdTuiProjectList).Count
    $project = Get-TdTuiSelectedProject
    switch ($Key.Key) {
        'UpArrow' { $tui.ListSel = [Math]::Max(0, $tui.ListSel - 1); return }
        'DownArrow' { $tui.ListSel = [Math]::Min([Math]::Max(0, $count - 1), $tui.ListSel + 1); return }
        'Tab' { $tui.Mode = 'daily'; $tui.ListSel = 0; return }
        'Escape' { $tui.Mode = 'main'; return }
        'Enter' { if ($project) { Add-TdTuiProjectBlock $project }; return }
        'Delete' { if ($project) { Remove-TdTuiProject $project }; return }
    }
    switch -CaseSensitive ($ch) {
        'a' { Open-TdTuiPrompt -Label 'Nouveau projet' -Hint 'nom ; pourquoi ; échéance (ex. Refonte du site ; livrer avant le salon ; 15/12)' -OnSubmit { param($text) Add-TdTuiProjectFromText -Text $text } }
        'q' { $tui.Mode = 'main' }
        'z' { if ($tui.Undo) { $u = $tui.Undo; $tui.Undo = $null; $tui.Message = $null; & $u.Action $u.Data } }
    }
    if (-not $project) { return }
    switch -CaseSensitive ($ch) {
        'b' { Add-TdTuiProjectBlock $project }
        's' { Open-TdTuiPrompt -Label 'Nouveau pas' -Hint 'un geste concret de quelques minutes' -Data $project.id -OnSubmit { param($text, $id) Add-TdTuiProjectStep -Id $id -Text $text } }
        'f' {
            $next = @(Get-TdProjectPendingSteps $project 1)
            if ($next.Count -eq 0) { Show-TdTuiMessage -Text 'Aucun pas en attente : [s] pour en ajouter un.' -Color 'muted'; return }
            [void](Set-TdProjectStepDone -Project $project -StepId $next[0].id)
            Save-TdTuiProjects
            Show-TdTuiMessage -Text ('Pas fait : « {0} ». Bravo !' -f $next[0].title) -Color 'success' -Seconds 4 -UndoData @{ P = $project; S = $next[0].id } -Undo {
                param($d)
                [void](Set-TdProjectStepDone -Project $d.P -StepId $d.S -Done $false)
                Save-TdTuiProjects
                $script:Tui.Dirty = $true
            }
        }
        'j' { Open-TdTuiBreadcrumbPrompt $project }
        'w' {
            Open-TdTuiPrompt -Label 'Pourquoi' -Text $project.why -Hint 'ce qui te motive dans ce projet' -Data $project.id -OnSubmit {
                param($text, $id)
                $p = Find-TdProject $script:Tui.Data.projects $id
                if ($p) { $p.why = $text.Trim(); Save-TdTuiProjects }
            }
        }
        'e' {
            $current = ''
            if ($project.deadline) { $current = [datetime]::ParseExact($project.deadline, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture).ToString('dd/MM/yyyy') }
            Open-TdTuiPrompt -Label 'Échéance' -Text $current -Hint 'ex. 15/12 · « aucune » pour retirer' -Data $project.id -OnSubmit {
                param($text, $id)
                $p = Find-TdProject $script:Tui.Data.projects $id
                if (-not $p) { return }
                if ($text -match '^(aucune|non|-)$') { $p.deadline = $null; Save-TdTuiProjects; return }
                $key = ConvertTo-TdDateKey $text (Get-TdNowMs)
                if (-not $key) { Show-TdTuiMessage -Text 'Échéance non comprise : écris par exemple 15/12 ou 15/12/2027.' -Color 'overtime'; return }
                $p.deadline = $key
                Save-TdTuiProjects
            }
        }
        'm' {
            $steps = @(15, 25, 45, 60)
            $i = [Array]::IndexOf($steps, [int]$project.blockMinutes)
            $project.blockMinutes = $steps[($i + 1) % $steps.Count]
            Save-TdTuiProjects
        }
        'p' {
            if ($project.status -eq 'active') { Set-TdTuiProjectStatus $project 'paused' }
            elseif ($project.status -eq 'paused') { Set-TdTuiProjectStatus $project 'active' }
        }
        't' {
            if ($project.status -eq 'done') { Set-TdTuiProjectStatus $project 'active' } else { Set-TdTuiProjectStatus $project 'done' }
        }
        'x' { Remove-TdTuiProject $project }
    }
}

# ---------------------------------------------------------------- actions : quotidien

function Update-TdTuiDailyToday {
    $added = Sync-TdDailyTasks -State $script:Tui.Data.state -Daily $script:Tui.Data.daily -NowMs (Get-TdNowMs)
    if ($added -gt 0) { Complete-TdTuiChange -Replan }
    $added
}

function Add-TdTuiDailyFromText {
    # « Point d'équipe 15 @9h30 ; en semaine » : saisie rapide, puis les jours (tous par défaut).
    param([string]$Text)
    $parts = @($Text -split ';' | ForEach-Object { $_.Trim() })
    $parsed = ConvertFrom-TdQuickInput $parts[0]
    if (-not $parsed.title) { return }
    $days = @(1, 2, 3, 4, 5, 6, 7)
    if ($parts.Count -gt 1 -and $parts[1]) {
        $days = ConvertFrom-TdDaysText $parts[1]
        if (-not $days) { Show-TdTuiMessage -Text 'Jours non compris (ex. en semaine, lun-ven, week-end, lun mer ven).' -Color 'overtime'; return }
    }
    $minutes = $parsed.minutes
    if (-not $minutes) { $minutes = 10 }
    $action = New-TdDailyAction -Title $parsed.title -Minutes ([double]$minutes) -Days $days -FixedStart $parsed.fixedStart
    $script:Tui.Data.daily.Add($action)
    Save-TdTuiDaily
    $script:Tui.ListSel = $script:Tui.Data.daily.Count - 1
    $text = '« {0} » ajoutée au quotidien ({1}).' -f $action.title, (Format-TdDays $action.days)
    if ((Update-TdTuiDailyToday) -gt 0) { $text += ' Elle est déjà dans ta journée.' }
    Show-TdTuiMessage -Text $text -Color 'success' -Seconds 5
}

function Invoke-TdTuiDailyKey {
    param([Parameter(Mandatory)][System.ConsoleKeyInfo]$Key)
    $tui = $script:Tui
    $ch = [string]$Key.KeyChar
    $count = $tui.Data.daily.Count
    $action = Get-TdTuiSelectedDaily
    switch ($Key.Key) {
        'UpArrow' { $tui.ListSel = [Math]::Max(0, $tui.ListSel - 1); return }
        'DownArrow' { $tui.ListSel = [Math]::Min([Math]::Max(0, $count - 1), $tui.ListSel + 1); return }
        'Tab' { $tui.Mode = 'projects'; $tui.ListSel = 0; return }
        'Escape' { $tui.Mode = 'main'; return }
    }
    if ($Key.Key -eq 'Spacebar' -or $Key.Key -eq 'Enter') {
        if (-not $action) { return }
        $action.active = -not $action.active
        Save-TdTuiDaily
        if ($action.active) { [void](Update-TdTuiDailyToday) }
        return
    }
    switch -CaseSensitive ($ch) {
        'a' { Open-TdTuiPrompt -Label 'Nouvelle action' -Hint 'ex. E-mails 15 @9h · Saisie des temps 5 ; en semaine' -OnSubmit { param($text) Add-TdTuiDailyFromText -Text $text } }
        'q' { $tui.Mode = 'main' }
        'z' { if ($tui.Undo) { $u = $tui.Undo; $tui.Undo = $null; $tui.Message = $null; & $u.Action $u.Data } }
    }
    if (-not $action) { return }
    switch -CaseSensitive ($ch) {
        'j' {
            Open-TdTuiPrompt -Label 'Jours' -Text (Format-TdDays $action.days) -Hint 'tous les jours · en semaine · week-end · lun mer ven' -Data $action.id -OnSubmit {
                param($text, $id)
                $a = $script:Tui.Data.daily | Where-Object { $_.id -eq $id } | Select-Object -First 1
                if (-not $a) { return }
                $days = ConvertFrom-TdDaysText $text
                if (-not $days) { Show-TdTuiMessage -Text 'Jours non compris (ex. en semaine, lun-ven, week-end, lun mer ven).' -Color 'overtime'; return }
                $a.days = @($days)
                Save-TdTuiDaily
                [void](Update-TdTuiDailyToday)
            }
        }
        'x' {
            $list = $tui.Data.daily
            $index = $list.IndexOf($action)
            $list.RemoveAt($index)
            Save-TdTuiDaily
            $tui.ListSel = [Math]::Max(0, [Math]::Min($tui.ListSel, $list.Count - 1))
            Show-TdTuiMessage -Text ('« {0} » retirée du quotidien.' -f $action.title) -UndoData @{ A = $action; I = $index } -Undo {
                param($d)
                $l = $script:Tui.Data.daily
                $l.Insert([Math]::Min($d.I, $l.Count), $d.A)
                Save-TdTuiDaily
                $script:Tui.Dirty = $true
            }
        }
    }
}

# ---------------------------------------------------------------- rendu

function Get-TdTuiProjectsFrame {
    param([long]$NowMs, [int]$Width, [int]$Height)
    $tui = $script:Tui
    $projects = @(Get-TdTuiProjectList)
    $active = @($projects | Where-Object { $_.status -eq 'active' }).Count
    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add('')
    $body.Add('  ' + (Format-TdTui -Text (Limit-TdTuiText -Text 'Peu de projets à la fois, avancés par petits pas dans des blocs courts : jamais le projet entier sous les yeux.' -Width ($Width - 4)) -Color 'muted'))
    $body.Add('')
    if ($projects.Count -eq 0) {
        $body.Add('    ' + (Format-TdTui -Text 'Aucun projet. [a] pour en créer un : un nom, ce qui te motive, et un premier petit pas.' -Color 'muted'))
    }
    $section = ''
    $sel = [Math]::Min($tui.ListSel, [Math]::Max(0, $projects.Count - 1))
    for ($i = 0; $i -lt $projects.Count; $i++) {
        $p = $projects[$i]
        $title = switch ($p.status) {
            'active' { 'EN COURS · {0}/{1}' -f $active, $script:TdMaxActiveProjects }
            'paused' { 'EN ATTENTE (sans culpabilité)' }
            default { 'TERMINÉS' }
        }
        if ($title -ne $section) {
            if ($section) { $body.Add('') }
            $section = $title
            $body.Add('  ' + (Format-TdTui -Text $title -Color 'muted' -Bold))
        }
        $selected = $i -eq $sel
        $marker = '  '
        if ($selected) { $marker = (Format-TdTui -Text ([string][char]0x203A) -Color 'accent' -Bold) + ' ' }
        $summary = Get-TdProjectSummary -Project $p -NowMs $NowMs
        $planned = ''
        if ($p.status -eq 'active' -and (Test-TdProjectPlannedToday -State $tui.Data.state -ProjectId $p.id)) { $planned = '  ' + [char]0x2713 + " bloc prévu aujourd'hui" }
        $name = Limit-TdTuiText -Text $p.name -Width ([Math]::Max(12, [int]($Width * 0.4)))
        $left = '  ' + $marker + $p.emoji + ' ' + (Format-TdTui -Text $name -Color 'title' -Bold:$selected)
        $room = $Width - (Get-TdTextWidth $left) - 3
        $right = Format-TdTui -Text (Limit-TdTuiText -Text ($summary + $planned) -Width $room) -Color 'muted'
        $body.Add((Join-TdTuiColumns -Left $left -Right ($right + ' ') -Width $Width))
        if (-not $selected) { continue }
        # Détails du projet choisi seulement : le reste reste discret.
        $indent = '       '
        if ($p.why) { $body.Add($indent + (Format-TdTui -Text (Limit-TdTuiText -Text ('Pourquoi : ' + $p.why) -Width ($Width - 9)) -Color 'muted')) }
        if ($p.status -ne 'done') {
            $next = @(Get-TdProjectPendingSteps $p 1)
            if ($next.Count -gt 0) { $body.Add($indent + (Format-TdTui -Text (Limit-TdTuiText -Text ('Prochain pas : ' + $next[0].title) -Width ($Width - 9)) -Color 'accent' -Bold)) }
            else { $body.Add($indent + (Format-TdTui -Text 'Prochain pas à définir : [s] un geste concret de quelques minutes.' -Color 'muted')) }
            if ($p.breadcrumb) { $body.Add($indent + (Limit-TdTuiText -Text ("Où j'en étais : " + $p.breadcrumb) -Width ($Width - 9))) }
            $body.Add($indent + (Format-TdTui -Text ('Bloc de {0} · [m] changer' -f (Format-TdMinutes $p.blockMinutes)) -Color 'muted'))
        }
    }
    Get-TdTuiPage -NowMs $NowMs -Width $Width -Height $Height -Title 'Projets' -Body $body.ToArray()
}

function Get-TdTuiDailyFrame {
    param([long]$NowMs, [int]$Width, [int]$Height)
    $tui = $script:Tui
    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add('')
    $body.Add('  ' + (Format-TdTui -Text 'CHAQUE JOUR, TOUT SEUL' -Color 'muted' -Bold))
    $body.Add('  ' + (Format-TdTui -Text (Limit-TdTuiText -Text 'Ajoutées d''elles-mêmes les jours prévus, sans rien décider. Pas faites ? Elles reviennent, sans s''accumuler.' -Width ($Width - 4)) -Color 'muted'))
    $body.Add('')
    $daily = @($tui.Data.daily)
    if ($daily.Count -eq 0) { $body.Add('    ' + (Format-TdTui -Text 'Aucune action. [a] pour ajouter : e-mails, point d''équipe, saisie des temps…' -Color 'muted')) }
    $items = @(foreach ($a in $daily) {
            $mark = Format-TdTui -Text ([string][char]0x25CB) -Color 'muted'
            if ($a.active) { $mark = Format-TdTui -Text ([string][char]0x21BB) -Color 'success' }
            $meta = @((Format-TdMinutes $a.minutes), (Format-TdDays $a.days))
            if ($a.fixedStart) { $meta += 'à ' + $a.fixedStart }
            if (-not $a.active) { $meta += 'en pause' }
            $title = Limit-TdTuiText -Text $a.title -Width ([Math]::Max(12, [int]($Width * 0.45)))
            Join-TdTuiColumns -Left ($mark + ' ' + $title) -Right ((Format-TdTui -Text ($meta -join ' · ') -Color 'muted') + ' ') -Width ($Width - 4)
        })
    foreach ($l in (Get-TdTuiSelectableLines -Items @($items) -Selected $tui.ListSel -MaxLines ($Height - 10))) { $body.Add($l) }
    Get-TdTuiPage -NowMs $NowMs -Width $Width -Height $Height -Title 'Quotidien' -Body $body.ToArray()
}
