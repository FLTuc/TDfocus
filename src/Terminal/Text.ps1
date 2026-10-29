# TDfocus (terminal) - outils de texte : couleurs ANSI, largeur affichée, gros chiffres.

$script:TdEsc = [string][char]27
$script:TdTuiPalette = @{
    accent   = '169;155;240'
    muted    = '150;145;168'
    title    = '236;234;244'
    overtime = '233;185;127'
    success  = '127;209;172'
    rule     = '70;67;86'
}
$script:TdTuiNoColor = [bool]$env:NO_COLOR

function Format-TdTui {
    # Texte coloré (couleurs 24 bits) ; respecte NO_COLOR.
    param([string]$Text, [string]$Color, [switch]$Bold, [switch]$Reverse, [switch]$Dim)
    if ($script:TdTuiNoColor) { return $Text }
    $codes = @()
    if ($Bold) { $codes += '1' }
    if ($Dim) { $codes += '2' }
    if ($Reverse) { $codes += '7' }
    if ($Color) { $codes += '38;2;' + $script:TdTuiPalette[$Color] }
    if ($codes.Count -eq 0) { return $Text }
    '{0}[{1}m{2}{0}[0m' -f $script:TdEsc, ($codes -join ';'), $Text
}

function Remove-TdAnsi {
    param([string]$Text)
    if (-not $Text) { return '' }
    [regex]::Replace($Text, '\x1b\[[0-9;?]*[A-Za-z]', '')
}

function Get-TdRuneWidth {
    # Largeur d'un caractère dans un terminal : 0 (combinant), 1 ou 2 (émoji, CJK).
    param([int]$Code)
    if ($Code -lt 32 -or ($Code -ge 0x7F -and $Code -lt 0xA0)) { return 0 }
    if (($Code -ge 0x0300 -and $Code -le 0x036F) -or $Code -eq 0x200D -or ($Code -ge 0xFE00 -and $Code -le 0xFE0F)) { return 0 }
    if (($Code -ge 0x1100 -and $Code -le 0x115F) -or ($Code -ge 0x2E80 -and $Code -le 0xA4CF) -or
        ($Code -ge 0xAC00 -and $Code -le 0xD7A3) -or ($Code -ge 0xF900 -and $Code -le 0xFAFF) -or
        ($Code -ge 0xFE30 -and $Code -le 0xFE4F) -or ($Code -ge 0xFF00 -and $Code -le 0xFF60) -or
        ($Code -ge 0xFFE0 -and $Code -le 0xFFE6) -or ($Code -ge 0x1F300 -and $Code -le 0x1FAFF) -or
        ($Code -ge 0x20000 -and $Code -le 0x3FFFD)) { return 2 }
    1
}

function Get-TdRunes {
    # Points de code d'une chaîne (paires de substitution regroupées).
    param([string]$Text)
    $codes = [System.Collections.Generic.List[int]]::new()
    if (-not $Text) { return , $codes.ToArray() }
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ([char]::IsHighSurrogate($Text[$i]) -and $i + 1 -lt $Text.Length) {
            $codes.Add([char]::ConvertToUtf32($Text[$i], $Text[$i + 1]))
            $i++
        }
        else { $codes.Add([int]$Text[$i]) }
    }
    , $codes.ToArray()
}

function Get-TdTextWidth {
    param([string]$Text)
    $width = 0
    foreach ($code in (Get-TdRunes (Remove-TdAnsi $Text))) { $width += Get-TdRuneWidth $code }
    $width
}

function Limit-TdTuiText {
    # Coupe un texte brut (sans couleurs) à une largeur affichée, avec « … ».
    param([string]$Text, [int]$Width)
    if ($Width -le 0 -or -not $Text) { return '' }
    if ((Get-TdTextWidth $Text) -le $Width) { return $Text }
    $builder = New-Object System.Text.StringBuilder
    $used = 0
    foreach ($code in (Get-TdRunes $Text)) {
        $w = Get-TdRuneWidth $code
        if ($used + $w -gt $Width - 1) { break }
        [void]$builder.Append([char]::ConvertFromUtf32($code))
        $used += $w
    }
    $builder.ToString() + [char]0x2026
}

$script:TdAnsiAt = [regex]'\G\x1b\[[0-9;?]*[A-Za-z]'

function Limit-TdTuiLine {
    # Coupe une ligne déjà colorée à une largeur affichée : filet de sécurité de chaque écran.
    param([string]$Line, [int]$Width)
    if (-not $Line -or (Get-TdTextWidth $Line) -le $Width) { return $Line }
    $builder = New-Object System.Text.StringBuilder
    $used = 0
    $i = 0
    while ($i -lt $Line.Length) {
        $ansi = $script:TdAnsiAt.Match($Line, $i)
        if ($ansi.Success) { [void]$builder.Append($ansi.Value); $i += $ansi.Length; continue }
        $len = 1
        $code = [int]$Line[$i]
        if ([char]::IsHighSurrogate($Line[$i]) -and $i + 1 -lt $Line.Length) { $len = 2; $code = [char]::ConvertToUtf32($Line[$i], $Line[$i + 1]) }
        $w = Get-TdRuneWidth $code
        if ($used + $w -gt $Width - 1) { break }
        [void]$builder.Append($Line.Substring($i, $len))
        $used += $w
        $i += $len
    }
    [void]$builder.Append([char]0x2026)
    if ($Line.IndexOf([char]27) -ge 0) { [void]$builder.Append("$script:TdEsc[0m") }
    $builder.ToString()
}

function Join-TdTuiColumns {
    # Ligne « gauche ... droite » à la largeur donnée (les deux parties peuvent être colorées).
    param([string]$Left, [string]$Right, [int]$Width)
    $lw = Get-TdTextWidth $Left
    $rw = Get-TdTextWidth $Right
    $space = $Width - $lw - $rw
    if ($space -lt 1) { return $Left }
    $Left + (' ' * $space) + $Right
}

$script:TdBigFont = @{
    '0' = @(' ███ ', '█   █', '█   █', '█   █', ' ███ ')
    '1' = @('  █  ', ' ██  ', '  █  ', '  █  ', ' ███ ')
    '2' = @(' ███ ', '█   █', '  ██ ', ' █   ', '█████')
    '3' = @('████ ', '    █', ' ███ ', '    █', '████ ')
    '4' = @('█   █', '█   █', '█████', '    █', '    █')
    '5' = @('█████', '█    ', '████ ', '    █', '████ ')
    '6' = @(' ███ ', '█    ', '████ ', '█   █', ' ███ ')
    '7' = @('█████', '    █', '   █ ', '  █  ', '  █  ')
    '8' = @(' ███ ', '█   █', ' ███ ', '█   █', ' ███ ')
    '9' = @(' ███ ', '█   █', ' ████', '    █', ' ███ ')
    ':' = @('   ', ' █ ', '   ', ' █ ', '   ')
    '+' = @('     ', '  █  ', ' ███ ', '  █  ', '     ')
}

function Get-TdBigText {
    # Minuteur en gros chiffres (5 lignes).
    param([Parameter(Mandatory)][string]$Text)
    $rows = @('', '', '', '', '')
    foreach ($ch in $Text.ToCharArray()) {
        $glyph = $script:TdBigFont[[string]$ch]
        if (-not $glyph) { continue }
        for ($r = 0; $r -lt 5; $r++) { $rows[$r] += $glyph[$r] + ' ' }
    }
    , @($rows | ForEach-Object { $_.TrimEnd() })
}

function Get-TdBigTextWidth {
    param([Parameter(Mandatory)][string]$Text)
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $glyph = $script:TdBigFont[[string]$ch]
        if ($glyph) { $width += $glyph[0].Length + 1 }
    }
    [Math]::Max(0, $width - 1)
}

function Get-TdProgressBar {
    param([double]$Fraction, [int]$Width, [string]$Color = 'accent')
    if ($Width -le 0) { return '' }
    $Fraction = [Math]::Min(1.0, [Math]::Max(0.0, $Fraction))
    $filled = [int][Math]::Round($Fraction * $Width)
    (Format-TdTui -Text ([string][char]0x2588 * $filled) -Color $Color) + (Format-TdTui -Text ([string][char]0x2591 * ($Width - $filled)) -Color 'rule')
}
