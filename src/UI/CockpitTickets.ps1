# TDfocus - cockpit flottant : la carte « Tickets ».
#
# Il n'y a pas de liste de tickets à part : la carte lit ta liste TDfocus (voir
# src\Core\Tickets.ps1). Un ticket = une action de la liste, sauf blocs projet et pauses.
# Chaque bouton du cockpit fait exactement le même geste que dans TDfocus :
#   Démarrer / Pause   le bouton Démarrer / Pause de TDfocus (Switch-TdTimerNow)
#   Fermer             valider la tâche (Complete-TdCurrentNow)
#   Traiter            « démarrer maintenant » (Start-TdTaskNowById)
#   + Ticket           ajouter une action à la liste, avec la même saisie rapide
# Seul « Escalader » est propre au cockpit : le ticket attend quelqu'un d'autre et reviendra
# dans la liste le prochain jour ouvré, marqué « à relancer ».
#
# Dans $script:Td.Cockpit, la carte Tickets utilise :
#   ListKind       la tuile dont la liste est ouverte : 'open', 'closed', 'waiting', ou $null
#   Undo           de quoi annuler la dernière action (voir Invoke-TdTicketAction), ou $null
#   MessageUntil   heure à laquelle le message du bas de la carte disparaît
#   Chrono         le dernier chrono affiché (pour ne redessiner que quand il change)
#   AlertId, AlertElapsed   dernière mesure du ticket en cours (pour l'alerte à la limite)

function Register-TdCockpitTicketEvents {
    $panelEls = $script:Td.Cockpit.PanelEls

    # Ajouter une action à la liste TDfocus.
    $panelEls.BtnAddTicket.Add_Click({ Switch-TdTicketForm })
    $panelEls.BtnAddConfirm.Add_Click({ Add-TdCockpitTicket })
    $panelEls.BtnAddCancel.Add_Click({ Hide-TdTicketForm })
    $panelEls.TicketBox.Add_TextChanged({ Update-TdTicketFormHint })
    $panelEls.TicketBox.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Return) { Add-TdCockpitTicket; $e.Handled = $true }
            elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) { Hide-TdTicketForm; $e.Handled = $true }
        })

    # Tuiles : un clic ouvre (ou referme) la liste correspondante.
    $panelEls.TileOpen.Add_Click({ Switch-TdTicketList -Kind 'open' })
    $panelEls.TileClosed.Add_Click({ Switch-TdTicketList -Kind 'closed' })
    $panelEls.TileWaiting.Add_Click({ Switch-TdTicketList -Kind 'waiting' })

    # Ticket en cours = tâche en cours de TDfocus.
    $panelEls.BtnTicketToggle.Add_Click({ Switch-TdTimerNow })
    $panelEls.BtnTicketEscalate.Add_Click({ Invoke-TdTicketAction -Kind 'escalate' -Id (Get-TdCurrentTicketId) })
    $panelEls.BtnTicketClose.Add_Click({ Invoke-TdTicketAction -Kind 'close' -Id (Get-TdCurrentTicketId) })

    $panelEls.BtnTicketUndo.Add_Click({ Undo-TdTicketAction })
}

function Get-TdCurrentTicketId {
    $ticket = Get-TdCurrentTicket (Get-TdState)
    if ($ticket) { return [string]$ticket.id }
    ''
}

# ---------------------------------------------------------------- petits outils d'affichage

function Get-TdCockpitBrush {
    # Une couleur du cockpit par son nom : CkText, CkMuted, CkTickets, CkProjects, CkAlert… (voir CockpitPanel.xaml).
    param([Parameter(Mandatory)][string]$Key)
    $script:Td.Cockpit.Panel.FindResource($Key)
}

function Set-TdCockpitVisible {
    param([Parameter(Mandatory)]$Element, [bool]$Visible)
    if ($Visible) { $Element.Visibility = [System.Windows.Visibility]::Visible }
    else { $Element.Visibility = [System.Windows.Visibility]::Collapsed }
}

function Set-TdCockpitAccent {
    # Met un bouton en avant (fond de couleur, texte sombre) ou le rend neutre : un seul bouton en avant à la fois.
    param([Parameter(Mandatory)]$Button, [bool]$On, [string]$Brush = 'CkTickets')
    if ($On) {
        $Button.Background = Get-TdCockpitBrush $Brush
        $Button.Foreground = Get-TdCockpitBrush 'CkBg'
    }
    else {
        $Button.Background = Get-TdCockpitBrush 'CkButtonBg'
        $Button.Foreground = Get-TdCockpitBrush 'CkText'
    }
}

function New-TdCockpitText {
    param([string]$Text = '', [double]$Size = 14, [string]$Brush = 'CkText', [switch]$Bold, [switch]$Wrap, [string]$Margin = '0')
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.FontSize = $Size
    $block.Foreground = Get-TdCockpitBrush $Brush
    if ($Bold) { $block.FontWeight = [System.Windows.FontWeights]::SemiBold }
    if ($Wrap) { $block.TextWrapping = [System.Windows.TextWrapping]::Wrap }
    else { $block.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis }
    $block.Margin = [System.Windows.Thickness](ConvertTo-TdThickness $Margin)
    $block
}

function New-TdCockpitButton {
    # Un bouton créé par le code (lignes de liste). Au clic, la commande rangée dans Tag est exécutée
    # par Invoke-TdCockpitCommand : « action|identifiant », par exemple « close|a1b2c3 ».
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Command, [string]$ToolTip, [string]$Margin = '0')
    $button = New-Object System.Windows.Controls.Button
    $button.Style = [System.Windows.Style]$script:Td.Cockpit.Panel.FindResource('CkButton')
    $button.Content = [string]$Text
    $button.Tag = [string]$Command
    $button.Padding = New-Object System.Windows.Thickness 12, 0, 12, 0
    $button.Margin = [System.Windows.Thickness](ConvertTo-TdThickness $Margin)
    if ($ToolTip) { $button.ToolTip = [string]$ToolTip }
    $button.Add_Click({ param($s, $e) Invoke-TdCockpitCommand -Command ([string]$s.Tag) })
    $button
}

function Invoke-TdCockpitCommand {
    # Exécute la commande d'un bouton de liste. Les commandes des tickets sont décrites dans
    # Invoke-TdTicketAction ; celles des projets et des relances dans CockpitProjects.ps1.
    param([Parameter(Mandatory)][string]$Command)
    $parts = $Command.Split('|')
    $id = ''
    if ($parts.Count -gt 1) { $id = $parts[1] }
    if ($parts[0] -like 'project-*') { Invoke-TdCockpitProjectAction -Kind $parts[0] -Id $id }
    else { Invoke-TdTicketAction -Kind $parts[0] -Id $id }
}

# ---------------------------------------------------------------- ajouter une action

function Switch-TdTicketForm {
    if ($script:Td.Cockpit.PanelEls.AddForm.IsVisible) { Hide-TdTicketForm } else { Show-TdTicketForm }
}

function Show-TdTicketForm {
    $panelEls = $script:Td.Cockpit.PanelEls
    $panelEls.TicketBox.Text = ''
    $panelEls.TicketUrgent.IsChecked = $false
    Set-TdCockpitVisible $panelEls.AddForm $true
    Update-TdTicketFormHint
    [void]$script:Td.Cockpit.Panel.Activate()
    [void]$panelEls.TicketBox.Focus()
}

function Hide-TdTicketForm {
    Set-TdCockpitVisible $script:Td.Cockpit.PanelEls.AddForm $false
}

function Update-TdTicketFormHint {
    # L'indication grise disparaît dès qu'on écrit.
    $panelEls = $script:Td.Cockpit.PanelEls
    Set-TdCockpitVisible $panelEls.TicketBoxHint ($panelEls.TicketBox.Text -eq '')
}

function Add-TdCockpitTicket {
    # « Ajouter » (ou Entrée) : l'action rejoint ta liste TDfocus, avec la même saisie rapide
    # que dans TDfocus (« INC-4821 VPN 20 », « !! » pour une urgence).
    $panelEls = $script:Td.Cockpit.PanelEls
    $parsed = ConvertFrom-TdQuickInput $panelEls.TicketBox.Text
    if (-not $parsed.title) {
        [void]$panelEls.TicketBox.Focus()
        return
    }
    $minutes = $parsed.minutes
    if (-not $minutes) { $minutes = (Get-TdSettings).defaultMinutes }
    $urgent = [bool]$parsed.urgent -or [bool]$panelEls.TicketUrgent.IsChecked
    $now = Get-TdNowMs
    $task = New-TdTask -Title $parsed.title -Minutes ([double]$minutes) -FixedStart $parsed.fixedStart -Urgent:$urgent -NowMs $now
    Add-TdTask -State (Get-TdState) -Task $task -NowMs $now
    Hide-TdTicketForm
    Set-TdTicketMessage -Text ('Ajouté à ta liste TDfocus : ' + $task.title) -Undo @{ Kind = 'add'; Id = $task.id }
    Complete-TdChange -Replan
    # Si c'est devenu la tâche en cours, « Démarrer » est prêt : une seconde pression sur Entrée lance le minuteur.
    if ((Get-TdCurrentTicketId) -eq $task.id) { [void]$panelEls.BtnTicketToggle.Focus() }
}

# ---------------------------------------------------------------- actions

function Invoke-TdTicketAction {
    # Une action sur un ticket, depuis le ticket en cours ou depuis une liste :
    #   start      « Traiter » : il devient la tâche en cours de TDfocus et le minuteur démarre
    #   close      « Fermer » : la tâche est validée dans TDfocus
    #   escalate   « Escalader » : en attente de quelqu'un, il reviendra le prochain jour ouvré
    #   followup   « Relancé » : la relance est faite, la suivante est repoussée
    #   resume     « Reprendre » : il n'est plus à relancer, il redevient la tâche en cours
    #   reopen     « Rouvrir » : une tâche validée aujourd'hui revient dans la liste
    param([Parameter(Mandatory)][string]$Kind, [string]$Id)
    if (-not $Id) { return }
    $state = Get-TdState
    $now = Get-TdNowMs
    $found = Find-TdTask $state $Id
    $task = $null
    if ($found) { $task = $found.task }
    else {
        $aside = Find-TdParkedTask $state $Id
        if ($aside) { $task = $aside.task }
    }
    if (-not $task) { return }
    $title = Limit-TdText $task.title 60
    switch ($Kind) {
        'start' {
            Hide-TdTicketMessage
            Start-TdTaskNowById -Id $Id
        }
        'close' {
            # Un ticket mis de côté revient d'abord dans la liste, puis il est validé comme n'importe quelle tâche.
            [void](Restore-TdTicket -State $state -Id $Id -Index $state.tasks.Count -NowMs $now)
            Set-TdTicketMessage -Text "Fermé : $title" -Undo @{ Kind = 'close'; Id = $Id }
            Complete-TdCurrentNow -Id $Id
        }
        'escalate' {
            if (-not $found -or $found.list -ne 'tasks') { return }
            $undo = @{ Kind = 'escalate'; Id = $Id; Index = $found.index; Running = ($null -ne $task.runningSince) }
            [void](Set-TdTicketEscalated -State $state -Id $Id -NowMs $now -KeepRunning:([bool](Get-TdSettings).autoStartNext))
            $script:Td.NoteOpen = $false
            Set-TdTicketMessage -Text ("Escaladé : $title (" + (Format-TdFollowUp -DateKey $task.deferUntil -NowMs $now) + ')') -Undo $undo
            Complete-TdChange -Replan
        }
        'followup' {
            [void](Set-TdTicketFollowUp -State $state -Id $Id -NowMs $now -KeepRunning:([bool](Get-TdSettings).autoStartNext))
            Set-TdTicketMessage -Text ("Relance notée : $title (" + (Format-TdFollowUp -DateKey $task.deferUntil -NowMs $now) + ')')
            Complete-TdChange -Replan
        }
        'resume' {
            [void](Resume-TdTicket -State $state -Id $Id -NowMs $now)
            $script:Td.NoteOpen = $false
            Set-TdTicketMessage -Text "Repris : $title"
            Complete-TdChange -Replan
        }
        'reopen' {
            Set-TdTicketMessage -Text "Rouvert : $title"
            Undo-TdCompleteNow -Id $Id
        }
    }
}

function Undo-TdTicketAction {
    # Bouton « Annuler » du cockpit : défait la dernière action (ajout, fermeture ou escalade).
    $ck = $script:Td.Cockpit
    $undo = $ck.Undo
    if (-not $undo) { return }
    $state = Get-TdState
    $now = Get-TdNowMs
    Set-TdTicketMessage -Text 'Annulé.' -Seconds 3
    switch ($undo.Kind) {
        'add' {
            [void](Remove-TdTask -State $state -Id $undo.Id -NowMs $now)
            Complete-TdChange -Replan
        }
        'close' { Undo-TdCompleteNow -Id $undo.Id }
        'escalate' {
            [void](Restore-TdTicket -State $state -Id $undo.Id -Index ([int]$undo.Index) -NowMs $now)
            # Son minuteur tournait avant l'escalade : il repart (si c'est bien la tâche en cours).
            if ($undo.Running -and $state.tasks.Count -gt 0 -and $state.tasks[0].id -eq $undo.Id) { Start-TdTimer $state $now }
            Complete-TdChange -Replan
        }
    }
}

# ---------------------------------------------------------------- message du bas de la carte

function Set-TdTicketMessage {
    # Dit ce qui vient de se passer. Avec -Undo, le bouton « Annuler » reste disponible quelques secondes.
    param([Parameter(Mandatory)][string]$Text, $Undo, [int]$Seconds = 8)
    $ck = $script:Td.Cockpit
    $panelEls = $ck.PanelEls
    $ck.Undo = $Undo
    $ck.MessageUntil = (Get-TdNowMs) + $Seconds * 1000
    $panelEls.TicketMessageText.Text = $Text
    Set-TdCockpitVisible $panelEls.BtnTicketUndo ($null -ne $Undo)
    Set-TdCockpitVisible $panelEls.TicketMessage $true
}

function Hide-TdTicketMessage {
    $ck = $script:Td.Cockpit
    $ck.Undo = $null
    $ck.MessageUntil = 0
    Set-TdCockpitVisible $ck.PanelEls.TicketMessage $false
}

function Send-TdTicketAlert {
    # Le ticket en cours vient d'atteindre la limite : signal doux, une seule fois, jamais bloquant.
    param([Parameter(Mandatory)]$Task)
    $settings = Get-TdSettings
    $minutes = [int]$settings.cockpit.ticketAlertMinutes
    if ($settings.timeUpSignal) { Invoke-TdSoundEffect -Name 'timeup' -Volume $settings.effectsVolume }
    if ($settings.notifications -and -not $script:Td.Cockpit.Panel.IsVisible) {
        Show-TdTrayBalloon -Text ('{0} min sur « {1} ». Escalader, ou continuer ?' -f $minutes, (Limit-TdText $Task.title 60))
    }
}

# ---------------------------------------------------------------- affichage

function Update-TdCockpitTickets {
    # Redessine la carte Tickets (tuiles, ticket en cours, liste ouverte) à partir de la liste TDfocus.
    # -Counts : les compteurs (Get-TdTicketCounts).
    param([Parameter(Mandatory)][long]$NowMs, [Parameter(Mandatory)]$Counts)
    $ck = $script:Td.Cockpit
    $panelEls = $ck.PanelEls
    $state = Get-TdState
    $counts = $Counts

    # Tuiles : un chiffre à zéro reste gris (rien à signaler).
    Set-TdTicketTile -Block $panelEls.TileOpenCount -Count $counts.open -Brush 'CkTickets'
    Set-TdTicketTile -Block $panelEls.TileClosedCount -Count $counts.closedToday -Brush 'CkText'
    $waitingBrush = 'CkText'
    if ($counts.followUpDue -gt 0) { $waitingBrush = 'CkProjects' }
    Set-TdTicketTile -Block $panelEls.TileWaitingCount -Count $counts.waiting -Brush $waitingBrush
    Set-TdCockpitVisible $panelEls.TileWaitingDot ($counts.followUpDue -gt 0)
    # Accord : « 1 ouvert », « 2 ouverts ».
    $panelEls.TileOpenLabel.Text = 'ouvert'
    if ($counts.open -gt 1) { $panelEls.TileOpenLabel.Text = 'ouverts' }
    $panelEls.TileClosedLabel.Text = "fermé aujourd'hui"
    if ($counts.closedToday -gt 1) { $panelEls.TileClosedLabel.Text = "fermés aujourd'hui" }
    $urgent = ''
    if ($counts.urgent -eq 1) { $urgent = ' ' + [char]0x00B7 + ' 1 urgent' }
    elseif ($counts.urgent -gt 1) { $urgent = ' ' + [char]0x00B7 + " $($counts.urgent) urgents" }
    $panelEls.TileOpenUrgent.Text = $urgent
    # La tuile dont la liste est ouverte garde un contour bleu.
    foreach ($pair in @(@('open', $panelEls.TileOpen), @('closed', $panelEls.TileClosed), @('waiting', $panelEls.TileWaiting))) {
        if ($ck.ListKind -eq $pair[0]) { $pair[1].BorderBrush = Get-TdCockpitBrush 'CkTickets' }
        else { $pair[1].BorderBrush = [System.Windows.Media.Brushes]::Transparent }
    }

    # Ticket en cours = tâche en cours de TDfocus, si ce n'est ni un bloc projet ni une pause.
    $ticket = Get-TdCurrentTicket $state
    Set-TdCockpitVisible $panelEls.CurrentBox ($null -ne $ticket)
    Set-TdCockpitVisible $panelEls.NoTicketText ($null -eq $ticket)
    if ($ticket) {
        $panelEls.CurrentRef.Text = [string]$ticket.title
        $panelEls.CurrentRef.ToolTip = [string]$ticket.title
        Set-TdCockpitVisible $panelEls.CurrentUrgent ([bool]$ticket.urgent)
        Set-TdCockpitVisible $panelEls.CurrentWaiting ($null -ne $ticket.waitingSince)
        $running = $null -ne $ticket.runningSince
        $word = 'Démarrer'
        if ($running) { $word = 'Pause' }
        elseif ([long]$ticket.elapsedMs -gt 0) { $word = 'Reprendre' }
        $panelEls.BtnTicketToggle.Content = [string]$word
        # Un seul bouton en avant : « Démarrer / Reprendre » à l'arrêt, « Fermer » quand le minuteur tourne.
        Set-TdCockpitAccent -Button $panelEls.BtnTicketToggle -On (-not $running)
        Set-TdCockpitAccent -Button $panelEls.BtnTicketClose -On $running
    }
    else {
        $current = Get-TdCurrentTask $state
        $text = 'Aucune action en cours. Note-la dans TDfocus, ou « + Ticket ».'
        if ($current -and $current.projectId) { $text = 'En ce moment dans TDfocus : bloc projet « {0} ».' -f (Limit-TdText $current.title 40) }
        elseif ($current) { $text = 'En ce moment dans TDfocus : pause.' }
        $panelEls.NoTicketText.Text = $text
    }
    $ck.Chrono = ''
    Update-TdTicketChrono -NowMs $NowMs
    Update-TdTicketListView -NowMs $NowMs
}

function Set-TdTicketTile {
    param([Parameter(Mandatory)]$Block, [int]$Count, [string]$Brush)
    $Block.Text = [string]$Count
    if ($Count -le 0) { $Brush = 'CkMuted' }
    $Block.Foreground = Get-TdCockpitBrush $Brush
}

function Update-TdTicketChrono {
    # Chrono, barre et alerte du ticket en cours. Appelée 4 fois par seconde : ne redessine que si le chrono a changé.
    param([Parameter(Mandatory)][long]$NowMs)
    $ck = $script:Td.Cockpit
    $ticket = Get-TdCurrentTicket (Get-TdState)
    if (-not $ticket) { return }
    $text = Format-TdTimer (Get-TdElapsedMs $ticket $NowMs)
    if ($text -eq $ck.Chrono) { return }
    $ck.Chrono = $text
    $panelEls = $ck.PanelEls
    $minutes = [int](Get-TdSettings).cockpit.ticketAlertMinutes
    $over = Test-TdTicketOverTime -Task $ticket -NowMs $NowMs -Minutes $minutes
    $panelEls.CurrentChrono.Text = $text
    $limit = "sur $minutes min"
    if ($null -eq $ticket.runningSince -and [long]$ticket.elapsedMs -gt 0) { $limit += ' ' + [char]0x00B7 + ' en pause' }
    $panelEls.CurrentLimit.Text = $limit
    # Barre : la partie pleine et la partie vide se partagent la largeur.
    $ratio = [double](Get-TdTicketProgress -Task $ticket -NowMs $NowMs -Minutes $minutes)
    $panelEls.BarDone.Width = [System.Windows.GridLength]::new($ratio, [System.Windows.GridUnitType]::Star)
    $panelEls.BarLeft.Width = [System.Windows.GridLength]::new(1 - $ratio, [System.Windows.GridUnitType]::Star)
    # Limite dépassée : couleur d'alerte et phrase fixe, sans clignotement.
    $color = 'CkTickets'
    $chronoColor = 'CkText'
    if ($over) { $color = 'CkAlert'; $chronoColor = 'CkAlert' }
    $panelEls.BarFill.Background = Get-TdCockpitBrush $color
    $panelEls.CurrentChrono.Foreground = Get-TdCockpitBrush $chronoColor
    $panelEls.CurrentAlert.Text = "$minutes min dépassées. Escalader, ou continuer ?"
    Set-TdCockpitVisible $panelEls.CurrentAlert $over
}

function Switch-TdTicketList {
    # Clic sur une tuile : ouvre sa liste ; un second clic la referme.
    param([Parameter(Mandatory)][string]$Kind)
    $ck = $script:Td.Cockpit
    if ($ck.ListKind -eq $Kind) { $ck.ListKind = $null } else { $ck.ListKind = $Kind }
    Update-TdCockpit -NowMs (Get-TdNowMs) -Force
}

function Update-TdTicketListView {
    param([Parameter(Mandatory)][long]$NowMs)
    $ck = $script:Td.Cockpit
    $panelEls = $ck.PanelEls
    $kind = $ck.ListKind
    if (-not $kind) {
        Set-TdCockpitVisible $panelEls.TicketListBox $false
        return
    }
    $titles = @{ open = 'OUVERTS'; closed = "FERMÉS AUJOURD'HUI"; waiting = 'À RELANCER' }
    $empty = @{ open = 'Aucune action ouverte dans ta liste TDfocus.'; closed = "Rien de fermé aujourd'hui pour l'instant."; waiting = 'Aucun ticket en attente.' }
    $panelEls.TicketListTitle.Text = [string]$titles[$kind]
    $rows = $panelEls.TicketList
    $rows.Children.Clear()
    $list = @(Get-TdTicketList -State (Get-TdState) -Kind $kind -NowMs $NowMs)
    if ($list.Count -eq 0) {
        [void]$rows.Children.Add((New-TdCockpitText -Text ([string]$empty[$kind]) -Brush 'CkMuted' -Wrap -Margin '0,6,0,0'))
    }
    # Dix lignes au plus : au-delà, la liste deviendrait un mur de texte.
    $max = 10
    for ($i = 0; $i -lt $list.Count -and $i -lt $max; $i++) {
        [void]$rows.Children.Add((New-TdTicketRow -Task $list[$i] -Kind $kind -NowMs $NowMs))
    }
    if ($list.Count -gt $max) {
        [void]$rows.Children.Add((New-TdCockpitText -Text ("… et {0} de plus (tout est dans TDfocus)" -f ($list.Count - $max)) -Size 12 -Brush 'CkMuted' -Margin '0,8,0,0'))
    }
    Set-TdCockpitVisible $panelEls.TicketListBox $true
}

function New-TdTicketRow {
    # Une ligne de liste : le titre, une précision en petit, et les boutons qui vont avec la tuile.
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][long]$NowMs)
    $id = [string]$Task.id
    $isCurrent = ((Get-TdCurrentTicketId) -eq $id)
    $spent = ''
    $elapsed = Get-TdElapsedMs $Task $NowMs
    if ($elapsed -ge 60000) { $spent = Format-TdDurationMs $elapsed }

    # Précision sous le titre, selon la liste.
    $details = @()
    $detailBrush = 'CkMuted'
    if ($Kind -eq 'open') {
        if ($Task.urgent) { $details += 'urgent'; $detailBrush = 'CkAlert' }
        if ($isCurrent) { $details += 'en cours' }
        if ($spent) { $details += $spent }
    }
    elseif ($Kind -eq 'closed') {
        $details += 'fermé à ' + (Format-TdClock ([long]$Task.completedAt))
        if ($spent) { $details += $spent }
    }
    else {
        $details += Format-TdFollowUp -DateKey $Task.deferUntil -NowMs $NowMs
        if (Test-TdTicketFollowUpDue -Task $Task -NowMs $NowMs) { $detailBrush = 'CkProjects' }
    }

    $texts = New-Object System.Windows.Controls.StackPanel
    $texts.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $name = New-TdCockpitText -Text ([string]$Task.title) -Bold:$isCurrent
    $name.ToolTip = [string]$Task.title
    [void]$texts.Children.Add($name)
    if ($details.Count -gt 0) {
        [void]$texts.Children.Add((New-TdCockpitText -Text ($details -join (' ' + [char]0x00B7 + ' ')) -Size 12 -Brush $detailBrush))
    }

    $row = New-Object System.Windows.Controls.DockPanel
    $row.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
    if ($Kind -eq 'waiting') {
        # Trois boutons : ils passent sous le titre, à largeur égale.
        $buttons = New-Object System.Windows.Controls.Primitives.UniformGrid
        $buttons.Rows = 1
        $buttons.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
        [void]$buttons.Children.Add((New-TdCockpitButton -Text 'Relancé' -Command "followup|$id" -ToolTip 'Relance faite : la prochaine est prévue le prochain jour ouvré' -Margin '0,0,6,0'))
        [void]$buttons.Children.Add((New-TdCockpitButton -Text 'Reprendre' -Command "resume|$id" -ToolTip 'Le ticket revient chez toi : il redevient la tâche en cours' -Margin '0,0,6,0'))
        [void]$buttons.Children.Add((New-TdCockpitButton -Text 'Fermer' -Command "close|$id" -ToolTip 'Ticket résolu'))
        [System.Windows.Controls.DockPanel]::SetDock($buttons, [System.Windows.Controls.Dock]::Bottom)
        [void]$row.Children.Add($buttons)
    }
    elseif ($Kind -eq 'closed' -or -not $isCurrent) {
        $button = $null
        if ($Kind -eq 'open') { $button = New-TdCockpitButton -Text 'Traiter' -Command "start|$id" -ToolTip 'Passer à cette action et démarrer le minuteur' -Margin '8,0,0,0' }
        else { $button = New-TdCockpitButton -Text 'Rouvrir' -Command "reopen|$id" -ToolTip 'Remettre cette action dans ta liste' -Margin '8,0,0,0' }
        [System.Windows.Controls.DockPanel]::SetDock($button, [System.Windows.Controls.Dock]::Right)
        [void]$row.Children.Add($button)
    }
    [void]$row.Children.Add($texts)    # le dernier élément d'un DockPanel occupe la place restante
    $row
}
