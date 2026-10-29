@echo off
rem TDfocus - desinstallation (utilisateur courant, sans droits administrateur).
rem Ajouter -RemoveData pour effacer aussi la liste, l'historique et les notes.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-TDfocus.ps1" %*
pause
