@echo off
REM Launch one of the stack processes with output captured to .logs\.
REM
REM Why this wrapper exists:
REM   Two measured problems are solved by moving the work into cmd.exe:
REM     1. Redirection. Start-Process -RedirectStandardOutput makes the child
REM        inherit the parent's pipes, and the launching script then never
REM        exits (it hangs on those handles after printing its status).
REM     2. Quoting. This repo path contains a space ("VOLUNTEER SYSTEM").
REM        Passing that path to `cmd.exe /c` without proper quoting fails with
REM        "'D:\VOLUNTEER' is not recognized as an internal or external command".
REM
REM The wrapper takes an argument (server|web) rather than a path, so the
REM caller never has to pass a space-containing path through cmd /c.
REM
REM Usage (called by dev-stack.ps1, not by hand):
REM   run-stack.cmd server
REM   run-stack.cmd web
REM
REM ENCODING: ASCII-only on purpose. cmd.exe decodes .cmd files with the
REM OEM/ANSI codepage (GBK here), so non-ASCII comments become garbage that
REM cmd then tries to EXECUTE.

setlocal

REM %~dp0 already ends with a backslash, so "%~dp0.." is
REM "D:\VOLUNTEER SYSTEM\tools\.." -- valid but ugly. Use /d + cd/p to
REM normalise it once, then everything downstream is a clean absolute path.
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
for %%I in ("%HERE%\..") do set "ROOT=%%~fI"

set "NODE_BIN=D:\dsh\resources\runtime\primary-runtime\dependencies\node\bin"
set "PATH=%NODE_BIN%;C:\Program Files\Git\cmd;%PATH%"
set "LOGDIR=%ROOT%\.logs"

if not exist "%NODE_BIN%\node.exe" (
  echo [run-stack] Cannot find node at "%NODE_BIN%\node.exe"
  exit /b 1
)

if not exist "%LOGDIR%" mkdir "%LOGDIR%"

if /i "%~1"=="server" (
  cd /d "%ROOT%\server"
  "%NODE_BIN%\node.exe" src/server.js > "%LOGDIR%\server.out.log" 2> "%LOGDIR%\server.err.log"
  exit /b %errorlevel%
)

if /i "%~1"=="web" (
  cd /d "%ROOT%\web"
  "%NODE_BIN%\node.exe" node_modules\vite\bin\vite.js --host 0.0.0.0 > "%LOGDIR%\web.out.log" 2> "%LOGDIR%\web.err.log"
  exit /b %errorlevel%
)

echo [run-stack] Unknown target: %~1
echo [run-stack] Expected: server ^| web
exit /b 2
