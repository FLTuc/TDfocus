# TDfocus - saisie rapide en un seul champ.
# Exemples :
#   "Répondre aux emails 15"       -> 15 min
#   "Rapport 1h30"                 -> 90 min
#   "Appeler la banque 10min @14h" -> 10 min, créneau figé à 14:00
#   "Réunion d'équipe à 9h30 45m"  -> 45 min, créneau figé à 09:30

function ConvertFrom-TdQuickInput {
    param([string]$Text)
    $result = [ordered]@{ title = ''; minutes = $null; fixedStart = $null }
    if ([string]::IsNullOrWhiteSpace($Text)) { return [pscustomobject]$result }

    $s = ' ' + ($Text.Trim() -replace '\s+', ' ') + ' '

    # Heure fixe : "@14h", "@14:30", "@9", "à 14h30"
    $fixedPatterns = @(
        '(?i)\s@\s*([01]?\d|2[0-3])(?:\s*[:h]\s*([0-5]\d)?)?(?=\s)',
        '(?i)\s(?:à|à)\s+([01]?\d|2[0-3])\s*[:h]\s*([0-5]\d)?(?=\s)'
    )
    foreach ($pattern in $fixedPatterns) {
        $m = [regex]::Match($s, $pattern)
        if ($m.Success) {
            $minute = 0
            if ($m.Groups[2].Success -and $m.Groups[2].Value) { $minute = [int]$m.Groups[2].Value }
            $result.fixedStart = '{0:00}:{1:00}' -f [int]$m.Groups[1].Value, $minute
            $s = $s.Remove($m.Index, $m.Length).Insert($m.Index, ' ')
            break
        }
    }

    # Durée en heures : "1h", "1h30", "2 h 15 min" (1 à 12 h pour ne pas confondre avec une heure)
    $m = [regex]::Match($s, '(?i)\s(1[0-2]|0?[1-9])\s*h(?:eures?)?\s*(?:([0-5]?\d)\s*(?:min|mn|m)?)?(?=\s)')
    if ($m.Success) {
        $minutes = [int]$m.Groups[1].Value * 60
        if ($m.Groups[2].Success -and $m.Groups[2].Value) { $minutes += [int]$m.Groups[2].Value }
        $result.minutes = $minutes
        $s = $s.Remove($m.Index, $m.Length).Insert($m.Index, ' ')
    }
    else {
        # Durée en minutes : "25min", "25 m", "25 minutes"
        $m = [regex]::Match($s, '(?i)\s(\d{1,3})\s*(?:minutes?|min|mn|m)(?=\s)')
        if ($m.Success -and [int]$m.Groups[1].Value -ge 1) {
            $result.minutes = [int]$m.Groups[1].Value
            $s = $s.Remove($m.Index, $m.Length).Insert($m.Index, ' ')
        }
        else {
            # Nombre seul en fin de saisie : "Emails 15"
            $m = [regex]::Match($s, '\s(\d{1,3})\s*$')
            if ($m.Success) {
                $before = $s.Substring(0, $m.Index).Trim()
                $value = [int]$m.Groups[1].Value
                if ($before -and $value -ge 1 -and $value -le 480) {
                    $result.minutes = $value
                    $s = $s.Substring(0, $m.Index)
                }
            }
        }
    }

    $title = ($s -replace '\s+', ' ').Trim()
    $title = $title.Trim(' ', '-', ',', ';', ':', [char]0x2013, [char]0x2014)
    $result.title = $title
    [pscustomobject]$result
}
