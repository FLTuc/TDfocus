# Cockpit flottant, étape 1 : positions, tailles, réglages et date (calculs sans interface).
# Les variables préparées dans BeforeEach sont utilisées dans les blocs It (portée Pester).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\TDfocus.Core.ps1')
    # Écran Full HD sans la barre des tâches, puis petit portable.
    $script:Big = @{ Left = 0; Top = 0; Width = 1920; Height = 1040 }
    $script:Small = @{ Left = 0; Top = 0; Width = 1366; Height = 728 }
}

Describe 'Réglages du cockpit' {
    It 'affiche la bulle par défaut, fermée, sans position imposée' {
        $s = ConvertTo-TdCockpitSettings $null
        $s.enabled | Should -BeTrue
        $s.open | Should -BeFalse
        $s.left | Should -BeNullOrEmpty
        $s.top | Should -BeNullOrEmpty
    }
    It 'relit les réglages enregistrés et ignore les valeurs illisibles' {
        $s = ConvertTo-TdCockpitSettings ('{"enabled":false,"open":true,"left":1200.5,"top":"abc"}' | ConvertFrom-Json)
        $s.enabled | Should -BeFalse
        $s.open | Should -BeTrue
        $s.left | Should -Be 1200.5
        $s.top | Should -BeNullOrEmpty
    }
    It 'fait partie des réglages de TDfocus et survit à l''enregistrement' {
        (ConvertTo-TdSettings $null).cockpit.enabled | Should -BeTrue
        $settings = ConvertTo-TdSettings $null
        $settings.cockpit.left = 40
        $settings.cockpit.open = $true
        $back = ConvertTo-TdSettings (ConvertTo-Json -InputObject $settings -Depth 8 | ConvertFrom-Json)
        $back.cockpit.left | Should -Be 40
        $back.cockpit.open | Should -BeTrue
        $back.cockpit.enabled | Should -BeTrue
    }
}

Describe 'Place de la bulle' {
    It 'apparaît en bas à droite, entièrement visible' {
        $p = Get-TdCockpitDefaultPosition -Area $Big
        $p.Left | Should -Be (1920 - 100 - 16)
        $p.Top | Should -Be (1040 - 100 - 152)
    }
    It 'tient compte d''un écran secondaire placé à gauche (coordonnées négatives)' {
        $p = Get-TdCockpitDefaultPosition -Area @{ Left = -1280; Top = 0; Width = 1280; Height = 984 }
        $p.Left | Should -Be (-1280 + 1280 - 100 - 16)
    }
    It 'est ramenée dans l''écran quand on la lâche trop loin' {
        $p = Limit-TdCockpitPosition -Left 5000 -Top -300 -Width 100 -Height 100 -Area $Big
        $p.Left | Should -Be 1820
        $p.Top | Should -Be 0
    }
    It 'distingue un clic d''un déplacement' {
        Test-TdCockpitMoved -StartLeft 100 -StartTop 100 -EndLeft 102 -EndTop 101 | Should -BeFalse
        Test-TdCockpitMoved -StartLeft 100 -StartTop 100 -EndLeft 100 -EndTop 140 | Should -BeTrue
    }
}

Describe 'Taille et place du cockpit' {
    It 'mesure 420 × 860 sur un grand écran' {
        $size = Get-TdCockpitPanelSize -Area $Big
        $size.Width | Should -Be 420
        $size.Height | Should -Be 860
    }
    It 'réduit sa hauteur sur un petit écran' {
        (Get-TdCockpitPanelSize -Area $Small).Height | Should -Be (728 - 24)
    }
    It 's''ouvre dans le coin où se trouve la bulle' -ForEach @(
        @{ Name = 'bas-droite'; Left = 1804; Top = 788; Right = $true; Bottom = $true; PanelLeft = 1484; PanelTop = 28 }
        @{ Name = 'haut-gauche'; Left = 20; Top = 30; Right = $false; Bottom = $false; PanelLeft = 20; PanelTop = 30 }
        @{ Name = 'haut-droite'; Left = 1700; Top = 0; Right = $true; Bottom = $false; PanelLeft = 1380; PanelTop = 12 }
        @{ Name = 'bas-gauche'; Left = 0; Top = 940; Right = $false; Bottom = $true; PanelLeft = 12; PanelTop = 168 }
    ) {
        $anchor = Get-TdCockpitAnchor -BubbleLeft $Left -BubbleTop $Top -Area $Big
        $anchor.Right | Should -Be $Right
        $anchor.Bottom | Should -Be $Bottom
        $p = Get-TdCockpitPanelPosition -BubbleLeft $Left -BubbleTop $Top -PanelWidth 420 -PanelHeight 860 -Anchor $anchor -Area $Big
        $p.Left | Should -Be $PanelLeft
        $p.Top | Should -Be $PanelTop
    }
    It 'reste entièrement dans un petit écran' {
        $size = Get-TdCockpitPanelSize -Area $Small
        $anchor = Get-TdCockpitAnchor -BubbleLeft 1250 -BubbleTop 476 -Area $Small
        $p = Get-TdCockpitPanelPosition -BubbleLeft 1250 -BubbleTop 476 -PanelWidth $size.Width -PanelHeight $size.Height -Anchor $anchor -Area $Small
        $p.Top | Should -BeGreaterOrEqual 12
        ($p.Top + $size.Height) | Should -BeLessOrEqual (728 - 12)
        ($p.Left + $size.Width) | Should -BeLessOrEqual (1366 - 12)
    }
    It 'rend la bulle au même coin après un déplacement du cockpit' {
        $anchor = @{ Right = $true; Bottom = $true }
        $b = Get-TdCockpitBubblePosition -PanelLeft 600 -PanelTop 100 -PanelWidth 420 -PanelHeight 860 -Anchor $anchor -Area $Big
        $b.Left | Should -Be (600 + 420 - 100)
        $b.Top | Should -Be (100 + 860 - 100)
        $b = Get-TdCockpitBubblePosition -PanelLeft 600 -PanelTop 100 -PanelWidth 420 -PanelHeight 860 -Anchor @{ Right = $false; Bottom = $false } -Area $Big
        $b.Left | Should -Be 600
        $b.Top | Should -Be 100
    }
}

Describe 'Date de l''en-tête' {
    It 'commence par une majuscule et donne le jour et le mois' {
        $text = Format-TdCockpitDate (ConvertFrom-TdLocalDate ([DateTime]::new(2026, 10, 29, 14, 32, 0)))
        $text | Should -Match '29'
        $text.Substring(0, 1) | Should -MatchExactly '[A-Z]'
    }
}
