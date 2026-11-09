@echo off
rem Lance TDfocus directement depuis ce dossier, sans l'installer.
rem Avec le lanceur TDfocus.exe (cree au premier lancement), aucune fenetre de console ne reste ouverte.
if exist "%~dp0TDfocus.exe" (
  start "" "%~dp0TDfocus.exe"
  exit /b 0
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0src\TDfocus.ps1" -HideConsole
