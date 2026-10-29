# TDfocus - bloc-notes « parking à idées » : capturer une pensée parasite sans quitter le focus.

function New-TdNote {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Context,
        [long]$NowMs = (Get-TdNowMs)
    )
    [pscustomobject][ordered]@{
        id        = New-TdId
        text      = $Text.Trim()
        context   = ConvertTo-TdNullableString $Context
        createdAt = $NowMs
    }
}

function ConvertTo-TdNote {
    param([Parameter(Mandatory)]$InputObject)
    $id = ConvertTo-TdNullableString (Get-TdValue $InputObject 'id')
    if (-not $id) { $id = New-TdId }
    $created = ConvertTo-TdNullableLong (Get-TdValue $InputObject 'createdAt')
    if ($null -eq $created) { $created = 0 }
    [pscustomobject][ordered]@{
        id        = $id
        text      = [string](Get-TdValue $InputObject 'text')
        context   = ConvertTo-TdNullableString (Get-TdValue $InputObject 'context')
        createdAt = [long]$created
    }
}
