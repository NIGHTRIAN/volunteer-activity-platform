@echo off
rem ---------------------------------------------------------------------
rem  Publish this repository to GitHub.
rem  Double-click this file; it will ask for a token.
rem
rem  NOTE: keep this file ASCII-only. Windows cmd parses .bat with the OEM
rem  code page (936/GBK on Chinese Windows); UTF-8 Chinese text in a .bat
rem  gets split into garbage commands like "'Hub' is not recognized".
rem  All Chinese messages live in publish-github.ps1 instead.
rem ---------------------------------------------------------------------
setlocal
title Publish to GitHub
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish-github.ps1" %*
set EXITCODE=%ERRORLEVEL%
if not "%EXITCODE%"=="0" (
  echo.
  echo   Publish did not finish successfully ^(exit code %EXITCODE%^). Reason is above.
  pause
)
rem Expand EXITCODE before endlocal drops it, then propagate to the caller.
endlocal & exit /b %EXITCODE%