@echo off
REM Flutter command wrapper for this repository.
REM
REM Why it exists: this machine's PowerShell execution policy refuses to run
REM .ps1 files, so `. .\tools\env.ps1` does not work. A .cmd is not covered by
REM that policy.
REM
REM Usage (from the repository root):
REM     tools\flutter.cmd --version
REM     tools\flutter.cmd pub get
REM     tools\flutter.cmd analyze
REM     tools\flutter.cmd test
REM     tools\flutter.cmd build apk --debug
REM
REM When moving to another machine, only the four paths below need changing.
REM
REM ENCODING: ASCII-only on purpose. cmd.exe reads .cmd files using the
REM OEM/ANSI codepage (GBK on a Chinese Windows), so non-ASCII REM lines get
REM decoded into garbage that cmd then tries to EXECUTE as commands.
REM Measured symptom: "'.cmd' is not recognized as an internal or external
REM command" and similar, coming from what were supposed to be comments.
REM Do not add Chinese text or emoji to this file.

setlocal

set "DEV_TOOLS=D:\dev-tools"
set "FLUTTER_ROOT=%DEV_TOOLS%\flutter"
set "JAVA_HOME=%DEV_TOOLS%\jdk\jdk-17.0.20.1+1"
set "ANDROID_HOME=%DEV_TOOLS%\android-sdk"
set "ANDROID_SDK_ROOT=%ANDROID_HOME%"

set "PATH=%FLUTTER_ROOT%\bin;%JAVA_HOME%\bin;%ANDROID_HOME%\platform-tools;%ANDROID_HOME%\cmdline-tools\latest\bin;C:\Program Files\Git\cmd;%PATH%"

REM On a slow connection to pub.dev, uncomment the next two lines to use a mirror.
REM set "PUB_HOSTED_URL=https://pub.flutter-io.cn"
REM set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"

call "%FLUTTER_ROOT%\bin\flutter.bat" %*
exit /b %errorlevel%
