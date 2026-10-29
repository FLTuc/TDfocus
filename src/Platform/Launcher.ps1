# TDfocus - lanceur Windows sans fenêtre de console.
#
# powershell.exe est une application console : même avec -WindowStyle Hidden, une console
# apparaît un instant au démarrage. TDfocus.exe est une petite application fenêtrée qui
# démarre PowerShell avec CreateNoWindow : aucune console n'est créée à l'écran.
# Il est compilé sur le PC à l'installation par le compilateur C# fourni avec .NET Framework
# (présent sur tout Windows 10/11), dans le profil de l'utilisateur, sans droits administrateur.

$script:TdLauncherSource = @'
using System;
using System.Diagnostics;
using System.IO;

[assembly: System.Reflection.AssemblyTitle("TDfocus")]
[assembly: System.Reflection.AssemblyProduct("TDfocus")]
[assembly: System.Reflection.AssemblyDescription("Lanceur de TDfocus (PowerShell) sans fenetre de console")]

internal static class TDfocusLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(root, "src", "TDfocus.ps1");
        if (!File.Exists(script)) { return 2; }
        if (args.Length > 0 && args[0] == "--check") { return 0; }

        string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        string powershell = Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe");
        string extra = "";
        foreach (string arg in args)
        {
            if (string.Equals(arg, "-Startup", StringComparison.OrdinalIgnoreCase)) { extra += " -Startup"; }
        }
        ProcessStartInfo info = new ProcessStartInfo(powershell,
            "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\" -HideConsole" + extra);
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.WorkingDirectory = root;
        Process.Start(info);
        return 0;
    }
}
'@

function Get-TdCscPath {
    foreach ($framework in @('Framework64', 'Framework')) {
        $csc = Join-Path $env:WINDIR "Microsoft.NET\$framework\v4.0.30319\csc.exe"
        if (Test-Path -LiteralPath $csc) { return $csc }
    }
    $null
}

function New-TdLauncher {
    # Compile TDfocus.exe dans le dossier de l'application. Renvoie son chemin, ou $null si la
    # compilation ou l'exécution est impossible (AppLocker/WDAC en entreprise par exemple).
    param([Parameter(Mandatory)][string]$Destination, [string]$IconPath)
    $exe = Join-Path $Destination 'TDfocus.exe'
    $csc = Get-TdCscPath
    if (-not $csc) {
        Write-TdLog 'Compilateur C# de .NET Framework introuvable : lanceur sans console indisponible.'
        return $null
    }
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('tdfocus-launcher-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $source = Join-Path $work 'Launcher.cs'
        [System.IO.File]::WriteAllText($source, $script:TdLauncherSource, (New-Object System.Text.UTF8Encoding($true)))
        $cscArgs = @('/nologo', '/target:winexe', '/optimize+', "/out:$exe")
        if ($IconPath -and (Test-Path -LiteralPath $IconPath)) { $cscArgs += "/win32icon:$IconPath" }
        $cscArgs += $source
        $output = & $csc @cscArgs 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
            Write-TdLog ('Compilation du lanceur impossible : ' + (@($output) -join ' '))
            return $null
        }
        # Le lanceur doit pouvoir s'exécuter : une stratégie d'entreprise peut bloquer les .exe du profil.
        $check = Start-Process -FilePath $exe -ArgumentList '--check' -Wait -PassThru -WindowStyle Hidden
        if ($check.ExitCode -ne 0) {
            Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
            Write-TdLog "Le lanceur ne peut pas s'exécuter (code $($check.ExitCode))."
            return $null
        }
        $exe
    }
    catch {
        Write-TdLog "Lanceur sans console indisponible : $($_.Exception.Message)"
        Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
        $null
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
