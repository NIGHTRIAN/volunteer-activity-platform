# Build internal-test APKs.
#
# Usage:
#   .\tools\build-release.ps1 -ApiBaseUrl http://192.168.1.100:8080/api
#   .\tools\build-release.ps1 -ApiBaseUrl https://vol.cumt.edu.cn/api -Clean
#
# NOTE ON ENCODING (this is not cosmetic):
# Windows PowerShell 5.1 reads .ps1 files as the system ANSI codepage
# (GBK on a Chinese Windows), NOT as UTF-8. A script containing non-ASCII
# characters therefore gets mangled -- measured symptom: emoji and Chinese
# text inside string literals turn into invalid bytes, the parser sees an
# unterminated string, and the whole script fails to load.
#
# Hence this file is deliberately ASCII-only. The user-facing prose lives in
# docs/build-environment.md instead. Do not add Chinese text or emoji here.
#
# If you must add non-ASCII, save the file WITH a UTF-8 BOM so both
# PowerShell 5.1 and 7 decode it correctly.

[CmdletBinding()]
param(
    # Server base URL. MUST end with /api (the contract's Base URL looks like
    # https://host/api). Without it every request 404s and the app shows
    # "endpoint not found", which is easily misread as "backend not deployed".
    [Parameter(Mandatory = $true)]
    [string]$ApiBaseUrl,

    # Which app(s) to build: user / admin / both
    [ValidateSet('both', 'user', 'admin')]
    [string]$App = 'both',

    # Clean before building (use when the Gradle cache misbehaves).
    [switch]$Clean,

    # Build debug instead of release.
    #
    # NOTE: this parameter is deliberately NOT named "Debug". PowerShell
    # reserves -Debug as a common parameter (the one that controls
    # Write-Debug output), and declaring [switch]$Debug makes the whole
    # script fail to load with:
    #   "A parameter with the name 'Debug' was defined multiple times"
    # Measured, not guessed. Same applies to -Verbose, -ErrorAction, etc.
    [switch]$DebugBuild
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$flutter = Join-Path $root 'tools\flutter.cmd'

# ---- Pre-flight checks -------------------------------------------------
if ($ApiBaseUrl -notmatch '/api/?$') {
    Write-Warning "API_BASE_URL does not look like it ends with /api: $ApiBaseUrl"
    Write-Warning "The contract expects Base URL of the form https://host/api."
    Write-Warning "Without it every request 404s and the app reports a missing"
    Write-Warning "endpoint, which gets misread as a backend deployment problem."
}

if (-not (Test-Path $flutter)) {
    throw "Cannot find $flutter. Check that the tools/ directory is intact."
}

# ---- Environment -------------------------------------------------------
$env:JAVA_HOME = 'D:\dev-tools\jdk\jdk-17.0.20.1+1'
$env:ANDROID_HOME = 'D:\dev-tools\android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:Path = "D:\dev-tools\flutter\bin;$env:JAVA_HOME\bin;C:\Program Files\Git\cmd;$env:Path"

$mode = if ($DebugBuild) { 'debug' } else { 'release' }
$targets = switch ($App) {
    'user'  { @('user_app') }
    'admin' { @('admin_app') }
    default { @('user_app', 'admin_app') }
}

# ---- Build -------------------------------------------------------------
foreach ($t in $targets) {
    $dir = Join-Path $root "apps\$t"
    Write-Host ""
    Write-Host "=== Building $t ($mode) ===" -ForegroundColor Cyan

    Push-Location $dir
    try {
        if ($Clean) {
            Write-Host "Cleaning build directory..."
            & $flutter clean | Out-Null
        }
        & $flutter pub get | Out-Null

        # --split-per-abi puts one CPU architecture's native libs in each
        # package: size drops from ~178MB (full debug) to 15-19MB.
        # Internal distribution must use this.
        $flutterArgs = @('build', 'apk', "--$mode")
        if (-not $DebugBuild) {
            $flutterArgs += '--split-per-abi'
        }
        $flutterArgs += "--dart-define=API_BASE_URL=$ApiBaseUrl"

        & $flutter @flutterArgs
        if ($LASTEXITCODE -ne 0) {
            throw "$t build failed (exit $LASTEXITCODE)"
        }
    }
    finally {
        Pop-Location
    }
}

# ---- Artifacts ---------------------------------------------------------
Write-Host ""
Write-Host "=== Artifacts ===" -ForegroundColor Green

foreach ($t in $targets) {
    $out = Join-Path $root "apps\$t\build\app\outputs\flutter-apk"
    Get-ChildItem $out -Filter '*.apk' -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object {
            $mb = [math]::Round($_.Length / 1MB, 1)
            Write-Host ("  {0,-42} {1,6} MB" -f $_.Name, $mb)
        }
}

# ---- Permission check (spec section 7 baseline; check every build) -----
$aapt = Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\aapt2.exe'
if (Test-Path $aapt) {
    Write-Host ""
    Write-Host "=== Permission check (spec 7: least privilege) ===" -ForegroundColor Green

    foreach ($t in $targets) {
        $out = Join-Path $root "apps\$t\build\app\outputs\flutter-apk"
        $apk = Get-ChildItem $out -Filter '*arm64-v8a*.apk' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $apk) { continue }

        $perms = & $aapt dump permissions $apk.FullName 2>&1 | Out-String

        $bg = if ($perms -match 'BACKGROUND_LOCATION') { 'PRESENT [BAD]' } else { 'absent [ok]' }
        Write-Host ("  {0,-12} background location: {1}" -f $t, $bg)

        if ($t -eq 'admin_app') {
            $loc = if ($perms -match 'ACCESS_FINE_LOCATION') { 'PRESENT [BAD]' } else { 'absent [ok]' }
            Write-Host ("  {0,-12} location:            {1}" -f $t, $loc)
        }
    }

    Write-Host ""
    Write-Host "  user app needs location (the primary check-in evidence)."
    Write-Host "  admin app does not; its manifest removes the merged-in location"
    Write-Host "  permissions with tools:node=remove."
    Write-Host "  Neither app requests background location (spec 7)."
}

Write-Host ""
Write-Host "Done. Install on a connected device with:" -ForegroundColor Green
Write-Host "  adb install -r apps\user_app\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"
Write-Host ""
Write-Host "Remember: the release build talks to $ApiBaseUrl -- verify it is"
Write-Host "reachable from the test phone."
