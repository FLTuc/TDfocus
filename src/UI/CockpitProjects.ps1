# TDfocus - cockpit flottant : projets, relances du jour, mode projet, « Où j'en étais », « Récap du jour ».
#
# Comme pour les tickets, rien n'est saisi ici : tout est lu dans TDfocus (voir src\Core\CockpitData.ps1).
#   Projets            le panneau Projets de TDfocus (pas, échéance, « bloqué : en attente de… »)
#   Relances du jour   tickets escaladés et projets bloqués dont la relance est due
#   Prochaine réunion  la prochaine action à heure fixe de la liste
#   Mode projet        s'affiche quand la tâche en cours de TDfocus est un bloc projet
#
# Dans $script:Td.Cockpit, ce fichier utilise :
#   Interrupted     « Interrompre » a été cliqué : le bloc est en pause et les tickets sont de nouveau visibles
#   BlockNote       la note de reprise est ouverte
#   BlockSignalId   bloc planifié déjà annoncé (pour ne donner le signal qu'une fois)
#   BlockText       dernier « Reste 52 min » affiché (pour ne redessiner que s'il change)
#   InfoKind        panneau ouvert par les boutons du bas : 'where', 'recap', ou $null

function Register-TdCockpitProjectEvents {
    $panelEls = $script:Td.Cockpit.PanelEls
    $panelEls.BtnProjectsManage.Add_Click({ Open-TdProjectsFromCockpit })

    # Bloc projet.
    $panelEls.BtnBlockStart.Add_Click({ Start-TdDueBlock })
    $panelEls.BtnBlockToggle.Add_Click({ Switch-TdTimerNow })
    $panelEls.BtnBlockStep.Add_Click({ Complete-TdBlockStep })
    $panelEls.BtnInterrupt.Add_Click({ Invoke-TdCockpitInterrupt })
    $panelEls.BtnNoteSave.Add_Click({ Save-TdBlockNote })
    $panelEls.BtnNoteSkip.Add_Click({ Hide-TdBlockNote })
    $panelEls.BlockNoteBox.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Return) { Save-TdBlockNote; $e.Handled = $true }
            elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) { Hide-TdBlockNote; $e.Handled = $true }
        })

    # Boutons du bas.
    $panelEls.BtnWhere.Add_Click({ Switch-TdCockpitInfo -Kind 'where' })
    $panelEls.BtnRecap.Add_Click({ Switch-TdCockpitInfo -Kind 'recap' })
    $panelEls.BtnInfoClose.Add_Click({ Switch-TdCockpitInfo -Kind '' })
}

function Open-TdProjectsFromCockpit {
    # « Gérer » : c'est dans TDfocus qu'on crée et modifie les projets.
    if ($script:Td.Compact) { Set-TdCompactMode $false }
    Show-TdWindow
    $script:Td.ProjectsTab = 'projects'
    Show-TdDrawer 'projects' -Force
}

function Invoke-TdCockpitProjectAction {
    # Commandes des boutons créés par le code pour les projets :
    #   project-followup   « Relancé » : la relance du projet bloqué est faite, la suivante est repoussée
    param([Parameter(Mandatory)][string]$Kind, [string]$Id)
    $project = Find-TdProject $script:Td.Data.projects $Id
    if (-not $project) { return }
    if ($Kind -eq 'project-followup') {
        Set-TdProjectFollowUp -Project $project -NowMs (Get-TdNowMs)
        Save-TdProjectsNow
        Update-TdView
    }
}

# ---------------------------------------------------------------- carte Projets, relances, réunion

function Update-TdCockpitProjects {
    # -Block : le bloc projet en cours (mode projet), ou $null. -FollowUps : les relances dues aujourd'hui.
    param([Parameter(Mandatory)][long]$NowMs, $Block, $FollowUps)
    $panelEls = $script:Td.Cockpit.PanelEls
    $items = @(Get-TdCockpitProjects -Projects $script:Td.Data.projects -State (Get-TdState) -NowMs $NowMs)

    # Projets. En mode projet : les autres projets, en résumé d'une ligne.
    $title = 'PROJETS'
    $empty = 'Aucun projet en cours. Crée-le dans TDfocus (bouton Projets).'
    if ($Block) {
        $title = 'AUTRES PROJETS'
        $empty = 'Pas d''autre projet en cours.'
        if ($Block.project) { $items = @($items | Where-Object { $_.id -ne $Block.project.id }) }
    }
    $panelEls.ProjectsTitle.Text = $title
    $panelEls.ProjectsEmpty.Text = $empty
    Set-TdCockpitVisible $panelEls.ProjectsEmpty ($items.Count -eq 0)
    $rows = $panelEls.ProjectList
    $rows.Children.Clear()
    foreach ($item in $items) { [void]$rows.Children.Add((New-TdCockpitProjectRow -Item $item -Short:($null -ne $Block))) }

    # Relances du jour : tickets et projets mélangés.
    $list = $panelEls.FollowList
    $list.Children.Clear()
    $due = @($FollowUps)
    Set-TdCockpitVisible $panelEls.FollowEmpty ($due.Count -eq 0)
    foreach ($item in $due) { [void]$list.Children.Add((New-TdFollowUpRow -Item $item)) }

    # Prochaine réunion.
    $meeting = Get-TdNextMeeting -State (Get-TdState) -NowMs $NowMs
    if ($meeting) {
        $panelEls.MeetingLabel.Text = 'Prochaine réunion : '
        $panelEls.MeetingWhat.Text = [string]$meeting.text
        $panelEls.MeetingDelay.Text = ' (' + $meeting.delay + ')'
    }
    else {
        $panelEls.MeetingLabel.Text = 'Pas de réunion à heure fixe à venir aujourd''hui.'
        $panelEls.MeetingWhat.Text = ''
        $panelEls.MeetingDelay.Text = ''
    }
}

function New-TdCockpitProjectRow {
    # Une ligne de projet : nom et avancement, puis jalon, échéance, blocage ou alerte « pas bougé ».
    # -Short : résumé d'une ligne (mode projet).
    param([Parameter(Mandatory)]$Item, [switch]$Short)
    $dot = ' ' + [char]0x00B7 + ' '
    $percent = [string][char]0x2014
    if ($null -ne $Item.percent) { $percent = "$($Item.percent) %" }

    $head = New-Object System.Windows.Controls.DockPanel
    if ($Short) {
        $right = $percent
        if ($Item.blocked) { $right += $dot + 'bloqué' }
        elseif ($Item.deadlineText) { $right += $dot + $Item.deadlineText }
        $side = New-TdCockpitText -Text $right -Brush 'CkMuted' -Margin '8,0,0,0'
    }
    else { $side = New-TdCockpitText -Text $percent -Size 15 -Bold -Brush 'CkProjects' -Margin '8,0,0,0' }
    [System.Windows.Controls.DockPanel]::SetDock($side, [System.Windows.Controls.Dock]::Right)
    [void]$head.Children.Add($side)
    $name = New-TdCockpitText -Text ([string]$Item.name) -Size 15 -Bold
    $name.ToolTip = [string]$Item.name
    [void]$head.Children.Add($name)

    $stack = New-Object System.Windows.Controls.StackPanel
    [void]$stack.Children.Add($head)
    if (-not $Short) {
        # Deuxième ligne : la partie « alerte » en couleur, le reste en gris.
        $detail = New-Object System.Windows.Controls.TextBlock
        $detail.FontSize = 12
        $detail.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $detail.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
        $rest = [string]$Item.detailText
        if ($Item.alertText) {
            $alert = New-Object System.Windows.Documents.Run ([string]$Item.alertText)
            $alert.Foreground = Get-TdCockpitBrush 'CkAlert'
            [void]$detail.Inlines.Add([System.Windows.Documents.Inline]$alert)
            if ($rest) { $rest = $dot + $rest }
        }
        $muted = New-Object System.Windows.Documents.Run $rest
        $muted.Foreground = Get-TdCockpitBrush 'CkMuted'
        [void]$detail.Inlines.Add([System.Windows.Documents.Inline]$muted)
        [void]$stack.Children.Add($detail)
    }
    # Un trait fin sépare les projets.
    $row = New-Object System.Windows.Controls.Border
    $row.BorderBrush = Get-TdCockpitBrush 'CkLine'
    $row.BorderThickness = New-Object System.Windows.Thickness 0, 1, 0, 0
    $row.Padding = New-Object System.Windows.Thickness 0, 8, 0, 8
    $row.Child = $stack
    $row
}

function New-TdFollowUpRow {
    # Une relance : étiquette TICKET (bleu) ou PROJET (orange), le texte, et le bouton « Relancé ».
    param([Parameter(Mandatory)]$Item)
    $row = New-Object System.Windows.Controls.DockPanel
    $row.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
    $command = "followup|$($Item.id)"
    $word = 'TICKET'
    $brush = 'CkTickets'
    if ($Item.kind -eq 'project') { $command = "project-followup|$($Item.id)"; $word = 'PROJET'; $brush = 'CkProjects' }
    $button = New-TdCockpitButton -Text 'Relancé' -Command $command -ToolTip 'Relance faite : la prochaine est prévue le prochain jour ouvré' -Margin '8,0,0,0'
    [System.Windows.Controls.DockPanel]::SetDock($button, [System.Windows.Controls.Dock]::Right)
    [void]$row.Children.Add($button)

    $pill = New-Object System.Windows.Controls.Border
    $pill.Background = Get-TdCockpitBrush $brush
    $pill.CornerRadius = New-Object System.Windows.CornerRadius 6
    $pill.Padding = New-Object System.Windows.Thickness 6, 1, 6, 1
    $pill.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
    $pill.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $label = New-TdCockpitText -Text $word -Size 10 -Brush 'CkBg'
    $label.FontWeight = [System.Windows.FontWeights]::Bold
    $pill.Child = $label
    [System.Windows.Controls.DockPanel]::SetDock($pill, [System.Windows.Controls.Dock]::Left)
    [void]$row.Children.Add($pill)

    $text = New-TdCockpitText -Text ([string]$Item.text) -Wrap
    $text.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [void]$row.Children.Add($text)
    $row
}

# ---------------------------------------------------------------- mode projet

function Update-TdCockpitMode {
    # Choisit ce qui s'affiche : mode normal (tickets en entier) ou mode projet (bloc en grand, tickets en une ligne).
    # -Block : le bloc projet en cours (Get-TdProjectBlockInfo), ou $null. -Counts : les compteurs des tickets.
    param([Parameter(Mandatory)][long]$NowMs, $Block, [Parameter(Mandatory)]$Counts)
    $ck = $script:Td.Cockpit
    $panelEls = $ck.PanelEls
    $projectMode = $null -ne $Block
    if (-not $projectMode) { $ck.Interrupted = $false; $ck.BlockNote = $false }
    elseif ($Block.running) { $ck.Interrupted = $false }

    Set-TdCockpitVisible $panelEls.ProjectModeCard $projectMode
    Set-TdCockpitVisible $panelEls.TicketsLine ($projectMode -and -not $ck.Interrupted)
    Set-TdCockpitVisible $panelEls.TicketsCard ((-not $projectMode) -or $ck.Interrupted)
    # Bordure orange pendant un bloc projet.
    $border = 'CkLine'
    if ($projectMode) { $border = 'CkProjects' }
    $panelEls.PanelRoot.BorderBrush = Get-TdCockpitBrush $border

    # Bloc planifié dont l'heure est arrivée : une invitation, avec un signal doux (une seule fois).
    $due = $null
    if (-not $projectMode) { $due = Get-TdDueProjectBlock -State (Get-TdState) -NowMs $NowMs }
    Set-TdCockpitVisible $panelEls.BlockBanner ($null -ne $due)
    if ($due) {
        # Déjà commencé puis interrompu : on propose de le reprendre.
        $started = [long]$due.elapsedMs -gt 0
        $bannerTitle = "C'EST L'HEURE DU BLOC PROJET"
        $bannerButton = 'Commencer'
        if ($started) { $bannerTitle = 'BLOC PROJET EN PAUSE'; $bannerButton = 'Reprendre' }
        $panelEls.BlockBannerTitle.Text = $bannerTitle
        $panelEls.BtnBlockStart.Content = [string]$bannerButton
        $panelEls.BlockBannerText.Text = [string]$due.title
        $panelEls.BlockBannerSlot.Text = Format-TdBlockSlot -Task $due -NowMs $NowMs
        if ($ck.BlockSignalId -ne $due.id) {
            $ck.BlockSignalId = $due.id
            $settings = Get-TdSettings
            if ($settings.timeUpSignal) { Invoke-TdSoundEffect -Name 'landing' -Volume $settings.effectsVolume }
            if ($settings.notifications -and -not $ck.Panel.IsVisible) {
                Show-TdTrayBalloon -Text ('C''est l''heure du bloc projet « {0} ».' -f (Limit-TdText $due.title 50))
            }
        }
    }
    if (-not $projectMode) { return }

    # Tickets en une ligne : « Tickets · 7 ouverts · 1 urgent ».
    $dot = ' ' + [char]0x00B7 + ' '
    $open = "$($Counts.open) ouverts"
    if ($Counts.open -le 1) { $open = "$($Counts.open) ouvert" }
    $panelEls.TicketsLineText.Text = $dot + $open
    $urgent = ''
    if ($Counts.urgent -eq 1) { $urgent = $dot + '1 urgent' }
    elseif ($Counts.urgent -gt 1) { $urgent = $dot + "$($Counts.urgent) urgents" }
    $panelEls.TicketsLineUrgent.Text = $urgent

    # Le bloc en grand.
    $panelEls.BlockSlot.Text = 'BLOC PROJET ' + [char]0x00B7 + ' ' + $Block.slotText
    $panelEls.BlockName.Text = [string]$Block.name
    $steps = @($Block.task.steps | Where-Object { $_ })
    $stepText = 'Avancer sur le projet'
    if ($Block.currentStep) { $stepText = [string]$Block.currentStep.title }
    elseif ($steps.Count -gt 0) { $stepText = 'Tous les pas de ce bloc sont faits.' }
    $panelEls.BlockStep.Text = $stepText
    $list = $panelEls.BlockChecklist
    $list.Children.Clear()
    foreach ($step in $steps) { [void]$list.Children.Add((New-TdBlockCheck -Step $step)) }
    Set-TdCockpitVisible $panelEls.BlockCrumbBox ([bool]$Block.breadcrumb)
    $panelEls.BlockCrumb.Text = [string]$Block.breadcrumb
    Set-TdCockpitVisible $panelEls.BlockNoteForm ([bool]$ck.BlockNote)

    $word = 'Démarrer'
    if ($Block.running) { $word = 'Pause' }
    elseif ([long]$Block.task.elapsedMs -gt 0) { $word = 'Reprendre' }
    $panelEls.BtnBlockToggle.Content = [string]$word
    $stepWord = 'Étape faite'
    if (-not $Block.currentStep) { $stepWord = 'Terminer le bloc' }
    $panelEls.BtnBlockStep.Content = [string]$stepWord
    # Un seul bouton en avant : « Démarrer / Reprendre » à l'arrêt, « Étape faite » quand le minuteur tourne.
    Set-TdCockpitAccent -Button $panelEls.BtnBlockToggle -On (-not $Block.running) -Brush 'CkProjects'
    Set-TdCockpitAccent -Button $panelEls.BtnBlockStep -On ([bool]$Block.running) -Brush 'CkProjects'
    $ck.BlockText = ''
    Update-TdBlockChrono -NowMs $NowMs
}

function New-TdBlockCheck {
    # Une ligne de la checklist : une vraie case à cocher. Un pas fait est barré et grisé.
    param([Parameter(Mandatory)]$Step)
    $check = New-Object System.Windows.Controls.CheckBox
    $check.Style = [System.Windows.Style]$script:Td.Cockpit.Panel.FindResource('CkCheck')
    $brush = 'CkText'
    if ($Step.done) { $brush = 'CkMuted' }
    $text = New-TdCockpitText -Text ([string]$Step.title) -Size 15 -Brush $brush -Wrap
    if ($Step.done) { $text.TextDecorations = [System.Windows.TextDecorations]::Strikethrough }
    $check.Content = [System.Windows.UIElement]$text
    $check.IsChecked = [bool]$Step.done
    $check.Tag = [string]$Step.id
    $check.Add_Click({ param($s, $e) Set-TdBlockStepDone -StepId ([string]$s.Tag) -Done ([bool]$s.IsChecked) })
    $check
}

function Set-TdBlockStepDone {
    # Coche ou décoche un pas du bloc ; le projet suit (comme dans TDfocus).
    param([Parameter(Mandatory)][string]$StepId, [bool]$Done)
    $task = Get-TdCurrentTask (Get-TdState)
    if (-not $task -or -not $task.projectId) { return }
    foreach ($step in @($task.steps)) { if ($step -and $step.id -eq $StepId) { $step.done = $Done } }
    if (Sync-TdProjectFromTask -Projects $script:Td.Data.projects -Task $task) { Save-TdProjectsNow }
    Complete-TdChange
}

function Update-TdBlockChrono {
    # « Reste 52 min » et la barre du bloc. Appelée 4 fois par seconde : ne redessine que si le texte a changé.
    param([Parameter(Mandatory)][long]$NowMs)
    $ck = $script:Td.Cockpit
    $block = Get-TdProjectBlockInfo -State (Get-TdState) -Projects $script:Td.Data.projects -NowMs $NowMs
    if (-not $block) { return }
    if ($block.remainingText -eq $ck.BlockText) { return }
    $ck.BlockText = $block.remainingText
    $panelEls = $ck.PanelEls
    $panelEls.BlockRemaining.Text = [string]$block.remainingText
    $color = 'CkProjects'
    if ($block.over) { $color = 'CkAlert' }
    $panelEls.BlockRemaining.Foreground = Get-TdCockpitBrush $color
    $panelEls.BlockBarFill.Background = Get-TdCockpitBrush $color
    $ratio = [double]$block.ratio
    $panelEls.BlockBarDone.Width = [System.Windows.GridLength]::new($ratio, [System.Windows.GridUnitType]::Star)
    $panelEls.BlockBarLeft.Width = [System.Windows.GridLength]::new(1 - $ratio, [System.Windows.GridUnitType]::Star)
}

function Start-TdDueBlock {
    # « Commencer » : le bloc planifié devient la tâche en cours de TDfocus et son minuteur démarre.
    $task = Get-TdDueProjectBlock -State (Get-TdState) -NowMs (Get-TdNowMs)
    if ($task) { Start-TdTaskNowById -Id ([string]$task.id) }
}

function Complete-TdBlockStep {
    # « Étape faite » : même geste que dans TDfocus. S'il n'y a plus de pas : « Terminer le bloc ».
    $task = Get-TdCurrentTask (Get-TdState)
    if (-not $task -or -not $task.projectId) { return }
    if (Get-TdCurrentStep $task) { Complete-TdStepNow } else { Complete-TdCurrentNow }
}

function Invoke-TdCockpitInterrupt {
    # « Interrompre » : le bloc projet se met en pause, la note de reprise s'ouvre, les tickets réapparaissent.
    $ck = $script:Td.Cockpit
    $panelEls = $ck.PanelEls
    $state = Get-TdState
    $now = Get-TdNowMs
    $block = Get-TdProjectBlockInfo -State $state -Projects $script:Td.Data.projects -NowMs $now
    if (-not $block) { return }
    if ($block.running) { Suspend-TdTimer -State $state -NowMs $now }
    $ck.Interrupted = $true
    $ck.BlockNote = $true
    $ck.ListKind = 'open'
    $panelEls.BlockNoteBox.Text = [string]$block.breadcrumb
    Complete-TdChange
    [void]$ck.Panel.Activate()
    [void]$panelEls.BlockNoteBox.Focus()
    $panelEls.BlockNoteBox.SelectAll()
}

function Save-TdBlockNote {
    # Enregistre la note de reprise sur le projet (la même note « Où j'en étais » que dans TDfocus).
    $ck = $script:Td.Cockpit
    $task = Get-TdCurrentTask (Get-TdState)
    $project = $null
    if ($task) { $project = Find-TdProject $script:Td.Data.projects $task.projectId }
    if ($project) {
        Set-TdProjectBreadcrumb -Project $project -Text $ck.PanelEls.BlockNoteBox.Text -NowMs (Get-TdNowMs)
        Save-TdProjectsNow
    }
    $ck.BlockNote = $false
    Update-TdView
}

function Hide-TdBlockNote {
    $script:Td.Cockpit.BlockNote = $false
    Update-TdCockpit -NowMs (Get-TdNowMs) -Force
}

# ---------------------------------------------------------------- « Où j'en étais » et « Récap du jour »

function Switch-TdCockpitInfo {
    # Ouvre le panneau demandé ('where' ou 'recap') ; un second clic, ou « Fermer », le referme.
    param([string]$Kind)
    $ck = $script:Td.Cockpit
    if (-not $Kind -or $ck.InfoKind -eq $Kind) { $ck.InfoKind = $null } else { $ck.InfoKind = $Kind }
    Update-TdCockpit -NowMs (Get-TdNowMs) -Force
}

function Update-TdCockpitInfo {
    param([Parameter(Mandatory)][long]$NowMs)
    $ck = $script:Td.Cockpit
    $panelEls = $ck.PanelEls
    $kind = $ck.InfoKind
    # Le bouton du panneau ouvert est mis en avant.
    foreach ($pair in @(@('where', $panelEls.BtnWhere), @('recap', $panelEls.BtnRecap))) {
        if ($kind -eq $pair[0]) { Set-TdCockpitAccent -Button $pair[1] -On $true }
        else {
            $pair[1].Background = Get-TdCockpitBrush 'CkCard'
            $pair[1].Foreground = Get-TdCockpitBrush 'CkText'
        }
    }
    Set-TdCockpitVisible $panelEls.InfoOverlay ([bool]$kind)
    if (-not $kind) { return }
    $state = Get-TdState
    if ($kind -eq 'where') {
        $panelEls.InfoTitle.Text = "OÙ J'EN ÉTAIS"
        $lines = @(Get-TdWhereWasI -State $state -Projects $script:Td.Data.projects -NowMs $NowMs)
    }
    else {
        $panelEls.InfoTitle.Text = 'RÉCAP DU JOUR'
        $lines = @(Get-TdDayRecap -State $state -Projects $script:Td.Data.projects -NowMs $NowMs -TicketShare ([int](Get-TdSettings).cockpit.ticketShare))
    }
    $list = $panelEls.InfoList
    $list.Children.Clear()
    foreach ($line in $lines) {
        [void]$list.Children.Add((New-TdCockpitText -Text ([string]$line.title) -Size 15 -Bold -Wrap -Margin '0,8,0,0'))
        [void]$list.Children.Add((New-TdCockpitText -Text ([string]$line.text) -Brush 'CkMuted' -Wrap -Margin '0,2,0,0'))
    }
}
