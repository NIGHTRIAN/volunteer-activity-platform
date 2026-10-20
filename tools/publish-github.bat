@echo off
chcp 65001 >nul
setlocal
title 发布到 GitHub
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish-github.ps1" %*
set EXITCODE=%ERRORLEVEL%
if not "%EXITCODE%"=="0" (
  echo.
  echo   发布没有成功退出（代码 %EXITCODE%）。上面有原因。
  pause
)
endlocal