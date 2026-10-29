# TDfocus - intégration Windows, sans droits administrateur :
#   - lancement automatique à l'ouverture de session via HKCU\...\Run (clé de l'utilisateur) ;
#   - instance unique (mutex nommé local à la session) ;
#   - barre de titre sombre, masquage de la console, thème système.

$script:TdRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:TdStartupApprovedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$script:TdRunName = 'TDfocus'
$script:TdNativeReady = $false

function Initialize-TdNative {
    if ($script:TdNativeReady) { return $true }
    try {
        if (-not ('TDfocus.Native' -as [type])) {
            Add-Type -Namespace TDfocus -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("dwmapi.dll", PreserveSig = true)] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
'@
        }
        $script:TdNativeReady = $true
    }
    catch {
        Write-TdLog "Fonctions natives indisponibles : $($_.Exception.Message)"
    }
    $script:TdNativeReady
}

function Hide-TdConsole {
    if (-not (Initialize-TdNative)) { return }
    try {
        $handle = [TDfocus.Native]::GetConsoleWindow()
        if ($handle -ne [IntPtr]::Zero) { [void][TDfocus.Native]::ShowWindow($handle, 0) }
    }
    catch { $null = $_ }
}

function Set-TdWindowDarkMode {
    param([Parameter(Mandatory)]$Window, [bool]$Dark)
    if (-not (Initialize-TdNative)) { return }
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $value = [int]$Dark
        # 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (Windows 10 20H1+), 19 sur les versions plus anciennes.
        if ([TDfocus.Native]::DwmSetWindowAttribute($hwnd, 20, [ref]$value, 4) -ne 0) {
            [void][TDfocus.Native]::DwmSetWindowAttribute($hwnd, 19, [ref]$value, 4)
        }
    }
    catch { $null = $_ }
}

function Test-TdSystemDarkTheme {
    try {
        $value = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        return ($value -eq 0)
    }
    catch { return $false }
}

function Get-TdPowerShellExe {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $ps) { return $ps }
    (Get-Process -Id $PID).Path
}

function Get-TdLaunchArguments {
    param([Parameter(Mandatory)][string]$ScriptPath, [switch]$Startup)
    $arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$ScriptPath`" -HideConsole"
    if ($Startup) { $arguments += ' -Startup' }
    $arguments
}

function Get-TdAutostartCommand {
    param([Parameter(Mandatory)][string]$ScriptPath)
    '"{0}" {1}' -f (Get-TdPowerShellExe), (Get-TdLaunchArguments -ScriptPath $ScriptPath -Startup)
}

function Get-TdAutostartValue {
    try { return (Get-ItemPropertyValue -Path $script:TdRunKey -Name $script:TdRunName -ErrorAction Stop) }
    catch { return $null }
}

function Set-TdAutostart {
    # Active ou retire le lancement automatique (clé utilisateur : aucun droit admin requis).
    param([Parameter(Mandatory)][bool]$Enabled, [Parameter(Mandatory)][string]$ScriptPath)
    try {
        if ($Enabled) {
            $command = Get-TdAutostartCommand -ScriptPath $ScriptPath
            if ((Get-TdAutostartValue) -ne $command) {
                if (-not (Test-Path -LiteralPath $script:TdRunKey)) { New-Item -Path $script:TdRunKey -Force | Out-Null }
                New-ItemProperty -Path $script:TdRunKey -Name $script:TdRunName -Value $command -PropertyType String -Force | Out-Null
            }
        }
        elseif ($null -ne (Get-TdAutostartValue)) {
            Remove-ItemProperty -Path $script:TdRunKey -Name $script:TdRunName -ErrorAction Stop
        }
        return $true
    }
    catch {
        Write-TdLog "Démarrage automatique : $($_.Exception.Message)"
        return $false
    }
}

function Test-TdAutostartBlockedByUser {
    # Vrai si l'utilisateur a désactivé TDfocus dans Paramètres > Applications > Démarrage
    # (ou dans le Gestionnaire des tâches). On respecte ce choix.
    try {
        $bytes = Get-ItemPropertyValue -Path $script:TdStartupApprovedKey -Name $script:TdRunName -ErrorAction Stop
        return ($bytes -and $bytes.Length -gt 0 -and ($bytes[0] -band 1) -eq 1)
    }
    catch { return $false }
}

function Enter-TdSingleInstance {
    # Renvoie $null si une autre instance tourne déjà (elle est alors priée de s'afficher).
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\TDfocus.SingleInstance', [ref]$created)
    $showEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\TDfocus.Show')
    if (-not $created) {
        [void]$showEvent.Set()
        $showEvent.Dispose()
        $mutex.Dispose()
        return $null
    }
    [pscustomobject]@{ Mutex = $mutex; ShowEvent = $showEvent }
}

function Exit-TdSingleInstance {
    param($Instance)
    if (-not $Instance) { return }
    try { $Instance.Mutex.ReleaseMutex() } catch { $null = $_ }
    $Instance.Mutex.Dispose()
    $Instance.ShowEvent.Dispose()
}
