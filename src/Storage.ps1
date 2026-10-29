# TDfocus - stockage local (offline-first).
# Les données vivent dans %APPDATA%\TDfocus sous forme de fichiers JSON écrits de façon
# atomique (fichier temporaire + remplacement) avec une copie de secours .bak.

$script:TdUtf8 = New-Object System.Text.UTF8Encoding($false)

function Get-TdDataDirectory {
    $dir = $env:TDFOCUS_DATA
    if (-not $dir) {
        $base = $env:APPDATA
        if (-not $base) { $base = [Environment]::GetFolderPath('ApplicationData') }
        if (-not $base) { $base = Join-Path $HOME '.config' }
        $dir = Join-Path $base 'TDfocus'
    }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $dir
}

function Get-TdDataPath {
    param([Parameter(Mandatory)][string]$Name)
    Join-Path (Get-TdDataDirectory) $Name
}

function Read-TdJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($candidate in @($Path, "$Path.bak")) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $text = [System.IO.File]::ReadAllText($candidate, $script:TdUtf8)
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            return ($text | ConvertFrom-Json)
        }
        catch {
            Write-TdLog "Lecture impossible de $candidate : $($_.Exception.Message)"
        }
    }
    $null
}

function Write-TdJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowNull()]$Data)
    $json = ConvertTo-Json -InputObject $Data -Depth 12
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, $script:TdUtf8)
    if (Test-Path -LiteralPath $Path) {
        try {
            [System.IO.File]::Replace($tmp, $Path, "$Path.bak")
            return
        }
        catch {
            # Replace n'est pas disponible partout (certains lecteurs réseau) : repli.
            Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force -ErrorAction SilentlyContinue
        }
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Write-TdLog {
    param([string]$Message)
    try {
        $path = Get-TdDataPath 'tdfocus.log'
        $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 512KB) {
            Move-Item -LiteralPath $path -Destination "$path.old" -Force
        }
        [System.IO.File]::AppendAllText($path, $line + [Environment]::NewLine, $script:TdUtf8)
    }
    catch { $null = $_ }
}

function Protect-TdSecret {
    # Chiffre un jeton d'API avec DPAPI (lié au compte Windows). Hors Windows : stocké tel quel.
    param([string]$Plain)
    if ([string]::IsNullOrEmpty($Plain)) { return '' }
    try {
        $secure = ConvertTo-SecureString -String $Plain -AsPlainText -Force
        return 'dpapi:' + (ConvertFrom-SecureString -SecureString $secure)
    }
    catch { return 'plain:' + $Plain }
}

function Unprotect-TdSecret {
    param([string]$Stored)
    if ([string]::IsNullOrEmpty($Stored)) { return '' }
    if ($Stored.StartsWith('plain:')) { return $Stored.Substring(6) }
    if ($Stored.StartsWith('dpapi:')) {
        try {
            $secure = ConvertTo-SecureString -String $Stored.Substring(6)
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        catch { return '' }
    }
    $Stored
}

function Import-TdData {
    # Charge toutes les données. Renvoie une hashtable { state; settings; history; templates; notes }.
    $state = ConvertTo-TdState (Read-TdJsonFile (Get-TdDataPath 'state.json'))
    $settings = ConvertTo-TdSettings (Read-TdJsonFile (Get-TdDataPath 'settings.json'))
    $history = [System.Collections.Generic.List[object]]::new()
    $rawHistory = Read-TdJsonFile (Get-TdDataPath 'history.json')
    foreach ($h in @(Get-TdValue $rawHistory 'items')) {
        if ($null -ne $h) { $history.Add((ConvertTo-TdHistoryEntry $h)) }
    }
    $templates = [System.Collections.Generic.List[object]]::new()
    foreach ($t in @(Get-TdValue (Read-TdJsonFile (Get-TdDataPath 'templates.json')) 'items')) {
        if ($null -ne $t) { $templates.Add((ConvertTo-TdTemplate $t)) }
    }
    $notes = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @(Get-TdValue (Read-TdJsonFile (Get-TdDataPath 'notes.json')) 'items')) {
        if ($null -ne $n) { $notes.Add((ConvertTo-TdNote $n)) }
    }
    $checkins = [System.Collections.Generic.List[object]]::new()
    foreach ($c in @(Get-TdValue (Read-TdJsonFile (Get-TdDataPath 'checkins.json')) 'items')) {
        if ($null -ne $c) { $checkins.Add((ConvertTo-TdCheckIn $c)) }
    }
    @{ state = $state; settings = $settings; history = $history; templates = $templates; notes = $notes; checkins = $checkins }
}

function ConvertTo-TdStateRecord {
    # Forme enregistrée de la file (state.json et sauvegardes).
    param([Parameter(Mandatory)]$State)
    [ordered]@{
        version    = 1
        tasks      = @($State.tasks)
        done       = @($State.done)
        parked     = @($State.parked)
        review     = @($State.review)
        planEndMs  = $State.planEndMs
        lastSeenMs = $State.lastSeenMs
        dayKey     = $State.dayKey
    }
}

function Save-TdState {
    param([Parameter(Mandatory)]$State)
    Write-TdJsonFile (Get-TdDataPath 'state.json') (ConvertTo-TdStateRecord $State)
}

function Save-TdSettings {
    param([Parameter(Mandatory)]$Settings)
    Write-TdJsonFile (Get-TdDataPath 'settings.json') $Settings
}

function Save-TdHistory {
    param([AllowEmptyCollection()]$History)
    Write-TdJsonFile (Get-TdDataPath 'history.json') ([ordered]@{ version = 1; items = @($History) })
}

function Save-TdTemplates {
    param([AllowEmptyCollection()]$Templates)
    Write-TdJsonFile (Get-TdDataPath 'templates.json') ([ordered]@{ version = 1; items = @($Templates) })
}

function Save-TdNotes {
    param([AllowEmptyCollection()]$Notes)
    Write-TdJsonFile (Get-TdDataPath 'notes.json') ([ordered]@{ version = 1; items = @($Notes) })
}

function Save-TdCheckIns {
    param([AllowEmptyCollection()]$CheckIns)
    Write-TdJsonFile (Get-TdDataPath 'checkins.json') ([ordered]@{ version = 1; items = @($CheckIns) })
}

function Export-TdBackup {
    # Sauvegarde complète dans un seul fichier JSON.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Data)
    $settings = [ordered]@{}
    foreach ($k in $Data.settings.Keys) { $settings[$k] = $Data.settings[$k] }
    foreach ($k in @('todoistToken', 'notionToken')) { $settings[$k] = '' }
    Write-TdJsonFile $Path ([ordered]@{
            app       = 'TDfocus'
            version   = 1
            exportedAt = (Get-Date).ToString('o')
            state     = ConvertTo-TdStateRecord $Data.state
            settings  = $settings
            history   = @($Data.history)
            templates = @($Data.templates)
            notes     = @($Data.notes)
            checkins  = @($Data.checkins)
        })
}

function Import-TdBackup {
    param([Parameter(Mandatory)][string]$Path)
    $raw = Read-TdJsonFile $Path
    if ($null -eq $raw -or (Get-TdValue $raw 'app') -ne 'TDfocus') { throw "Ce fichier n'est pas une sauvegarde TDfocus." }
    $history = [System.Collections.Generic.List[object]]::new()
    foreach ($h in @(Get-TdValue $raw 'history')) { if ($null -ne $h) { $history.Add((ConvertTo-TdHistoryEntry $h)) } }
    $templates = [System.Collections.Generic.List[object]]::new()
    foreach ($t in @(Get-TdValue $raw 'templates')) { if ($null -ne $t) { $templates.Add((ConvertTo-TdTemplate $t)) } }
    $notes = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @(Get-TdValue $raw 'notes')) { if ($null -ne $n) { $notes.Add((ConvertTo-TdNote $n)) } }
    $checkins = [System.Collections.Generic.List[object]]::new()
    foreach ($c in @(Get-TdValue $raw 'checkins')) { if ($null -ne $c) { $checkins.Add((ConvertTo-TdCheckIn $c)) } }
    @{
        state     = ConvertTo-TdState (Get-TdValue $raw 'state')
        settings  = ConvertTo-TdSettings (Get-TdValue $raw 'settings')
        history   = $history
        templates = $templates
        notes     = $notes
        checkins  = $checkins
    }
}
