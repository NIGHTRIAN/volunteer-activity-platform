@echo off
REM Dart command wrapper for this repository (for pure-Dart packages such as
REM packages/shared_core).
REM
REM Usage:
REM     tools\dart.cmd --version
REM     tools\dart.cmd test
REM     tools\dart.cmd analyze
REM
REM Note: this is the Dart SDK bundled with Flutter, not a standalone install.
REM
REM ENCODING: ASCII-only on purpose. cmd.exe decodes .cmd files with the
REM OEM/ANSI codepage (GBK on a Chinese Windows), so non-ASCII REM lines
REM become garbage that cmd then tries to EXECUTE as commands.
REM Measured symptom: "'...' is not recognized as an internal or external
REM command" emitted from what were supposed to be comments.
REM Do not add Chinese text or emoji to this file.

setlocal

set "DEV_TOOLS=D:\dev-tools"
set "FLUTTER_ROOT=%DEV_TOOLS%\flutter"
set "JAVA_HOME=%DEV_TOOLS%\jdk\jdk-17.0.20.1+1"
set "ANDROID_HOME=%DEV_TOOLS%\android-sdk"
set "ANDROID_SDK_ROOT=%ANDROID_HOME%"

set "PATH=%FLUTTER_ROOT%\bin;%FLUTTER_ROOT%\bin\cache\dart-sdk\bin;%JAVA_HOME%\bin;%ANDROID_HOME%\cmdline-tools\latest\bin;C:\Program Files\Git\cmd;%PATH%"

REM Reuse Flutter's pub cache so a package is not downloaded twice.
set "PUB_CACHE=%FLUTTER_ROOT%\.pub-cache"

call "%FLUTTER_ROOT%\bin\cache\dart-sdk\bin\dart.exe" %*
exit /b %errorlevel%
