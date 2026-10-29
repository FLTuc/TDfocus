# TDfocus - icône de la zone de notification (près de l'horloge Windows).

function Initialize-TdTray {
    try {
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $iconPath = Join-Path $script:Td.Assets 'TDfocus.ico'
        if (Test-Path -LiteralPath $iconPath) { $notify.Icon = New-Object System.Drawing.Icon $iconPath, ([System.Windows.Forms.SystemInformation]::SmallIconSize) }
        else { $notify.Icon = [System.Drawing.SystemIcons]::Application }
        $notify.Text = 'TDfocus'

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $open = $menu.Items.Add('Ouvrir TDfocus')
        $open.Font = New-Object System.Drawing.Font $open.Font, ([System.Drawing.FontStyle]::Bold)
        $open.Add_Click({ if ($script:Td.Compact) { Set-TdCompactMode $false }; Show-TdWindow })
        $toggle = $menu.Items.Add('Démarrer')
        $toggle.Add_Click({ Switch-TdTimerNow })
        $done = $menu.Items.Add('Terminer la tâche en cours')
        $done.Add_Click({ Complete-TdCurrentNow })
        $compact = $menu.Items.Add('Mode compact flottant')
        $compact.Add_Click({ Show-TdWindow; Set-TdCompactMode $true })
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $quit = $menu.Items.Add('Quitter TDfocus')
        $quit.Add_Click({ $script:Td.Quitting = $true; Stop-TdApp })
        $notify.ContextMenuStrip = $menu

        $notify.Add_MouseClick({
                param($s, $e)
                if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                    $w = $script:Td.Window
                    if ($w.IsVisible -and $w.IsActive) { $w.Hide() } else { Show-TdWindow }
                }
            })
        $notify.Add_BalloonTipClicked({ Show-TdWindow })
        $notify.Visible = $true
        $script:Td.Tray = @{ Icon = $notify; Menu = $menu; Toggle = $toggle; Done = $done }
        Update-TdTrayMenu
    }
    catch {
        Write-TdLog "Zone de notification indisponible : $($_.Exception.Message)"
        $script:Td.Tray = $null
    }
}

function Update-TdTrayMenu {
    $tray = $script:Td.Tray
    if (-not $tray) { return }
    $state = Get-TdState
    $current = Get-TdCurrentTask $state
    $tray.Toggle.Enabled = [bool]$current
    $tray.Done.Enabled = [bool]$current
    if ($current -and $null -ne $current.runningSince) { $tray.Toggle.Text = 'Pause' }
    elseif ($current -and $current.elapsedMs -gt 0) { $tray.Toggle.Text = 'Reprendre' }
    else { $tray.Toggle.Text = 'Démarrer' }
}

function Show-TdTrayBalloon {
    param([Parameter(Mandatory)][string]$Text)
    $tray = $script:Td.Tray
    if (-not $tray) { return }
    try { $tray.Icon.ShowBalloonTip(5000, 'TDfocus', $Text, [System.Windows.Forms.ToolTipIcon]::None) } catch { $null = $_ }
}

function Remove-TdTray {
    $tray = $script:Td.Tray
    if (-not $tray) { return }
    try {
        $tray.Icon.Visible = $false
        $tray.Icon.Dispose()
        $tray.Menu.Dispose()
    }
    catch { $null = $_ }
    $script:Td.Tray = $null
}
