@echo off
REM cmd wrapper for building internal-test APKs.
REM
REM Why this exists: the Windows default execution policy refuses to run .ps1
REM files, and -ExecutionPolicy Bypass applies only to that single process --
REM it does not change any system setting.
REM
REM Usage:
REM   tools\build-release.cmd http://192.168.1.100:8080/api
REM   tools\build-release.cmd https://vol.cumt.edu.cn/api both -Clean
REM
REM ENCODING: this file is ASCII-only on purpose. cmd.exe reads .cmd files as
REM the OEM/ANSI codepage (GBK here), so non-ASCII REM lines get garbled into
REM things cmd then tries to EXECUTE. Measured symptom: lines like
REM "'...' is not recognized as an internal or external command" coming from
REM what was supposed to be a comment. Do not add Chinese text or emoji.
REM
REM QUOTING: %~dp0 expands to "D:\VOLUNTEER SYSTEM\tools\" which CONTAINS A
REM SPACE, so every expansion below must be quoted. Missing one yields
REM "'D:\VOLUNTEER' is not recognized ...".
setlocal
set "SCRIPT=%~dp0build-release.ps1"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
%PS% "%SCRIPT%" -ApiBaseUrl %*
exit /b %ERRORLEVEL%
