# TDfocus - outils de temps.
# Toutes les heures sont stockées en millisecondes Unix (UTC) ; l'affichage se fait en heure locale.

$script:TdCulture = [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')

function Get-TdNowMs {
    [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function ConvertTo-TdLocalDate {
    param([Parameter(Mandatory)][long]$Ms)
    [DateTimeOffset]::FromUnixTimeMilliseconds($Ms).ToLocalTime().DateTime
}

function ConvertFrom-TdLocalDate {
    param([Parameter(Mandatory)][DateTime]$Date)
    $local = [DateTime]::SpecifyKind($Date, [DateTimeKind]::Local)
    ([DateTimeOffset]$local).ToUnixTimeMilliseconds()
}

function Format-TdClock {
    # 14:05
    param([Parameter(Mandatory)][long]$Ms)
    (ConvertTo-TdLocalDate $Ms).ToString('HH:mm', $script:TdCulture)
}

function Format-TdTimer {
    # Minuteur : 04:59, 1:02:03. Le signe est géré par l'appelant.
    param([Parameter(Mandatory)][double]$Ms)
    $totalSeconds = [long][Math]::Floor([Math]::Abs($Ms) / 1000)
    $h = [long][Math]::Floor($totalSeconds / 3600)
    $m = [long][Math]::Floor(($totalSeconds % 3600) / 60)
    $s = $totalSeconds % 60
    if ($h -gt 0) { return ('{0}:{1:00}:{2:00}' -f $h, $m, $s) }
    '{0:00}:{1:00}' -f $m, $s
}

function Format-TdCountdown {
    # Compte à rebours : arrondi à la seconde supérieure pour ne jamais afficher 00:00 trop tôt.
    param([Parameter(Mandatory)][double]$Ms)
    if ($Ms -le 0) { return '00:00' }
    Format-TdTimer ([Math]::Ceiling($Ms / 1000) * 1000)
}

function Format-TdMinutes {
    # 25 min, 1 h, 1 h 30
    param([Parameter(Mandatory)][double]$Minutes)
    $total = [long][Math]::Round($Minutes)
    if ($total -lt 60) { return "$total min" }
    $h = [long][Math]::Floor($total / 60)
    $m = $total % 60
    if ($m -eq 0) { return "$h h" }
    '{0} h {1:00}' -f $h, $m
}

function Format-TdDurationMs {
    param([Parameter(Mandatory)][double]$Ms)
    Format-TdMinutes ([Math]::Round($Ms / 60000))
}

function Get-TdDayKey {
    # Clé de journée locale : 2026-10-29
    param([Parameter(Mandatory)][long]$Ms)
    (ConvertTo-TdLocalDate $Ms).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-TdDayStartMs {
    param([Parameter(Mandatory)][long]$Ms)
    ConvertFrom-TdLocalDate ((ConvertTo-TdLocalDate $Ms).Date)
}

function Test-TdClockText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $Text -match '^([01]?\d|2[0-3])[:hH]([0-5]\d)?$'
}

function ConvertTo-TdClockText {
    # Normalise '9h', '9:5', '09h30' en 'HH:mm'. Renvoie $null si invalide.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    if ($t -notmatch '^([01]?\d|2[0-3])\s*[:hH]\s*([0-5]?\d)?$') { return $null }
    $h = [int]$Matches[1]
    $m = 0
    if ($Matches[2]) { $m = [int]$Matches[2] }
    '{0:00}:{1:00}' -f $h, $m
}

function ConvertFrom-TdClockText {
    # 'HH:mm' du jour de $DayMs -> ms Unix.
    param(
        [Parameter(Mandatory)][string]$Clock,
        [Parameter(Mandatory)][long]$DayMs
    )
    $normalized = ConvertTo-TdClockText $Clock
    if (-not $normalized) { return $null }
    $parts = $normalized.Split(':')
    $day = (ConvertTo-TdLocalDate $DayMs).Date
    ConvertFrom-TdLocalDate ($day.AddHours([int]$parts[0]).AddMinutes([int]$parts[1]))
}

function Format-TdDayLabel {
    # lun. 29
    param([Parameter(Mandatory)][string]$DayKey)
    $d = [DateTime]::ParseExact($DayKey, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $d.ToString('ddd d', $script:TdCulture)
}
