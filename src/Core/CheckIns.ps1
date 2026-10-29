# TDfocus - points de contrôle au carillon : « Toujours sur ta tâche ? »
# Répondre « je me suis égaré·e » n'est pas un échec : c'est un recentrage réussi.

function New-TdCheckIn {
    param(
        [string]$TaskId,
        [Parameter(Mandatory)][ValidateSet('focused', 'drifted', 'missed')][string]$Answer,
        [long]$NowMs = (Get-TdNowMs)
    )
    [pscustomobject][ordered]@{
        at     = $NowMs
        dayKey = Get-TdDayKey $NowMs
        taskId = ConvertTo-TdNullableString $TaskId
        answer = $Answer
    }
}

function ConvertTo-TdCheckIn {
    param([Parameter(Mandatory)]$InputObject)
    $answer = [string](Get-TdValue $InputObject 'answer')
    if (@('focused', 'drifted', 'missed') -notcontains $answer) { $answer = 'missed' }
    $at = [long](Get-TdValue $InputObject 'at')
    [pscustomobject][ordered]@{
        at     = $at
        dayKey = Get-TdDayKey $at
        taskId = ConvertTo-TdNullableString (Get-TdValue $InputObject 'taskId')
        answer = $answer
    }
}

function Get-TdCheckInSummary {
    param([AllowNull()][AllowEmptyCollection()]$CheckIns, [Parameter(Mandatory)][long]$NowMs)
    $today = Get-TdDayKey $NowMs
    $entries = @($CheckIns | Where-Object { $null -ne $_ -and $_.dayKey -eq $today })
    [pscustomobject][ordered]@{
        total   = $entries.Count
        focused = @($entries | Where-Object { $_.answer -eq 'focused' }).Count
        drifted = @($entries | Where-Object { $_.answer -eq 'drifted' }).Count
        missed  = @($entries | Where-Object { $_.answer -eq 'missed' }).Count
    }
}

function Limit-TdCheckIns {
    param([AllowNull()][AllowEmptyCollection()]$CheckIns, [Parameter(Mandatory)][long]$NowMs, [int]$KeepDays = 90)
    $limit = $NowMs - [long]$KeepDays * 24 * 3600 * 1000
    , @($CheckIns | Where-Object { $null -ne $_ -and [long]$_.at -ge $limit })
}
