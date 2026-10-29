# TDfocus (terminal) - sons sous Linux / macOS, avec les lecteurs du système.
# Mêmes sons que sous Windows, calculés en PowerShell (Audio/Synth.ps1). Les ambiances
# utilisent une boucle « sans couture » de 60 s relancée en continu.

$script:TdTuiAudio = $null

function Get-TdTuiSoundDirectory {
    $base = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $base) { $base = Join-Path (Join-Path $HOME '.local') 'share' }
    Join-Path $base 'TDfocus/sounds'
}

function Initialize-TdTuiAudio {
    param([Parameter(Mandatory)][string]$SynthPath)
    $player = $null
    foreach ($candidate in @('pw-play', 'paplay', 'aplay', 'afplay')) {
        if (Get-Command -Name $candidate -CommandType Application -ErrorAction Ignore) { $player = $candidate; break }
    }
    $dir = Get-TdTuiSoundDirectory
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:TdTuiAudio = @{
        Player    = $player
        Dir       = $dir
        SynthCode = [System.IO.File]::ReadAllText($SynthPath, [System.Text.Encoding]::UTF8)
        Jobs      = @{}
        Ready     = @{}
        Ambient   = @{ Name = 'none'; Volume = 0.35; Process = $null }
    }
    foreach ($name in @('complete', 'chime', 'timeup', 'landing')) { [void](Request-TdTuiSound $name) }
    $script:TdTuiAudio
}

function Get-TdTuiSoundPath {
    param([Parameter(Mandatory)][string]$Name)
    $ambient = $script:TdSoundCatalog[$Name] -and $script:TdSoundCatalog[$Name].Ambient
    Join-Path $script:TdTuiAudio.Dir (Get-TdSoundFileName -Name $Name -Seamless:$ambient)
}

function Request-TdTuiSound {
    # Vrai si le fichier est prêt ; sinon lance sa préparation en arrière-plan (une seule fois).
    param([Parameter(Mandatory)][string]$Name)
    $a = $script:TdTuiAudio
    if (-not $a -or -not $script:TdSoundCatalog.ContainsKey($Name)) { return $false }
    if ($a.Ready.ContainsKey($Name)) { return $true }
    $path = Get-TdTuiSoundPath $Name
    if (Test-Path -LiteralPath $path) { $a.Ready[$Name] = $true; return $true }
    if ($a.Jobs.ContainsKey($Name)) { return $false }
    $seamless = ''
    if ($script:TdSoundCatalog[$Name].Ambient) { $seamless = ' -Seamless' }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($a.SynthCode + "`n" + "New-TdSoundFile -Name '$($Name.Replace("'", "''"))' -Path '$($path.Replace("'", "''"))'$seamless")
    $a.Jobs[$Name] = @{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
    $false
}

function Get-TdTuiSoundStatus {
    param([Parameter(Mandatory)][string]$Name)
    $a = $script:TdTuiAudio
    if (-not $a) { return 'unavailable' }
    if (-not $a.Player) { return 'noplayer' }
    if ($a.Ready.ContainsKey($Name)) { return 'ready' }
    if ($a.Jobs.ContainsKey($Name)) { return 'preparing' }
    'missing'
}

function Start-TdTuiPlayer {
    param([Parameter(Mandatory)][string]$Path, [double]$Volume = 0.6)
    $a = $script:TdTuiAudio
    if (-not $a.Player) { return $null }
    $Volume = [Math]::Min(1.0, [Math]::Max(0.0, $Volume))
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $info = New-Object System.Diagnostics.ProcessStartInfo $a.Player
    switch ($a.Player) {
        'pw-play' { $info.ArgumentList.Add('--volume=' + $Volume.ToString('0.00', $inv)) }
        'paplay' { $info.ArgumentList.Add('--volume=' + [int]($Volume * 65536)) }
        'aplay' { $info.ArgumentList.Add('-q') }
        'afplay' { $info.ArgumentList.Add('-v'); $info.ArgumentList.Add($Volume.ToString('0.00', $inv)) }
    }
    $info.ArgumentList.Add($Path)
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    try { return [System.Diagnostics.Process]::Start($info) }
    catch { Write-TdLog "Lecture audio impossible ($($a.Player)) : $($_.Exception.Message)"; return $null }
}

function Invoke-TdTuiSound {
    param([Parameter(Mandatory)][string]$Name, [double]$Volume = 0.6)
    if (-not $script:TdTuiAudio -or -not (Request-TdTuiSound $Name)) { return }
    [void](Start-TdTuiPlayer -Path (Get-TdTuiSoundPath $Name) -Volume $Volume)
}

function Set-TdTuiAmbient {
    param([Parameter(Mandatory)][string]$Name, [double]$Volume = 0.35)
    $a = $script:TdTuiAudio
    if (-not $a) { return }
    $amb = $a.Ambient
    $changed = ($amb.Name -ne $Name) -or ([Math]::Abs($amb.Volume - $Volume) -gt 0.001)
    $amb.Name = $Name
    $amb.Volume = $Volume
    if ($changed) { Stop-TdTuiAmbient }
    if ($Name -ne 'none') { [void](Request-TdTuiSound $Name) }
}

function Stop-TdTuiAmbient {
    $amb = $script:TdTuiAudio.Ambient
    if ($amb.Process) {
        try { if (-not $amb.Process.HasExited) { $amb.Process.Kill() } } catch { $null = $_ }
        $amb.Process = $null
    }
}

function Update-TdTuiAudio {
    # Termine les préparations et relance la boucle d'ambiance quand elle s'arrête.
    $a = $script:TdTuiAudio
    if (-not $a) { return }
    foreach ($name in @($a.Jobs.Keys)) {
        $job = $a.Jobs[$name]
        if (-not $job.Handle.IsCompleted) { continue }
        try { [void]$job.PowerShell.EndInvoke($job.Handle); $a.Ready[$name] = $true }
        catch { Write-TdLog "Préparation du son $name impossible : $($_.Exception.Message)" }
        finally { $job.PowerShell.Dispose(); $a.Jobs.Remove($name) }
    }
    $amb = $a.Ambient
    if ($amb.Name -eq 'none' -or -not $a.Player -or -not $a.Ready.ContainsKey($amb.Name)) { return }
    if (-not $amb.Process -or $amb.Process.HasExited) {
        $amb.Process = Start-TdTuiPlayer -Path (Get-TdTuiSoundPath $amb.Name) -Volume $amb.Volume
    }
}

function Stop-TdTuiAudio {
    $a = $script:TdTuiAudio
    if (-not $a) { return }
    Stop-TdTuiAmbient
    foreach ($job in $a.Jobs.Values) { try { $job.PowerShell.Stop(); $job.PowerShell.Dispose() } catch { $null = $_ } }
    $a.Jobs.Clear()
}
