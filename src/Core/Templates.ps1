# TDfocus - routines (templates) chargeables en un clic.

function Get-TdDefaultCategories {
    @(
        [pscustomobject]@{ id = 'travail'; name = 'Travail'; emoji = [char]::ConvertFromUtf32(0x1F4BC); color = '#8FB8E8' }
        [pscustomobject]@{ id = 'maison'; name = 'Maison'; emoji = [char]::ConvertFromUtf32(0x1F3E0); color = '#9FD8B5' }
        [pscustomobject]@{ id = 'pause'; name = 'Pause'; emoji = [char]::ConvertFromUtf32(0x2615); color = '#F5C99B' }
        [pscustomobject]@{ id = 'perso'; name = 'Perso'; emoji = [char]::ConvertFromUtf32(0x1F331); color = '#C9B6EC' }
        [pscustomobject]@{ id = 'sante'; name = 'Santé'; emoji = [char]::ConvertFromUtf32(0x1F9D8); color = '#F2B5C8' }
        [pscustomobject]@{ id = 'admin'; name = 'Admin'; emoji = [char]::ConvertFromUtf32(0x1F4C4); color = '#E8D98F' }
    )
}

function New-TdTemplateItem {
    param([string]$Title, [double]$Minutes, [string]$CategoryId)
    [pscustomobject][ordered]@{ title = $Title; minutes = $Minutes; categoryId = $CategoryId }
}

function Get-TdBuiltInTemplates {
    @(
        [pscustomobject][ordered]@{
            id      = 'builtin-morning'
            name    = 'Routine du matin'
            emoji   = [char]::ConvertFromUtf32(0x1F305)
            builtIn = $true
            items   = @(
                New-TdTemplateItem "Boire un grand verre d'eau" 2 'sante'
                New-TdTemplateItem 'Douche et habillage' 15 'maison'
                New-TdTemplateItem 'Petit-déjeuner' 15 'maison'
                New-TdTemplateItem 'Préparer mes affaires' 5 'maison'
                New-TdTemplateItem 'Relire la liste du jour' 5 'travail'
            )
        }
        [pscustomobject][ordered]@{
            id      = 'builtin-deepwork'
            name    = 'Sprint de deep work'
            emoji   = [char]::ConvertFromUtf32(0x1F3AF)
            builtIn = $true
            items   = @(
                New-TdTemplateItem 'Préparer l''espace (téléphone loin)' 5 'travail'
                New-TdTemplateItem 'Bloc de concentration 1' 45 'travail'
                New-TdTemplateItem 'Pause mouvement' 10 'pause'
                New-TdTemplateItem 'Bloc de concentration 2' 45 'travail'
                New-TdTemplateItem 'Pause' 10 'pause'
                New-TdTemplateItem 'Bilan rapide' 5 'travail'
            )
        }
        [pscustomobject][ordered]@{
            id      = 'builtin-closing'
            name    = 'Closing de fin de journée'
            emoji   = [char]::ConvertFromUtf32(0x1F319)
            builtIn = $true
            items   = @(
                New-TdTemplateItem 'Vider la boîte de réception' 15 'travail'
                New-TdTemplateItem 'Noter où je me suis arrêté·e' 5 'travail'
                New-TdTemplateItem 'Choisir les 3 priorités de demain' 10 'travail'
                New-TdTemplateItem 'Ranger le bureau' 5 'maison'
                New-TdTemplateItem 'Déconnexion douce' 10 'pause'
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
        New-TdTemplateItem $title ([double]$minutes) (ConvertTo-TdNullableString (Get-TdValue $item 'categoryId'))
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
        items   = @($items)
    }
}

function New-TdTemplateFromTasks {
    # Enregistre la liste actuelle comme routine réutilisable.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowEmptyCollection()]$Tasks)
    $items = foreach ($t in $Tasks) {
        New-TdTemplateItem $t.title ([Math]::Round([long]$t.plannedMs / 60000)) $t.categoryId
    }
    ConvertTo-TdTemplate @{ name = $Name.Trim(); items = @($items) }
}

function ConvertTo-TdTasksFromTemplate {
    param([Parameter(Mandatory)]$Template, [long]$NowMs = (Get-TdNowMs))
    $tasks = foreach ($item in $Template.items) {
        New-TdTask -Title $item.title -Minutes ([double]$item.minutes) -CategoryId $item.categoryId -Source 'template' -NowMs $NowMs
    }
    , @($tasks)
}
