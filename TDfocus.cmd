@echo off
rem Lance TDfocus directement depuis ce dossier, sans l'installer.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0src\TDfocus.ps1" -HideConsole
