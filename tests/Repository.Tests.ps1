BeforeDiscovery {
    $root = Split-Path -Parent $PSScriptRoot
    $script:ScriptFiles = Get-ChildItem -Path $root -Recurse -Include '*.ps1', '*.psm1', '*.psd1' |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
        ForEach-Object { @{ Name = $_.FullName.Substring($root.Length + 1); Path = $_.FullName } }
}

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Src = Join-Path $script:Root 'src'
    $script:XamlText = [System.IO.File]::ReadAllText((Join-Path $script:Src 'UI/MainWindow.xaml'))
}

Describe 'Fichiers PowerShell' {
    It '<Name> est en UTF-8 avec BOM (indispensable aux accents sous Windows PowerShell 5.1)' -ForEach $ScriptFiles {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
    }
    It '<Name> ne contient pas d''erreur de syntaxe' -ForEach $ScriptFiles {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'Interface' {
    It 'le XAML est bien formé et sans x:Class ni gestionnaire déclaré' {
        { [xml]$script:XamlText } | Should -Not -Throw
        $script:XamlText | Should -Not -Match 'x:Class'
        $script:XamlText | Should -Not -Match '\s(Click|Loaded|Checked)="'
    }
    It 'chaque élément $ui.Nom utilisé dans le code existe dans MainWindow.xaml' {
        $names = [regex]::Matches($script:XamlText, 'x:Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        $missing = foreach ($file in Get-ChildItem (Join-Path $script:Src 'UI') -Filter '*.ps1') {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            foreach ($m in [regex]::Matches($text, '(?:\$ui|\$script:Td\.Ui)\.([A-Z][A-Za-z0-9]+)')) {
                if ($names -notcontains $m.Groups[1].Value) { '{0}: {1}' -f $file.Name, $m.Groups[1].Value }
            }
        }
        $missing | Sort-Object -Unique | Should -BeNullOrEmpty
    }
    It 'chaque fonction « *-Td* » appelée est définie' {
        $files = Get-ChildItem -Path $script:Src, (Join-Path $script:Root 'tests'), $script:Root -Filter '*.ps1' -Recurse:$false
        $files = @($files) + @(Get-ChildItem -Path $script:Src -Recurse -Filter '*.ps1')
        $defined = @{}
        $called = @{}
        foreach ($file in ($files | Sort-Object FullName -Unique)) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $defined[$f.Name] = $true }
            foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $name = $c.GetCommandName()
                if ($name -and $name -match '^[A-Z][a-z]+-Td[A-Z]') { $called["$name ($($file.Name))"] = $name }
            }
        }
        # Les scripts réseau et de synthèse s'exécutent dans un runspace : leurs fonctions sont définies dans des chaînes.
        $defined['Invoke-TdHttp'] = $true
        $undefined = $called.GetEnumerator() | Where-Object { -not $defined.ContainsKey($_.Value) } | ForEach-Object Key
        $undefined | Sort-Object | Should -BeNullOrEmpty
    }
}
