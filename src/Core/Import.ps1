# TDfocus - importation unidirectionnelle de la to-do du jour.
# Sources : calendrier iCalendar (.ics / adresse secrète Google Agenda / Outlook),
# Todoist, Notion et texte collé (listes Markdown, copier-coller Notion...).
# Toutes les fonctions renvoient des éléments { title, minutes, fixedStart, allDay, externalId }.

$script:TdIanaToWindows = @{
    'UTC'                 = 'UTC'
    'Etc/UTC'             = 'UTC'
    'Europe/Paris'        = 'Romance Standard Time'
    'Europe/Brussels'     = 'Romance Standard Time'
    'Europe/Madrid'       = 'Romance Standard Time'
    'Europe/Luxembourg'   = 'W. Europe Standard Time'
    'Europe/Monaco'       = 'W. Europe Standard Time'
    'Europe/Zurich'       = 'W. Europe Standard Time'
    'Europe/Berlin'       = 'W. Europe Standard Time'
    'Europe/Amsterdam'    = 'W. Europe Standard Time'
    'Europe/Rome'         = 'W. Europe Standard Time'
    'Europe/London'       = 'GMT Standard Time'
    'Europe/Dublin'       = 'GMT Standard Time'
    'Europe/Lisbon'       = 'GMT Standard Time'
    'Africa/Casablanca'   = 'Morocco Standard Time'
    'Africa/Algiers'      = 'W. Central Africa Standard Time'
    'Africa/Tunis'        = 'W. Central Africa Standard Time'
    'Africa/Dakar'        = 'Greenwich Standard Time'
    'Africa/Abidjan'      = 'Greenwich Standard Time'
    'America/Montreal'    = 'Eastern Standard Time'
    'America/Toronto'     = 'Eastern Standard Time'
    'America/New_York'    = 'Eastern Standard Time'
    'America/Chicago'     = 'Central Standard Time'
    'America/Denver'      = 'Mountain Standard Time'
    'America/Los_Angeles' = 'Pacific Standard Time'
    'Indian/Reunion'      = 'Mauritius Standard Time'
    'America/Martinique'  = 'SA Western Standard Time'
    'America/Guadeloupe'  = 'SA Western Standard Time'
    'Pacific/Noumea'      = 'Central Pacific Standard Time'
    'Pacific/Tahiti'      = 'Hawaiian Standard Time'
    'Asia/Tokyo'          = 'Tokyo Standard Time'
}

function Get-TdTimeZone {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    $id = $Id.Trim('"')
    foreach ($candidate in @($id, $script:TdIanaToWindows[$id])) {
        if (-not $candidate) { continue }
        try { return [TimeZoneInfo]::FindSystemTimeZoneById($candidate) } catch { $null = $_ }
    }
    $null
}

function ConvertFrom-TdIcsText {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    $Value -replace '\\[nN]', ' ' -replace '\\([,;\\])', '$1'
}

function ConvertFrom-TdIcsLine {
    # NOM;PARAM=VAL;PARAM2="v:al":VALEUR
    param([string]$Line)
    $m = [regex]::Match($Line, '^(?<name>[A-Za-z0-9-]+)(?<params>(?:;[^:;=]+=(?:"[^"]*"|[^:;]*))*):(?<value>.*)$')
    if (-not $m.Success) { return $null }
    $params = @{}
    foreach ($pm in [regex]::Matches($m.Groups['params'].Value, ';([^:;=]+)=("[^"]*"|[^:;]*)')) {
        $params[$pm.Groups[1].Value.ToUpperInvariant()] = $pm.Groups[2].Value.Trim('"')
    }
    [pscustomobject]@{
        name   = $m.Groups['name'].Value.ToUpperInvariant()
        params = $params
        value  = $m.Groups['value'].Value
    }
}

function ConvertFrom-TdIcsDate {
    # Renvoie { local = [DateTime] heure locale ; allDay = [bool] } ou $null.
    param([string]$Value, [hashtable]$Params = @{})
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $v = $Value.Trim()
    if ($Params['VALUE'] -eq 'DATE' -or $v -match '^\d{8}$') {
        $d = [DateTime]::ParseExact($v.Substring(0, 8), 'yyyyMMdd', $inv)
        return [pscustomobject]@{ local = $d; allDay = $true }
    }
    if ($v -match '^(\d{8}T\d{6})Z$') {
        $utc = [DateTime]::ParseExact($Matches[1], "yyyyMMdd'T'HHmmss", $inv,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        return [pscustomobject]@{ local = $utc.ToLocalTime(); allDay = $false }
    }
    if ($v -match '^(\d{8}T\d{4,6})$') {
        $raw = $Matches[1]
        if ($raw.Length -eq 13) { $raw += '00' }
        $dt = [DateTime]::ParseExact($raw, "yyyyMMdd'T'HHmmss", $inv)
        $tz = Get-TdTimeZone $Params['TZID']
        if ($tz) {
            $unspecified = [DateTime]::SpecifyKind($dt, [DateTimeKind]::Unspecified)
            $utc = [TimeZoneInfo]::ConvertTimeToUtc($unspecified, $tz)
            return [pscustomobject]@{ local = $utc.ToLocalTime(); allDay = $false }
        }
        # Heure « flottante » : interprétée en heure locale.
        return [pscustomobject]@{ local = [DateTime]::SpecifyKind($dt, [DateTimeKind]::Local); allDay = $false }
    }
    $null
}

function ConvertFrom-TdIcsDuration {
    # P1DT2H30M -> TimeSpan
    param([string]$Value)
    if ($Value -notmatch '^(?<sign>[+-])?P(?:(?<w>\d+)W)?(?:(?<d>\d+)D)?(?:T(?:(?<h>\d+)H)?(?:(?<m>\d+)M)?(?:(?<s>\d+)S)?)?$') { return $null }
    $ts = New-Object TimeSpan
    if ($Matches['w']) { $ts = $ts.Add([TimeSpan]::FromDays(7 * [int]$Matches['w'])) }
    if ($Matches['d']) { $ts = $ts.Add([TimeSpan]::FromDays([int]$Matches['d'])) }
    if ($Matches['h']) { $ts = $ts.Add([TimeSpan]::FromHours([int]$Matches['h'])) }
    if ($Matches['m']) { $ts = $ts.Add([TimeSpan]::FromMinutes([int]$Matches['m'])) }
    if ($Matches['s']) { $ts = $ts.Add([TimeSpan]::FromSeconds([int]$Matches['s'])) }
    $ts
}

function ConvertFrom-TdRRule {
    param([string]$Value)
    $rule = @{}
    foreach ($part in $Value.Split(';')) {
        $kv = $part.Split('=', 2)
        if ($kv.Count -eq 2) { $rule[$kv[0].Trim().ToUpperInvariant()] = $kv[1].Trim() }
    }
    $rule
}

$script:TdIcsDays = @{ MO = [DayOfWeek]::Monday; TU = [DayOfWeek]::Tuesday; WE = [DayOfWeek]::Wednesday; TH = [DayOfWeek]::Thursday; FR = [DayOfWeek]::Friday; SA = [DayOfWeek]::Saturday; SU = [DayOfWeek]::Sunday }

function Get-TdMondayOf {
    param([DateTime]$Date)
    $offset = (([int]$Date.DayOfWeek) + 6) % 7
    $Date.Date.AddDays(-$offset)
}

function Test-TdRRuleDay {
    # Le jour $Day correspond-il au motif (sans tenir compte de COUNT/UNTIL) ?
    param([hashtable]$Rule, [DateTime]$Start, [DateTime]$Day)
    $freq = ([string]$Rule['FREQ']).ToUpperInvariant()
    $interval = 1
    if ($Rule['INTERVAL']) { $interval = [Math]::Max(1, [int]$Rule['INTERVAL']) }
    $startDate = $Start.Date
    $byDay = @()
    if ($Rule['BYDAY']) {
        $byDay = foreach ($token in $Rule['BYDAY'].Split(',')) {
            if ($token.Trim() -match '^(?<n>[+-]?\d{1,2})?(?<d>MO|TU|WE|TH|FR|SA|SU)$') {
                $n = 0
                if ($Matches['n']) { $n = [int]$Matches['n'] }
                [pscustomobject]@{ n = $n; day = $script:TdIcsDays[$Matches['d']] }
            }
        }
        $byDay = @($byDay)
    }
    $byMonthDay = @()
    if ($Rule['BYMONTHDAY']) { $byMonthDay = @($Rule['BYMONTHDAY'].Split(',') | ForEach-Object { [int]$_ }) }
    $byMonth = @()
    if ($Rule['BYMONTH']) { $byMonth = @($Rule['BYMONTH'].Split(',') | ForEach-Object { [int]$_ }) }

    if ($byMonth.Count -gt 0 -and $byMonth -notcontains $Day.Month) { return $false }
    $daysInMonth = [DateTime]::DaysInMonth($Day.Year, $Day.Month)
    $monthDayOk = {
        param($d)
        foreach ($md in $byMonthDay) {
            if ($md -gt 0 -and $d.Day -eq $md) { return $true }
            if ($md -lt 0 -and $d.Day -eq ($daysInMonth + $md + 1)) { return $true }
        }
        $false
    }
    $byDayOk = {
        param($d, [bool]$UseOrdinal)
        foreach ($bd in $byDay) {
            if ($bd.day -ne $d.DayOfWeek) { continue }
            if (-not $UseOrdinal -or $bd.n -eq 0) { return $true }
            if ($bd.n -gt 0 -and [Math]::Ceiling($d.Day / 7) -eq $bd.n) { return $true }
            if ($bd.n -lt 0 -and [Math]::Floor(($daysInMonth - $d.Day) / 7) + 1 -eq -$bd.n) { return $true }
        }
        $false
    }

    switch ($freq) {
        'DAILY' {
            if ((($Day - $startDate).Days % $interval) -ne 0) { return $false }
            if ($byDay.Count -gt 0) { return (& $byDayOk $Day $false) }
            if ($byMonthDay.Count -gt 0) { return (& $monthDayOk $Day) }
            return $true
        }
        'WEEKLY' {
            $weeks = [int][Math]::Floor(((Get-TdMondayOf $Day) - (Get-TdMondayOf $startDate)).TotalDays / 7)
            if (($weeks % $interval) -ne 0) { return $false }
            if ($byDay.Count -gt 0) { return (& $byDayOk $Day $false) }
            return ($Day.DayOfWeek -eq $startDate.DayOfWeek)
        }
        'MONTHLY' {
            $months = ($Day.Year - $startDate.Year) * 12 + $Day.Month - $startDate.Month
            if (($months % $interval) -ne 0) { return $false }
            if ($byMonthDay.Count -gt 0) { return (& $monthDayOk $Day) }
            if ($byDay.Count -gt 0) { return (& $byDayOk $Day $true) }
            return ($Day.Day -eq $startDate.Day)
        }
        'YEARLY' {
            if ((($Day.Year - $startDate.Year) % $interval) -ne 0) { return $false }
            if ($byMonth.Count -eq 0 -and $Day.Month -ne $startDate.Month) { return $false }
            if ($byMonthDay.Count -gt 0) { return (& $monthDayOk $Day) }
            if ($byDay.Count -gt 0) { return (& $byDayOk $Day $true) }
            return ($Day.Day -eq $startDate.Day)
        }
    }
    $false
}

function Test-TdIcsOccursOn {
    param([Parameter(Mandatory)]$IcsEvent, [Parameter(Mandatory)][DateTime]$Day)
    $Day = $Day.Date
    $start = $IcsEvent.start.local
    $startDate = $start.Date
    if (-not $IcsEvent.rrule) {
        if ($IcsEvent.start.allDay) {
            $endDate = $startDate.AddDays(1)
            if ($IcsEvent.end) { $endDate = $IcsEvent.end.local.Date }
            if ($endDate -le $startDate) { $endDate = $startDate.AddDays(1) }
            return ($Day -ge $startDate -and $Day -lt $endDate)
        }
        return ($startDate -eq $Day)
    }
    if ($Day -lt $startDate) { return $false }
    foreach ($ex in $IcsEvent.exdates) { if ($ex.Date -eq $Day) { return $false } }
    $rule = $IcsEvent.rrule
    if ($rule['UNTIL']) {
        $until = ConvertFrom-TdIcsDate $rule['UNTIL']
        if ($until -and $Day -gt $until.local.Date) { return $false }
    }
    if (-not (Test-TdRRuleDay -Rule $rule -Start $start -Day $Day)) { return $false }
    if ($rule['COUNT']) {
        $count = [int]$rule['COUNT']
        $seen = 0
        $cursor = $startDate
        $guard = 0
        while ($cursor -le $Day -and $guard -lt 4000) {
            if ((Test-TdRRuleDay -Rule $rule -Start $start -Day $cursor)) {
                $excluded = $false
                foreach ($ex in $IcsEvent.exdates) { if ($ex.Date -eq $cursor) { $excluded = $true } }
                # Les dates exclues consomment quand même une occurrence (RFC 5545).
                $seen++
                if ($cursor -eq $Day) { return (-not $excluded -and $seen -le $count) }
                if ($seen -ge $count) { return $false }
            }
            $cursor = $cursor.AddDays(1)
            $guard++
        }
        return $false
    }
    $true
}

function Read-TdIcsEvents {
    param([string]$Content)
    $events = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Content)) { return , $events.ToArray() }
    # Dépliage des lignes (RFC 5545 : une ligne qui commence par un espace prolonge la précédente).
    $unfolded = [regex]::Replace($Content, '\r?\n[ \t]', '')
    $current = $null
    $depth = 0
    foreach ($line in ($unfolded -split '\r?\n')) {
        if ($line -eq '') { continue }
        $prop = ConvertFrom-TdIcsLine $line
        if (-not $prop) { continue }
        if ($prop.name -eq 'BEGIN') {
            if ($prop.value.Trim().ToUpperInvariant() -eq 'VEVENT') {
                $current = @{ summary = ''; uid = ''; start = $null; end = $null; duration = $null; rrule = $null; exdates = @(); status = ''; recurrenceId = $null }
                $depth = 0
            }
            elseif ($current) { $depth++ }
            continue
        }
        if ($prop.name -eq 'END') {
            if ($current -and $depth -gt 0) { $depth--; continue }
            if ($current -and $prop.value.Trim().ToUpperInvariant() -eq 'VEVENT') {
                if ($current.start) { $events.Add([pscustomobject]$current) }
                $current = $null
            }
            continue
        }
        if (-not $current -or $depth -gt 0) { continue }
        switch ($prop.name) {
            'SUMMARY' { $current.summary = ConvertFrom-TdIcsText $prop.value }
            'UID' { $current.uid = $prop.value.Trim() }
            'DTSTART' { $current.start = ConvertFrom-TdIcsDate $prop.value $prop.params }
            'DTEND' { $current.end = ConvertFrom-TdIcsDate $prop.value $prop.params }
            'DURATION' { $current.duration = ConvertFrom-TdIcsDuration $prop.value.Trim() }
            'RRULE' { $current.rrule = ConvertFrom-TdRRule $prop.value }
            'STATUS' { $current.status = $prop.value.Trim().ToUpperInvariant() }
            'RECURRENCE-ID' {
                $rid = ConvertFrom-TdIcsDate $prop.value $prop.params
                if ($rid) { $current.recurrenceId = $rid.local }
            }
            'EXDATE' {
                foreach ($v in $prop.value.Split(',')) {
                    $ex = ConvertFrom-TdIcsDate $v $prop.params
                    if ($ex) { $current.exdates += $ex.local }
                }
            }
        }
    }
    , $events.ToArray()
}

function ConvertFrom-TdIcs {
    # Événements du jour $DayMs -> éléments importables (créneaux figés).
    param(
        [string]$Content,
        [Parameter(Mandatory)][long]$DayMs
    )
    $day = (ConvertTo-TdLocalDate $DayMs).Date
    $dayKey = $day.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $events = Read-TdIcsEvents $Content
    $overrides = @{}
    foreach ($e in $events) {
        if ($e.recurrenceId -and $e.uid) { $overrides["$($e.uid)|$($e.recurrenceId.Date.ToString('yyyyMMdd'))"] = $true }
    }
    $items = foreach ($e in $events) {
        if ($e.status -eq 'CANCELLED') { continue }
        if ($e.rrule -and $e.uid -and $overrides.ContainsKey("$($e.uid)|$($day.ToString('yyyyMMdd'))")) { continue }
        if ($e.rrule -and $e.recurrenceId) { continue }
        if (-not (Test-TdIcsOccursOn -IcsEvent $e -Day $day)) { continue }
        $title = $e.summary.Trim()
        if (-not $title) { $title = '(Sans titre)' }
        $uid = $e.uid
        if (-not $uid) { $uid = $title }
        if ($e.start.allDay) {
            [pscustomobject][ordered]@{
                title = $title; minutes = $null; fixedStart = $null; allDay = $true
                startMs = $null; externalId = "ics:$uid`:$dayKey"
            }
            continue
        }
        $minutes = 30
        if ($e.end -and -not $e.end.allDay) { $minutes = ($e.end.local - $e.start.local).TotalMinutes }
        elseif ($e.duration) { $minutes = $e.duration.TotalMinutes }
        if ($minutes -lt 1) { $minutes = 15 }
        $startLocal = $day.Add($e.start.local.TimeOfDay)
        [pscustomobject][ordered]@{
            title      = $title
            minutes    = [Math]::Round($minutes)
            fixedStart = $startLocal.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            allDay     = $false
            startMs    = ConvertFrom-TdLocalDate $startLocal
            externalId = "ics:$uid`:$dayKey"
        }
    }
    , @($items | Sort-Object -Property @{ Expression = { if ($_.allDay) { 0 } else { 1 } } }, @{ Expression = { $_.startMs } })
}

function ConvertFrom-TdTextList {
    # Listes collées : "- [ ] Tâche 15 min", "☐ Tâche", "1. Tâche", lignes simples...
    # Les éléments déjà cochés ([x], ☑, ✅) sont ignorés.
    param([string]$Content, [double]$DefaultMinutes = 25)
    if ([string]::IsNullOrWhiteSpace($Content)) { return , @() }
    $checked = '^\s*(?:[-*+]\s*)?\[[xX]\]|^\s*[☑✅✔]'
    $bullet = '^\s*(?:[-*+•▪◦‣]|\d{1,3}[.)])\s+'
    $box = '^\s*(?:\[\s?\]|[☐□◻⬜])\s*'
    $items = foreach ($raw in ($Content -split '\r?\n')) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line -match '^#{1,6}\s' -or $line -match '^[-=_*]{3,}$') { continue }
        if ($line -match $checked) { continue }
        $line = $line -replace $bullet, ''
        if ($line -match $checked) { continue }
        $line = $line -replace $box, ''
        $parsed = ConvertFrom-TdQuickInput $line
        if (-not $parsed.title) { continue }
        $minutes = $DefaultMinutes
        if ($parsed.minutes) { $minutes = $parsed.minutes }
        [pscustomobject][ordered]@{
            title = $parsed.title; minutes = $minutes; fixedStart = $parsed.fixedStart; allDay = $false
            startMs = $null; externalId = $null
        }
    }
    , @($items)
}

function ConvertTo-TdDateInfo {
    # Date JSON (chaîne ISO, ou DateTime déjà converti par PowerShell 7) -> { dayKey ; clock ; hasTime }.
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $local = $null
    $hasTime = $false
    if ($Value -is [DateTimeOffset]) {
        $local = $Value.ToLocalTime().DateTime
        $hasTime = $true
    }
    elseif ($Value -is [DateTime]) {
        $local = $Value
        if ($Value.Kind -eq [DateTimeKind]::Utc) { $local = $Value.ToLocalTime() }
        $hasTime = $Value.TimeOfDay.Ticks -ne 0
    }
    else {
        $text = ([string]$Value).Trim()
        try {
            if ($text -match '^\d{4}-\d{2}-\d{2}$') {
                $local = [DateTime]::ParseExact($text, 'yyyy-MM-dd', $inv)
            }
            elseif ($text -match '(Z|[+-]\d{2}:?\d{2})$') {
                $local = [DateTimeOffset]::Parse($text, $inv).ToLocalTime().DateTime
                $hasTime = $true
            }
            else {
                $local = [DateTime]::Parse($text, $inv)
                $hasTime = $text -match 'T'
            }
        }
        catch { return $null }
    }
    [pscustomobject]@{
        dayKey  = $local.ToString('yyyy-MM-dd', $inv)
        clock   = $local.ToString('HH:mm', $inv)
        hasTime = $hasTime
    }
}

function ConvertFrom-TdTodoistTasks {
    # Tâches renvoyées par l'API Todoist v1 (tasks/filter?query=today | overdue).
    param([AllowNull()][AllowEmptyCollection()]$Tasks, [Parameter(Mandatory)][long]$NowMs, [double]$DefaultMinutes = 25)
    $todayKey = Get-TdDayKey $NowMs
    $items = foreach ($t in @($Tasks)) {
        if ($null -eq $t) { continue }
        $title = [string](Get-TdValue $t 'content')
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        # Liens Markdown [texte](url) -> texte
        $title = [regex]::Replace($title, '\[([^\]]+)\]\([^)]+\)', '$1').Trim()
        $minutes = $DefaultMinutes
        $duration = Get-TdValue $t 'duration'
        if ($duration) {
            $amount = Get-TdValue $duration 'amount'
            $unit = [string](Get-TdValue $duration 'unit')
            if ($amount -and $unit -eq 'minute') { $minutes = [double]$amount }
        }
        $fixed = $null
        $due = Get-TdValue $t 'due'
        if ($due) {
            $info = ConvertTo-TdDateInfo (Get-TdValue $due 'datetime')
            if (-not $info) { $info = ConvertTo-TdDateInfo (Get-TdValue $due 'date') }
            if ($info -and $info.hasTime -and $info.dayKey -eq $todayKey) { $fixed = $info.clock }
        }
        $priority = Get-TdValue $t 'priority'
        if ($null -eq $priority) { $priority = 1 }
        [pscustomobject][ordered]@{
            title      = $title
            minutes    = $minutes
            fixedStart = $fixed
            allDay     = $false
            startMs    = $null
            externalId = "todoist:$(Get-TdValue $t 'id')"
            priority   = [int]$priority
        }
    }
    , @($items | Sort-Object -Property @{ Expression = { if ($_.fixedStart) { $_.fixedStart } else { '99:99' } } }, @{ Expression = { $_.priority }; Descending = $true })
}

$script:TdNotionDoneStatus = @('done', 'terminé', 'termine', 'fait', 'complete', 'completed', 'complété', 'archivé', 'archived')

function ConvertFrom-TdNotionPages {
    # Pages d'une base Notion (databases/{id}/query). Détection automatique :
    # titre, case à cocher / statut « fait », nombre « durée/minutes », date du jour.
    param([AllowNull()][AllowEmptyCollection()]$Pages, [Parameter(Mandatory)][long]$NowMs, [double]$DefaultMinutes = 25)
    $todayKey = Get-TdDayKey $NowMs
    $items = foreach ($page in @($Pages)) {
        if ($null -eq $page) { continue }
        if ((Get-TdValue $page 'archived') -eq $true -or (Get-TdValue $page 'in_trash') -eq $true) { continue }
        $props = Get-TdValue $page 'properties'
        if ($null -eq $props) { continue }
        $title = ''
        $done = $false
        $minutes = $null
        $dateStart = $null
        $propList = if ($props -is [System.Collections.IDictionary]) { $props.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = $_.Key; Value = $_.Value } } } else { $props.PSObject.Properties }
        foreach ($p in $propList) {
            $value = $p.Value
            $type = [string](Get-TdValue $value 'type')
            switch ($type) {
                'title' {
                    $title = (@(Get-TdValue $value 'title') | ForEach-Object { Get-TdValue $_ 'plain_text' }) -join ''
                }
                'checkbox' { if ((Get-TdValue $value 'checkbox') -eq $true) { $done = $true } }
                'status' {
                    $name = [string](Get-TdValue (Get-TdValue $value 'status') 'name')
                    if ($script:TdNotionDoneStatus -contains $name.ToLowerInvariant()) { $done = $true }
                }
                'number' {
                    $n = Get-TdValue $value 'number'
                    if ($null -ne $n -and $p.Name -match '(?i)dur|min|temps|time|estim') { $minutes = [double]$n }
                }
                'date' {
                    $date = Get-TdValue $value 'date'
                    if ($date -and -not $dateStart) { $dateStart = Get-TdValue $date 'start' }
                }
            }
        }
        if ($done -or [string]::IsNullOrWhiteSpace($title)) { continue }
        $fixed = $null
        $info = ConvertTo-TdDateInfo $dateStart
        if ($info) {
            if ([string]::CompareOrdinal($info.dayKey, $todayKey) -gt 0) { continue }
            if ($info.hasTime -and $info.dayKey -eq $todayKey) { $fixed = $info.clock }
        }
        if (-not $minutes -or $minutes -lt 1) { $minutes = $DefaultMinutes }
        [pscustomobject][ordered]@{
            title      = $title.Trim()
            minutes    = $minutes
            fixedStart = $fixed
            allDay     = $false
            startMs    = $null
            externalId = "notion:$(Get-TdValue $page 'id')"
        }
    }
    , @($items)
}

function Select-TdNewImportItems {
    # Évite les doublons : ignore les éléments déjà importés (même identifiant externe).
    param([AllowNull()][AllowEmptyCollection()]$Items, [Parameter(Mandatory)]$State)
    $known = @{}
    foreach ($t in @($State.tasks) + @($State.done)) {
        if ($t -and $t.externalId) { $known[$t.externalId] = $true }
    }
    , @($Items | Where-Object { $null -ne $_ -and (-not $_.externalId -or -not $known.ContainsKey($_.externalId)) })
}
