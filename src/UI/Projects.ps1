# TDfocus - panneau « Projets et quotidien ».
#   - Projets : 3 au plus en cours, avancés par petits pas dans des blocs de temps courts,
#     avec le « pourquoi » et une note « où j'en étais » pour reprendre sans effort.
#   - Quotidien : actions récurrentes ajoutées toutes seules les jours prévus, sans dette.

function Save-TdProjectsNow {
    try { Save-TdProjects $script:Td.Data.projects } catch { Write-TdLog "Sauvegarde des projets impossible : $($_.Exception.Message)" }
}

function Save-TdDailyNow {
    try { Save-TdDaily $script:Td.Data.daily } catch { Write-TdLog "Sauvegarde du quotidien impossible : $($_.Exception.Message)" }
}

function Build-TdProjectsPanel {
    param($Panel)
    $tabs = New-TdPanel -Wrap -Margin '0,0,0,14'
    foreach ($t in @(@('projects', 'Projets'), @('daily', 'Quotidien'))) {
        $chip = New-TdChip -Content $t[1] -Group 'ProjectsTab' -Checked ($script:Td.ProjectsTab -eq $t[0]) -Tag $t[0] -OnClick {
            $script:Td.ProjectsTab = [string]$this.Tag
            Update-TdDrawer
        }
        $chip.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
        [void]$tabs.Children.Add($chip)
    }
    [void]$Panel.Children.Add($tabs)
    if ($script:Td.ProjectsTab -eq 'daily') { Build-TdDailySection $Panel } else { Build-TdProjectSection $Panel }
}

# ---------------------------------------------------------------- projets

function Build-TdProjectSection {
    param($Panel)
    $projects = $script:Td.Data.projects
    $state = Get-TdState
    $now = Get-TdNowMs
    $active = @(Get-TdActiveProjects $projects)
    Add-TdSection $Panel ('En cours · {0}/{1}' -f $active.Count, $script:TdMaxActiveProjects) 'Peu de projets à la fois, chacun avancé par petits pas dans un bloc de temps court : tu n''as jamais à porter le projet entier.'
    if ($active.Count -eq 0) {
        [void]$Panel.Children.Add((New-TdText -Text 'Aucun projet en cours. Crée-en un plus bas, ou reprends un projet en attente.' -Size 13 -Brush 'MutedBrush' -Wrap -Margin '2,0,0,10'))
    }
    foreach ($p in $active) { [void]$Panel.Children.Add((New-TdProjectCard -Project $p -State $state -NowMs $now)) }

    $paused = @($projects | Where-Object { $_.status -eq 'paused' })
    if ($paused.Count -gt 0) {
        Add-TdSection $Panel 'En attente' 'Mis de côté sans culpabilité : ils reprendront quand il y aura de la place.'
        foreach ($p in $paused) { [void]$Panel.Children.Add((New-TdProjectCard -Project $p -State $state -NowMs $now)) }
    }
    $done = @($projects | Where-Object { $_.status -eq 'done' })
    if ($done.Count -gt 0) {
        Add-TdSection $Panel 'Terminés'
        foreach ($p in $done) { [void]$Panel.Children.Add((New-TdProjectCard -Project $p -State $state -NowMs $now)) }
    }

    Add-TdSection $Panel 'Nouveau projet' 'Un nom, ce qui te motive, et le tout premier pas : un geste concret de quelques minutes (« ouvrir le dossier », pas « faire le dossier »).'
    $form = @{
        Name     = New-TdTextBox -Margin '0,0,0,6'
        Why      = New-TdTextBox -Margin '0,0,0,6'
        Deadline = New-TdTextBox -Margin '0,0,0,6' -Width 150
        Steps    = New-TdTextBox -Margin '0,0,0,8' -Multiline
    }
    $form.Deadline.HorizontalAlignment = 'Left'
    $form.Steps.MinHeight = 64
    $form.Name.ToolTip = 'Nom du projet'
    $form.Why.ToolTip = 'Pourquoi ce projet compte pour toi : la motivation se lit ici quand elle manque.'
    $form.Deadline.ToolTip = 'Facultatif. Ex. 15/12 ou 15/12/2027'
    $form.Steps.ToolTip = 'Un pas par ligne. Les 3 premiers seront proposés dans chaque bloc.'
    $script:Td.ProjectForm = $form
    [void]$Panel.Children.Add((New-TdLabeledRow -Label 'Nom' -Control $form.Name))
    [void]$Panel.Children.Add((New-TdLabeledRow -Label 'Pourquoi' -Control $form.Why))
    [void]$Panel.Children.Add((New-TdLabeledRow -Label 'Échéance' -Control $form.Deadline))
    [void]$Panel.Children.Add((New-TdLabeledRow -Label 'Premiers pas' -Control $form.Steps))
    $form.Name.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { New-TdProjectFromForm; $e.Handled = $true } })
    $create = New-TdButton -Content 'Créer le projet' -Style 'PrimaryButton' -OnClick { New-TdProjectFromForm }
    $create.HorizontalAlignment = 'Left'
    [void]$Panel.Children.Add($create)
}

function New-TdProjectCard {
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)]$State, [long]$NowMs)
    $id = $Project.id
    $card = New-TdCard
    $stack = New-TdPanel
    $head = New-TdPanel -Orientation 'Horizontal'
    $emoji = New-TdText -Text $Project.emoji -Size 18 -Margin '0,0,8,0' -Font 'EmojiFont'
    $emoji.VerticalAlignment = 'Center'
    [void]$head.Children.Add($emoji)
    $title = New-TdText -Text $Project.name -Size 15 -Bold
    $title.VerticalAlignment = 'Center'
    $title.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    [void]$head.Children.Add($title)
    [void]$stack.Children.Add($head)
    if ($Project.why) {
        $why = New-TdText -Text ('Pourquoi : ' + $Project.why) -Size 12 -Brush 'MutedBrush' -Wrap -Margin '0,4,0,0'
        $why.FontStyle = [System.Windows.FontStyles]::Italic
        [void]$stack.Children.Add($why)
    }
    $summary = Get-TdProjectSummary -Project $Project -NowMs $NowMs
    if ($summary) { [void]$stack.Children.Add((New-TdText -Text $summary -Size 12 -Brush 'MutedBrush' -Wrap -Margin '0,3,0,0')) }

    if ($Project.status -ne 'done') {
        $next = @(Get-TdProjectPendingSteps $Project 1)
        if ($next.Count -gt 0) { [void]$stack.Children.Add((New-TdText -Text ('Prochain pas : ' + $next[0].title) -Size 13 -Brush 'AccentBrush' -Bold -Wrap -Margin '0,6,0,0')) }
        else { [void]$stack.Children.Add((New-TdText -Text 'Prochain pas à définir : un geste concret de quelques minutes.' -Size 13 -Brush 'MutedBrush' -Wrap -Margin '0,6,0,0')) }
        if ($Project.breadcrumb) { [void]$stack.Children.Add((New-TdText -Text ("Où j'en étais : " + $Project.breadcrumb) -Size 12 -Wrap -Margin '0,3,0,0')) }
    }

    $actions = New-TdPanel -Wrap -Margin '0,10,0,0'
    switch ($Project.status) {
        'active' {
            if (Test-TdProjectPlannedToday -State $State -ProjectId $id) {
                $planned = New-TdButton -Content ([string][char]0x2713 + " Bloc prévu aujourd'hui") -Margin '0,0,6,4'
                $planned.IsEnabled = $false
                [void]$actions.Children.Add($planned)
            }
            else {
                $block = New-TdButton -Content ('Bloc de {0} aujourd''hui' -f (Format-TdMinutes $Project.blockMinutes)) -Style 'PrimaryButton' -Margin '0,0,6,4' -Tag $id -ToolTip 'Ajoute un bloc de temps pour ce projet à ta journée, avec ses prochains pas.' -OnClick { Add-TdProjectBlockNow -Id ([string]$this.Tag) }
                $block.Padding = New-Object System.Windows.Thickness 14, 6, 14, 6
                [void]$actions.Children.Add($block)
            }
        }
        'paused' { [void]$actions.Children.Add((New-TdButton -Content 'Reprendre' -Margin '0,0,6,4' -Tag $id -OnClick { Set-TdProjectStatusNow -Id ([string]$this.Tag) -Status 'active' })) }
    }
    $label = 'Détails'
    if ($script:Td.ExpandedProjectId -eq $id) { $label = 'Masquer' }
    [void]$actions.Children.Add((New-TdButton -Content $label -Style 'GhostButton' -Margin '0,0,0,4' -Tag $id -OnClick {
                $pid2 = [string]$this.Tag
                if ($script:Td.ExpandedProjectId -eq $pid2) { $script:Td.ExpandedProjectId = $null } else { $script:Td.ExpandedProjectId = $pid2 }
                Update-TdDrawer
            }))
    [void]$stack.Children.Add($actions)
    if ($script:Td.ExpandedProjectId -eq $id) { Add-TdProjectDetails -Panel $stack -Project $Project }
    $card.Child = $stack
    $card
}

function Add-TdProjectDetails {
    param([Parameter(Mandatory)]$Panel, [Parameter(Mandatory)]$Project)
    $id = $Project.id
    $details = New-TdPanel -Margin '0,10,0,0'

    [void]$details.Children.Add((New-TdText -Text 'PAS' -Size 11 -Brush 'MutedBrush' -Bold -Margin '0,0,0,4'))
    foreach ($step in @($Project.steps)) {
        if (-not $step) { continue }
        $row = New-Object System.Windows.Controls.DockPanel
        $row.Margin = New-Object System.Windows.Thickness 0, 0, 0, 2
        $del = New-TdButton -Content ([string][char]0xE74D) -Style 'SmallIconButton' -ToolTip 'Retirer ce pas' -Tag "$id|$($step.id)" -OnClick {
            $p = ([string]$this.Tag).Split('|')
            $project = Find-TdProject $script:Td.Data.projects $p[0]
            if ($project) { Remove-TdProjectStep -Project $project -StepId $p[1]; Save-TdProjectsNow; Update-TdDrawer }
        }
        [System.Windows.Controls.DockPanel]::SetDock($del, [System.Windows.Controls.Dock]::Right)
        [void]$row.Children.Add($del)
        $check = New-Object System.Windows.Controls.CheckBox
        $check.Content = [System.Windows.UIElement](New-TdText -Text $step.title -Size 13 -Wrap)
        $check.IsChecked = [bool]$step.done
        $check.VerticalAlignment = 'Center'
        $check.Tag = "$id|$($step.id)"
        $check.Add_Click({
                $p = ([string]$this.Tag).Split('|')
                $project = Find-TdProject $script:Td.Data.projects $p[0]
                if (-not $project) { return }
                [void](Set-TdProjectStepDone -Project $project -StepId $p[1] -Done ([bool]$this.IsChecked))
                Save-TdProjectsNow
                Update-TdDrawer
            })
        [void]$row.Children.Add($check)
        [void]$details.Children.Add($row)
    }
    $stepBox = New-TdTextBox -Margin '0,4,0,10'
    $stepBox.Tag = $id
    $stepBox.ToolTip = 'Nouveau pas, puis Entrée. Un geste concret de quelques minutes.'
    $stepBox.Add_KeyDown({
            param($s, $e)
            if ($e.Key -ne 'Return') { return }
            $e.Handled = $true
            $project = Find-TdProject $script:Td.Data.projects ([string]$s.Tag)
            if (-not $project -or [string]::IsNullOrWhiteSpace($s.Text)) { return }
            [void](Add-TdProjectStep -Project $project -Title $s.Text)
            Save-TdProjectsNow
            $script:Td.FocusProjectBox = 'step'
            Update-TdDrawer
        })
    [void]$details.Children.Add((New-TdLabeledRow -Label 'Ajouter' -Control $stepBox))

    $crumb = New-TdTextBox -Text $Project.breadcrumb -Margin '0,0,0,8' -Multiline
    $crumb.MinHeight = 54
    $crumb.Tag = $id
    $crumb.ToolTip = 'Où tu t''es arrêté·e et ce que tu comptais faire ensuite : ta mémoire de travail, gardée pour toi.'
    $crumb.Add_LostFocus({
            param($s, $e)
            $project = Find-TdProject $script:Td.Data.projects ([string]$s.Tag)
            if (-not $project -or $project.breadcrumb -eq $s.Text.Trim()) { return }
            Set-TdProjectBreadcrumb -Project $project -Text $s.Text
            Save-TdProjectsNow
            Update-TdView
        })
    [void]$details.Children.Add((New-TdLabeledRow -Label "Où j'en suis" -Control $crumb))

    $deadline = ''
    if ($Project.deadline) { $deadline = [datetime]::ParseExact($Project.deadline, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture).ToString('dd/MM/yyyy') }
    $due = New-TdTextBox -Text $deadline -Margin '0,0,0,8' -Width 150
    $due.HorizontalAlignment = 'Left'
    $due.Tag = $id
    $due.ToolTip = 'Facultatif. Ex. 15/12 ou 15/12/2027. Vide = pas d''échéance.'
    $due.Add_LostFocus({ param($s, $e) Set-TdProjectDeadlineFromBox $s })
    $due.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Set-TdProjectDeadlineFromBox $s; $e.Handled = $true } })
    [void]$details.Children.Add((New-TdLabeledRow -Label 'Échéance' -Control $due))

    $blocks = New-TdPanel -Wrap
    foreach ($m in @(15, 25, 45, 60)) {
        $chip = New-TdChip -Content "$m min" -Group "Block$id" -Checked ([int]$Project.blockMinutes -eq $m) -Tag "$id|$m" -OnClick {
            $p = ([string]$this.Tag).Split('|')
            $project = Find-TdProject $script:Td.Data.projects $p[0]
            if ($project) { $project.blockMinutes = [int]$p[1]; Save-TdProjectsNow; Update-TdDrawer; Update-TdView }
        }
        $chip.Margin = New-Object System.Windows.Thickness 0, 0, 4, 4
        [void]$blocks.Children.Add($chip)
    }
    [void]$details.Children.Add((New-TdLabeledRow -Label 'Bloc' -Control $blocks))

    $actions = New-TdPanel -Wrap -Margin '0,8,0,0'
    if ($Project.status -eq 'active') {
        [void]$actions.Children.Add((New-TdButton -Content 'Mettre en attente' -Margin '0,0,6,4' -Tag $id -OnClick { Set-TdProjectStatusNow -Id ([string]$this.Tag) -Status 'paused' }))
    }
    if ($Project.status -ne 'done') {
        [void]$actions.Children.Add((New-TdButton -Content 'Projet terminé' -Style 'SuccessButton' -Margin '0,0,6,4' -Tag $id -OnClick { Set-TdProjectStatusNow -Id ([string]$this.Tag) -Status 'done' }))
    }
    else {
        [void]$actions.Children.Add((New-TdButton -Content 'Rouvrir' -Margin '0,0,6,4' -Tag $id -OnClick { Set-TdProjectStatusNow -Id ([string]$this.Tag) -Status 'active' }))
    }
    [void]$actions.Children.Add((New-TdButton -Content 'Supprimer' -Style 'GhostButton' -Margin '0,0,0,4' -Tag $id -OnClick { Remove-TdProjectNow -Id ([string]$this.Tag) }))
    [void]$details.Children.Add($actions)
    # Les champs ont le fond des cartes : on les éclaircit pour qu'ils restent visibles.
    foreach ($box in @($stepBox, $crumb, $due)) { $box.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'SurfaceBrush') }
    [void]$Panel.Children.Add($details)

    $focus = $script:Td.FocusProjectBox
    $script:Td.FocusProjectBox = $null
    if ($focus -eq 'step') { $stepBox.Add_Loaded({ $this.Focus() | Out-Null }) }
    elseif ($focus -eq 'crumb') { $crumb.Add_Loaded({ $this.Focus() | Out-Null; $this.SelectAll() }) }
}

function Set-TdProjectDeadlineFromBox {
    param([Parameter(Mandatory)]$Box)
    $project = Find-TdProject $script:Td.Data.projects ([string]$Box.Tag)
    if (-not $project) { return }
    $text = $Box.Text.Trim()
    $key = $null
    if ($text) {
        $key = ConvertTo-TdDateKey $text (Get-TdNowMs)
        if (-not $key) { Show-TdToast -Text 'Échéance non comprise : écris par exemple 15/12 ou 15/12/2027.'; return }
    }
    if ($project.deadline -eq $key) { return }
    $project.deadline = $key
    Save-TdProjectsNow
    Update-TdDrawer
    Update-TdView
}

function New-TdProjectFromForm {
    $form = $script:Td.ProjectForm
    if (-not $form) { return }
    $name = $form.Name.Text.Trim()
    if (-not $name) { Show-TdToast -Text 'Donne un nom à ton projet.'; $form.Name.Focus() | Out-Null; return }
    $now = Get-TdNowMs
    $deadline = $null
    if ($form.Deadline.Text.Trim()) {
        $deadline = ConvertTo-TdDateKey $form.Deadline.Text $now
        if (-not $deadline) { Show-TdToast -Text 'Échéance non comprise : écris par exemple 15/12 ou 15/12/2027.'; $form.Deadline.Focus() | Out-Null; return }
    }
    $steps = @(ConvertFrom-TdStepsText $form.Steps.Text | ForEach-Object { $_.title })
    $project = New-TdProject -Name $name -Why $form.Why.Text -Deadline $deadline -Steps $steps -NowMs $now
    $status = Add-TdProject -Projects $script:Td.Data.projects -Project $project
    Save-TdProjectsNow
    $script:Td.ExpandedProjectId = $project.id
    if ($status -eq 'paused') {
        Show-TdToast -Text ('Projet « {0} » créé et rangé en attente : {1} projets sont déjà en cours.' -f (Limit-TdText $name 30), $script:TdMaxActiveProjects) -Seconds 8
    }
    elseif ($steps.Count -eq 0) {
        $script:Td.FocusProjectBox = 'step'
        Show-TdToast -Text ('Projet « {0} » créé. Ajoute son premier pas : un geste de quelques minutes.' -f (Limit-TdText $name 30)) -Seconds 8
    }
    else { Show-TdToast -Text ('Projet « {0} » créé. Son premier pas t''attend.' -f (Limit-TdText $name 30)) }
    Update-TdDrawer
    Update-TdView
}

function Add-TdProjectBlockNow {
    param([Parameter(Mandatory)][string]$Id)
    $project = Find-TdProject $script:Td.Data.projects $Id
    if (-not $project) { return }
    $now = Get-TdNowMs
    $task = New-TdProjectBlockTask -Project $project -NowMs $now
    Add-TdTask -State (Get-TdState) -Task $task -NowMs $now
    Complete-TdChange -Replan
    Update-TdDrawer
    Show-TdToast -Text ('Bloc de {0} pour « {1} » ajouté à ta journée.' -f (Format-TdMinutes $project.blockMinutes), (Limit-TdText $project.name 30)) -ActionText 'Annuler' -Data @{ Id = $task.id } -Action {
        param($d)
        [void](Remove-TdTask -State (Get-TdState) -Id $d.Id -NowMs (Get-TdNowMs))
        Hide-TdToast
        Complete-TdChange -Replan
        Update-TdDrawer
    }
}

function Set-TdProjectStatusNow {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Status)
    $projects = $script:Td.Data.projects
    $project = Find-TdProject $projects $Id
    if (-not $project) { return }
    if (-not (Set-TdProjectStatus -Projects $projects -Project $project -Status $Status -NowMs (Get-TdNowMs))) {
        Show-TdToast -Text ('{0} projets en cours, c''est déjà beaucoup : mets-en un en attente pour reprendre celui-ci.' -f $script:TdMaxActiveProjects) -Seconds 8
        return
    }
    Save-TdProjectsNow
    switch ($Status) {
        'done' {
            Invoke-TdConfetti -Origin $null
            Show-TdToast -Text ('Projet « {0} » terminé ! Prends le temps de savourer.' -f (Limit-TdText $project.name 30)) -Seconds 8
        }
        'paused' { Show-TdToast -Text ('« {0} » mis en attente. Il t''attendra sans rien exiger.' -f (Limit-TdText $project.name 30)) }
    }
    Update-TdDrawer
    Update-TdView
}

function Remove-TdProjectNow {
    param([Parameter(Mandatory)][string]$Id)
    $projects = $script:Td.Data.projects
    for ($i = 0; $i -lt $projects.Count; $i++) {
        if ($projects[$i].id -ne $Id) { continue }
        $project = $projects[$i]
        $projects.RemoveAt($i)
        Save-TdProjectsNow
        Update-TdDrawer
        Update-TdView
        Show-TdToast -Text ('Projet « {0} » supprimé.' -f (Limit-TdText $project.name 30)) -ActionText 'Annuler' -Data @{ Project = $project; Index = $i } -Action {
            param($d)
            $list = $script:Td.Data.projects
            $list.Insert([Math]::Min($d.Index, $list.Count), $d.Project)
            Save-TdProjectsNow
            Hide-TdToast
            Update-TdDrawer
            Update-TdView
        }
        return
    }
}

function Show-TdBreadcrumbEditor {
    # Après un bloc : noter où l'on s'arrête, pour reprendre sans effort la prochaine fois.
    param([Parameter(Mandatory)][string]$ProjectId)
    $script:Td.ProjectsTab = 'projects'
    $script:Td.ExpandedProjectId = $ProjectId
    $script:Td.FocusProjectBox = 'crumb'
    Show-TdDrawer 'projects' -Force
}

function Set-TdNudgeOffToday {
    (Get-TdState).nudgeOff = Get-TdDayKey (Get-TdNowMs)
    Save-TdStateNow
    Update-TdView
}

# ---------------------------------------------------------------- quotidien

function Build-TdDailySection {
    param($Panel)
    Add-TdSection $Panel 'Chaque jour, tout seul' 'Ces actions s''ajoutent d''elles-mêmes à ta journée les jours prévus, sans rien décider. Pas faites ? Elles ne s''accumulent pas : elles reviennent simplement le prochain jour prévu.'
    $daily = @($script:Td.Data.daily)
    if ($daily.Count -eq 0) {
        [void]$Panel.Children.Add((New-TdText -Text 'Aucune action pour l''instant. Pense aux petites tâches qui reviennent : relever les e-mails, point d''équipe, saisie des temps, mise à jour du suivi…' -Size 13 -Brush 'MutedBrush' -Wrap -Margin '2,0,0,10'))
    }
    foreach ($action in $daily) { [void]$Panel.Children.Add((New-TdDailyCard -Action $action)) }

    Add-TdSection $Panel 'Nouvelle action du quotidien' 'Même saisie rapide que pour les tâches : « E-mails 15 @9h », « Point d''équipe 15 @9h30 », « Saisie des temps 5 ».'
    $box = New-TdTextBox -Margin '0,0,0,8'
    $box.ToolTip = 'Titre, durée et heure fixe facultative'
    $box.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Add-TdDailyNow; $e.Handled = $true } })
    $script:Td.DailyBox = $box
    [void]$Panel.Children.Add($box)
    [void]$Panel.Children.Add((New-TdDayChips -Days @($script:Td.NewDailyDays) -Tag 'new'))
    $add = New-TdButton -Content 'Ajouter au quotidien' -Style 'PrimaryButton' -Margin '0,8,0,0' -OnClick { Add-TdDailyNow }
    $add.HorizontalAlignment = 'Left'
    [void]$Panel.Children.Add($add)
}

function New-TdDayChips {
    # Sept pastilles « lun » … « dim » ; Tag : identifiant de l'action ou « new ».
    param([int[]]$Days, [Parameter(Mandatory)][string]$Tag)
    $wrap = New-TdPanel -Wrap
    for ($d = 1; $d -le 7; $d++) {
        $chip = New-TdChip -Content $script:TdDayNames[$d - 1] -Checked (@($Days) -contains $d) -Tag "$Tag|$d" -OnClick { Switch-TdDailyDayNow -Tag ([string]$this.Tag) -Checked ([bool]$this.IsChecked) }
        $chip.Margin = New-Object System.Windows.Thickness 0, 0, 4, 4
        [void]$wrap.Children.Add($chip)
    }
    $wrap
}

function New-TdDailyCard {
    param([Parameter(Mandatory)]$Action)
    $card = New-TdCard -Padding '12'
    $stack = New-TdPanel
    if ($script:Td.EditingDailyId -eq $Action.id) {
        # Modification : même saisie rapide que pour les tâches.
        [void]$stack.Children.Add((New-TdText -Text 'MODIFIER L''ACTION' -Size 11 -Brush 'AccentBrush' -Bold -Margin '0,0,0,6'))
        $box = New-TdTextBox -Text (ConvertTo-TdDailyActionText $Action) -Margin '0,0,0,8'
        $box.Tag = $Action.id
        $box.ToolTip = 'Titre, durée et heure fixe facultative : « Point d''équipe 15 @9h30 »'
        $box.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'SurfaceBrush')
        $box.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Save-TdDailyEdit -Box $s; $e.Handled = $true } })
        $box.Add_Loaded({ $this.Focus() | Out-Null; $this.SelectAll() })
        $script:Td.DailyEditBox = $box
        [void]$stack.Children.Add($box)
        $actions = New-TdPanel -Wrap
        [void]$actions.Children.Add((New-TdButton -Content 'Enregistrer' -Style 'PrimaryButton' -Margin '0,0,6,0' -OnClick { Save-TdDailyEdit -Box $script:Td.DailyEditBox }))
        [void]$actions.Children.Add((New-TdButton -Content 'Annuler' -OnClick { $script:Td.EditingDailyId = $null; Update-TdDrawer }))
        [void]$stack.Children.Add($actions)
        $card.Child = $stack
        return $card
    }
    $row = New-Object System.Windows.Controls.DockPanel
    $del = New-TdButton -Content ([string][char]0xE74D) -Style 'SmallIconButton' -ToolTip 'Retirer du quotidien' -Tag $Action.id -OnClick { Remove-TdDailyNow -Id ([string]$this.Tag) }
    [System.Windows.Controls.DockPanel]::SetDock($del, [System.Windows.Controls.Dock]::Right)
    [void]$row.Children.Add($del)
    $edit = New-TdButton -Content ([string][char]0xE70F) -Style 'SmallIconButton' -ToolTip 'Modifier (titre, durée, heure)' -Tag $Action.id -OnClick { $script:Td.EditingDailyId = [string]$this.Tag; Update-TdDrawer }
    [System.Windows.Controls.DockPanel]::SetDock($edit, [System.Windows.Controls.Dock]::Right)
    [void]$row.Children.Add($edit)
    $toggle = New-TdSwitch -Label $Action.title -Checked ([bool]$Action.active) -ToolTip 'Active : ajoutée toute seule les jours prévus. Désactivée : mise de côté.' -OnChange { Set-TdDailyActiveNow -Id ([string]$this.Tag) -Active ([bool]$this.IsChecked) }
    $toggle.Tag = $Action.id
    [void]$row.Children.Add($toggle)
    [void]$stack.Children.Add($row)
    $meta = @((Format-TdMinutes $Action.minutes), (Format-TdDays $Action.days))
    if ($Action.fixedStart) { $meta += 'à ' + $Action.fixedStart }
    [void]$stack.Children.Add((New-TdText -Text ($meta -join ' · ') -Size 12 -Brush 'MutedBrush' -Margin '0,2,0,6'))
    [void]$stack.Children.Add((New-TdDayChips -Days @($Action.days) -Tag $Action.id))
    $card.Child = $stack
    $card
}

function Save-TdDailyEdit {
    param([Parameter(Mandatory)]$Box)
    $action = Find-TdDailyAction ([string]$Box.Tag)
    if (-not $action) { return }
    if (-not (Set-TdDailyActionFromText -Action $action -Text $Box.Text)) {
        Show-TdToast -Text 'Écris au moins un titre, par exemple « Point d''équipe 15 @9h30 ».'
        return
    }
    Save-TdDailyNow
    $script:Td.EditingDailyId = $null
    if (Update-TdDailyTaskToday -State (Get-TdState) -Action $action) { Complete-TdChange -Replan }
    Show-TdToast -Text ('« {0} » modifiée.' -f (Limit-TdText $action.title 30))
    Update-TdDrawer
}

function Find-TdDailyAction {
    param([string]$Id)
    foreach ($a in @($script:Td.Data.daily)) { if ($a.id -eq $Id) { return $a } }
    $null
}

function Update-TdDailyToday {
    # Ajoute aujourd'hui ce qui est prévu et pas encore fait (après un ajout ou une réactivation).
    $added = Sync-TdDailyTasks -State (Get-TdState) -Daily $script:Td.Data.daily -NowMs (Get-TdNowMs)
    if ($added -gt 0) { Complete-TdChange -Replan }
    $added
}

function Add-TdDailyNow {
    $box = $script:Td.DailyBox
    $text = $box.Text.Trim()
    if (-not $text) { Show-TdToast -Text 'Écris l''action, par exemple « Saisie des temps 5 ».'; $box.Focus() | Out-Null; return }
    $parsed = ConvertFrom-TdQuickInput $text
    if (-not $parsed.title) { return }
    $minutes = $parsed.minutes
    if (-not $minutes) { $minutes = 10 }
    $days = @($script:Td.NewDailyDays)
    if ($days.Count -eq 0) { $days = @(1, 2, 3, 4, 5, 6, 7) }
    $action = New-TdDailyAction -Title $parsed.title -Minutes ([double]$minutes) -Days $days -FixedStart $parsed.fixedStart
    $script:Td.Data.daily.Add($action)
    Save-TdDailyNow
    $added = Update-TdDailyToday
    $script:Td.NewDailyDays = @(1, 2, 3, 4, 5, 6, 7)
    $message = '« {0} » ajoutée au quotidien ({1}).' -f (Limit-TdText $action.title 30), (Format-TdDays $action.days)
    if ($added -gt 0) { $message += " Elle est déjà dans ta journée." }
    Show-TdToast -Text $message
    Update-TdDrawer
}

function Switch-TdDailyDayNow {
    param([Parameter(Mandatory)][string]$Tag, [bool]$Checked)
    $p = $Tag.Split('|')
    $day = [int]$p[1]
    if ($p[0] -eq 'new') {
        $days = @(@($script:Td.NewDailyDays) | Where-Object { $_ -ne $day })
        if ($Checked) { $days += $day }
        $script:Td.NewDailyDays = @($days | Sort-Object -Unique)
        return
    }
    $action = Find-TdDailyAction $p[0]
    if (-not $action) { return }
    $days = @(@($action.days) | Where-Object { $_ -ne $day })
    if ($Checked) { $days += $day }
    if ($days.Count -eq 0) {
        Show-TdToast -Text 'Garde au moins un jour, ou désactive l''action.'
        Update-TdDrawer
        return
    }
    $action.days = @($days | Sort-Object -Unique)
    Save-TdDailyNow
    [void](Update-TdDailyToday)
    Update-TdDrawer
}

function Set-TdDailyActiveNow {
    param([Parameter(Mandatory)][string]$Id, [bool]$Active)
    $action = Find-TdDailyAction $Id
    if (-not $action -or $action.active -eq $Active) { return }
    $action.active = $Active
    Save-TdDailyNow
    if ($Active) { [void](Update-TdDailyToday) }
}

function Remove-TdDailyNow {
    param([Parameter(Mandatory)][string]$Id)
    $daily = $script:Td.Data.daily
    for ($i = 0; $i -lt $daily.Count; $i++) {
        if ($daily[$i].id -ne $Id) { continue }
        $action = $daily[$i]
        $daily.RemoveAt($i)
        Save-TdDailyNow
        Update-TdDrawer
        Show-TdToast -Text ('« {0} » retirée du quotidien.' -f (Limit-TdText $action.title 30)) -ActionText 'Annuler' -Data @{ Action = $action; Index = $i } -Action {
            param($d)
            $list = $script:Td.Data.daily
            $list.Insert([Math]::Min($d.Index, $list.Count), $d.Action)
            Save-TdDailyNow
            Hide-TdToast
            Update-TdDrawer
        }
        return
    }
}
