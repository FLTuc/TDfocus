# TDfocus (terminal) - routines : charger, modifier (y compris celles d'origine), rétablir.

function Get-TdTuiTemplates {
    Get-TdTemplates $script:Tui.Data.templates
}

function Save-TdTuiTemplates {
    try { Save-TdTemplates $script:Tui.Data.templates } catch { Write-TdLog "Sauvegarde des routines impossible : $($_.Exception.Message)" }
}

function Get-TdTuiSelectedTemplate {
    $list = @(Get-TdTuiTemplates)
    if ($list.Count -eq 0) { return $null }
    $list[[Math]::Min($script:Tui.ListSel, $list.Count - 1)]
}

function Open-TdTuiRoutineEditor {
    # Copie de travail : rien n'est enregistré avant [s].
    param([Parameter(Mandatory)]$Template)
    $script:Tui.RoutineDraft = Copy-TdTemplate $Template
    $script:Tui.RoutineOrigin = Get-TdTemplateOrigin $Template
    $script:Tui.ItemSel = 0
    $script:Tui.Mode = 'routine-edit'
}

function Remove-TdTuiRoutine {
    param([Parameter(Mandatory)]$Template)
    $backup = @($script:Tui.Data.templates | ForEach-Object { Copy-TdTemplate $_ })
    Remove-TdTemplate -UserTemplates $script:Tui.Data.templates -Id $Template.id
    Save-TdTuiTemplates
    $script:Tui.ListSel = [Math]::Max(0, [Math]::Min($script:Tui.ListSel, @(Get-TdTuiTemplates).Count - 1))
    Show-TdTuiMessage -Text ('Routine « {0} » supprimée.' -f $Template.name) -UndoData @{ Backup = $backup } -Undo {
        param($d)
        $list = $script:Tui.Data.templates
        $list.Clear()
        foreach ($t in $d.Backup) { $list.Add($t) }
        Save-TdTuiTemplates
        $script:Tui.Dirty = $true
    }
}

function Invoke-TdTuiRoutinesKey {
    param([Parameter(Mandatory)][System.ConsoleKeyInfo]$Key)
    $tui = $script:Tui
    $ch = [string]$Key.KeyChar
    $count = @(Get-TdTuiTemplates).Count
    if ($ch -match '^[1-9]$') { Add-TdTuiTemplate -Number ([int]$ch); return }
    switch ($Key.Key) {
        'UpArrow' { $tui.ListSel = [Math]::Max(0, $tui.ListSel - 1); return }
        'DownArrow' { $tui.ListSel = [Math]::Min([Math]::Max(0, $count - 1), $tui.ListSel + 1); return }
        'Enter' { Add-TdTuiTemplate -Number ($tui.ListSel + 1); return }
        'Escape' { $tui.Mode = 'main'; return }
    }
    $selected = Get-TdTuiSelectedTemplate
    switch -CaseSensitive ($ch) {
        's' { Open-TdTuiPrompt -Label 'Nom de la routine' -Hint 'enregistre toute la liste actuelle' -OnSubmit { param($text) Save-TdTuiCurrentAsTemplate -Name $text } }
        'e' { if ($selected) { Open-TdTuiRoutineEditor $selected } }
        'x' { if ($selected) { Remove-TdTuiRoutine $selected } }
        'R' {
            $restored = 0
            if ($selected -and (Get-TdTemplateOrigin $selected) -eq 'modified') { if (Reset-TdTemplate -UserTemplates $tui.Data.templates -Id $selected.id) { $restored++ } }
            else { foreach ($t in @($tui.Data.templates | Where-Object { $_.hidden })) { if (Reset-TdTemplate -UserTemplates $tui.Data.templates -Id $t.id) { $restored++ } } }
            if ($restored -gt 0) { Save-TdTuiTemplates; Show-TdTuiMessage -Text 'Routine d''origine rétablie.' -Color 'success' -Seconds 4 }
        }
        'z' { if ($tui.Undo) { $u = $tui.Undo; $tui.Undo = $null; $tui.Message = $null; & $u.Action $u.Data } }
        'q' { $tui.Mode = 'main' }
    }
}

function Set-TdTuiDraftItem {
    # Ajoute (Index = -1) ou remplace une tâche de la routine en cours de modification.
    param([string]$Text, [int]$Index = -1)
    $draft = $script:Tui.RoutineDraft
    $category = $null
    if ($Index -ge 0 -and $Index -lt @($draft.items).Count) { $category = $draft.items[$Index].categoryId }
    $item = ConvertFrom-TdTemplateItemText -Text $Text -CategoryId $category
    if (-not $item) { return }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($it in @($draft.items)) { $items.Add($it) }
    if ($Index -ge 0 -and $Index -lt $items.Count) { $items[$Index] = $item }
    else { $items.Add($item); $script:Tui.ItemSel = $items.Count - 1 }
    $draft.items = $items.ToArray()
    $script:Tui.Dirty = $true
}

function Invoke-TdTuiRoutineEditKey {
    param([Parameter(Mandatory)][System.ConsoleKeyInfo]$Key)
    $tui = $script:Tui
    $draft = $tui.RoutineDraft
    $ch = [string]$Key.KeyChar
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($it in @($draft.items)) { $items.Add($it) }
    $sel = [Math]::Min($tui.ItemSel, [Math]::Max(0, $items.Count - 1))
    switch ($Key.Key) {
        'UpArrow' { $tui.ItemSel = [Math]::Max(0, $sel - 1); return }
        'DownArrow' { $tui.ItemSel = [Math]::Min([Math]::Max(0, $items.Count - 1), $sel + 1); return }
        'Escape' { $tui.Mode = 'routines'; $tui.RoutineDraft = $null; Show-TdTuiMessage -Text 'Modifications abandonnées.' -Color 'muted' -Seconds 3; return }
        'Delete' { $ch = 'x' }
        'Enter' { $ch = 'e' }
    }
    switch -CaseSensitive ($ch) {
        'a' { Open-TdTuiPrompt -Label 'Nouvelle tâche' -Hint 'titre durée | sous-étape ; sous-étape' -OnSubmit { param($text) Set-TdTuiDraftItem -Text $text } }
        'e' {
            if ($items.Count -eq 0) { return }
            Open-TdTuiPrompt -Label 'Tâche' -Text (ConvertTo-TdTemplateItemText $items[$sel]) -Hint 'titre durée | sous-étape ; sous-étape' -Data $sel -OnSubmit { param($text, $index) Set-TdTuiDraftItem -Text $text -Index $index }
        }
        'x' {
            if ($items.Count -eq 0) { return }
            $items.RemoveAt($sel)
            $draft.items = $items.ToArray()
            $tui.ItemSel = [Math]::Max(0, [Math]::Min($sel, $items.Count - 1))
        }
        'K' {
            if ($sel -gt 0) { $it = $items[$sel]; $items.RemoveAt($sel); $items.Insert($sel - 1, $it); $draft.items = $items.ToArray(); $tui.ItemSel = $sel - 1 }
        }
        'J' {
            if ($sel -lt $items.Count - 1) { $it = $items[$sel]; $items.RemoveAt($sel); $items.Insert($sel + 1, $it); $draft.items = $items.ToArray(); $tui.ItemSel = $sel + 1 }
        }
        'n' { Open-TdTuiPrompt -Label 'Nom de la routine' -Text $draft.name -OnSubmit { param($text) $script:Tui.RoutineDraft.name = $text.Trim() } }
        's' {
            if (@($draft.items).Count -eq 0) { Show-TdTuiMessage -Text 'Garde au moins une tâche dans la routine.' -Color 'overtime'; return }
            [void](Set-TdTemplate -UserTemplates $tui.Data.templates -Template $draft)
            Save-TdTuiTemplates
            $tui.Mode = 'routines'
            $tui.RoutineDraft = $null
            Show-TdTuiMessage -Text ('Routine « {0} » enregistrée.' -f $draft.name) -Color 'success' -Seconds 4
        }
        'q' { $tui.Mode = 'routines'; $tui.RoutineDraft = $null; Show-TdTuiMessage -Text 'Modifications abandonnées.' -Color 'muted' -Seconds 3 }
    }
}

function Get-TdTuiRoutinesFrame {
    param([long]$NowMs, [int]$Width, [int]$Height)
    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add('')
    $body.Add('  ' + (Format-TdTui -Text (Limit-TdTuiText -Text 'Les tâches de la routine s''ajoutent à la fin de ta liste. Toutes se modifient, y compris celles d''origine : [e].' -Width ($Width - 4)) -Color 'muted'))
    $body.Add('')
    $templates = @(Get-TdTuiTemplates)
    $items = @(for ($n = 0; $n -lt $templates.Count; $n++) {
            $tpl = $templates[$n]
            $total = 0.0
            foreach ($it in $tpl.items) { $total += [double]$it.minutes }
            $num = ''
            if ($n -lt 9) { $num = Format-TdTui -Text ([string]($n + 1)) -Color 'accent' -Bold }
            $meta = '{0} tâche(s) · {1}' -f @($tpl.items).Count, (Format-TdMinutes $total)
            if ((Get-TdTemplateOrigin $tpl) -eq 'modified') { $meta += ' · modifiée' }
            $num + '  ' + $tpl.name + (Format-TdTui -Text (' · ' + $meta) -Color 'muted')
        })
    foreach ($l in (Get-TdTuiSelectableLines -Items $items -Selected $script:Tui.ListSel -MaxLines ($Height - 11))) { $body.Add($l) }
    $hidden = Get-TdHiddenTemplateCount $script:Tui.Data.templates
    if ($hidden -gt 0) { $body.Add('    ' + (Format-TdTui -Text ('{0} routine(s) d''origine supprimée(s) · [R] rétablir' -f $hidden) -Color 'muted')) }
    $body.Add('')
    $body.Add('  ' + (Format-TdTui -Text 'Pour enregistrer la liste actuelle comme routine : [s] puis son nom.' -Color 'muted'))
    Get-TdTuiPage -NowMs $NowMs -Width $Width -Height $Height -Title 'Routines' -Body $body.ToArray()
}

function Get-TdTuiRoutineEditFrame {
    param([long]$NowMs, [int]$Width, [int]$Height)
    $draft = $script:Tui.RoutineDraft
    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add('')
    $body.Add('  ' + (Format-TdTui -Text 'MODIFIER LA ROUTINE' -Color 'accent' -Bold) + '  ' + (Format-TdTui -Text $draft.name -Color 'title' -Bold))
    $body.Add('  ' + (Format-TdTui -Text 'Rien n''est enregistré avant [s]. Échap abandonne les modifications.' -Color 'muted'))
    $body.Add('')
    $items = @(foreach ($it in @($draft.items)) {
            $meta = Format-TdMinutes $it.minutes
            $steps = @(@($it.steps) | Where-Object { $_ }).Count
            if ($steps -gt 0) { $meta += ' · {0} sous-étape(s)' -f $steps }
            $it.title + (Format-TdTui -Text ('  ' + $meta) -Color 'muted')
        })
    if ($items.Count -eq 0) { $body.Add('    ' + (Format-TdTui -Text 'Aucune tâche : [a] pour en ajouter.' -Color 'muted')) }
    foreach ($l in (Get-TdTuiSelectableLines -Items $items -Selected $script:Tui.ItemSel -MaxLines ($Height - 11))) { $body.Add($l) }
    Get-TdTuiPage -NowMs $NowMs -Width $Width -Height $Height -Title 'Routines' -Body $body.ToArray()
}
