# TDfocus - intégration Linux (et macOS pour les notifications), sans droits root :
#   - lancement automatique à l'ouverture de session (fichier XDG ~/.config/autostart) ;
#   - ouverture dans un émulateur de terminal quand TDfocus est lancé hors terminal ;
#   - notifications de bureau (notify-send / osascript).

function Get-TdXdgConfigHome {
    if ($env:XDG_CONFIG_HOME) { return $env:XDG_CONFIG_HOME }
    Join-Path $HOME '.config'
}

function Get-TdXdgDataHome {
    if ($env:XDG_DATA_HOME) { return $env:XDG_DATA_HOME }
    Join-Path (Join-Path $HOME '.local') 'share'
}

function Get-TdLinuxAutostartPath {
    Join-Path (Join-Path (Get-TdXdgConfigHome) 'autostart') 'tdfocus.desktop'
}

function ConvertTo-TdDesktopExecArg {
    # Guillemets de la spécification Desktop Entry pour la clé Exec.
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -notmatch '[\s"`$\\]') { return $Value }
    '"' + ($Value -replace '(["`$\\])', '\$1') + '"'
}

function New-TdDesktopEntry {
    param(
        [Parameter(Mandatory)][string[]]$Command,
        [string]$Icon,
        [switch]$Autostart
    )
    $exec = ($Command | ForEach-Object { ConvertTo-TdDesktopExecArg $_ }) -join ' '
    $lines = @(
        '[Desktop Entry]'
        'Type=Application'
        'Name=TDfocus'
        'GenericName=Minuteur séquentiel'
        'Comment=Une seule tâche à la fois, l''heure de fin toujours sous les yeux'
        "Exec=$exec"
        'Terminal=false'
        'Categories=Utility;'
        'Keywords=TDAH;ADHD;focus;minuteur;timer;'
    )
    if ($Icon) { $lines += "Icon=$Icon" }
    if ($Autostart) { $lines += @('X-GNOME-Autostart-enabled=true', 'X-GNOME-Autostart-Delay=5') }
    ($lines -join "`n") + "`n"
}

function Get-TdLinuxLauncherCommand {
    # Commande lancée à l'ouverture de session : le lanceur installé, sinon pwsh + le script.
    param([Parameter(Mandatory)][string]$ScriptPath)
    $launcher = Join-Path (Join-Path (Join-Path $HOME '.local') 'bin') 'tdfocus'
    if (Test-Path -LiteralPath $launcher) { return , @($launcher, '-Startup') }
    $pwsh = (Get-Process -Id $PID).Path
    , @($pwsh, '-NoProfile', '-File', $ScriptPath, '-Startup')
}

function Set-TdLinuxAutostart {
    param([Parameter(Mandatory)][bool]$Enabled, [Parameter(Mandatory)][string]$ScriptPath)
    $path = Get-TdLinuxAutostartPath
    try {
        if ($Enabled) {
            $icon = Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptPath)) 'assets/TDfocus.png'
            $content = New-TdDesktopEntry -Command (Get-TdLinuxLauncherCommand -ScriptPath $ScriptPath) -Icon $icon -Autostart
            $dir = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $current = $null
            if (Test-Path -LiteralPath $path) { $current = [System.IO.File]::ReadAllText($path) }
            if ($current -ne $content) { [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false))) }
        }
        elseif (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
        return $true
    }
    catch {
        Write-TdLog "Démarrage automatique (Linux) : $($_.Exception.Message)"
        return $false
    }
}

function Test-TdCommand {
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-Command -Name $Name -CommandType Application -ErrorAction Ignore)
}

function Get-TdTerminalCandidates {
    # Émulateurs de terminal disponibles, dans l'ordre de préférence ($TERMINAL d'abord).
    # Chaque entrée : { file ; args } où « args » précède la commande à exécuter.
    $known = @(
        @{ name = 'x-terminal-emulator'; args = @('-e') }
        @{ name = 'gnome-terminal'; args = @('--title=TDfocus', '--') }
        @{ name = 'konsole'; args = @('-e') }
        @{ name = 'xfce4-terminal'; args = @('--title=TDfocus', '-x') }
        @{ name = 'mate-terminal'; args = @('--title=TDfocus', '-x') }
        @{ name = 'kitty'; args = @('--title', 'TDfocus') }
        @{ name = 'alacritty'; args = @('--title', 'TDfocus', '-e') }
        @{ name = 'foot'; args = @('--title=TDfocus') }
        @{ name = 'wezterm'; args = @('start', '--') }
        @{ name = 'tilix'; args = @('-e') }
        @{ name = 'xterm'; args = @('-T', 'TDfocus', '-e') }
    )
    if ($env:TERMINAL -and (Test-TdCommand $env:TERMINAL)) {
        [pscustomobject]@{ file = $env:TERMINAL; args = @('-e') }
    }
    foreach ($c in $known) {
        if (Test-TdCommand $c.name) { [pscustomobject]@{ file = $c.name; args = $c.args } }
    }
}

function Start-TdInTerminal {
    # Relance la commande dans un émulateur de terminal. Vrai si l'un d'eux a démarré.
    # Un terminal qui s'arrête aussitôt en erreur (pas d'affichage...) laisse sa place au suivant.
    param([Parameter(Mandatory)][string[]]$Command)
    if (-not $env:DISPLAY -and -not $env:WAYLAND_DISPLAY) { return $false }
    foreach ($terminal in @(Get-TdTerminalCandidates)) {
        $info = New-Object System.Diagnostics.ProcessStartInfo $terminal.file
        foreach ($a in @($terminal.args) + @($Command)) { $info.ArgumentList.Add($a) }
        $info.UseShellExecute = $false
        $info.RedirectStandardError = $true
        try {
            $process = [System.Diagnostics.Process]::Start($info)
            if ($process.WaitForExit(1500) -and $process.ExitCode -ne 0) {
                Write-TdLog "Terminal $($terminal.file) en échec ($($process.ExitCode)) : $($process.StandardError.ReadToEnd().Trim())"
                continue
            }
            return $true
        }
        catch { Write-TdLog "Terminal $($terminal.file) introuvable : $($_.Exception.Message)" }
    }
    $false
}

function Send-TdDesktopNotification {
    # Notification discrète (jamais une alarme). Silencieux si rien n'est disponible.
    param([Parameter(Mandatory)][string]$Message, [string]$Icon)
    try {
        if (Test-TdCommand 'notify-send') {
            $info = New-Object System.Diagnostics.ProcessStartInfo 'notify-send'
            foreach ($a in @('--app-name=TDfocus', '--urgency=low')) { $info.ArgumentList.Add($a) }
            if ($Icon) { $info.ArgumentList.Add("--icon=$Icon") }
            $info.ArgumentList.Add('TDfocus')
            $info.ArgumentList.Add($Message)
        }
        elseif (Test-TdCommand 'osascript') {
            $info = New-Object System.Diagnostics.ProcessStartInfo 'osascript'
            $text = $Message.Replace('\', '\\').Replace('"', '\"')
            $info.ArgumentList.Add('-e')
            $info.ArgumentList.Add("display notification `"$text`" with title `"TDfocus`"")
        }
        else { return }
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        [void][System.Diagnostics.Process]::Start($info)
    }
    catch { $null = $_ }
}
