@echo off
rem Launcher for Win10 Tile Fixer (requires PowerShell 7 - pwsh)
where pwsh >nul 2>nul
if errorlevel 1 (
  echo [Win10 Tile Fixer] PowerShell 7 ^(pwsh^) is required but not found.
  echo Install it with:  winget install Microsoft.PowerShell
  pause
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0TileFixer.ps1" %*
pause
