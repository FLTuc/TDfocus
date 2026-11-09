# TDfocus - routines (templates) chargeables en un clic.

function Get-TdDefaultCategories {
    # Outil de travail : uniquement des catégories professionnelles.
    @(
        [pscustomobject]@{ id = 'travail'; name = 'Production'; emoji = [char]::ConvertFromUtf32(0x1F4BC); color = '#8FB8E8' }
        [pscustomobject]@{ id = 'reunion'; name = 'Réunions'; emoji = [char]::ConvertFromUtf32(0x1F465); color = '#9FD8B5' }
        [pscustomobject]@{ id = 'communication'; name = 'E-mails'; emoji = [char]::ConvertFromUtf32(0x1F4E8); color = '#C9B6EC' }
        [pscustomobject]@{ id = 'admin'; name = 'Admin'; emoji = [char]::ConvertFromUtf32(0x1F4C4); color = '#E8D98F' }
        [pscustomobject]@{ id = 'veille'; name = 'Veille'; emoji = [char]::ConvertFromUtf32(0x1F4DA); color = '#F2B5C8' }
        [pscustomobject]@{ id = 'pause'; name = 'Pause'; emoji = [char]::ConvertFromUtf32(0x2615); color = '#F5C99B' }
    )
}

function Test-TdLegacyCategories {
    # Anciennes catégories par défaut (Travail, Maison, Pause, Perso, Santé, Admin), jamais modifiées.
    param([AllowNull()][AllowEmptyCollection()]$Categories)
    $names = @{}
    foreach ($c in @($Categories)) { if ($c) { $names[[string]$c.id] = [string]$c.name } }
    $legacy = @{ travail = 'Travail'; maison = 'Maison'; pause = 'Pause'; perso = 'Perso'; sante = 'Santé'; admin = 'Admin' }
    if ($names.Count -ne $legacy.Count) { return $false }
    foreach ($id in $legacy.Keys) { if ($names[$id] -ne $legacy[$id]) { return $false } }
    $true
}

function New-TdTemplateItem {
    param([string]$Title, [double]$Minutes, [string]$CategoryId, [string[]]$Steps = @())
    [pscustomobject][ordered]@{ title = $Title; minutes = $Minutes; categoryId = $CategoryId; steps = @($Steps) }
}

function Get-TdBuiltInTemplates {
    @(
        [pscustomobject][ordered]@{
            id      = 'builtin-morning'
            name    = 'Routine du matin'
            emoji   = [char]::ConvertFromUtf32(0x1F305)
            builtIn = $true
            hidden  = $false
            items   = @(
                New-TdTemplateItem 'Préparer mon poste de travail' 5 'travail' @('Fermer les onglets de la veille', 'Ouvrir les outils du jour', 'Couper les notifications non urgentes')
                New-TdTemplateItem 'Relever les e-mails et messages urgents' 10 'communication'
                New-TdTemplateItem 'Relire l''agenda du jour' 5 'reunion'
                New-TdTemplateItem 'Choisir les 3 priorités du jour' 5 'travail' @('Relire la liste', 'Choisir 3 priorités', 'Les placer en tête de file')
                New-TdTemplateItem 'Lancer la première priorité' 25 'travail'
            )
        }
        [pscustomobject][ordered]@{
            id      = 'builtin-deepwork'
            name    = 'Sprint de deep work'
            emoji   = [char]::ConvertFromUtf32(0x1F3AF)
            builtIn = $true
            hidden  = $false
            items   = @(
                New-TdTemplateItem 'Préparer le bloc' 5 'travail' @('Couper les notifications', 'Fermer les onglets inutiles', 'Noter le but du bloc')
                New-TdTemplateItem 'Bloc de concentration 1' 45 'travail'
                New-TdTemplateItem 'Pause' 10 'pause'
                New-TdTemplateItem 'Bloc de concentration 2' 45 'travail'
                New-TdTemplateItem 'Pause' 10 'pause'
                New-TdTemplateItem 'Bilan rapide' 5 'travail'
            )
        }
        [pscustomobject][ordered]@{
            id      = 'builtin-closing'
            name    = 'Routine de fin de journée'
            emoji   = [char]::ConvertFromUtf32(0x1F319)
            builtIn = $true
            hidden  = $false
            items   = @(
                New-TdTemplateItem 'Traiter les messages restants' 15 'communication'
                New-TdTemplateItem 'Mettre à jour le suivi des tâches' 10 'admin'
                New-TdTemplateItem 'Noter où je me suis arrêté·e' 5 'travail'
                New-TdTemplateItem 'Choisir les 3 priorités de demain' 10 'travail' @('Relire ce qui reste', 'Choisir 3 priorités', 'Les écrire dans TDfocus')
                New-TdTemplateItem 'Ranger le poste de travail' 5 'travail' @('Fermer les applications', 'Classer les documents du jour')
            )
        }
    )
}

function ConvertTo-TdTemplate {
    param([Parameter(Mandatory)]$InputObject)
    $items = foreach ($item in @(Get-TdValue $InputObject 'items')) {
        if ($null -eq $item) { continue }
        $title = [string](Get-TdValue $item 'title')
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        $minutes = Get-TdValue $item 'minutes'
        if ($null -eq $minutes -or [double]$minutes -lt 1) { $minutes = 25 }
        $steps = @(Get-TdValue $item 'steps' | Where-Object { $_ } | ForEach-Object { if ($_ -is [string]) { $_ } else { [string](Get-TdValue $_ 'title') } })
        New-TdTemplateItem $title ([double]$minutes) (ConvertTo-TdNullableString (Get-TdValue $item 'categoryId')) $steps
    }
    $id = ConvertTo-TdNullableString (Get-TdValue $InputObject 'id')
    if (-not $id) { $id = New-TdId }
    $emoji = ConvertTo-TdNullableString (Get-TdValue $InputObject 'emoji')
    if (-not $emoji) { $emoji = [char]::ConvertFromUtf32(0x1F4CB) }
    [pscustomobject][ordered]@{
        id      = $id
        name    = [string](Get-TdValue $InputObject 'name')
        emoji   = $emoji
        builtIn = $false
        hidden  = [bool](Get-TdValue $InputObject 'hidden')
        items   = @($items)
    }
}

function New-TdTemplateFromTasks {
    # Enregistre la liste actuelle comme routine réutilisable.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowEmptyCollection()]$Tasks)
    $items = foreach ($t in $Tasks) {
        New-TdTemplateItem $t.title ([Math]::Round([long]$t.plannedMs / 60000)) $t.categoryId @(@($t.steps) | Where-Object { $_ } | ForEach-Object { $_.title })
    }
    ConvertTo-TdTemplate @{ name = $Name.Trim(); items = @($items) }
}

function ConvertTo-TdTasksFromTemplate {
    param([Parameter(Mandatory)]$Template, [long]$NowMs = (Get-TdNowMs))
    $tasks = foreach ($item in $Template.items) {
        New-TdTask -Title $item.title -Minutes ([double]$item.minutes) -CategoryId $item.categoryId -Steps @($item.steps) -Source 'template' -NowMs $NowMs
    }
    , @($tasks)
}

# ---------------------------------------------------------------- modification des routines
# Une routine d'origine (identifiant « builtin-… ») se modifie par une copie enregistrée sous le
# même identifiant ; « Rétablir » supprime cette copie. Supprimer une routine d'origine la masque.

function Get-TdTemplates {
    # Routines proposées : celles d'origine (éventuellement modifiées ou masquées), puis les tiennes.
    param([AllowNull()][AllowEmptyCollection()]$UserTemplates)
    $own = @{}
    foreach ($t in @($UserTemplates)) { if ($t) { $own[[string]$t.id] = $t } }
    foreach ($b in (Get-TdBuiltInTemplates)) {
        if (-not $own.ContainsKey($b.id)) { $b; continue }
        if (-not $own[$b.id].hidden) { $own[$b.id] }
    }
    foreach ($t in @($UserTemplates)) { if ($t -and -not ([string]$t.id).StartsWith('builtin-')) { $t } }
}

function Get-TdTemplateOrigin {
    # builtin (d'origine), modified (d'origine modifiée) ou user (créée par toi).
    param([Parameter(Mandatory)]$Template)
    if (-not ([string]$Template.id).StartsWith('builtin-')) { return 'user' }
    if ($Template.builtIn) { return 'builtin' }
    'modified'
}

function Copy-TdTemplate {
    param([Parameter(Mandatory)]$Template)
    ConvertTo-TdTemplate (ConvertFrom-Json (ConvertTo-Json -InputObject $Template -Depth 6))
}

function Set-TdTemplate {
    # Enregistre une routine modifiée (remplace la version précédente, même identifiant).
    param([Parameter(Mandatory)][AllowEmptyCollection()]$UserTemplates, [Parameter(Mandatory)]$Template)
    $copy = Copy-TdTemplate $Template
    $copy.hidden = $false
    for ($i = 0; $i -lt $UserTemplates.Count; $i++) {
        if ($UserTemplates[$i].id -eq $copy.id) { $UserTemplates[$i] = $copy; return $copy }
    }
    $UserTemplates.Add($copy)
    $copy
}

function Reset-TdTemplate {
    # Rétablit une routine d'origine (supprime sa version modifiée ou masquée).
    param([Parameter(Mandatory)][AllowEmptyCollection()]$UserTemplates, [Parameter(Mandatory)][string]$Id)
    $removed = $false
    for ($i = $UserTemplates.Count - 1; $i -ge 0; $i--) {
        if ($UserTemplates[$i].id -eq $Id -and $Id.StartsWith('builtin-')) { $UserTemplates.RemoveAt($i); $removed = $true }
    }
    $removed
}

function Remove-TdTemplate {
    # Supprime une routine ; une routine d'origine est masquée (et peut être rétablie).
    param([Parameter(Mandatory)][AllowEmptyCollection()]$UserTemplates, [Parameter(Mandatory)][string]$Id)
    if (-not $Id.StartsWith('builtin-')) {
        for ($i = $UserTemplates.Count - 1; $i -ge 0; $i--) { if ($UserTemplates[$i].id -eq $Id) { $UserTemplates.RemoveAt($i) } }
        return
    }
    $original = Get-TdBuiltInTemplates | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $original) { return }
    $hidden = Set-TdTemplate -UserTemplates $UserTemplates -Template $original
    $hidden.hidden = $true
}

function Get-TdHiddenTemplateCount {
    param([AllowNull()][AllowEmptyCollection()]$UserTemplates)
    @($UserTemplates | Where-Object { $_ -and $_.hidden }).Count
}

function ConvertTo-TdTemplateItemText {
    # « Relever les e-mails 10 | étape ; étape » : une ligne par tâche de la routine.
    param([Parameter(Mandatory)]$Item)
    $text = '{0} {1}' -f $Item.title, (Format-TdQuickMinutes $Item.minutes)
    $steps = @(@($Item.steps) | Where-Object { $_ })
    if ($steps.Count -gt 0) { $text += ' | ' + ($steps -join ' ; ') }
    $text
}

function Format-TdQuickMinutes {
    # Durée relisible par la saisie rapide : 10, 1h30.
    param([double]$Minutes)
    $m = [int][Math]::Round($Minutes)
    if ($m -ge 60 -and $m % 60 -ne 0) { return '{0}h{1:00}' -f [int][Math]::Floor($m / 60), ($m % 60) }
    if ($m -ge 60) { return '{0}h' -f ($m / 60) }
    "$m"
}

function ConvertFrom-TdTemplateItemText {
    # Inverse de ConvertTo-TdTemplateItemText. La catégorie d'origine est conservée si fournie.
    param([string]$Text, [string]$CategoryId, [double]$DefaultMinutes = 10)
    $parts = $Text -split '\|', 2
    $parsed = ConvertFrom-TdQuickInput $parts[0].Trim()
    if (-not $parsed.title) { return $null }
    $minutes = $parsed.minutes
    if (-not $minutes) { $minutes = $DefaultMinutes }
    $steps = @()
    if ($parts.Count -gt 1) { $steps = @($parts[1] -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    New-TdTemplateItem $parsed.title ([double]$minutes) $CategoryId $steps
}
