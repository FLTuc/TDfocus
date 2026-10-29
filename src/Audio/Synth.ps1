# TDfocus - synthèse sonore en PowerShell pur (aucun fichier audio fourni, aucun téléchargement).
# Chaque son est calculé une seule fois puis mis en cache en WAV dans %LOCALAPPDATA%\TDfocus\sounds.
# Ce fichier est autonome : il est aussi exécuté dans un runspace d'arrière-plan.
#
# Les ambiances (bruits, pluie, carillons) ont une montée et une descente « à puissance
# constante » de $TdLoopFadeSeconds : le lecteur enchaîne deux copies qui se chevauchent
# pendant ce fondu, ce qui donne une boucle continue, sans coupure audible.

$script:TdSoundVersion = 1
$script:TdLoopFadeSeconds = 2.0

$script:TdSoundCatalog = @{
    white    = @{ Ambient = $true }
    pink     = @{ Ambient = $true }
    brown    = @{ Ambient = $true }
    rain     = @{ Ambient = $true }
    chimes   = @{ Ambient = $true }
    chime    = @{ Ambient = $false }
    complete = @{ Ambient = $false }
    timeup   = @{ Ambient = $false }
    landing  = @{ Ambient = $false }
}

function Get-TdSoundFileName {
    # -Seamless : variante d'ambiance bouclable sans fondu (lecteurs Linux / macOS).
    param([Parameter(Mandatory)][string]$Name, [switch]$Seamless)
    if ($Seamless) { return "$Name-seamless-v$($script:TdSoundVersion).wav" }
    "$Name-v$($script:TdSoundVersion).wav"
}

function ConvertTo-TdWavBytes {
    # Mono, 16 bits, PCM.
    param([Parameter(Mandatory)][double[]]$Samples, [Parameter(Mandatory)][int]$SampleRate)
    $n = $Samples.Length
    $pcm = New-Object 'int16[]' $n
    for ($i = 0; $i -lt $n; $i++) {
        $v = $Samples[$i]
        if ($v -gt 1.0) { $v = 1.0 } elseif ($v -lt -1.0) { $v = -1.0 }
        $pcm[$i] = [int16][Math]::Round($v * 32000)
    }
    $dataBytes = $n * 2
    $stream = New-Object System.IO.MemoryStream (44 + $dataBytes)
    $w = New-Object System.IO.BinaryWriter $stream
    $ascii = [System.Text.Encoding]::ASCII
    $w.Write($ascii.GetBytes('RIFF'))
    $w.Write([int](36 + $dataBytes))
    $w.Write($ascii.GetBytes('WAVE'))
    $w.Write($ascii.GetBytes('fmt '))
    $w.Write([int]16)
    $w.Write([int16]1)               # PCM
    $w.Write([int16]1)               # mono
    $w.Write([int]$SampleRate)
    $w.Write([int]($SampleRate * 2)) # octets par seconde
    $w.Write([int16]2)               # alignement
    $w.Write([int16]16)              # bits par échantillon
    $w.Write($ascii.GetBytes('data'))
    $w.Write([int]$dataBytes)
    $bytes = New-Object 'byte[]' $dataBytes
    [Buffer]::BlockCopy($pcm, 0, $bytes, 0, $dataBytes)
    $w.Write($bytes)
    $w.Flush()
    , $stream.ToArray()
}

function Set-TdNormalized {
    # Normalise au niveau RMS visé, sans dépasser la crête maximale.
    param([Parameter(Mandatory)][double[]]$Samples, [double]$TargetRms = 0.18, [double]$MaxPeak = 0.95)
    $sum = 0.0
    $peak = 0.0
    $n = $Samples.Length
    for ($i = 0; $i -lt $n; $i++) {
        $v = $Samples[$i]
        $sum += $v * $v
        $a = [Math]::Abs($v)
        if ($a -gt $peak) { $peak = $a }
    }
    if ($n -eq 0 -or $sum -le 0) { return }
    $rms = [Math]::Sqrt($sum / $n)
    $gain = $TargetRms / $rms
    if ($peak * $gain -gt $MaxPeak) { $gain = $MaxPeak / $peak }
    for ($i = 0; $i -lt $n; $i++) { $Samples[$i] = $Samples[$i] * $gain }
}

function Set-TdLoopFades {
    # Montée en sinus et descente en cosinus : somme de puissance constante au chevauchement.
    param([Parameter(Mandatory)][double[]]$Samples, [Parameter(Mandatory)][int]$SampleRate, [double]$Seconds = $script:TdLoopFadeSeconds)
    $f = [int]($Seconds * $SampleRate)
    $n = $Samples.Length
    $halfPi = [Math]::PI / 2
    for ($i = 0; $i -lt $f -and $i -lt $n; $i++) {
        $g = [Math]::Sin($halfPi * $i / $f)
        $Samples[$i] = $Samples[$i] * $g
        $j = $n - 1 - $i
        $Samples[$j] = $Samples[$j] * $g
    }
}

function ConvertTo-TdSeamlessLoop {
    # Boucle sans couture : la fin se fond (à puissance constante) dans le début.
    # Entrée : N + F échantillons ; sortie : N échantillons qui se rebouclent sans saut.
    param([Parameter(Mandatory)][double[]]$Samples, [Parameter(Mandatory)][int]$SampleRate, [double]$Seconds = $script:TdLoopFadeSeconds)
    $f = [int]($Seconds * $SampleRate)
    $n = $Samples.Length - $f
    $out = New-Object 'double[]' $n
    [Array]::Copy($Samples, $out, $n)
    $halfPi = [Math]::PI / 2
    for ($i = 0; $i -lt $f; $i++) {
        $t = $halfPi * $i / $f
        $out[$i] = $Samples[$i] * [Math]::Sin($t) + $Samples[$n + $i] * [Math]::Cos($t)
    }
    , $out
}

function New-TdNoiseSamples {
    param([ValidateSet('white', 'pink', 'brown')][string]$Kind, [int]$SampleRate = 16000, [double]$Seconds = 16, [int]$Seed = 7, [switch]$NoFades)
    $n = [int]($SampleRate * $Seconds)
    $out = New-Object 'double[]' $n
    $rnd = New-Object System.Random $Seed
    switch ($Kind) {
        'white' {
            for ($i = 0; $i -lt $n; $i++) { $out[$i] = $rnd.NextDouble() * 2 - 1 }
        }
        'pink' {
            # Filtre de Paul Kellet.
            $b0 = 0.0; $b1 = 0.0; $b2 = 0.0; $b3 = 0.0; $b4 = 0.0; $b5 = 0.0; $b6 = 0.0
            for ($i = 0; $i -lt $n; $i++) {
                $w = $rnd.NextDouble() * 2 - 1
                $b0 = 0.99886 * $b0 + $w * 0.0555179
                $b1 = 0.99332 * $b1 + $w * 0.0750759
                $b2 = 0.96900 * $b2 + $w * 0.1538520
                $b3 = 0.86650 * $b3 + $w * 0.3104856
                $b4 = 0.55000 * $b4 + $w * 0.5329522
                $b5 = -0.7616 * $b5 - $w * 0.0168980
                $out[$i] = $b0 + $b1 + $b2 + $b3 + $b4 + $b5 + $b6 + $w * 0.5362
                $b6 = $w * 0.115926
            }
        }
        'brown' {
            # Intégrateur à fuite + passe-haut très bas pour supprimer toute dérive.
            $b = 0.0
            $dc = 0.0
            for ($i = 0; $i -lt $n; $i++) {
                $w = $rnd.NextDouble() * 2 - 1
                $b = ($b + 0.02 * $w) / 1.02
                $dc = $dc + 0.0005 * ($b - $dc)
                $out[$i] = $b - $dc
            }
        }
    }
    $target = 0.16
    if ($Kind -eq 'white') { $target = 0.12 }
    Set-TdNormalized -Samples $out -TargetRms $target
    if (-not $NoFades) { Set-TdLoopFades -Samples $out -SampleRate $SampleRate }
    , $out
}

function New-TdRainSamples {
    # Pluie douce : bruit rose adouci + gouttes aléatoires + légères rafales.
    param([int]$SampleRate = 16000, [double]$Seconds = 18, [int]$Seed = 11, [switch]$NoFades)
    $n = [int]($SampleRate * $Seconds)
    $out = New-Object 'double[]' $n
    $rnd = New-Object System.Random $Seed
    $b0 = 0.0; $b1 = 0.0; $b2 = 0.0
    $lp = 0.0; $slow = 0.0
    $drop = 0.0; $dropDecay = 0.0; $dropLp = 0.0
    $dropChance = 45.0 / $SampleRate
    $twoPi = 2 * [Math]::PI
    for ($i = 0; $i -lt $n; $i++) {
        $w = $rnd.NextDouble() * 2 - 1
        $b0 = 0.99765 * $b0 + $w * 0.0990460
        $b1 = 0.96300 * $b1 + $w * 0.2965164
        $b2 = 0.57000 * $b2 + $w * 1.0526913
        $pink = ($b0 + $b1 + $b2 + $w * 0.1848) * 0.2
        $lp = $lp + 0.45 * ($pink - $lp)
        $slow = $slow + 0.06 * ($lp - $slow)
        $bed = $lp - $slow
        if ($rnd.NextDouble() -lt $dropChance) {
            $drop = 0.25 + 0.75 * $rnd.NextDouble()
            $dropDecay = [Math]::Exp(-1.0 / ($SampleRate * (0.002 + 0.008 * $rnd.NextDouble())))
        }
        $dropNoise = $drop * ($rnd.NextDouble() * 2 - 1)
        $dropLp = $dropLp + 0.5 * ($dropNoise - $dropLp)
        $drop = $drop * $dropDecay
        $gust = 0.8 + 0.2 * [Math]::Sin($twoPi * $i / ($SampleRate * 6.0))
        $out[$i] = $gust * $bed + 0.35 * ($dropNoise - $dropLp)
    }
    Set-TdNormalized -Samples $out -TargetRms 0.15
    if (-not $NoFades) { Set-TdLoopFades -Samples $out -SampleRate $SampleRate }
    , $out
}

function Add-TdBell {
    # Ajoute une cloche douce (partiels inharmoniques à décroissance exponentielle).
    param(
        [Parameter(Mandatory)][double[]]$Buffer,
        [Parameter(Mandatory)][int]$SampleRate,
        [Parameter(Mandatory)][double]$StartSeconds,
        [Parameter(Mandatory)][double]$Frequency,
        [double]$Amplitude = 0.3,
        [double]$DecaySeconds = 2.5,
        [double[]]$Ratios = @(1.0, 2.0, 2.76, 4.07),
        [double[]]$Gains = @(1.0, 0.45, 0.25, 0.12)
    )
    $start = [int]($StartSeconds * $SampleRate)
    $length = [int]([Math]::Min($DecaySeconds * 4, 6) * $SampleRate)
    $attack = [int](0.004 * $SampleRate)
    $twoPi = 2 * [Math]::PI
    for ($p = 0; $p -lt $Ratios.Length; $p++) {
        $freq = $Frequency * $Ratios[$p]
        if ($freq -ge $SampleRate / 2) { continue }
        $gain = $Amplitude * $Gains[$p]
        $decay = $DecaySeconds / (1 + $p * 0.8)
        $k = -1.0 / ($decay * $SampleRate)
        $step = $twoPi * $freq / $SampleRate
        $end = [Math]::Min($Buffer.Length, $start + $length)
        for ($i = $start; $i -lt $end; $i++) {
            $t = $i - $start
            $env = [Math]::Exp($k * $t)
            if ($t -lt $attack) { $env = $env * $t / $attack }
            $Buffer[$i] = $Buffer[$i] + $gain * $env * [Math]::Sin($step * $t)
        }
    }
}

function New-TdChimesSamples {
    # Carillon d'ambiance : notes pentatoniques aléatoires sur un léger souffle de vent.
    param([int]$SampleRate = 22050, [double]$Seconds = 30, [int]$Seed = 5, [switch]$NoFades)
    $n = [int]($SampleRate * $Seconds)
    $out = New-Object 'double[]' $n
    $rnd = New-Object System.Random $Seed
    $b = 0.0
    $dc = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $b = ($b + 0.02 * ($rnd.NextDouble() * 2 - 1)) / 1.02
        $dc = $dc + 0.0005 * ($b - $dc)
        $out[$i] = 0.25 * ($b - $dc)
    }
    $notes = @(523.25, 587.33, 659.25, 783.99, 880.0, 1046.5, 1174.66)
    $t = 0.8
    while ($t -lt $Seconds - 3) {
        $freq = $notes[$rnd.Next($notes.Length)]
        Add-TdBell -Buffer $out -SampleRate $SampleRate -StartSeconds $t -Frequency $freq -Amplitude (0.08 + 0.08 * $rnd.NextDouble()) -DecaySeconds 3.2 -Ratios @(1.0, 2.0, 3.01) -Gains @(1.0, 0.3, 0.12)
        $t += 1.2 + 2.6 * $rnd.NextDouble()
    }
    Set-TdNormalized -Samples $out -TargetRms 0.08 -MaxPeak 0.6
    if (-not $NoFades) { Set-TdLoopFades -Samples $out -SampleRate $SampleRate }
    , $out
}

function New-TdEffectSamples {
    param([ValidateSet('chime', 'complete', 'timeup', 'landing')][string]$Name, [int]$SampleRate = 22050)
    switch ($Name) {
        'chime' {
            # Carillon périodique : une cloche discrète pour sortir de la rêverie.
            $out = New-Object 'double[]' ([int](3.0 * $SampleRate))
            Add-TdBell -Buffer $out -SampleRate $SampleRate -StartSeconds 0.02 -Frequency 659.25 -Amplitude 0.32 -DecaySeconds 1.6
        }
        'complete' {
            # Validation : petit arpège ascendant lumineux.
            $out = New-Object 'double[]' ([int](1.6 * $SampleRate))
            $freqs = @(1046.5, 1318.51, 1567.98, 2093.0)
            for ($k = 0; $k -lt $freqs.Length; $k++) {
                Add-TdBell -Buffer $out -SampleRate $SampleRate -StartSeconds (0.01 + 0.075 * $k) -Frequency $freqs[$k] -Amplitude (0.22 - 0.02 * $k) -DecaySeconds 0.45 -Ratios @(1.0, 2.0, 3.0) -Gains @(1.0, 0.25, 0.08)
            }
        }
        'landing' {
            # Atterrissage : trois notes descendantes très douces, « on se pose ».
            $out = New-Object 'double[]' ([int](2.6 * $SampleRate))
            $freqs = @(880.0, 783.99, 659.25)
            for ($k = 0; $k -lt $freqs.Length; $k++) {
                Add-TdBell -Buffer $out -SampleRate $SampleRate -StartSeconds (0.02 + 0.32 * $k) -Frequency $freqs[$k] -Amplitude 0.16 -DecaySeconds 0.9 -Ratios @(1.0, 2.0) -Gains @(1.0, 0.2)
            }
        }
        'timeup' {
            # Temps prévu écoulé : deux notes douces, jamais une alarme.
            $out = New-Object 'double[]' ([int](2.4 * $SampleRate))
            Add-TdBell -Buffer $out -SampleRate $SampleRate -StartSeconds 0.02 -Frequency 783.99 -Amplitude 0.2 -DecaySeconds 0.9
            Add-TdBell -Buffer $out -SampleRate $SampleRate -StartSeconds 0.42 -Frequency 659.25 -Amplitude 0.2 -DecaySeconds 1.1
        }
    }
    Set-TdNormalized -Samples $out -TargetRms 0.12 -MaxPeak 0.7
    # Fin en douceur : pas de « clic » quand le fichier s'arrête.
    $fade = [int](0.25 * $SampleRate)
    for ($i = 0; $i -lt $fade; $i++) {
        $j = $out.Length - 1 - $i
        $out[$j] = $out[$j] * ($i / [double]$fade)
    }
    , $out
}

function New-TdSoundFile {
    # Calcule le son $Name et l'écrit dans $Path. Renvoie la durée en secondes.
    # -Seamless : ambiance de 60 s bouclable telle quelle (pas de fondus à chevaucher).
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path, [switch]$Seamless)
    $rate = 16000
    $loop = @{}
    if ($Seamless) { $loop = @{ Seconds = 60 + $script:TdLoopFadeSeconds; NoFades = $true } }
    switch ($Name) {
        'white' { $samples = New-TdNoiseSamples -Kind white -SampleRate $rate @loop }
        'pink' { $samples = New-TdNoiseSamples -Kind pink -SampleRate $rate @loop }
        'brown' { $samples = New-TdNoiseSamples -Kind brown -SampleRate $rate @loop }
        'rain' { $samples = New-TdRainSamples -SampleRate $rate @loop }
        'chimes' { $rate = 22050; $samples = New-TdChimesSamples -SampleRate $rate @loop }
        default { $rate = 22050; $samples = New-TdEffectSamples -Name $Name -SampleRate $rate }
    }
    if ($Seamless -and $script:TdSoundCatalog[$Name].Ambient) {
        $samples = ConvertTo-TdSeamlessLoop -Samples $samples -SampleRate $rate
    }
    $bytes = ConvertTo-TdWavBytes -Samples $samples -SampleRate $rate
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllBytes($tmp, $bytes)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path
    $samples.Length / [double]$rate
}

function Get-TdWavDurationSeconds {
    param([Parameter(Mandatory)][string]$Path)
    $info = Get-Item -LiteralPath $Path
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $reader = New-Object System.IO.BinaryReader $stream
        $null = $reader.ReadBytes(24)
        $rate = $reader.ReadInt32()
        $byteRate = $reader.ReadInt32()
        if ($byteRate -le 0) { $byteRate = $rate * 2 }
        ($info.Length - 44) / [double]$byteRate
    }
    finally { $stream.Dispose() }
}
