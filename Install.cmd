@echo off
rem TDfocus - installation pour l'utilisateur courant, sans droits administrateur.
rem 1) retire la "marque du Web" des fichiers telecharges (commande en ligne : non soumise a la strategie d'execution)
rem 2) lance l'installateur PowerShell pour ce processus uniquement (-ExecutionPolicy Bypass)
powershell.exe -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0.' -Recurse -File | Unblock-File -ErrorAction SilentlyContinue"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-TDfocus.ps1" %*
if errorlevel 1 (
  echo.
  echo L'installation a echoue. Voir le message ci-dessus.
  pause
  exit /b 1
)
timeout /t 4 >nul
