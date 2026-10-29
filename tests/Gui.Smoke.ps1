# TDfocus - test d'interface de bout en bout (Windows uniquement).
# Lancé par : powershell -STA -File src\TDfocus.ps1 -SmokeTest -Screenshot <dossier>
# avec TDFOCUS_DATA pointant vers un dossier temporaire. Chaque étape passe par les vrais
# boutons et gestionnaires d'événements ; des captures PNG sont enregistrées pour relecture.

function Wait-TdUi {
    param([int]$Milliseconds = 150)
    $script:TdSmokeFrame = New-Object System.Windows.Threading.DispatcherFrame
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $t.Add_Tick({ $this.Stop(); $script:TdSmokeFrame.Continue = $false })
    $t.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($script:TdSmokeFrame)
}

function Invoke-TdClick {
    param([Parameter(Mandatory)]$Control)
    if ($Control -is [System.Windows.Controls.Primitives.ToggleButton]) { $Control.IsChecked = -not $Control.IsChecked }
    $Control.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Wait-TdUi 80
}

function Assert-Td {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "ÉCHEC : $Message" }
    Write-Host "  ok  $Message"
}

function Find-TdDescendant {
    # Premier descendant (arbre logique) qui satisfait le prédicat.
    param([Parameter(Mandatory)]$Root, [Parameter(Mandatory)][scriptblock]$Predicate)
    foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($Root)) {
        if ($child -isnot [System.Windows.DependencyObject]) { continue }
        if (& $Predicate $child) { return $child }
        $found = Find-TdDescendant -Root $child -Predicate $Predicate
        if ($found) { return $found }
    }
    $null
}

function Save-TdScreenshot {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:TdSmokeOutput) { return }
    Wait-TdUi 250
    $root = $script:Td.Window.Content
    $w = [int][Math]::Ceiling($root.ActualWidth)
    $h = [int][Math]::Ceiling($root.ActualHeight)
    # Fond de la fenêtre, puis le contenu rendu tel quel (sans recadrage ni mise à l'échelle).
    $background = New-Object System.Windows.Media.DrawingVisual
    $dc = $background.RenderOpen()
    $dc.DrawRectangle($script:Td.Window.Background, $null, (New-Object System.Windows.Rect 0, 0, $w, $h))
    $dc.Close()
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $w, $h, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render([System.Windows.Media.Visual]$background)
    $bitmap.Render([System.Windows.Media.Visual]$root)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $path = Join-Path $script:TdSmokeOutput "$Name.png"
    $stream = [System.IO.File]::Create($path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    Write-Host "  capture $path"
}

function Invoke-TdSmokeTest {
    param([string]$OutputDirectory)
    $script:TdSmokeOutput = $OutputDirectory
    if ($OutputDirectory -and -not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
    $ui = $script:Td.Ui
    $w = $script:Td.Window
    $state = $script:Td.Data.state
    Write-Host "TDfocus $script:TdVersion - test d'interface (PowerShell $($PSVersionTable.PSVersion))"

    $script:Td.Data.settings.theme = 'light'
    Update-TdThemeNow
    $w.WindowStartupLocation = 'Manual'
    $w.Left = 0; $w.Top = 0; $w.Width = 1180; $w.Height = 860
    $w.Show()
    $script:Td.Timer.Start()
    Wait-TdUi 400
    Assert-Td ($ui.FocusEmpty.Visibility -eq 'Visible') 'état vide affiché au premier lancement'
    Save-TdScreenshot '01-vide'

    # Saisie rapide
    $ui.NewTaskBox.Text = 'Répondre aux emails 15'
    Invoke-TdClick $ui.BtnAdd
    Assert-Td ($state.tasks.Count -eq 1) 'ajout par le bouton Ajouter'
    Assert-Td ($state.tasks[0].plannedMs -eq 15 * 60000) 'durée « 15 » reconnue'
    $ui.NewTaskBox.Text = 'Rédiger le rapport 1h30'
    $source = [System.Windows.PresentationSource]::FromVisual($ui.NewTaskBox)
    $keyArgs = New-Object System.Windows.Input.KeyEventArgs ([System.Windows.Input.Keyboard]::PrimaryDevice), $source, 0, ([System.Windows.Input.Key]::Return)
    $keyArgs.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
    $ui.NewTaskBox.RaiseEvent($keyArgs)
    Wait-TdUi 80
    Assert-Td ($state.tasks.Count -eq 2 -and $state.tasks[1].plannedMs -eq 90 * 60000) 'ajout avec Entrée et « 1h30 »'
    $chip = $ui.CategoryChips.Children | Where-Object { $_.Tag -eq 'pause' } | Select-Object -First 1
    Invoke-TdClick $chip
    $ui.NewTaskBox.Text = 'Pause thé 10'
    Invoke-TdClick $ui.BtnAdd
    Assert-Td ($state.tasks[2].categoryId -eq 'pause') 'catégorie choisie par pastille'
    $fixed = (Get-Date).AddHours(3).ToString('HH:mm')
    if ((Get-Date).Hour -ge 20) { $fixed = '23:30' }
    $ui.NewTaskBox.Text = "Point d'équipe 30 @$fixed"
    Invoke-TdClick $ui.BtnAdd
    $meeting = $state.tasks | Where-Object { $_.title -eq "Point d'équipe" }
    Assert-Td ($null -ne $meeting -and $meeting.fixedStart -eq $fixed) 'créneau figé reconnu'

    # Routine + annulation
    Invoke-TdClick $ui.BtnTemplates
    Assert-Td ($script:Td.Drawer -eq 'templates') 'panneau Routines ouvert'
    $card = Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Tag -eq 'builtin-morning' }
    $before = $state.tasks.Count
    Invoke-TdClick $card
    Assert-Td ($state.tasks.Count -eq $before + 5) 'routine du matin chargée en un clic'
    Save-TdScreenshot '02-routines'
    Invoke-TdClick $ui.ToastAction
    Assert-Td ($state.tasks.Count -eq $before) 'annulation du chargement de routine'
    Invoke-TdClick $ui.BtnDrawerClose

    # Minuteur
    Invoke-TdClick $ui.BtnStartPause
    Assert-Td (Test-TdRunning $state) 'démarrage du minuteur'
    Invoke-TdClick $ui.BtnPlus5
    Assert-Td ($state.tasks[0].plannedMs -eq 20 * 60000) '+5 min à la volée'
    Invoke-TdClick $ui.BtnMinus1
    Assert-Td ($state.tasks[0].plannedMs -eq 19 * 60000) '−1 min à la volée'
    $text = $ui.TimerText.Text
    Wait-TdUi 1300
    Assert-Td ($ui.TimerText.Text -ne $text) "le minuteur s'écoule ($text -> $($ui.TimerText.Text))"
    Assert-Td ($ui.EndTime.Text -match '^\d{2}:\d{2}$') "heure de fin de liste affichée ($($ui.EndTime.Text))"
    Assert-Td ($w.Title -match 'Répondre aux emails') 'temps restant dans le titre de la fenêtre'
    Save-TdScreenshot '03-minuteur'

    # Note sur la tâche
    Invoke-TdClick $ui.BtnTaskNote
    $ui.TaskNoteBox.Text = 'Penser à joindre le devis'
    Assert-Td ($state.tasks[0].note -eq 'Penser à joindre le devis') 'note de tâche enregistrée'

    # Sous-étapes
    Open-TdEditor $state.tasks[0].id
    $script:Td.EditorRefs.EditSteps.Text = "Ouvrir le document`nÉcrire le plan`nRelire"
    Invoke-TdClick $script:Td.EditorRefs.EditSave
    Assert-Td ($state.tasks[0].steps.Count -eq 3) 'sous-étapes saisies dans l''éditeur'
    Assert-Td ($ui.StepPanel.Visibility -eq 'Visible' -and $ui.StepTitle.Text -eq 'Ouvrir le document') 'étape en cours affichée sur la carte'
    Invoke-TdClick $ui.BtnStepDone
    Assert-Td ($ui.StepTitle.Text -eq 'Écrire le plan' -and $ui.StepCounter.Text -like '*2 / 3*') 'étape faite : la suivante s''affiche'
    Save-TdScreenshot '14-etapes'
    Invoke-TdClick $ui.BtnStepUndo
    Assert-Td ($ui.StepTitle.Text -eq 'Ouvrir le document') 'retour à l''étape précédente'

    # Compteur de pause
    Invoke-TdClick $ui.BtnStartPause
    Wait-TdUi 1200
    Assert-Td ($ui.CurrentState.Text -like 'En pause depuis*') "compteur de pause visible ($($ui.CurrentState.Text))"
    Assert-Td ($w.Title -like '*en pause depuis*') 'pause visible dans le titre de la fenêtre'
    Invoke-TdClick $ui.BtnStartPause
    Assert-Td ($ui.CurrentState.Text -eq 'En cours') 'reprise : le compteur disparaît'

    # Signal d'atterrissage
    $cur = $state.tasks[0]
    $cur.runningSince = [long]$cur.runningSince - 10 * 60000
    $cur.plannedMs = (Get-TdElapsedMs $cur (Get-TdNowMs)) + 90000
    $script:Td.Signals.LandingKey = ''
    Wait-TdUi 500
    Assert-Td ($script:Td.Signals.LandingKey -eq (Get-TdSignalKey $cur)) 'signal d''atterrissage émis'
    Assert-Td ($ui.LandingHint.Visibility -eq 'Visible') "atterrissage affiché ($($ui.LandingHint.Text))"
    Save-TdScreenshot '15-atterrissage'

    # Point de contrôle au carillon
    $script:Td.Data.settings.chimeEveryMin = 1
    $script:Td.Signals.ChimeTaskId = $cur.id
    $script:Td.Signals.ChimeIndex = [long][Math]::Floor((Get-TdElapsedMs $cur (Get-TdNowMs)) / 60000) - 1
    Wait-TdUi 500
    Assert-Td ($ui.CheckInBar.Visibility -eq 'Visible') 'point de contrôle affiché au carillon'
    Save-TdScreenshot '16-point-de-controle'
    Invoke-TdClick $ui.BtnCheckInDrift
    Assert-Td ($script:Td.Data.checkins.Count -eq 1 -and $script:Td.Data.checkins[0].answer -eq 'drifted') 'recentrage enregistré'
    Assert-Td ($ui.CheckInBar.Visibility -eq 'Collapsed' -and $ui.ToastAction.Content -eq 'Noter la distraction') 'proposition de noter la distraction'
    $script:Td.Data.settings.chimeEveryMin = 0

    # Validation
    Invoke-TdClick $ui.BtnDone
    Assert-Td ($state.done.Count -eq 1 -and $script:Td.Data.history.Count -eq 1) 'validation : tâche terminée et historisée'
    Assert-Td (Test-TdRunning $state) 'la suivante enchaîne automatiquement'
    Assert-Td ($ui.Toast.Visibility -eq 'Visible') 'message de félicitation avec annulation'
    Save-TdScreenshot '04-validation'
    Invoke-TdClick $ui.ToastAction
    Assert-Td ($state.done.Count -eq 0 -and $state.tasks[0].title -eq 'Répondre aux emails') 'annulation de la validation'
    Invoke-TdClick $ui.BtnDone

    # Plus tard / glisser-déposer (logique) / édition
    $first = $state.tasks[0].title
    Invoke-TdClick $ui.BtnLater
    Assert-Td ($state.tasks[$state.tasks.Count - 1].title -eq $first) '« Plus tard » reporte en fin de liste'
    $last = $state.tasks[$state.tasks.Count - 1]
    Move-TdTaskRelative -DraggedId $last.id -TargetId $state.tasks[1].id -Before $true
    Assert-Td ($state.tasks[1].id -eq $last.id) 'réordonnancement (glisser-déposer)'
    $rowCount = @($ui.UpNextList.Children | Where-Object { $_ -is [System.Windows.Controls.Border] }).Count
    Assert-Td ($rowCount -eq $state.tasks.Count - 1) "liste « Ensuite » rendue ($rowCount lignes)"
    Open-TdEditor $state.tasks[1].id
    $script:Td.EditorRefs.EditTitle.Text = 'Tâche renommée'
    $script:Td.EditorRefs.EditMinutes.Text = '12'
    Invoke-TdClick $script:Td.EditorRefs.EditSave
    Assert-Td ($state.tasks[1].title -eq 'Tâche renommée' -and $state.tasks[1].plannedMs -eq 12 * 60000) 'édition en ligne'
    Invoke-TdRowCommand -Command 'down' -Id $state.tasks[1].id
    Assert-Td ($state.tasks[2].title -eq 'Tâche renommée') 'menu contextuel : descendre'

    # Bloc-notes
    Invoke-TdClick $ui.BtnNotes
    $script:Td.NoteCaptureBox.Text = 'Appeler le garage 10'
    Add-TdNoteNow
    Assert-Td ($script:Td.Data.notes.Count -eq 1) 'note rapide capturée'
    Save-TdScreenshot '05-notes'
    $count = $state.tasks.Count
    Convert-TdNoteToTask $script:Td.Data.notes[0].id
    Assert-Td ($state.tasks.Count -eq $count + 1 -and $script:Td.Data.notes.Count -eq 0) 'note transformée en tâche'

    # Import texte + iCalendar
    Invoke-TdClick $ui.BtnImport
    $script:Td.ImportTextBox.Text = "- [ ] Lire un chapitre 20 min`n- [x] Déjà fait`n☐ Arroser les plantes"
    $analyze = Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq 'Analyser le texte' }
    Invoke-TdClick $analyze
    Assert-Td (@($script:Td.ImportItems).Count -eq 2) 'import texte : aperçu'
    Save-TdScreenshot '06-import'
    $count = $state.tasks.Count
    Complete-TdImport
    Assert-Td ($state.tasks.Count -eq $count + 2) 'import texte : ajout de la sélection'
    $day = (Get-Date).ToString('yyyyMMdd')
    $ics = "BEGIN:VCALENDAR`r`nBEGIN:VEVENT`r`nUID:smoke`r`nSUMMARY:Dentiste`r`nDTSTART:${day}T235000`r`nDTEND:${day}T235900`r`nEND:VEVENT`r`nEND:VCALENDAR"
    Show-TdImportPreview -Items (ConvertFrom-TdIcs -Content $ics -DayMs (Get-TdNowMs)) -Source 'calendar' -Label 'test'
    Complete-TdImport
    Assert-Td ($null -ne ($state.tasks | Where-Object { $_.externalId -like 'ics:smoke:*' })) 'import iCalendar : créneau figé ajouté'

    # Revue du matin (changement de jour simulé)
    $state.dayKey = '2000-01-01'
    Wait-TdUi 500
    Assert-Td ($script:Td.Drawer -eq 'review') 'revue du matin ouverte au changement de jour'
    $reviewTasks = @(Get-TdReviewTasks $state)
    Assert-Td ($reviewTasks.Count -eq $state.tasks.Count) "toutes les tâches d'hier sont proposées ($($reviewTasks.Count))"
    Save-TdScreenshot '17-revue'
    $first = $reviewTasks[0]
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Tag -eq "tomorrow|$($first.id)" })
    Assert-Td ($state.parked.Count -eq 1 -and $state.tasks.id -notcontains $first.id) 'tâche reportée à demain'
    $second = $reviewTasks[1]
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Tag -eq "drop|$($second.id)" })
    Assert-Td ($state.tasks.id -notcontains $second.id) 'tâche abandonnée sans culpabilité'
    Invoke-TdClick $ui.ToastAction
    Assert-Td ($state.tasks.id -contains $second.id) 'abandon annulé'
    $keepAll = Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -like 'Tout garder*' }
    Invoke-TdClick $keepAll
    Assert-Td ($null -eq $script:Td.Drawer -and $state.review.Count -eq 0) '« Tout garder » termine la revue'
    Assert-Td ($ui.ParkedBar.Visibility -eq 'Visible') 'tâches reportées signalées sous la liste'
    Invoke-TdClick $ui.BtnParkedRestore
    Assert-Td ($state.parked.Count -eq 0 -and $state.tasks.id -contains $first.id) 'tâche reportée ramenée aujourd''hui'

    # Statistiques, sons, réglages
    Invoke-TdClick $ui.BtnStats
    Assert-Td ($null -ne $ui.DrawerContent.Content) 'panneau Statistiques'
    Save-TdScreenshot '07-stats'
    Invoke-TdClick $ui.BtnSounds
    $rain = Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.RadioButton] -and $n.Tag -eq 'rain' }
    Invoke-TdClick $rain
    Assert-Td ($script:Td.Data.settings.ambient -eq 'rain') 'ambiance « pluie douce » choisie'
    Save-TdScreenshot '08-sons'
    Invoke-TdClick $ui.BtnSettings
    Assert-Td ($script:Td.Drawer -eq 'settings') 'panneau Réglages'
    Save-TdScreenshot '09-reglages'
    Close-TdDrawer

    # Modes d'affichage
    Invoke-TdClick $ui.BtnFocusMode
    Assert-Td ($script:Td.FocusMode -and $ui.ListScroll.Visibility -eq 'Collapsed') 'mode focus : la liste passe en retrait'
    Save-TdScreenshot '10-focus'
    Invoke-TdClick $ui.BtnFocusMode
    Invoke-TdClick $ui.BtnCompact
    Assert-Td ($script:Td.Compact -and $ui.CompactRoot.Visibility -eq 'Visible') 'mode compact flottant'
    Save-TdScreenshot '11-compact'
    Start-TdCheckIn
    Assert-Td ($ui.CompactCheckYes.Visibility -eq 'Visible' -and $ui.CompactMeta.Text -eq 'Toujours dessus ?') 'point de contrôle en mode compact'
    Save-TdScreenshot '18-compact-point-de-controle'
    Invoke-TdClick $ui.CompactCheckYes
    Assert-Td ($script:Td.Data.checkins[$script:Td.Data.checkins.Count - 1].answer -eq 'focused') 'réponse depuis le mode compact'
    Invoke-TdClick $ui.CompactExpand
    Assert-Td (-not $script:Td.Compact) 'retour à la vue complète'
    Invoke-TdClick $ui.BtnTheme
    Assert-Td ($script:Td.DarkActive) 'thème sombre'
    Save-TdScreenshot '12-sombre'
    $w.Width = 520
    Wait-TdUi 300
    Save-TdScreenshot '13-etroit'
    $w.Width = 1180

    # Sons calculés en arrière-plan (PowerShell pur)
    $deadline = (Get-Date).AddSeconds(240)
    while ($script:TdAudio.Jobs.Count -gt 0 -and (Get-Date) -lt $deadline) { Wait-TdUi 500 }
    foreach ($name in @('complete', 'chime', 'timeup', 'landing', 'rain')) {
        Assert-Td ((Get-TdSoundStatus $name) -eq 'ready') "son « $name » généré"
    }

    # Persistance
    Save-TdStateNow
    $reloaded = Import-TdData
    Assert-Td ($reloaded.state.tasks.Count -eq $state.tasks.Count) 'la liste est relue à l''identique depuis le disque'

    if ($global:Error.Count -gt 0) {
        Write-Host "Erreurs non bloquantes rencontrées ($($global:Error.Count)) :"
        foreach ($err in @($global:Error)) { Write-Host ('  - ' + $err.ToString()) }
    }
    $script:Td.Quitting = $true
    $script:Td.Timer.Stop()
    Stop-TdAudio
    Remove-TdTray
    $w.Close()
    Write-Host 'Test d''interface réussi.'
}
