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
    # -Window : une autre fenêtre que la principale (bulle ou cockpit flottant).
    param([Parameter(Mandatory)][string]$Name, $Window = $script:Td.Window)
    if (-not $script:TdSmokeOutput) { return }
    Wait-TdUi 250
    $root = $Window.Content
    $w = [int][Math]::Ceiling($root.ActualWidth)
    $h = [int][Math]::Ceiling($root.ActualHeight)
    # Fond de la fenêtre, puis le contenu rendu tel quel (sans recadrage ni mise à l'échelle).
    # Fenêtre transparente (bulle, cockpit) : un fond uni joue le rôle du bureau, pour voir les contours.
    $brush = $Window.Background
    if ($Window.AllowsTransparency) { $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x4A, 0x52, 0x66)) }
    $background = New-Object System.Windows.Media.DrawingVisual
    $dc = $background.RenderOpen()
    $dc.DrawRectangle($brush, $null, (New-Object System.Windows.Rect 0, 0, $w, $h))
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
    $ui.NewTaskBox.Text = 'Pause 10'
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

    # Modifier une routine d'origine (routine du matin), puis la rétablir
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Tag -eq 'builtin-morning' -and $n.ToolTip -eq 'Modifier cette routine' })
    Assert-Td ($script:Td.EditingTemplateId -eq 'builtin-morning') 'éditeur de la routine du matin ouvert'
    $draft = $script:Td.TemplateDraft
    $draft.NameBox.Text = 'Routine du matin (équipe)'
    $draft.Refs[1].Minutes.Text = '20'
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq '+ Ajouter une tâche' })
    $draft = $script:Td.TemplateDraft
    $draft.Refs[$draft.Refs.Count - 1].Title.Text = "Point d'équipe"
    $draft.Refs[$draft.Refs.Count - 1].Minutes.Text = '15'
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Tag -eq 'remove|0' })
    Assert-Td ($script:Td.TemplateDraft.Items.Count -eq 5 -and $script:Td.TemplateDraft.Items[4].Title -eq "Point d'équipe") 'ajout et retrait de tâches dans la routine'
    Save-TdScreenshot '23-routine-edition'
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq 'Enregistrer' })
    $edited = Get-TdAllTemplates | Where-Object { $_.id -eq 'builtin-morning' }
    Assert-Td ($edited.name -eq 'Routine du matin (équipe)' -and @($edited.items).Count -eq 5 -and $edited.items[0].minutes -eq 20 -and $edited.items[4].title -eq "Point d'équipe") 'routine d''origine modifiée et enregistrée'
    Assert-Td ((Read-TdJsonFile (Get-TdDataPath 'templates.json')).items[0].name -eq 'Routine du matin (équipe)') 'routine modifiée enregistrée sur le disque'
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Tag -eq 'builtin-morning' -and $n.ToolTip -eq 'Modifier cette routine' })
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq 'Rétablir l''original' })
    Assert-Td ((Get-TdAllTemplates | Where-Object { $_.id -eq 'builtin-morning' }).name -eq 'Routine du matin') 'routine d''origine rétablie'
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
    Assert-Td ($w.Title -match 'Répondre aux emails') 'temps restant dans le titre de la fenêtre'
    Assert-Td ($ui.FocusCard.ActualHeight -le 140) "carte de la tâche en cours compacte ($([int]$ui.FocusCard.ActualHeight) px de haut)"
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
    $script:Td.NoteCaptureBox.Text = 'Rappeler le client 10'
    Add-TdNoteNow
    Assert-Td ($script:Td.Data.notes.Count -eq 1) 'note rapide capturée'
    Save-TdScreenshot '05-notes'
    $count = $state.tasks.Count
    Convert-TdNoteToTask $script:Td.Data.notes[0].id
    Assert-Td ($state.tasks.Count -eq $count + 1 -and $script:Td.Data.notes.Count -eq 0) 'note transformée en tâche'

    # Import texte + iCalendar
    Invoke-TdClick $ui.BtnImport
    $script:Td.ImportTextBox.Text = "- [ ] Relire le contrat 20 min`n- [x] Déjà fait`n☐ Mettre à jour le planning"
    $analyze = Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq 'Analyser le texte' }
    Invoke-TdClick $analyze
    Assert-Td (@($script:Td.ImportItems).Count -eq 2) 'import texte : aperçu'
    Save-TdScreenshot '06-import'
    $count = $state.tasks.Count
    Complete-TdImport
    Assert-Td ($state.tasks.Count -eq $count + 2) 'import texte : ajout de la sélection'
    $day = (Get-Date).ToString('yyyyMMdd')
    $ics = "BEGIN:VCALENDAR`r`nBEGIN:VEVENT`r`nUID:smoke`r`nSUMMARY:Visio client`r`nDTSTART:${day}T235000`r`nDTEND:${day}T235900`r`nEND:VEVENT`r`nEND:VCALENDAR"
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
    Assert-Td ($ui.FocusActive.LayoutTransform.ScaleX -gt 1.2) "mode focus : la carte est agrandie (×$($ui.FocusActive.LayoutTransform.ScaleX))"
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

    # Projets au long cours : petits pas, blocs de temps, note de reprise, 3 au plus en cours
    Invoke-TdClick $ui.BtnTheme
    Assert-Td (-not $script:Td.DarkActive) 'retour au thème clair'
    Invoke-TdClick $ui.BtnProjects
    Assert-Td ($script:Td.Drawer -eq 'projects') 'panneau Projets et quotidien'
    $form = $script:Td.ProjectForm
    $form.Name.Text = 'Refonte du site client'
    $form.Why.Text = 'Livrer avant le salon professionnel'
    $form.Steps.Text = "Lister les pages`nValider la maquette`nRédiger les contenus`nTester sur mobile"
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq 'Créer le projet' })
    $project = $script:Td.Data.projects | Where-Object { $_.name -eq 'Refonte du site client' }
    Assert-Td ($null -ne $project -and $project.status -eq 'active' -and @($project.steps).Count -eq 4) 'projet créé avec son pourquoi et ses pas'
    $sixDaysAgo = (Get-TdNowMs) - 6 * 86400000
    $thesis = New-TdProject -Name 'Rapport annuel' -Why 'Présenter les résultats au comité' -Steps @('Relire le plan', 'Rédiger l''introduction') -NowMs $sixDaysAgo
    $thesis.lastWorkedAt = $sixDaysAgo
    $thesis.investedMs = 200 * 60000
    $thesis.sessions = 7
    Set-TdProjectBreadcrumb -Project $thesis -Text 'Plan validé ; reprendre à la partie 2.' -NowMs $sixDaysAgo
    [void](Add-TdProject -Projects $script:Td.Data.projects -Project $thesis)
    Save-TdProjectsNow
    Update-TdView
    Update-TdDrawer
    Assert-Td ($ui.ProjectNudge.Visibility -eq 'Visible' -and $ui.ProjectNudgeText.Text -like '*Rapport annuel*attend depuis 6 jours*') "rappel doux du projet qui attend ($($ui.ProjectNudgeText.Text))"
    Save-TdScreenshot '19-projets'
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Tag -eq $project.id -and "$($n.Content)" -like 'Bloc de*' })
    $block = $state.tasks | Where-Object { $_.projectId -eq $project.id } | Select-Object -First 1
    Assert-Td ($null -ne $block -and @($block.steps).Count -eq 3 -and $block.steps[0].title -eq 'Lister les pages') 'bloc projet ajouté avec ses 3 prochains pas seulement'
    Assert-Td ($ui.ProjectNudge.Visibility -eq 'Collapsed') 'le rappel se tait quand un bloc projet est prévu'
    Close-TdDrawer
    Start-TdTaskNowById $block.id
    Complete-TdStepNow
    Assert-Td ($project.steps[0].done) 'le pas coché pendant le bloc est reporté sur le projet'
    Assert-Td ($ui.CurrentCategoryText.Text -like '*Projet' -and $ui.ProjectHint.Text -like 'Pourquoi : Livrer*') 'la carte rappelle le projet et son pourquoi'
    Save-TdScreenshot '20-bloc-projet'
    Complete-TdCurrentNow
    Assert-Td ($project.sessions -eq 1 -and $null -ne $project.lastWorkedAt) 'bloc terminé : avancement enregistré sur le projet'
    Assert-Td ("$($ui.ToastAction.Content)" -like "Où j'en suis*") 'proposition de noter où l''on s''arrête'
    Invoke-TdClick $ui.ToastAction
    Assert-Td ($script:Td.Drawer -eq 'projects' -and $script:Td.ExpandedProjectId -eq $project.id) 'note de reprise ouverte'
    $crumb = Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.TextBox] -and $n.Tag -eq $project.id -and $n.AcceptsReturn }
    $crumb.Text = 'Pages listées. Prochaine fois : envoyer la maquette au client.'
    $crumb.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.UIElement]::LostFocusEvent)))
    Assert-Td ($project.breadcrumb -like 'Pages listées*') 'note « où j''en étais » enregistrée'
    foreach ($name in @('Former la nouvelle recrue', 'Migrer les archives')) { [void](Add-TdProject -Projects $script:Td.Data.projects -Project (New-TdProject -Name $name)) }
    Assert-Td (($script:Td.Data.projects | Where-Object { $_.name -eq 'Migrer les archives' }).status -eq 'paused') 'au-delà de 3 projets en cours, le suivant attend'
    Save-TdProjectsNow

    # Quotidien : ajouté tout seul les jours prévus, sans accumulation
    $script:Td.ProjectsTab = 'daily'
    Update-TdDrawer
    $script:Td.DailyBox.Text = 'Point d''équipe 15 @9h30'
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq 'Ajouter au quotidien' })
    $meds = $script:Td.Data.daily | Where-Object { $_.title -eq 'Point d''équipe' }
    Assert-Td ($null -ne $meds -and $meds.fixedStart -eq '09:30' -and $meds.minutes -eq 15) 'action du quotidien créée'
    Assert-Td (@($state.tasks | Where-Object { $_.dailyId -eq $meds.id }).Count -eq 1) 'ajoutée dès aujourd''hui dans la journée'
    $script:Td.DailyBox.Text = 'Saisie des temps 10'
    foreach ($tag in @('new|6', 'new|7')) { Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Primitives.ToggleButton] -and $n.Tag -eq $tag }) }
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq 'Ajouter au quotidien' })
    $dishes = $script:Td.Data.daily | Where-Object { $_.title -eq 'Saisie des temps' }
    Assert-Td ((@($dishes.days) -join ',') -eq '1,2,3,4,5') 'jours choisis : en semaine'
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Tag -eq $meds.id -and "$($n.ToolTip)" -like 'Modifier*' })
    $script:Td.DailyEditBox.Text = "Point d'équipe 20 @9h45"
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq 'Enregistrer' })
    Assert-Td ($meds.minutes -eq 20 -and $meds.fixedStart -eq '09:45') 'action du quotidien modifiée'
    Assert-Td (($state.tasks | Where-Object { $_.dailyId -eq $meds.id }).plannedMs -eq 20 * 60000) 'la tâche du jour suit la modification'
    $script:Td.DailyBox.Text = 'Trier les e-mails 5'
    Invoke-TdClick (Find-TdDescendant $ui.DrawerContent { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq 'Ajouter au quotidien' })
    Save-TdScreenshot '21-quotidien'
    $reloaded = Import-TdData
    Assert-Td ($reloaded.projects.Count -eq 4 -and $reloaded.daily.Count -eq 3) 'projets et quotidien relus depuis le disque'
    Close-TdDrawer
    Save-TdScreenshot '22-journee-avec-quotidien'

    # Cockpit flottant, étape 1 : bulle toujours au-dessus, ouverture, réduction, position mémorisée
    $ck = $script:Td.Cockpit
    Assert-Td ($null -ne $ck) 'cockpit construit (bulle et fenêtre)'
    Assert-Td ($script:Td.Data.settings.cockpit.enabled -and -not $ck.Bubble.IsVisible) 'bulle prévue par défaut, pas encore affichée pendant le test'
    Show-TdCockpit
    Wait-TdUi 300
    Assert-Td ($ck.Bubble.IsVisible -and $ck.Bubble.Topmost -and -not $ck.Bubble.ShowInTaskbar) 'bulle affichée, toujours au-dessus, hors barre des tâches'
    Assert-Td ($ck.BubbleEls.BubbleButton.ActualWidth -eq 84 -and $ck.BubbleEls.BubbleButton.ActualHeight -eq 84 -and $ck.BubbleEls.BubbleCount.Text -eq [string](Get-TdTicketCounts -State $state -NowMs (Get-TdNowMs)).closedToday) "bulle ronde de 84 px avec son compteur ($($ck.BubbleEls.BubbleCount.Text))"
    $bubbleHandle = (New-Object System.Windows.Interop.WindowInteropHelper $ck.Bubble).Handle
    Assert-Td (([TDfocus.Native]::GetWindowLong($bubbleHandle, -20) -band 0x80) -ne 0) 'bulle absente de la liste Alt+Tab'
    $area = Get-TdCockpitWorkArea -Left $ck.Bubble.Left -Top $ck.Bubble.Top
    Write-Host ("  écran de test : zone utilisable {0} x {1}" -f [int]$area.Width, [int]$area.Height)
    Assert-Td ($ck.Bubble.Left -ge $area.Left -and $ck.Bubble.Left + $ck.Bubble.Width -le $area.Left + $area.Width + 1 -and $ck.Bubble.Top + $ck.Bubble.Height -le $area.Top + $area.Height + 1) "bulle entièrement dans l'écran, en bas à droite ($([int]$ck.Bubble.Left), $([int]$ck.Bubble.Top))"
    # Police Inter fournie avec TDfocus (aucune installation sur le PC)
    $typeface = New-Object System.Windows.Media.Typeface $ck.Panel.FontFamily, ([System.Windows.FontStyles]::Normal), ([System.Windows.FontWeights]::SemiBold), ([System.Windows.FontStretches]::Normal)
    $glyphs = $null
    [void]$typeface.TryGetGlyphTypeface([ref]$glyphs)
    Assert-Td ($null -ne $glyphs -and "$($glyphs.FontUri)" -like '*Inter-SemiBold.ttf') "police Inter chargée depuis assets\fonts ($($glyphs.FontUri))"
    Save-TdScreenshot '24-cockpit-bulle' -Window $ck.Bubble

    # Clic sur la bulle, par le vrai gestionnaire de souris : le cockpit s'ouvre
    $down = New-Object System.Windows.Input.MouseButtonEventArgs ([System.Windows.Input.Mouse]::PrimaryDevice), 0, ([System.Windows.Input.MouseButton]::Left)
    $down.RoutedEvent = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent
    $ck.BubbleEls.BubbleButton.RaiseEvent($down)
    Wait-TdUi 300
    Assert-Td ($ck.Panel.IsVisible -and -not $ck.Bubble.IsVisible -and $ck.Panel.Topmost) 'clic sur la bulle : le cockpit s''ouvre, toujours au-dessus'
    Assert-Td ($ck.Panel.Width -eq 420 -and $ck.Panel.Height -le 860 -and $ck.Panel.Height -le $area.Height) "cockpit de 420 px de large, hauteur adaptée à l'écran ($([int]$ck.Panel.Height) px)"
    Assert-Td ($ck.Panel.Left -ge $area.Left -and $ck.Panel.Top -ge $area.Top -and $ck.Panel.Left + $ck.Panel.Width -le $area.Left + $area.Width -and $ck.Panel.Top + $ck.Panel.Height -le $area.Top + $area.Height) 'cockpit entièrement dans l''écran'
    Assert-Td ($ck.PanelEls.TimeText.Text -match '\d{2}:\d{2}' -and $ck.PanelEls.DateText.Text.Length -gt 3) "date et heure dans l'en-tête ($($ck.PanelEls.DateText.Text) $($ck.PanelEls.TimeText.Text))"
    Assert-Td ($ck.PanelEls.BtnReduce.ActualWidth -ge 44 -and $ck.PanelEls.BtnReduce.ActualHeight -ge 44) 'bouton « réduire en bulle » d''au moins 44 px'
    Assert-Td ($script:Td.Data.settings.cockpit.open) 'état « ouvert » mémorisé'
    Save-TdScreenshot '25-cockpit-ouvert' -Window $ck.Panel
    Invoke-TdClick $ck.PanelEls.BtnReduce
    Assert-Td ($ck.Bubble.IsVisible -and -not $ck.Panel.IsVisible -and -not $script:Td.Data.settings.cockpit.open) '« réduire en bulle » : retour à la bulle'

    # Déplacement de la bulle : sa place est mémorisée ; lâchée hors de l'écran, elle y est ramenée
    $startLeft = $ck.Bubble.Left
    $startTop = $ck.Bubble.Top
    $ck.Bubble.Left = $area.Left + 40
    $ck.Bubble.Top = $area.Top + 60
    Complete-TdCockpitBubbleMove -StartLeft $startLeft -StartTop $startTop
    Assert-Td (-not $ck.Panel.IsVisible -and $script:Td.Data.settings.cockpit.left -eq [Math]::Round($area.Left + 40)) 'bulle déplacée : place mémorisée, sans ouvrir le cockpit'
    $ck.Bubble.Left = $area.Left - 500
    Complete-TdCockpitBubbleMove -StartLeft ($area.Left + 40) -StartTop ($area.Top + 60)
    Assert-Td ($ck.Bubble.Left -ge $area.Left) 'bulle lâchée hors de l''écran : ramenée dans la zone visible'
    $savedCockpit = (Import-TdData).settings.cockpit
    Assert-Td ($savedCockpit.enabled -and -not $savedCockpit.open -and $savedCockpit.top -eq [Math]::Round($area.Top + 60)) 'réglages du cockpit relus depuis le disque'
    # Bulle en haut à gauche : le cockpit s'ouvre de ce côté ; déplacé, il emmène la bulle avec lui
    Open-TdCockpitPanel
    Assert-Td ($ck.Panel.Left -lt $area.Left + $area.Width / 2 -and $ck.Panel.Top -lt $area.Top + 100) 'le cockpit s''ouvre du côté où se trouve la bulle'
    $startLeft = $ck.Panel.Left
    $ck.Panel.Left = $startLeft + 120
    Complete-TdCockpitPanelMove -StartLeft $startLeft -StartTop $ck.Panel.Top
    Close-TdCockpitPanel
    Assert-Td ([Math]::Abs($ck.Bubble.Left - ($startLeft + 120)) -le 1) 'cockpit déplacé : la bulle le suit'
    # Masquer, puis retrouver par le menu de la zone de notification (même action)
    Hide-TdCockpit
    Assert-Td (-not $ck.Bubble.IsVisible -and -not $ck.Panel.IsVisible -and -not $script:Td.Data.settings.cockpit.enabled) '« masquer la bulle »'
    Show-TdCockpit -Open
    Assert-Td ($ck.Panel.IsVisible -and $script:Td.Data.settings.cockpit.enabled) 'cockpit rouvert depuis le menu'

    # Cockpit : la carte Tickets lit la liste TDfocus (aucune liste à part, aucun outil de ticketing)
    $pe = $ck.PanelEls
    $projects = $script:Td.Data.projects
    $today = Get-TdDayKey (Get-TdNowMs)
    Suspend-TdTimer $state (Get-TdNowMs)
    Complete-TdChange
    Wait-TdUi 200
    $c0 = Get-TdTicketCounts -State $state -NowMs (Get-TdNowMs)
    Write-Host ("  liste TDfocus : {0} ouverts, {1} fermés aujourd'hui, {2} à relancer" -f $c0.open, $c0.closedToday, $c0.waiting)
    Assert-Td ($pe.TileOpenCount.Text -eq [string]$c0.open -and $pe.TileClosedCount.Text -eq [string]$c0.closedToday -and $pe.TileWaitingCount.Text -eq [string]$c0.waiting) 'les tuiles comptent les actions de la liste TDfocus'
    Assert-Td ($pe.Body.Children.IndexOf($pe.BalanceCard) -eq 0 -and $pe.BalanceTarget.Text -eq 'objectif 60 / 40') 'jauge « Équilibre du jour » tout en haut, objectif 60 / 40'
    # Une action saisie dans TDfocus apparaît dans le cockpit ; « !! » la rend urgente
    $ui.NewTaskBox.Text = 'INC-4821 VPN impossible (compta) 20'
    Invoke-TdClick $ui.BtnAdd
    $inc1 = $state.tasks | Where-Object { $_.title -eq 'INC-4821 VPN impossible (compta)' }
    Assert-Td ($null -ne $inc1 -and $pe.TileOpenCount.Text -eq [string]($c0.open + 1)) 'une action saisie dans TDfocus compte aussitôt dans la tuile « ouverts »'
    $ui.NewTaskBox.Text = 'INC-4830 Imprimante RH 15 !!'
    Invoke-TdClick $ui.BtnAdd
    $inc2 = $state.tasks | Where-Object { $_.title -eq 'INC-4830 Imprimante RH' }
    Assert-Td ($null -ne $inc2 -and $inc2.urgent -and $inc2.plannedMs -eq 15 * 60000 -and $state.tasks[1].id -eq $inc2.id) '« !! » dans TDfocus : action urgente, placée juste après la tâche en cours'
    Assert-Td ($pe.TileOpenUrgent.Text -like '*1 urgent') 'le cockpit compte l''action urgente'
    # Elle devient la tâche en cours de TDfocus : c'est le ticket en cours du cockpit
    Start-TdTaskNowById -Id $inc1.id
    Wait-TdUi 300
    Assert-Td ($pe.TicketsCard.IsVisible -and $pe.CurrentBox.IsVisible -and $pe.CurrentRef.Text -eq $inc1.title -and $pe.BtnTicketToggle.Content -eq 'Pause') 'la tâche en cours de TDfocus est le ticket en cours du cockpit'
    foreach ($control in @($pe.BtnAddTicket, $pe.TileOpen, $pe.TileClosed, $pe.TileWaiting, $pe.BtnTicketToggle, $pe.BtnTicketEscalate, $pe.BtnTicketClose, $pe.BtnWhere, $pe.BtnRecap)) {
        Assert-Td ($control.ActualWidth -ge 44 -and $control.ActualHeight -ge 44) "bouton d'au moins 44 px ($($control.Name) : $([int]$control.ActualWidth) x $([int]$control.ActualHeight))"
    }
    # « + Ticket » dans le cockpit : même saisie, même liste ; puis « Annuler »
    Invoke-TdClick $pe.BtnAddTicket
    Assert-Td ($pe.AddForm.IsVisible -and $pe.TicketBoxHint.IsVisible) 'formulaire d''ajout ouvert'
    $pe.TicketBox.Text = 'INC-4835 Accès dossier partagé 10'
    Wait-TdUi 80
    $source = [System.Windows.PresentationSource]::FromVisual($pe.TicketBox)
    $keyArgs = New-Object System.Windows.Input.KeyEventArgs ([System.Windows.Input.Keyboard]::PrimaryDevice), $source, 0, ([System.Windows.Input.Key]::Return)
    $keyArgs.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
    $pe.TicketBox.RaiseEvent($keyArgs)
    Wait-TdUi 120
    $inc3 = $state.tasks | Where-Object { $_.title -eq 'INC-4835 Accès dossier partagé' }
    Assert-Td ($null -ne $inc3 -and $inc3.plannedMs -eq 10 * 60000 -and -not $pe.AddForm.IsVisible -and $pe.TicketMessageText.Text -like 'Ajouté à ta liste TDfocus*') '« + Ticket » ajoute l''action à la liste TDfocus (Entrée, durée reconnue)'
    Invoke-TdClick $pe.BtnAddTicket
    $pe.TicketBox.Text = 'Erreur de saisie'
    Invoke-TdClick $pe.TicketUrgent
    Invoke-TdClick $pe.BtnAddConfirm
    $mistake = $state.tasks | Where-Object { $_.title -eq 'Erreur de saisie' }
    Assert-Td ($null -ne $mistake -and $mistake.urgent -and $pe.BtnTicketUndo.IsVisible) 'bascule « Urgent » du cockpit'
    Invoke-TdClick $pe.BtnTicketUndo
    Assert-Td ($null -eq ($state.tasks | Where-Object { $_.title -eq 'Erreur de saisie' }) -and -not $pe.BtnTicketUndo.IsVisible) '« Annuler » retire l''action ajoutée par erreur'

    # Chrono du ticket = minuteur de TDfocus ; barre vers 30 min ; la jauge compte le temps
    $inc1.runningSince = (Get-TdNowMs) - (18 * 60 + 24) * 1000
    Update-TdCockpit -NowMs (Get-TdNowMs) -Force
    Wait-TdUi 150
    Assert-Td ($pe.CurrentChrono.Text -match '^18:2\d$' -and $pe.CurrentLimit.Text -eq 'sur 30 min') "chrono du ticket ($($pe.CurrentChrono.Text) $($pe.CurrentLimit.Text))"
    Assert-Td ($pe.BarDone.Width.Value -gt 0.6 -and $pe.BarDone.Width.Value -lt 0.63 -and -not $pe.CurrentAlert.IsVisible) 'barre de progression vers 30 min (61 %)'
    $balance = Get-TdDayBalance -State $state -NowMs (Get-TdNowMs)
    Assert-Td ($balance.ticketMs -gt 0 -and $pe.BalanceTicketsText.Text -eq ('Tickets ' + (Format-TdDurationMs $balance.ticketMs)) -and $pe.BalanceBar.IsVisible) "la jauge compte le temps du minuteur ($($pe.BalanceTicketsText.Text), $($pe.BalanceProjectsText.Text))"
    Hide-TdTicketMessage
    Save-TdScreenshot '26-cockpit-tickets' -Window $ck.Panel
    $before = $pe.CurrentChrono.Text
    Wait-TdUi 1300
    Assert-Td ($pe.CurrentChrono.Text -ne $before) "le chrono avance ($before -> $($pe.CurrentChrono.Text))"
    # Alerte douce à 30 min : couleur et phrase fixes
    $inc1.runningSince = (Get-TdNowMs) - 31 * 60000
    Wait-TdUi 700
    Assert-Td ($pe.CurrentAlert.IsVisible -and $pe.CurrentAlert.Text -like '30 min dépassées*') 'alerte à 30 min affichée'
    Assert-Td ($pe.BarDone.Width.Value -eq 1 -and $pe.BarFill.Background.Color.ToString() -eq '#FFF28B82') 'barre pleine, en couleur d''alerte'
    Save-TdScreenshot '27-cockpit-alerte' -Window $ck.Panel
    # Réglages > Confort : limite du ticket et objectif de la jauge
    $box = New-Object System.Windows.Controls.TextBox
    $box.Tag = 'ticketAlertMinutes|1|240'
    $box.Text = '45'
    Set-TdCockpitNumber -Box $box
    Assert-Td ($script:Td.Data.settings.cockpit.ticketAlertMinutes -eq 45 -and $pe.CurrentLimit.Text -eq 'sur 45 min' -and -not $pe.CurrentAlert.IsVisible) 'limite réglée à 45 min : le cockpit suit'
    $box.Text = 'abc'
    Set-TdCockpitNumber -Box $box
    Assert-Td ($box.Text -eq '45' -and $script:Td.Data.settings.cockpit.ticketAlertMinutes -eq 45) 'valeur illisible refusée'
    $box.Text = '30'
    Set-TdCockpitNumber -Box $box
    $box.Tag = 'ticketShare|10|90'
    $box.Text = '70'
    Set-TdCockpitNumber -Box $box
    Assert-Td ($pe.BalanceTarget.Text -eq 'objectif 70 / 30' -and $pe.BalanceMarkLeft.Width.Value -eq 70) 'objectif de la jauge réglé à 70 / 30 : le repère suit'
    $box.Text = '60'
    Set-TdCockpitNumber -Box $box
    # Pause et Fermer : les mêmes gestes que dans TDfocus
    Invoke-TdClick $pe.BtnTicketToggle
    Assert-Td (-not (Test-TdRunning $state) -and $pe.BtnTicketToggle.Content -eq 'Reprendre' -and $pe.CurrentLimit.Text -like '*en pause') '« Pause » du cockpit : le minuteur de TDfocus s''arrête'
    $historyBefore = $script:Td.Data.history.Count
    Invoke-TdClick $pe.BtnTicketClose
    Assert-Td ((Find-TdTask $state $inc1.id).list -eq 'done' -and $script:Td.Data.history.Count -eq $historyBefore + 1 -and $pe.TileClosedCount.Text -eq [string]($c0.closedToday + 1)) '« Fermer » valide la tâche dans TDfocus (historique compris) : fermés aujourd''hui + 1'
    Assert-Td ($pe.TicketMessageText.Text -like 'Fermé : INC-4821*' -and $pe.BtnTicketUndo.IsVisible) 'message « Fermé » avec « Annuler »'
    Invoke-TdClick $pe.BtnTicketUndo
    Assert-Td ($state.tasks[0].id -eq $inc1.id -and $pe.TileClosedCount.Text -eq [string]$c0.closedToday -and $pe.CurrentRef.Text -eq $inc1.title) '« Annuler » rouvre le ticket, de nouveau en cours'
    Invoke-TdClick $pe.BtnTicketClose
    Assert-Td ((Find-TdTask $state $inc1.id).list -eq 'done' -and $inc1.elapsedMs -ge 31 * 60000 -and ($inc1.days.Values | Measure-Object -Sum).Sum -ge 31 * 60000) 'ticket fermé, temps passé conservé (et rangé dans la journée)'
    # « Traiter » depuis la liste des ouverts
    if (-not $pe.TicketListBox.IsVisible -or $pe.TicketListTitle.Text -ne 'OUVERTS') { Invoke-TdClick $pe.TileOpen }
    Assert-Td ($pe.TicketListTitle.Text -eq 'OUVERTS' -and $pe.TicketList.Children.Count -ge 2) 'tuile « ouverts » : la liste des actions'
    Invoke-TdClick (Find-TdDescendant $pe.TicketList { param($n) $n -is [System.Windows.Controls.Button] -and $n.Tag -eq "start|$($inc2.id)" })
    Wait-TdUi 300
    Assert-Td ($state.tasks[0].id -eq $inc2.id -and (Test-TdRunning $state) -and $pe.CurrentRef.Text -eq $inc2.title -and $pe.CurrentUrgent.IsVisible) '« Traiter » : l''action devient la tâche en cours de TDfocus, minuteur en marche'
    # Escalader : le ticket attend quelqu'un, il reviendra le prochain jour ouvré
    Invoke-TdClick $pe.BtnTicketEscalate
    Assert-Td ($null -ne (Find-TdParkedTask $state $inc2.id) -and $null -ne $inc2.waitingSince -and $inc2.deferUntil -gt $today -and $pe.TileWaitingCount.Text -eq [string]($c0.waiting + 1)) "« Escalader » : mis de côté jusqu'au $($inc2.deferUntil), compté dans « à relancer »"
    Assert-Td ($pe.TicketMessageText.Text -like 'Escaladé : INC-4830*' -and -not $pe.TileWaitingDot.IsVisible) "message d'escalade ($($pe.TicketMessageText.Text))"
    Invoke-TdClick $pe.BtnTicketUndo
    Assert-Td ($state.tasks[0].id -eq $inc2.id -and $null -eq $inc2.waitingSince -and (Test-TdRunning $state)) '« Annuler » : le ticket reprend sa place, minuteur en marche'
    Invoke-TdClick $pe.BtnTicketEscalate
    # Une action ordinaire redevient la tâche en cours (le cockpit reste en mode normal)
    Start-TdTaskNowById -Id $inc3.id
    Suspend-TdTimer $state (Get-TdNowMs)
    Complete-TdChange
    # Relance due aujourd'hui : pastille orange, carte « Relances du jour »
    Invoke-TdClick $pe.TileWaiting
    Assert-Td ($pe.TicketListBox.IsVisible -and $pe.TicketListTitle.Text -eq 'À RELANCER' -and $pe.TicketList.Children.Count -eq $c0.waiting + 1) 'tuile « à relancer » : sa liste s''ouvre'
    Assert-Td ($pe.FollowEmpty.IsVisible -and $pe.FollowList.Children.Count -eq 0) 'aucune relance due pour l''instant'
    $inc2.deferUntil = $today
    Update-TdView
    Assert-Td ($pe.TileWaitingDot.IsVisible -and $ck.BubbleEls.BubbleDot.Visibility -eq 'Visible' -and $pe.FollowList.Children.Count -eq 1 -and -not $pe.FollowEmpty.IsVisible) 'relance due : pastille orange (tuile et bulle) et ligne dans « Relances du jour »'
    Save-TdScreenshot '28-cockpit-relances' -Window $ck.Panel
    Invoke-TdClick (Find-TdDescendant $pe.FollowList { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq 'Relancé' })
    Assert-Td ($inc2.deferUntil -gt $today -and -not $pe.TileWaitingDot.IsVisible -and $ck.BubbleEls.BubbleDot.Visibility -ne 'Visible' -and $pe.FollowList.Children.Count -eq 0) '« Relancé » : relance repoussée, la pastille disparaît'
    Invoke-TdClick (Find-TdDescendant $pe.TicketList { param($n) $n -is [System.Windows.Controls.Button] -and $n.Tag -eq "resume|$($inc2.id)" })
    Wait-TdUi 300
    Assert-Td ($state.tasks[0].id -eq $inc2.id -and $null -eq $inc2.waitingSince -and (Test-TdRunning $state) -and $pe.TileWaitingCount.Text -eq [string]$c0.waiting) '« Reprendre » : le ticket redevient la tâche en cours'
    Invoke-TdClick $pe.TileWaiting
    Assert-Td (-not $pe.TicketListBox.IsVisible) 'second clic sur la tuile : la liste se referme'
    Invoke-TdClick $pe.BtnTicketToggle

    # Projets : lus dans le panneau Projets de TDfocus ; « bloqué : en attente de… » saisi dans TDfocus
    $shown = @(Get-TdCockpitProjects -Projects $projects -State $state -NowMs (Get-TdNowMs))
    Assert-Td ($shown.Count -ge 1 -and $pe.ProjectList.Children.Count -eq $shown.Count -and $pe.ProjectsTitle.Text -eq 'PROJETS') "carte Projets : $($shown.Count) projets en cours"
    foreach ($item in $shown) { Write-Host ("    {0} : {1} % · {2} {3}" -f $item.name, $item.percent, $item.alertText, $item.detailText) }
    $stale = $shown | Where-Object { $_.name -eq 'Rapport annuel' }
    Assert-Td ($null -ne $stale -and $stale.stale -and $stale.alertText -like 'Pas bougé depuis*') "alerte « pas bougé » : $($stale.alertText)"
    $blockedProject = $projects | Where-Object { $_.name -eq 'Rapport annuel' }
    $box = New-Object System.Windows.Controls.TextBox
    $box.Tag = $blockedProject.id
    $box.Text = 'la validation du comité'
    Set-TdProjectBlockedFromBox $box
    Assert-Td ($blockedProject.blockedBy -eq 'la validation du comité' -and $blockedProject.followUpOn -gt $today) 'projet bloqué depuis TDfocus : relance prévue le prochain jour ouvré'
    $blockedProject.followUpOn = $today
    Update-TdView
    Assert-Td ($pe.FollowList.Children.Count -eq 1 -and $ck.BubbleEls.BubbleDot.Visibility -eq 'Visible') 'projet bloqué à relancer : dans « Relances du jour », pastille sur la bulle'
    $meeting = Get-TdNextMeeting -State $state -NowMs (Get-TdNowMs)
    if ($meeting) { Assert-Td ($pe.MeetingWhat.Text -eq $meeting.text) "prochaine réunion : $($meeting.text) $($pe.MeetingDelay.Text)" }
    else { Assert-Td ($pe.MeetingWhat.Text -eq '') 'pas de réunion à venir' }
    $pe.BodyScroll.ScrollToEnd()
    Save-TdScreenshot '29-cockpit-projets' -Window $ck.Panel
    $pe.BodyScroll.ScrollToTop()
    Invoke-TdClick (Find-TdDescendant $pe.FollowList { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq 'Relancé' })
    Assert-Td ($blockedProject.followUpOn -gt $today -and $pe.FollowList.Children.Count -eq 0) '« Relancé » sur le projet : relance repoussée'

    # Bloc projet planifié (saisi dans TDfocus) : annonce à l'heure dite, puis mode projet
    $site = $projects | Where-Object { $_.name -eq 'Refonte du site client' }
    foreach ($old in @($state.tasks | Where-Object { $_.projectId -eq $site.id })) { [void](Remove-TdTask -State $state -Id $old.id) }
    $site.blockMinutes = 90
    foreach ($title in @('Rédiger la page Offres', 'Relire avec le client', 'Mettre en ligne')) { [void](Add-TdProjectStep -Project $site -Title $title) }
    $box = New-Object System.Windows.Controls.TextBox
    $box.Tag = $site.id
    $blockStart = (Get-Date).AddMinutes(-2)
    if ($blockStart.Date -ne (Get-Date).Date) { $blockStart = (Get-Date).Date }    # juste après minuit
    $box.Text = $blockStart.ToString('HH:mm')
    Add-TdProjectBlockAt -Box $box
    $block = $state.tasks | Where-Object { $_.projectId -eq $site.id } | Select-Object -First 1
    Assert-Td ($null -ne $block -and $block.fixedStart -eq $box.Text -and $block.plannedMs -eq 90 * 60000) "bloc de 1 h 30 planifié à $($box.Text) depuis le panneau Projets"
    if ($state.tasks[0].id -ne $block.id) {
        Assert-Td ($pe.BlockBanner.IsVisible -and $ck.BlockSignalId -eq $block.id -and $pe.BlockBannerText.Text -eq $block.title -and $pe.BlockBannerSlot.Text -like "$($block.fixedStart)*" -and $pe.BtnBlockStart.Content -eq 'Commencer') "à l'heure du bloc : invitation « $($pe.BlockBannerText.Text) $($pe.BlockBannerSlot.Text) »"
        Invoke-TdClick $pe.BtnBlockStart
    }
    else { Start-TdTaskNowById -Id $block.id }
    Wait-TdUi 300
    Assert-Td ($state.tasks[0].id -eq $block.id -and (Test-TdRunning $state)) '« Commencer » : le bloc devient la tâche en cours de TDfocus'
    Assert-Td ($pe.ProjectModeCard.IsVisible -and $pe.TicketsLine.IsVisible -and -not $pe.TicketsCard.IsVisible -and -not $pe.BlockBanner.IsVisible) 'mode projet : bloc en grand, tickets réduits à une ligne'
    Assert-Td ($pe.PanelRoot.BorderBrush.Color.ToString() -eq '#FFF0A35B' -and $pe.BlockSlot.Text -like 'BLOC PROJET*' -and $pe.BlockName.Text -eq 'Refonte du site client' -and $pe.ProjectsTitle.Text -eq 'AUTRES PROJETS') "bordure et titre orange ($($pe.BlockSlot.Text))"
    Assert-Td ($pe.BlockChecklist.Children.Count -eq @($block.steps).Count -and $pe.BlockStep.Text -eq $block.steps[0].title) "tâche projet en grand avec sa checklist ($($pe.BlockStep.Text))"
    Assert-Td ($pe.TicketsLineText.Text -match '\d+ ouverts?$' -and $pe.BtnInterrupt.ActualHeight -ge 44) "tickets en une ligne : Tickets$($pe.TicketsLineText.Text)$($pe.TicketsLineUrgent.Text)"
    $block.runningSince = (Get-TdNowMs) - 38 * 60000
    Update-TdCockpit -NowMs (Get-TdNowMs) -Force
    Assert-Td ($pe.BlockRemaining.Text -eq 'Reste 52 min' -and $pe.BlockBarDone.Width.Value -gt 0.41 -and $pe.BlockBarDone.Width.Value -lt 0.44) "temps restant du bloc ($($pe.BlockRemaining.Text))"
    # Étape faite, case à cocher
    Invoke-TdClick $pe.BtnBlockStep
    Assert-Td ($block.steps[0].done -and ($site.steps | Where-Object { $_.id -eq $block.steps[0].id }).done -and $pe.BlockStep.Text -eq $block.steps[1].title) '« Étape faite » : le pas est coché, dans le bloc et dans le projet'
    Invoke-TdClick $pe.BlockChecklist.Children[1]
    Assert-Td ($block.steps[1].done -and ($site.steps | Where-Object { $_.id -eq $block.steps[1].id }).done) 'case de la checklist cochée à la main'
    Invoke-TdClick $pe.BlockChecklist.Children[1]
    Assert-Td (-not $block.steps[1].done) 'case décochée'
    $site.breadcrumb = ''
    Update-TdView
    Save-TdScreenshot '30-cockpit-mode-projet' -Window $ck.Panel
    # Interrompre : pause du bloc, note de reprise, tickets de nouveau visibles
    Invoke-TdClick $pe.BtnInterrupt
    Assert-Td (-not (Test-TdRunning $state) -and $pe.BlockNoteForm.IsVisible -and $pe.TicketsCard.IsVisible -and -not $pe.TicketsLine.IsVisible -and $pe.TicketListTitle.Text -eq 'OUVERTS') '« Interrompre » : bloc en pause, note de reprise ouverte, tickets visibles'
    $pe.BlockNoteBox.Text = 'Maquette validée ; reprendre aux contenus de la page Offres.'
    Invoke-TdClick $pe.BtnNoteSave
    Assert-Td ($site.breadcrumb -eq 'Maquette validée ; reprendre aux contenus de la page Offres.' -and -not $pe.BlockNoteForm.IsVisible -and $pe.BlockCrumbBox.IsVisible -and $pe.BlockCrumb.Text -eq $site.breadcrumb) 'note de reprise enregistrée sur le projet (la même que dans TDfocus)'
    Save-TdScreenshot '31-cockpit-interruption' -Window $ck.Panel
    Invoke-TdClick (Find-TdDescendant $pe.TicketList { param($n) $n -is [System.Windows.Controls.Button] -and $n.Tag -eq "start|$($inc3.id)" })
    Wait-TdUi 300
    Assert-Td ($state.tasks[0].id -eq $inc3.id -and -not $pe.ProjectModeCard.IsVisible -and $pe.TicketsCard.IsVisible -and $pe.PanelRoot.BorderBrush.Color.ToString() -ne '#FFF0A35B') 'on traite le ticket : retour au mode normal'
    Assert-Td ($pe.BlockBanner.IsVisible -and $pe.BlockBannerTitle.Text -eq 'BLOC PROJET EN PAUSE' -and $pe.BtnBlockStart.Content -eq 'Reprendre') 'le bloc interrompu reste à portée : « Reprendre »'
    Invoke-TdClick $pe.BtnTicketToggle

    # Jauge avec l'exemple de la maquette : 2 h 40 de tickets, 1 h 05 de projets
    foreach ($task in @($state.tasks) + @($state.done) + @($state.parked)) { $task.days.Clear() }
    $inc3.days[$today] = [long]160 * 60000
    $block.days[$today] = [long]65 * 60000
    Update-TdView
    Assert-Td ($pe.BalanceTicketsText.Text -eq 'Tickets 2 h 40' -and $pe.BalanceProjectsText.Text -eq 'Projets 1 h 05') "jauge : $($pe.BalanceTicketsText.Text), $($pe.BalanceProjectsText.Text)"
    Assert-Td ($pe.BalanceMessage.IsVisible -and $pe.BalanceMessage.Text -eq 'Les projets passent derrière : un bloc de 45 min rééquilibrerait.' -and $pe.BalanceMessage.Foreground.Color.ToString() -eq '#FFF0A35B') "message de dérive : $($pe.BalanceMessage.Text)"
    Assert-Td ([Math]::Abs($pe.BalanceTicketsCol.Width.Value - 160 / 225) -lt 0.01 -and $pe.BalanceMarkLeft.Width.Value -eq 60) 'barre bicolore proportionnelle au temps, repère à 60 %'
    if ($pe.TicketListBox.IsVisible) { Invoke-TdClick $pe.TileOpen }
    Hide-TdTicketMessage
    Save-TdScreenshot '32-cockpit-jauge' -Window $ck.Panel
    # « Où j'en étais » et « Récap du jour »
    Invoke-TdClick $pe.BtnWhere
    Assert-Td ($pe.InfoOverlay.IsVisible -and $pe.InfoTitle.Text -eq "OÙ J'EN ÉTAIS" -and $pe.InfoList.Children.Count -ge 4) '« Où j''en étais » : la tâche en cours et les notes de reprise'
    Assert-Td ($pe.InfoList.Children[0].Text -eq ('En cours : ' + $inc3.title)) "première ligne : $($pe.InfoList.Children[0].Text)"
    Save-TdScreenshot '33-cockpit-ou-j-en-etais' -Window $ck.Panel
    Invoke-TdClick $pe.BtnRecap
    Assert-Td ($pe.InfoOverlay.IsVisible -and $pe.InfoTitle.Text -eq 'RÉCAP DU JOUR' -and $pe.InfoList.Children[0].Text -like 'Tickets fermés : *' -and $pe.InfoList.Children[3].Text -eq 'Tickets 2 h 40 · Projets 1 h 05') '« Récap du jour » : fermés, temps, reste à faire'
    Save-TdScreenshot '34-cockpit-recap' -Window $ck.Panel
    Invoke-TdClick $pe.BtnInfoClose
    Assert-Td (-not $pe.InfoOverlay.IsVisible) 'panneau refermé'
    # La bulle : actions fermées aujourd'hui, contour bleu quand le minuteur d'un ticket tourne, pastille si relance due
    Invoke-TdClick $pe.BtnTicketToggle
    Invoke-TdClick $pe.BtnReduce
    Wait-TdUi 200
    $closedNow = (Get-TdTicketCounts -State $state -NowMs (Get-TdNowMs)).closedToday
    Assert-Td ($ck.Bubble.IsVisible -and $ck.BubbleEls.BubbleCount.Text -eq [string]$closedNow -and $closedNow -ge 1) "la bulle affiche le nombre d'actions fermées aujourd'hui ($closedNow)"
    Assert-Td ($ck.BubbleEls.BubbleButton.BorderBrush.Color.ToString() -eq '#FF5B9BF0') 'contour de la bulle bleu : le minuteur d''un ticket tourne'
    $blockedProject.followUpOn = $today
    Update-TdView
    Assert-Td ($ck.BubbleEls.BubbleDot.Visibility -eq 'Visible') 'pastille orange sur la bulle : une relance est due'
    Save-TdScreenshot '35-cockpit-bulle' -Window $ck.Bubble
    # Tout est dans les fichiers habituels de TDfocus
    Suspend-TdTimer $state (Get-TdNowMs)
    Complete-TdChange
    Save-TdProjectsNow
    $saved = Import-TdData
    $savedInc2 = $saved.state.tasks | Where-Object { $_.title -eq 'INC-4830 Imprimante RH' }
    $savedProject = $saved.projects | Where-Object { $_.name -eq 'Rapport annuel' }
    Assert-Td ($null -ne $savedInc2 -and $savedInc2.urgent -and $savedProject.blockedBy -eq 'la validation du comité' -and -not (Test-Path -LiteralPath (Join-Path $env:TDFOCUS_DATA 'tickets.json'))) 'tout est relu depuis les fichiers de TDfocus (aucun fichier de tickets à part)'
    Hide-TdCockpit
    Assert-Td ($w.IsVisible -and $ui.MainRoot.Visibility -eq 'Visible') 'la fenêtre principale n''est pas affectée par le cockpit'

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
