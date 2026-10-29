# TDfocus - lecture audio (WPF MediaPlayer, aucune dépendance externe).
#
# Les sons sont calculés en arrière-plan (runspace séparé) pour ne jamais figer l'interface.
# Les ambiances sont jouées par deux lecteurs qui se relaient avec un fondu croisé :
# la boucle est continue, sans silence entre deux passages.

$script:TdAudio = $null

function Get-TdSoundDirectory {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
    Join-Path $base 'TDfocus\sounds'
}

function Initialize-TdAudio {
    param([Parameter(Mandatory)][string]$SynthPath)
    $dir = Get-TdSoundDirectory
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:TdAudio = @{
        Dir       = $dir
        SynthCode = [System.IO.File]::ReadAllText($SynthPath, [System.Text.Encoding]::UTF8)
        Jobs      = @{}
        Durations = @{}
        Failed    = @{}
        Effects   = @{}
        Ambient   = @{ Name = 'none'; Volume = 0.35; Players = @($null, $null); Opened = @($null, $null); Active = -1 }
        # Vrai si le lecteur WPF échoue (Windows « N » sans Media Feature Pack, serveurs) :
        # les effets passent alors par System.Media.SoundPlayer (sans réglage de volume).
        MediaBroken = $false
    }
    foreach ($name in $script:TdSoundCatalog.Keys) {
        $path = Get-TdSoundPath $name
        if (Test-Path -LiteralPath $path) {
            try { $script:TdAudio.Durations[$name] = Get-TdWavDurationSeconds $path } catch { $null = $_ }
        }
    }
    # Les effets courts sont préparés tout de suite (quelques secondes, une seule fois).
    foreach ($name in @('complete', 'chime', 'timeup', 'landing')) { [void](Request-TdSound $name) }
}

function Get-TdSoundPath {
    param([Parameter(Mandatory)][string]$Name)
    Join-Path (Get-TdSoundDirectory) (Get-TdSoundFileName $Name)
}

function Request-TdSound {
    # Vrai si le son est prêt ; sinon lance (une fois) sa préparation en arrière-plan.
    param([Parameter(Mandatory)][string]$Name)
    $a = $script:TdAudio
    if (-not $a) { return $false }
    if ($a.Durations.ContainsKey($Name)) { return $true }
    if ($a.Jobs.ContainsKey($Name) -or $a.Failed.ContainsKey($Name)) { return $false }
    if (-not $script:TdSoundCatalog.ContainsKey($Name)) { return $false }
    $path = Get-TdSoundPath $Name
    $quotedName = $Name.Replace("'", "''")
    $quotedPath = $path.Replace("'", "''")
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($a.SynthCode + "`n" + "New-TdSoundFile -Name '$quotedName' -Path '$quotedPath'")
    $a.Jobs[$Name] = @{ PowerShell = $ps; Handle = $ps.BeginInvoke(); Path = $path }
    $false
}

function Get-TdSoundStatus {
    param([Parameter(Mandatory)][string]$Name)
    $a = $script:TdAudio
    if (-not $a) { return 'unavailable' }
    if ($a.Durations.ContainsKey($Name)) { return 'ready' }
    if ($a.Jobs.ContainsKey($Name)) { return 'preparing' }
    if ($a.Failed.ContainsKey($Name)) { return 'failed' }
    'missing'
}

function New-TdMediaPlayer {
    $player = New-Object System.Windows.Media.MediaPlayer
    $player.Add_MediaFailed({
            param($s, $e)
            if (-not $script:TdAudio.MediaBroken) {
                $script:TdAudio.MediaBroken = $true
                Write-TdLog "Lecteur multimédia Windows indisponible, repli sur la lecture simple : $($e.ErrorException.Message)"
            }
        })
    $player
}

function Start-TdAmbientPlayer {
    param([Parameter(Mandatory)][int]$Slot)
    $amb = $script:TdAudio.Ambient
    $player = $amb.Players[$Slot]
    if (-not $player) {
        $player = New-TdMediaPlayer
        $amb.Players[$Slot] = $player
    }
    if ($amb.Opened[$Slot] -ne $amb.Name) {
        $player.Open([Uri](Get-TdSoundPath $amb.Name))
        $amb.Opened[$Slot] = $amb.Name
    }
    $player.Volume = $amb.Volume
    $player.Position = [TimeSpan]::Zero
    $player.Play()
    $amb.Active = $Slot
}

function Stop-TdAmbient {
    $amb = $script:TdAudio.Ambient
    foreach ($p in $amb.Players) { if ($p) { $p.Stop() } }
    $amb.Active = -1
}

function Set-TdAmbient {
    param([Parameter(Mandatory)][string]$Name, [double]$Volume = 0.35)
    $a = $script:TdAudio
    if (-not $a) { return }
    $amb = $a.Ambient
    $amb.Volume = [Math]::Min(1.0, [Math]::Max(0.0, $Volume))
    foreach ($p in $amb.Players) { if ($p) { $p.Volume = $amb.Volume } }
    if ($Name -ne $amb.Name) {
        Stop-TdAmbient
        $amb.Name = $Name
        if ($Name -ne 'none') { [void](Request-TdSound $Name) }
        Update-TdAudio
    }
}

function Invoke-TdSoundEffect {
    param([Parameter(Mandatory)][string]$Name, [double]$Volume = 0.6)
    $a = $script:TdAudio
    if (-not $a) { return }
    if (-not (Request-TdSound $Name)) { return }
    try {
        if ($a.MediaBroken) {
            (New-Object System.Media.SoundPlayer (Get-TdSoundPath $Name)).Play()
            return
        }
        $player = $a.Effects[$Name]
        if (-not $player) {
            $player = New-TdMediaPlayer
            $player.Open([Uri](Get-TdSoundPath $Name))
            $a.Effects[$Name] = $player
        }
        $player.Volume = [Math]::Min(1.0, [Math]::Max(0.0, $Volume))
        $player.Stop()
        $player.Position = [TimeSpan]::Zero
        $player.Play()
    }
    catch { Write-TdLog "Lecture de $Name impossible : $($_.Exception.Message)" }
}

function Update-TdAudio {
    # Appelé ~6 fois par seconde : termine les préparations et relance la boucle d'ambiance.
    $a = $script:TdAudio
    if (-not $a) { return }
    foreach ($name in @($a.Jobs.Keys)) {
        $job = $a.Jobs[$name]
        if (-not $job.Handle.IsCompleted) { continue }
        try {
            [void]$job.PowerShell.EndInvoke($job.Handle)
            if (-not (Test-Path -LiteralPath $job.Path)) { throw 'fichier absent' }
            $a.Durations[$name] = Get-TdWavDurationSeconds $job.Path
        }
        catch {
            $a.Failed[$name] = $true
            Write-TdLog "Préparation du son $name impossible : $($_.Exception.Message)"
        }
        finally {
            $job.PowerShell.Dispose()
            $a.Jobs.Remove($name)
        }
    }
    $amb = $a.Ambient
    if ($amb.Name -eq 'none' -or $a.MediaBroken) { return }
    if (-not $a.Durations.ContainsKey($amb.Name)) { [void](Request-TdSound $amb.Name); return }
    try {
        if ($amb.Active -lt 0) { Start-TdAmbientPlayer 0; return }
        $player = $amb.Players[$amb.Active]
        $duration = [double]$a.Durations[$amb.Name]
        if ($player.Position.TotalSeconds -ge ($duration - $script:TdLoopFadeSeconds)) {
            Start-TdAmbientPlayer (1 - $amb.Active)
        }
    }
    catch {
        $a.MediaBroken = $true
        Write-TdLog "Ambiance sonore impossible : $($_.Exception.Message)"
    }
}

function Stop-TdAudio {
    $a = $script:TdAudio
    if (-not $a) { return }
    foreach ($p in @($a.Ambient.Players) + @($a.Effects.Values)) {
        if ($p) { try { $p.Stop(); $p.Close() } catch { $null = $_ } }
    }
    foreach ($job in $a.Jobs.Values) { try { $job.PowerShell.Stop(); $job.PowerShell.Dispose() } catch { $null = $_ } }
    $a.Jobs.Clear()
}
