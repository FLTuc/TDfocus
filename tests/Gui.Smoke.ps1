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
    Assert-Td ($ck.BubbleEls.BubbleButton.ActualWidth -eq 84 -and $ck.BubbleEls.BubbleButton.ActualHeight -eq 84 -and $ck.BubbleEls.BubbleCount.Text -eq '0') 'bulle ronde de 84 px avec son compteur'
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

    # Cockpit, étape 2 : tickets (ajout, chrono, alerte, fermer, escalader, listes, annuler, bulle)
    $pe = $ck.PanelEls
    $tickets = $script:Td.Data.tickets
    Wait-TdUi 200
    Assert-Td ($pe.NoTicketText.IsVisible -and -not $pe.CurrentBox.IsVisible -and $pe.TileOpenCount.Text -eq '0' -and -not $pe.AddForm.IsVisible) 'carte Tickets vide au départ'
    foreach ($control in @($pe.BtnAddTicket, $pe.TileOpen, $pe.TileClosed, $pe.TileWaiting)) {
        Assert-Td ($control.ActualWidth -ge 44 -and $control.ActualHeight -ge 44) "bouton d'au moins 44 px ($($control.Name) : $([int]$control.ActualWidth) x $([int]$control.ActualHeight))"
    }
    # « + Ticket », saisie, touche Entrée
    Invoke-TdClick $pe.BtnAddTicket
    Assert-Td ($pe.AddForm.IsVisible -and $pe.TicketBoxHint.IsVisible) 'formulaire d''ajout ouvert'
    $pe.TicketBox.Text = 'INC-4821 · VPN impossible (compta)'
    Wait-TdUi 80
    Assert-Td (-not $pe.TicketBoxHint.IsVisible) 'l''indication disparaît dès qu''on écrit'
    $source = [System.Windows.PresentationSource]::FromVisual($pe.TicketBox)
    $keyArgs = New-Object System.Windows.Input.KeyEventArgs ([System.Windows.Input.Keyboard]::PrimaryDevice), $source, 0, ([System.Windows.Input.Key]::Return)
    $keyArgs.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
    $pe.TicketBox.RaiseEvent($keyArgs)
    Wait-TdUi 120
    Assert-Td ($tickets.items.Count -eq 1 -and $pe.TileOpenCount.Text -eq '1' -and $pe.TileOpenLabel.Text -eq 'ouvert' -and -not $pe.AddForm.IsVisible) 'ticket ajouté avec Entrée : tuile « 1 ouvert »'
    Assert-Td ($pe.CurrentBox.IsVisible -and $pe.CurrentRef.Text -eq 'INC-4821 · VPN impossible (compta)' -and $pe.BtnTicketToggle.Content -eq 'Démarrer' -and $pe.CurrentChrono.Text -eq '00:00') 'il devient le ticket en cours, chrono à l''arrêt'
    # Deuxième ticket, urgent, par le bouton « Ajouter »
    Invoke-TdClick $pe.BtnAddTicket
    $pe.TicketBox.Text = 'INC-4830 Imprimante RH'
    Invoke-TdClick $pe.TicketUrgent
    Invoke-TdClick $pe.BtnAddConfirm
    Assert-Td ($pe.TileOpenCount.Text -eq '2' -and $pe.TileOpenLabel.Text -eq 'ouverts' -and $pe.TileOpenUrgent.Text -like '*1 urgent' -and $pe.CurrentRef.Text -like 'INC-4821*') 'deuxième ticket urgent : 2 ouverts dont 1 urgent, le ticket en cours ne change pas'
    # Troisième ticket sans libellé, puis « Annuler »
    Invoke-TdClick $pe.BtnAddTicket
    Invoke-TdClick $pe.BtnAddConfirm
    Assert-Td ($tickets.items.Count -eq 3 -and $pe.TicketMessage.IsVisible -and $pe.TicketMessageText.Text -match '^Ajouté : Ticket de \d{2}:\d{2}$' -and $pe.BtnTicketUndo.IsVisible) 'ticket sans libellé : nommé par son heure, message avec « Annuler »'
    Invoke-TdClick $pe.BtnTicketUndo
    Assert-Td ($tickets.items.Count -eq 2 -and $pe.TileOpenCount.Text -eq '2' -and -not $pe.BtnTicketUndo.IsVisible) '« Annuler » retire le ticket ajouté par erreur'

    # Démarrer : le chrono du ticket tourne, la tâche TDfocus se met en pause (un seul chrono à la fois)
    if (-not (Get-TdCurrentTask $state)) { [void](Add-TdTask -State $state -Task (New-TdTask -Title 'Suivi des demandes' -Minutes 20)) }
    Start-TdTimer $state ((Get-TdNowMs) - 5000)
    Assert-Td (Test-TdRunning $state) 'une tâche TDfocus tourne'
    Invoke-TdClick $pe.BtnTicketToggle
    Wait-TdUi 400
    Assert-Td ((Test-TdTicketRunning $tickets) -and -not (Test-TdRunning $state) -and $pe.BtnTicketToggle.Content -eq 'Pause') '« Démarrer » : le chrono du ticket tourne, la tâche TDfocus est mise en pause'
    Assert-Td ($null -ne (Get-TdCurrentTask $state).pausedAt -and $pe.TicketMessageText.Text -like 'Tâche TDfocus mise en pause*') 'la pause de la tâche est annoncée'
    # 18 min 24 plus tard
    $current = Get-TdCurrentTicket $tickets
    $current.runningSince = (Get-TdNowMs) - (18 * 60 + 24) * 1000
    Update-TdCockpit -NowMs (Get-TdNowMs) -Force
    Wait-TdUi 150
    Assert-Td ($pe.CurrentChrono.Text -match '^18:2\d$' -and $pe.CurrentLimit.Text -eq 'sur 30 min') "chrono du ticket ($($pe.CurrentChrono.Text) $($pe.CurrentLimit.Text))"
    Assert-Td ($pe.BarDone.Width.Value -gt 0.6 -and $pe.BarDone.Width.Value -lt 0.63 -and -not $pe.CurrentAlert.IsVisible) 'barre de progression vers 30 min (61 %)'
    foreach ($control in @($pe.BtnTicketToggle, $pe.BtnTicketEscalate, $pe.BtnTicketClose)) {
        Assert-Td ($control.ActualHeight -ge 44 -and $control.ActualWidth -ge 100) "bouton « $($control.Content) » : $([int]$control.ActualWidth) x $([int]$control.ActualHeight) px"
    }
    Hide-TdTicketMessage
    Save-TdScreenshot '26-cockpit-tickets' -Window $ck.Panel
    # Le temps passe en vrai : le chrono avance tout seul
    $before = $pe.CurrentChrono.Text
    Wait-TdUi 1300
    Assert-Td ($pe.CurrentChrono.Text -ne $before) "le chrono avance ($before -> $($pe.CurrentChrono.Text))"
    # Alerte douce à 30 min : couleur et phrase fixes, une seule fois
    $current.runningSince = (Get-TdNowMs) - 31 * 60000
    Wait-TdUi 700
    Assert-Td ($null -ne $current.alertedAt -and $pe.CurrentAlert.IsVisible -and $pe.CurrentAlert.Text -like '30 min dépassées*') 'alerte à 30 min affichée'
    Assert-Td ($pe.BarDone.Width.Value -eq 1 -and $pe.BarFill.Background.Color.ToString() -eq '#FFF28B82') 'barre pleine, en couleur d''alerte'
    $alertedAt = $current.alertedAt
    Wait-TdUi 600
    Assert-Td ($current.alertedAt -eq $alertedAt) 'l''alerte n''est donnée qu''une fois'
    Save-TdScreenshot '27-cockpit-alerte' -Window $ck.Panel
    # Réglage de la limite (Réglages > Confort)
    $box = New-Object System.Windows.Controls.TextBox
    $box.Text = '45'
    Set-TdTicketAlertMinutes -Box $box
    Assert-Td ($script:Td.Data.settings.cockpit.ticketAlertMinutes -eq 45 -and $pe.CurrentLimit.Text -eq 'sur 45 min' -and -not $pe.CurrentAlert.IsVisible) 'limite réglée à 45 min : le cockpit suit'
    $box.Text = 'abc'
    Set-TdTicketAlertMinutes -Box $box
    Assert-Td ($box.Text -eq '45' -and $script:Td.Data.settings.cockpit.ticketAlertMinutes -eq 45) 'valeur illisible refusée'
    $box.Text = '30'
    Set-TdTicketAlertMinutes -Box $box
    # Pause, puis Fermer
    Invoke-TdClick $pe.BtnTicketToggle
    Assert-Td (-not (Test-TdTicketRunning $tickets) -and $pe.BtnTicketToggle.Content -eq 'Reprendre' -and $pe.CurrentLimit.Text -like '*en pause') '« Pause » : chrono arrêté, bouton « Reprendre »'
    Invoke-TdClick $pe.BtnTicketClose
    Assert-Td ($pe.TileClosedCount.Text -eq '1' -and $pe.TileOpenCount.Text -eq '1' -and $pe.CurrentRef.Text -eq 'INC-4830 Imprimante RH' -and $pe.CurrentUrgent.IsVisible) '« Fermer » : 1 fermé aujourd''hui, le ticket urgent devient le ticket en cours'
    Assert-Td ($pe.TicketMessageText.Text -like 'Fermé : INC-4821*' -and $pe.BtnTicketUndo.IsVisible) 'message « Fermé » avec « Annuler »'
    Invoke-TdClick $pe.BtnTicketUndo
    Assert-Td ($pe.TileClosedCount.Text -eq '0' -and $pe.TileOpenCount.Text -eq '2' -and $pe.CurrentRef.Text -like 'INC-4821*') '« Annuler » rouvre le ticket et le remet en cours'
    Invoke-TdClick $pe.BtnTicketClose
    Assert-Td ($pe.TileClosedCount.Text -eq '1' -and $current.status -eq 'closed' -and $current.elapsedMs -ge 31 * 60000) 'ticket fermé, temps passé conservé'
    # Escalader : le ticket passe dans « à relancer »
    Invoke-TdClick $pe.BtnTicketEscalate
    Assert-Td ($pe.TileOpenCount.Text -eq '0' -and $pe.TileWaitingCount.Text -eq '1' -and $pe.NoTicketText.IsVisible -and -not $pe.TileWaitingDot.IsVisible) '« Escalader » : 0 ouvert, 1 à relancer (relance pas encore due)'
    Assert-Td ($pe.TicketMessageText.Text -like 'Escaladé : INC-4830*') "message d'escalade ($($pe.TicketMessageText.Text))"
    # Listes des tuiles
    Invoke-TdClick $pe.TileWaiting
    Assert-Td ($pe.TicketListBox.IsVisible -and $pe.TicketListTitle.Text -eq 'À RELANCER' -and $pe.TicketList.Children.Count -eq 1) 'clic sur la tuile « à relancer » : sa liste s''ouvre'
    $waiting = @(Get-TdTicketList -Store $tickets -Kind waiting)
    $waiting[0].followUpOn = Get-TdDayKey (Get-TdNowMs)
    Update-TdCockpit -NowMs (Get-TdNowMs) -Force
    Assert-Td ($pe.TileWaitingDot.IsVisible -and $ck.BubbleEls.BubbleDot.Visibility -eq 'Visible') 'relance due aujourd''hui : pastille orange sur la tuile et sur la bulle'
    Invoke-TdClick $pe.BtnAddTicket
    $pe.TicketBox.Text = 'INC-4835 Accès dossier partagé'
    Invoke-TdClick $pe.BtnAddConfirm
    Hide-TdTicketMessage
    Save-TdScreenshot '28-cockpit-relances' -Window $ck.Panel
    Invoke-TdClick (Find-TdDescendant $pe.TicketList { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq 'Relancé' })
    Assert-Td ($waiting[0].followUpOn -gt (Get-TdDayKey (Get-TdNowMs)) -and -not $pe.TileWaitingDot.IsVisible -and $ck.BubbleEls.BubbleDot.Visibility -ne 'Visible') '« Relancé » : relance repoussée, la pastille disparaît'
    Invoke-TdClick (Find-TdDescendant $pe.TicketList { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq 'Reprendre' })
    Wait-TdUi 300
    Assert-Td ($pe.TileWaitingCount.Text -eq '0' -and $pe.CurrentRef.Text -eq 'INC-4830 Imprimante RH' -and (Test-TdTicketRunning $tickets)) '« Reprendre » : le ticket escaladé redevient le ticket en cours, chrono en marche'
    Invoke-TdClick $pe.TileOpen
    Assert-Td ($pe.TicketListTitle.Text -eq 'OUVERTS' -and $pe.TicketList.Children.Count -eq 2) 'tuile « ouverts » : 2 tickets listés'
    Invoke-TdClick (Find-TdDescendant $pe.TicketList { param($n) $n -is [System.Windows.Controls.Button] -and $n.Content -eq 'Traiter' })
    Wait-TdUi 300
    Assert-Td ($pe.CurrentRef.Text -eq 'INC-4835 Accès dossier partagé' -and (Test-TdTicketRunning $tickets) -and $null -eq (Find-TdTicket $tickets $waiting[0].id).runningSince) '« Traiter » : on change de ticket, un seul chrono tourne'
    Invoke-TdClick (Find-TdDescendant $pe.TicketList { param($n) $n -is [System.Windows.Controls.Button] -and "$($n.ToolTip)" -like 'Supprimer*' })
    Assert-Td ($tickets.items.Count -eq 2 -and $pe.TicketMessageText.Text -like 'Supprimé :*') 'ticket supprimé (saisi par erreur)'
    Invoke-TdClick $pe.BtnTicketUndo
    Assert-Td ($tickets.items.Count -eq 3) 'suppression annulée'
    Invoke-TdClick $pe.TileClosed
    Assert-Td ($pe.TicketListTitle.Text -eq "FERMÉS AUJOURD'HUI" -and $pe.TicketList.Children.Count -eq 1) 'tuile « fermés aujourd''hui » : 1 ticket listé'
    Invoke-TdClick $pe.TileClosed
    Assert-Td (-not $pe.TicketListBox.IsVisible) 'second clic sur la tuile : la liste se referme'
    # Reprise d'une tâche TDfocus : c'est le ticket qui se met en pause
    Assert-Td (Test-TdTicketRunning $tickets) 'un chrono de ticket tourne'
    Start-TdTimer $state (Get-TdNowMs)
    Wait-TdUi 500
    Assert-Td ((Test-TdRunning $state) -and -not (Test-TdTicketRunning $tickets)) 'la tâche TDfocus redémarre : le ticket se met en pause'
    Suspend-TdTimer $state (Get-TdNowMs)
    # La bulle : nombre de tickets fermés aujourd'hui, contour bleu quand un chrono de ticket tourne
    Invoke-TdClick $pe.BtnTicketToggle
    Invoke-TdClick $pe.BtnReduce
    Wait-TdUi 200
    Assert-Td ($ck.Bubble.IsVisible -and $ck.BubbleEls.BubbleCount.Text -eq '1' -and $ck.BubbleEls.BubbleLabel.Text -eq 'fermé') 'la bulle affiche le nombre de tickets fermés aujourd''hui'
    Assert-Td ($ck.BubbleEls.BubbleButton.BorderBrush.Color.ToString() -eq '#FF5B9BF0') 'contour de la bulle bleu : un chrono de ticket tourne'
    (Find-TdTicket $tickets $waiting[0].id).status = 'escalated'
    (Find-TdTicket $tickets $waiting[0].id).followUpOn = Get-TdDayKey (Get-TdNowMs)
    Update-TdCockpit -NowMs (Get-TdNowMs) -Force
    Save-TdScreenshot '29-cockpit-bulle-tickets' -Window $ck.Bubble
    # Tout est relu depuis tickets.json
    Suspend-TdTicket -Store $tickets -NowMs (Get-TdNowMs)
    Save-TdTicketsNow
    $savedTickets = (Import-TdData).tickets
    $savedCounts = Get-TdTicketCounts -Store $savedTickets
    Assert-Td ($savedTickets.items.Count -eq 3 -and $savedCounts.closedToday -eq 1 -and $savedCounts.waiting -eq 1 -and $savedCounts.open -eq 1) 'tickets relus depuis le disque (1 ouvert, 1 fermé, 1 à relancer)'
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
