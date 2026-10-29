# TDfocus - statistiques bienveillantes : estimation vs temps réel.
# Aucun score négatif, aucune « série » à perdre : uniquement de la connaissance de soi.

$script:TdMinSampleActualMs = 30000
$script:TdMinSampleEstimateMs = 60000

function ConvertTo-TdHistoryEntry {
    param([Parameter(Mandatory)]$InputObject)
    $completed = [long](Get-TdValue $InputObject 'completedAt')
    $dayKey = [string](Get-TdValue $InputObject 'dayKey')
    if (-not $dayKey -and $completed -gt 0) { $dayKey = Get-TdDayKey $completed }
    [pscustomobject][ordered]@{
        id          = [string](Get-TdValue $InputObject 'id')
        title       = [string](Get-TdValue $InputObject 'title')
        categoryId  = ConvertTo-TdNullableString (Get-TdValue $InputObject 'categoryId')
        estimateMs  = [long](Get-TdValue $InputObject 'estimateMs')
        plannedMs   = [long](Get-TdValue $InputObject 'plannedMs')
        actualMs    = [long](Get-TdValue $InputObject 'actualMs')
        completedAt = $completed
        dayKey      = $dayKey
    }
}

function Get-TdMedian {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = [double[]]($Values | Sort-Object)
    $n = $sorted.Count
    if ($n % 2 -eq 1) { return $sorted[[int][Math]::Floor($n / 2)] }
    ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2
}

function Get-TdUsableSamples {
    param($History, [long]$SinceMs = 0)
    @($History | Where-Object {
            $_ -and [long]$_.completedAt -ge $SinceMs -and
            [long]$_.estimateMs -ge $script:TdMinSampleEstimateMs -and
            [long]$_.actualMs -ge $script:TdMinSampleActualMs
        })
}

function Get-TdStats {
    param(
        [AllowNull()][AllowEmptyCollection()]$History,
        [Parameter(Mandatory)][long]$NowMs,
        [int]$Days = 7,
        [int]$RatioWindowDays = 30
    )
    $History = @($History | Where-Object { $null -ne $_ })
    $todayKey = Get-TdDayKey $NowMs
    $todayDate = (ConvertTo-TdLocalDate $NowMs).Date
    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    $buckets = [ordered]@{}
    for ($d = $Days - 1; $d -ge 0; $d--) {
        $key = $todayDate.AddDays(-$d).ToString('yyyy-MM-dd', $inv)
        $buckets[$key] = [pscustomobject][ordered]@{
            dayKey     = $key
            label      = Format-TdDayLabel $key
            count      = 0
            estimateMs = [long]0
            actualMs   = [long]0
        }
    }
    foreach ($entry in $History) {
        $key = [string]$entry.dayKey
        if ($buckets.Contains($key)) {
            $b = $buckets[$key]
            $b.count++
            $b.estimateMs += [long]$entry.estimateMs
            $b.actualMs += [long]$entry.actualMs
        }
    }

    $since = ConvertFrom-TdLocalDate ($todayDate.AddDays(-$RatioWindowDays))
    $samples = Get-TdUsableSamples -History $History -SinceMs $since
    $ratios = [double[]]@($samples | ForEach-Object { [double]$_.actualMs / [double]$_.estimateMs })
    $median = Get-TdMedian $ratios

    $byCategory = foreach ($group in ($samples | Group-Object -Property { if ($_.categoryId) { $_.categoryId } else { '' } })) {
        $r = [double[]]@($group.Group | ForEach-Object { [double]$_.actualMs / [double]$_.estimateMs })
        [pscustomobject][ordered]@{
            categoryId = $group.Name
            count      = $group.Count
            ratio      = Get-TdMedian $r
        }
    }

    $todayEntries = @($History | Where-Object { $_.dayKey -eq $todayKey })
    $todayFocus = [long]0
    foreach ($e in $todayEntries) { $todayFocus += [long]$e.actualMs }

    $within = @($ratios | Where-Object { $_ -ge 0.8 -and $_ -le 1.25 }).Count
    $accuracy = $null
    if ($ratios.Count -gt 0) { $accuracy = [double]$within / $ratios.Count }

    [pscustomobject][ordered]@{
        todayCount   = $todayEntries.Count
        todayFocusMs = $todayFocus
        totalCount   = $History.Count
        days         = @($buckets.Values)
        sampleCount  = $ratios.Count
        medianRatio  = $median
        accuracy     = $accuracy
        byCategory   = @($byCategory | Sort-Object -Property count -Descending)
    }
}

function Get-TdEstimateHint {
    # Suggestion douce : « ≈ 32 min réelles d'après ton historique ».
    param(
        [AllowNull()][AllowEmptyCollection()]$History,
        [Parameter(Mandatory)][double]$Minutes,
        [string]$CategoryId,
        [long]$NowMs = (Get-TdNowMs),
        [int]$MinSamples = 5
    )
    $since = $NowMs - 30L * 24 * 3600 * 1000
    $samples = Get-TdUsableSamples -History @($History | Where-Object { $null -ne $_ }) -SinceMs $since
    $scope = 'global'
    if ($CategoryId) {
        $cat = @($samples | Where-Object { $_.categoryId -eq $CategoryId })
        if ($cat.Count -ge $MinSamples) { $samples = $cat; $scope = 'category' }
    }
    if ($samples.Count -lt $MinSamples) { return $null }
    $ratio = Get-TdMedian ([double[]]@($samples | ForEach-Object { [double]$_.actualMs / [double]$_.estimateMs }))
    if ($null -eq $ratio -or [Math]::Abs($ratio - 1) -lt 0.1) { return $null }
    [pscustomobject][ordered]@{
        ratio   = [Math]::Round($ratio, 2)
        minutes = [int][Math]::Max(1, [Math]::Round($Minutes * $ratio))
        scope   = $scope
        samples = $samples.Count
    }
}

function Limit-TdHistory {
    # Garde 180 jours d'historique.
    param([AllowNull()][AllowEmptyCollection()]$History, [Parameter(Mandatory)][long]$NowMs, [int]$KeepDays = 180)
    $limit = $NowMs - [long]$KeepDays * 24 * 3600 * 1000
    , @($History | Where-Object { $null -ne $_ -and [long]$_.completedAt -ge $limit })
}
