@echo off
REM Web frontend command wrapper (npm/pnpm + node on PATH).
REM
REM Why this exists: `node` is NOT on this machine's PATH by default --
REM it lives in the DSH runtime. That breaks two things measurably:
REM   1. esbuild's postinstall script fails ("'node' is not recognized"),
REM      so the Vite build tool never gets its platform binary;
REM   2. any npm script that shells out to node fails the same way.
REM
REM Rather than asking everyone to edit their PATH, this wrapper adds the
REM runtime directories for the duration of one command.
REM
REM Usage (from the repository root, or from web/):
REM     tools\web.cmd install
REM     tools\web.cmd run dev
REM     tools\web.cmd run build
REM     tools\web.cmd exec -- vite --version
REM
REM ENCODING: ASCII-only on purpose. cmd.exe decodes .cmd files with the
REM OEM/ANSI codepage (GBK here), so non-ASCII comment lines turn into
REM garbage that cmd then tries to EXECUTE. Do not add Chinese text or emoji.

setlocal

set "NODE_BIN=D:\dsh\resources\runtime\primary-runtime\dependencies\node\bin"
set "PNPM_BIN=D:\dsh\resources\runtime\pnpm"

if not exist "%NODE_BIN%\node.exe" (
  echo [web.cmd] Cannot find node at "%NODE_BIN%\node.exe".
  echo [web.cmd] Update NODE_BIN in tools\web.cmd to match your machine.
  exit /b 1
)

set "PATH=%NODE_BIN%;%PNPM_BIN%;C:\Program Files\Git\cmd;%PATH%"

REM Run from web/ so relative paths in package.json scripts behave the same
REM however this wrapper is invoked.
pushd "%~dp0..\web"

call npm %*
set "RC=%ERRORLEVEL%"

popd
exit /b %RC%
