# TDfocus - cockpit flottant, étape 2 : la carte « Tickets ».
#
# Ce fichier ne fait qu'afficher et réagir aux clics. Tout ce qui touche aux tickets eux-mêmes
# (ajouter, fermer, escalader, compter, chrono…) passe par src\Core\Tickets.ps1, la « couche de
# données » : le jour où un outil de ticketing sera branché, ce fichier-ci ne changera pas.
#
# Dans $script:Td.Cockpit, la carte Tickets utilise :
#   ListKind       la tuile dont la liste est ouverte : 'open', 'closed', 'waiting', ou $null
#   Undo           de quoi annuler la dernière action (voir Invoke-TdTicketAction), ou $null
#   MessageUntil   heure à laquelle le message du bas de la carte disparaît
#   Chrono         le dernier chrono affiché (pour ne redessiner que quand il change)

function Save-TdTicketsNow {
    try { Save-TdTickets $script:Td.Data.tickets } catch { Write-TdLog "Sauvegarde des tickets impossible : $($_.Exception.Message)" }
}

function Register-TdCockpitTicketEvents {
    $panelEls = $script:Td.Cockpit.PanelEls

    # Ajouter un ticket.
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

    # Ticket en cours.
    $panelEls.BtnTicketToggle.Add_Click({ Switch-TdTicketChrono })
    $panelEls.BtnTicketEscalate.Add_Click({ Invoke-TdTicketAction -Kind 'escalate' -Id ([string]$script:Td.Data.tickets.currentId) })
    $panelEls.BtnTicketClose.Add_Click({ Invoke-TdTicketAction -Kind 'close' -Id ([string]$script:Td.Data.tickets.currentId) })

    $panelEls.BtnTicketUndo.Add_Click({ Undo-TdTicketAction })
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
    # Met un bouton en avant (fond bleu, texte sombre) ou le rend neutre : un seul bouton en avant à la fois.
    param([Parameter(Mandatory)]$Button, [bool]$On)
    if ($On) {
        $Button.Background = Get-TdCockpitBrush 'CkTickets'
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

function New-TdTicketButton {
    # Un bouton d'une ligne de liste. Au clic : Invoke-TdTicketAction avec l'action et le ticket rangés dans Tag.
    # -Name : nom lu par un lecteur d'écran quand le texte du bouton ne suffit pas (« × »).
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][string]$Id, [string]$ToolTip, [string]$Name, [string]$Margin = '0')
    $button = New-Object System.Windows.Controls.Button
    $button.Style = [System.Windows.Style]$script:Td.Cockpit.Panel.FindResource('CkButton')
    $button.Content = [string]$Text
    $button.Tag = [string]"$Action|$Id"
    $button.Padding = New-Object System.Windows.Thickness 12, 0, 12, 0
    $button.Margin = [System.Windows.Thickness](ConvertTo-TdThickness $Margin)
    if ($ToolTip) { $button.ToolTip = [string]$ToolTip }
    if ($Name) { [System.Windows.Automation.AutomationProperties]::SetName($button, $Name) }
    $button.Add_Click({
            param($s, $e)
            $parts = ([string]$s.Tag).Split('|')
            Invoke-TdTicketAction -Kind $parts[0] -Id $parts[1]
        })
    $button
}

# ---------------------------------------------------------------- ajouter un ticket

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
    # Bouton « Ajouter » (ou touche Entrée) : le ticket rejoint les « ouverts ».
    $panelEls = $script:Td.Cockpit.PanelEls
    $store = $script:Td.Data.tickets
    $now = Get-TdNowMs
    $ticket = New-TdTicket -Ref $panelEls.TicketBox.Text -Urgent:([bool]$panelEls.TicketUrgent.IsChecked) -NowMs $now
    Add-TdTicket -Store $store -Ticket $ticket
    Hide-TdTicketForm
    Set-TdTicketMessage -Text ('Ajouté : ' + (Get-TdTicketLabel $ticket)) -Undo @{ Kind = 'add'; Id = $ticket.id }
    Save-TdTicketsNow
    Update-TdCockpit -NowMs $now -Force
    # S'il est devenu le ticket en cours, « Démarrer » est prêt : une seconde pression sur Entrée lance le chrono.
    if ($store.currentId -eq $ticket.id) { [void]$panelEls.BtnTicketToggle.Focus() }
}

# ---------------------------------------------------------------- actions

function Switch-TdTicketChrono {
    # Bouton « Démarrer / Pause / Reprendre » du ticket en cours.
    $store = $script:Td.Data.tickets
    $now = Get-TdNowMs
    if (Test-TdTicketRunning $store) { Suspend-TdTicket -Store $store -NowMs $now }
    else { Start-TdTicket -Store $store -NowMs $now }
    Save-TdTicketsNow
    Update-TdCockpit -NowMs $now -Force
}

function Invoke-TdTicketAction {
    # Une action sur un ticket, depuis le ticket en cours ou depuis une liste :
    #   start      « Traiter » : il devient le ticket en cours et son chrono démarre
    #   close      « Fermer »
    #   escalate   « Escalader » : en attente de quelqu'un, à relancer le prochain jour ouvré
    #   followup   « Relancé » : la relance est faite, la suivante est repoussée
    #   reopen     « Rouvrir » : retour dans les ouverts
    #   resume     « Reprendre » : retour dans les ouverts, et le chrono démarre
    #   remove     « × » : ticket saisi par erreur
    param([Parameter(Mandatory)][string]$Kind, [string]$Id)
    $store = $script:Td.Data.tickets
    $now = Get-TdNowMs
    $ticket = Find-TdTicket $store $Id
    if (-not $ticket) { return }
    $label = Get-TdTicketLabel $ticket
    $index = 0
    for ($i = 0; $i -lt $store.items.Count; $i++) { if ($store.items[$i].id -eq $ticket.id) { $index = $i } }
    # De quoi annuler : l'état du ticket juste avant l'action.
    $undo = @{
        Kind = $Kind; Id = $ticket.id; Ticket = $ticket; Index = $index
        Status = $ticket.status; ClosedAt = $ticket.closedAt; EscalatedAt = $ticket.escalatedAt; FollowUpOn = $ticket.followUpOn
        CurrentId = $store.currentId; Running = ($null -ne $ticket.runningSince)
    }
    $message = ''
    switch ($Kind) {
        'start' {
            [void](Select-TdTicket -Store $store -Id $ticket.id -NowMs $now)
            Start-TdTicket -Store $store -NowMs $now
        }
        'close' {
            [void](Close-TdTicket -Store $store -Id $ticket.id -NowMs $now)
            $message = "Fermé : $label"
        }
        'escalate' {
            [void](Set-TdTicketEscalated -Store $store -Id $ticket.id -NowMs $now)
            $message = "Escaladé : $label (" + (Format-TdFollowUp -DateKey $ticket.followUpOn -NowMs $now) + ')'
        }
        'followup' {
            [void](Set-TdTicketFollowUp -Store $store -Id $ticket.id -NowMs $now)
            $message = "Relance notée : $label (" + (Format-TdFollowUp -DateKey $ticket.followUpOn -NowMs $now) + ')'
        }
        'reopen' {
            [void](Restore-TdTicket -Store $store -Id $ticket.id)
            $message = "Rouvert : $label"
        }
        'resume' {
            [void](Restore-TdTicket -Store $store -Id $ticket.id)
            [void](Select-TdTicket -Store $store -Id $ticket.id -NowMs $now)
            Start-TdTicket -Store $store -NowMs $now
            $message = "Repris : $label"
        }
        'remove' {
            Stop-TdTicketClock $ticket $now
            [void](Remove-TdTicket -Store $store -Id $ticket.id)
            $message = "Supprimé : $label"
        }
        default { return }
    }
    if ($message) { Set-TdTicketMessage -Text $message -Undo $undo } else { Hide-TdTicketMessage }
    Save-TdTicketsNow
    Update-TdCockpit -NowMs $now -Force
}

function Undo-TdTicketAction {
    # Bouton « Annuler » : le ticket retrouve l'état qu'il avait juste avant la dernière action.
    $ck = $script:Td.Cockpit
    $undo = $ck.Undo
    if (-not $undo) { return }
    $store = $script:Td.Data.tickets
    $now = Get-TdNowMs
    if ($undo.Kind -eq 'add') {
        [void](Remove-TdTicket -Store $store -Id $undo.Id)
    }
    else {
        $ticket = $undo.Ticket
        if ($undo.Kind -eq 'remove') { $store.items.Insert([Math]::Min([int]$undo.Index, $store.items.Count), $ticket) }
        if (-not $undo.Running) { Stop-TdTicketClock $ticket $now }    # son chrono ne tournait pas avant l'action
        $ticket.status = $undo.Status
        $ticket.closedAt = $undo.ClosedAt
        $ticket.escalatedAt = $undo.EscalatedAt
        $ticket.followUpOn = $undo.FollowUpOn
        # Le ticket en cours redevient celui d'avant ; son chrono repart s'il tournait.
        $current = Get-TdCurrentTicket $store
        if ($current -and $current.id -ne $undo.CurrentId) { Stop-TdTicketClock $current $now }
        $store.currentId = $undo.CurrentId
        Update-TdCurrentTicket $store
        if ($undo.Running -and $store.currentId -eq $ticket.id) { Start-TdTicket -Store $store -NowMs $now }
    }
    Set-TdTicketMessage -Text 'Annulé.' -Seconds 3
    Save-TdTicketsNow
    Update-TdCockpit -NowMs $now -Force
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

# ---------------------------------------------------------------- chronos : un seul à la fois, alerte

function Show-TdChronoPaused {
    # La tâche TDfocus et le ticket ne tournent jamais ensemble (voir Sync-TdChronos dans Core\Tickets.ps1).
    # Ici, on enregistre et on prévient de ce qui vient d'être mis en pause : 'task' ou 'ticket'.
    param([Parameter(Mandatory)][string]$What)
    $ck = $script:Td.Cockpit
    Save-TdStateNow
    Save-TdTicketsNow
    Update-TdView
    if ($What -eq 'task') {
        if (-not $ck.Undo) { Set-TdTicketMessage -Text 'Tâche TDfocus mise en pause : un seul chrono à la fois.' }
    }
    else {
        if (-not $ck.Undo) { Set-TdTicketMessage -Text 'Ticket mis en pause : une tâche TDfocus a démarré.' }
        Show-TdToast -Text 'Chrono du ticket mis en pause : un seul chrono à la fois.'
    }
}

function Send-TdTicketAlert {
    # Le chrono d'un ticket vient d'atteindre la limite : signal doux, une seule fois, jamais bloquant.
    param([Parameter(Mandatory)]$Ticket)
    $settings = $script:Td.Data.settings
    $minutes = [int]$settings.cockpit.ticketAlertMinutes
    if ($settings.timeUpSignal) { Invoke-TdSoundEffect -Name 'timeup' -Volume $settings.effectsVolume }
    if ($settings.notifications -and -not $script:Td.Cockpit.Panel.IsVisible) {
        Show-TdTrayBalloon -Text ('{0} min sur « {1} ». Escalader, ou continuer ?' -f $minutes, (Limit-TdText (Get-TdTicketLabel $Ticket) 60))
    }
    Save-TdTicketsNow
}

# ---------------------------------------------------------------- affichage

function Update-TdCockpitTickets {
    # Redessine la carte Tickets (tuiles, ticket en cours, liste ouverte) et la bulle.
    param([Parameter(Mandatory)][long]$NowMs)
    $ck = $script:Td.Cockpit
    $panelEls = $ck.PanelEls
    $store = $script:Td.Data.tickets
    $counts = Get-TdTicketCounts -Store $store -NowMs $NowMs

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

    # Ticket en cours.
    $ticket = Get-TdCurrentTicket $store
    Set-TdCockpitVisible $panelEls.CurrentBox ($null -ne $ticket)
    Set-TdCockpitVisible $panelEls.NoTicketText ($null -eq $ticket)
    if ($ticket) {
        $label = Get-TdTicketLabel $ticket
        $panelEls.CurrentRef.Text = $label
        $panelEls.CurrentRef.ToolTip = [string]$label
        Set-TdCockpitVisible $panelEls.CurrentUrgent ([bool]$ticket.urgent)
        $running = $null -ne $ticket.runningSince
        $word = 'Démarrer'
        if ($running) { $word = 'Pause' }
        elseif ([long]$ticket.elapsedMs -gt 0) { $word = 'Reprendre' }
        $panelEls.BtnTicketToggle.Content = [string]$word
        # Un seul bouton en avant : « Démarrer / Reprendre » à l'arrêt, « Fermer » quand le chrono tourne.
        Set-TdCockpitAccent -Button $panelEls.BtnTicketToggle -On (-not $running)
        Set-TdCockpitAccent -Button $panelEls.BtnTicketClose -On $running
    }
    $ck.Chrono = ''
    Update-TdTicketChrono -NowMs $NowMs
    Update-TdTicketListView -NowMs $NowMs
    Update-TdCockpitBubble -Counts $counts -NowMs $NowMs
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
    $ticket = Get-TdCurrentTicket $script:Td.Data.tickets
    if (-not $ticket) { return }
    $text = Format-TdTimer (Get-TdElapsedMs $ticket $NowMs)
    if ($text -eq $ck.Chrono) { return }
    $ck.Chrono = $text
    $panelEls = $ck.PanelEls
    $minutes = [int]$script:Td.Data.settings.cockpit.ticketAlertMinutes
    $over = Test-TdTicketOverTime -Ticket $ticket -NowMs $NowMs -Minutes $minutes
    $panelEls.CurrentChrono.Text = $text
    $limit = "sur $minutes min"
    if ($null -eq $ticket.runningSince -and [long]$ticket.elapsedMs -gt 0) { $limit += ' ' + [char]0x00B7 + ' en pause' }
    $panelEls.CurrentLimit.Text = $limit
    # Barre : la partie pleine et la partie vide se partagent la largeur.
    $ratio = [double](Get-TdTicketProgress -Ticket $ticket -NowMs $NowMs -Minutes $minutes)
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
    $empty = @{ open = 'Aucun ticket ouvert.'; closed = "Aucun ticket fermé aujourd'hui."; waiting = 'Aucun ticket en attente.' }
    $panelEls.TicketListTitle.Text = [string]$titles[$kind]
    $rows = $panelEls.TicketList
    $rows.Children.Clear()
    $list = @(Get-TdTicketList -Store $script:Td.Data.tickets -Kind $kind -NowMs $NowMs)
    if ($list.Count -eq 0) {
        [void]$rows.Children.Add((New-TdCockpitText -Text ([string]$empty[$kind]) -Brush 'CkMuted' -Wrap -Margin '0,6,0,0'))
    }
    # Dix lignes au plus : au-delà, la liste deviendrait un mur de texte.
    $max = 10
    for ($i = 0; $i -lt $list.Count -and $i -lt $max; $i++) {
        [void]$rows.Children.Add((New-TdTicketRow -Ticket $list[$i] -Kind $kind -NowMs $NowMs))
    }
    if ($list.Count -gt $max) {
        [void]$rows.Children.Add((New-TdCockpitText -Text ("… et {0} de plus" -f ($list.Count - $max)) -Size 12 -Brush 'CkMuted' -Margin '0,8,0,0'))
    }
    Set-TdCockpitVisible $panelEls.TicketListBox $true
}

function New-TdTicketRow {
    # Une ligne de liste : le libellé, une précision en petit, et les boutons qui vont avec la tuile.
    param([Parameter(Mandatory)]$Ticket, [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][long]$NowMs)
    $id = [string]$Ticket.id
    $label = Get-TdTicketLabel $Ticket
    $isCurrent = ($script:Td.Data.tickets.currentId -eq $id)
    $spent = ''
    $elapsed = Get-TdElapsedMs $Ticket $NowMs
    if ($elapsed -ge 60000) { $spent = Format-TdDurationMs $elapsed }

    # Précision sous le libellé, selon la liste.
    $details = @()
    $detailBrush = 'CkMuted'
    if ($Kind -eq 'open') {
        if ($Ticket.urgent) { $details += 'urgent'; $detailBrush = 'CkAlert' }
        if ($isCurrent) { $details += 'en cours' }
        if ($spent) { $details += $spent }
    }
    elseif ($Kind -eq 'closed') {
        $details += 'fermé à ' + (Format-TdClock ([long]$Ticket.closedAt))
        if ($spent) { $details += $spent }
    }
    else {
        $details += Format-TdFollowUp -DateKey $Ticket.followUpOn -NowMs $NowMs
        if (Test-TdTicketFollowUpDue -Ticket $Ticket -NowMs $NowMs) { $detailBrush = 'CkProjects' }
    }

    $texts = New-Object System.Windows.Controls.StackPanel
    $texts.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $name = New-TdCockpitText -Text $label -Bold:$isCurrent
    $name.ToolTip = [string]$label
    [void]$texts.Children.Add($name)
    if ($details.Count -gt 0) {
        [void]$texts.Children.Add((New-TdCockpitText -Text ($details -join (' ' + [char]0x00B7 + ' ')) -Size 12 -Brush $detailBrush))
    }

    $row = New-Object System.Windows.Controls.DockPanel
    $row.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
    if ($Kind -eq 'waiting') {
        # Trois boutons : ils passent sous le libellé, à largeur égale.
        $buttons = New-Object System.Windows.Controls.Primitives.UniformGrid
        $buttons.Rows = 1
        $buttons.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
        [void]$buttons.Children.Add((New-TdTicketButton -Text 'Relancé' -Action 'followup' -Id $id -ToolTip 'Relance faite : la prochaine est prévue le prochain jour ouvré' -Margin '0,0,6,0'))
        [void]$buttons.Children.Add((New-TdTicketButton -Text 'Reprendre' -Action 'resume' -Id $id -ToolTip 'Le ticket revient chez toi : il redevient le ticket en cours' -Margin '0,0,6,0'))
        [void]$buttons.Children.Add((New-TdTicketButton -Text 'Fermer' -Action 'close' -Id $id -ToolTip 'Ticket résolu'))
        [System.Windows.Controls.DockPanel]::SetDock($buttons, [System.Windows.Controls.Dock]::Bottom)
        [void]$row.Children.Add($buttons)
    }
    else {
        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        if ($Kind -eq 'open') {
            if (-not $isCurrent) { [void]$buttons.Children.Add((New-TdTicketButton -Text 'Traiter' -Action 'start' -Id $id -ToolTip 'Passer à ce ticket et démarrer son chrono' -Margin '8,0,0,0')) }
            [void]$buttons.Children.Add((New-TdTicketButton -Text ([string][char]0x00D7) -Action 'remove' -Id $id -ToolTip 'Supprimer ce ticket (saisi par erreur)' -Name 'Supprimer ce ticket' -Margin '6,0,0,0'))
        }
        else {
            [void]$buttons.Children.Add((New-TdTicketButton -Text 'Rouvrir' -Action 'reopen' -Id $id -ToolTip 'Remettre ce ticket dans les ouverts' -Margin '8,0,0,0'))
        }
        [System.Windows.Controls.DockPanel]::SetDock($buttons, [System.Windows.Controls.Dock]::Right)
        [void]$row.Children.Add($buttons)
    }
    [void]$row.Children.Add($texts)    # le dernier élément d'un DockPanel occupe la place restante
    $row
}

function Update-TdCockpitBubble {
    # La bulle : nombre de tickets fermés aujourd'hui, pastille orange si une relance est due,
    # contour bleu quand le chrono d'un ticket tourne (couleur d'alerte au-delà de la limite).
    param([Parameter(Mandatory)]$Counts, [Parameter(Mandatory)][long]$NowMs)
    $bubbleEls = $script:Td.Cockpit.BubbleEls
    $closed = [int]$Counts.closedToday
    $bubbleEls.BubbleCount.Text = [string]$closed
    $word = 'fermés'
    if ($closed -le 1) { $word = 'fermé' }
    $bubbleEls.BubbleLabel.Text = $word
    Set-TdCockpitVisible $bubbleEls.BubbleDot ($Counts.followUpDue -gt 0)

    $ring = 'CkRing'
    $state = ''
    $ticket = Get-TdCurrentTicket $script:Td.Data.tickets
    if ($ticket -and $null -ne $ticket.runningSince) {
        $ring = 'CkTickets'
        $state = ' En cours : ' + (Limit-TdText (Get-TdTicketLabel $ticket) 40) + '.'
        if (Test-TdTicketOverTime -Ticket $ticket -NowMs $NowMs -Minutes ([int]$script:Td.Data.settings.cockpit.ticketAlertMinutes)) { $ring = 'CkAlert' }
    }
    $bubbleEls.BubbleButton.BorderBrush = Get-TdCockpitBrush $ring
    $summary = "$closed $word aujourd'hui, $($Counts.open) ouverts."
    if ($Counts.followUpDue -gt 0) { $summary += " Relances à faire : $($Counts.followUpDue)." }
    $bubbleEls.BubbleButton.ToolTip = [string]($summary + $state + ' Clic : ouvrir le cockpit. Glisser : déplacer la bulle.')
    [System.Windows.Automation.AutomationProperties]::SetName($bubbleEls.BubbleButton, 'Cockpit TDfocus : ' + $summary + $state)
}
