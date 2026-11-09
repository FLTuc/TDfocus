# Routines modifiables (y compris celles d'origine) et catégories professionnelles.
# Les variables préparées dans BeforeEach sont utilisées dans les blocs It (portée Pester).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\TDfocus.Core.ps1')
}

Describe 'Routines modifiables' {
    BeforeEach { $user = [System.Collections.Generic.List[object]]::new() }

    It 'propose les 3 routines d''origine, toutes professionnelles' {
        $all = @(Get-TdTemplates $user)
        ($all | ForEach-Object name) -join '|' | Should -Be 'Routine du matin|Sprint de deep work|Routine de fin de journée'
        foreach ($t in $all) { Get-TdTemplateOrigin $t | Should -Be 'builtin' }
    }
    It 'modifie la routine du matin sans toucher à l''original' {
        $morning = Copy-TdTemplate (Get-TdTemplates $user | Where-Object id -eq 'builtin-morning')
        $morning.name = 'Démarrage de journée'
        $morning.items = @($morning.items[1], (New-TdTemplateItem 'Point d''équipe' 15 'reunion'))
        [void](Set-TdTemplate -UserTemplates $user -Template $morning)
        $edited = Get-TdTemplates $user | Where-Object id -eq 'builtin-morning'
        $edited.name | Should -Be 'Démarrage de journée'
        $edited.items.Count | Should -Be 2
        Get-TdTemplateOrigin $edited | Should -Be 'modified'
        @(Get-TdTemplates $user).Count | Should -Be 3
        (Get-TdBuiltInTemplates | Where-Object id -eq 'builtin-morning').name | Should -Be 'Routine du matin'
    }
    It 'rétablit la routine d''origine' {
        $closing = Copy-TdTemplate (Get-TdTemplates $user | Where-Object id -eq 'builtin-closing')
        $closing.name = 'Fin de journée courte'
        [void](Set-TdTemplate -UserTemplates $user -Template $closing)
        Reset-TdTemplate -UserTemplates $user -Id 'builtin-closing' | Should -BeTrue
        (Get-TdTemplates $user | Where-Object id -eq 'builtin-closing').name | Should -Be 'Routine de fin de journée'
        $user.Count | Should -Be 0
    }
    It 'masque une routine d''origine supprimée, puis la rétablit' {
        Remove-TdTemplate -UserTemplates $user -Id 'builtin-deepwork'
        @(Get-TdTemplates $user | Where-Object id -eq 'builtin-deepwork').Count | Should -Be 0
        Get-TdHiddenTemplateCount $user | Should -Be 1
        [void](Reset-TdTemplate -UserTemplates $user -Id 'builtin-deepwork')
        @(Get-TdTemplates $user).Count | Should -Be 3
    }
    It 'modifie et supprime une routine créée' {
        $mine = New-TdTemplateFromTasks -Name 'Lundi' -Tasks @(New-TdTask -Title 'Rapport hebdo' -Minutes 30)
        $user.Add($mine)
        $copy = Copy-TdTemplate $mine
        $copy.name = 'Lundi matin'
        [void](Set-TdTemplate -UserTemplates $user -Template $copy)
        $user.Count | Should -Be 1
        (Get-TdTemplates $user | Where-Object id -eq $mine.id).name | Should -Be 'Lundi matin'
        Get-TdTemplateOrigin $copy | Should -Be 'user'
        Remove-TdTemplate -UserTemplates $user -Id $mine.id
        $user.Count | Should -Be 0
    }
    It 'survit à l''enregistrement JSON' {
        Remove-TdTemplate -UserTemplates $user -Id 'builtin-deepwork'
        $copy = ConvertTo-TdTemplate (ConvertTo-Json -InputObject $user[0] -Depth 6 | ConvertFrom-Json)
        $copy.hidden | Should -BeTrue
        $copy.id | Should -Be 'builtin-deepwork'
    }
    It 'écrit et relit une tâche de routine en une ligne' {
        $item = New-TdTemplateItem 'Choisir les 3 priorités' 10 'travail' @('Relire la liste', 'Choisir 3 priorités')
        $text = ConvertTo-TdTemplateItemText $item
        $text | Should -Be 'Choisir les 3 priorités 10 | Relire la liste ; Choisir 3 priorités'
        $back = ConvertFrom-TdTemplateItemText -Text $text -CategoryId 'travail'
        $back.title | Should -Be 'Choisir les 3 priorités'
        $back.minutes | Should -Be 10
        $back.steps -join '|' | Should -Be 'Relire la liste|Choisir 3 priorités'
        $back.categoryId | Should -Be 'travail'
        (ConvertFrom-TdTemplateItemText -Text (ConvertTo-TdTemplateItemText (New-TdTemplateItem 'Bloc de concentration 1' 45 'travail'))).title | Should -Be 'Bloc de concentration 1'
        (ConvertFrom-TdTemplateItemText -Text (ConvertTo-TdTemplateItemText (New-TdTemplateItem 'Revue' 90 'travail'))).minutes | Should -Be 90
        (ConvertFrom-TdTemplateItemText -Text 'Veille techno').minutes | Should -Be 10
        ConvertFrom-TdTemplateItemText -Text '   ' | Should -BeNullOrEmpty
    }
}

Describe 'Catégories professionnelles' {
    It 'propose uniquement des catégories de travail' {
        (Get-TdDefaultCategories | ForEach-Object name) -join '|' | Should -Be 'Production|Réunions|E-mails|Admin|Veille|Pause'
    }
    It 'remplace les anciennes catégories par défaut (Maison, Perso, Santé…)' {
        $old = @(
            @{ id = 'travail'; name = 'Travail' }, @{ id = 'maison'; name = 'Maison' }, @{ id = 'pause'; name = 'Pause' },
            @{ id = 'perso'; name = 'Perso' }, @{ id = 'sante'; name = 'Santé' }, @{ id = 'admin'; name = 'Admin' }
        )
        $settings = ConvertTo-TdSettings @{ categories = $old }
        ($settings.categories | ForEach-Object name) -join '|' | Should -Be 'Production|Réunions|E-mails|Admin|Veille|Pause'
    }
    It 'garde des catégories personnalisées' {
        $custom = @(@{ id = 'clients'; name = 'Clients'; emoji = 'C'; color = '#FFFFFF' })
        (ConvertTo-TdSettings @{ categories = $custom }).categories[0].name | Should -Be 'Clients'
    }
    It 'les routines d''origine n''utilisent que des catégories existantes' {
        $ids = Get-TdDefaultCategories | ForEach-Object id
        foreach ($t in Get-TdBuiltInTemplates) { foreach ($i in $t.items) { $ids | Should -Contain $i.categoryId } }
    }
}
