@echo off
rem =====================================================================
rem  Volunteer Platform - one-click server launcher
rem
rem  This is the ONLY entry point. It does everything:
rem    1. first run: generate .env (random TOKEN_SECRET)
rem    2. allow the inbound firewall port (one UAC prompt - click Yes)
rem    3. start the server (serves both the web page and the phone API)
rem    4. copy the phone server address to the clipboard automatically
rem
rem  All Chinese output lives in start.ps1 (saved as UTF-8 with BOM)
rem  to avoid codepage problems in cmd.exe. Keep THIS file ASCII-only.
rem
rem  Options:  -Port 8081   -NoBrowser   -FirewallOnly   -SkipFirewall
rem =====================================================================
chcp 65001 >nul 2>&1
setlocal
set "PS=powershell"
where pwsh >nul 2>&1 && set "PS=pwsh"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
if errorlevel 1 (
  echo.
  echo [Launcher exited with an error. See messages above.]
  pause
)
endlocal
