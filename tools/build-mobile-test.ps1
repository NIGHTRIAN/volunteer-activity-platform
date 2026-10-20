# Build phone-test APKs with the CURRENT LAN address.
#
# ## Why this exists
#
# The APK bakes the server address in at build time
# (`--dart-define=API_BASE_URL=...`). On a campus / home Wi-Fi the IP comes
# from DHCP and changes between sessions -- measured during this project:
# it went from 10.3.215.117 to 192.168.72.34 between two test attempts.
#
# Rebuilding by hand each time means someone has to look up the IP, remember
# the exact command, and not typo the address. This script does all of it:
# detect -> build -> verify the address is actually inside the APK -> print
# the install command.
#
# ## Usage (from the repo root)
#
#   tools\build-mobile-test.ps1              rebuild both apps
#   tools\build-mobile-test.ps1 -App user    only the user app
#   tools\build-mobile-test.ps1 -CheckOnly   just show the current address
#
# ENCODING: keep this file ASCII-only, or save WITH a UTF-8 BOM.
# Windows PowerShell 5.1 decodes .ps1 as the system ANSI codepage (GBK),
# so non-ASCII without a BOM breaks parsing.

[CmdletBinding()]
param(
    [ValidateSet('both', 'user', 'admin')]
    [string]$App = 'both',
    [switch]$CheckOnly,
    # Force a specific address (rarely needed; auto-detection covers it).
    [string]$ApiHost = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$adb = 'D:\dev-tools\android-sdk\platform-tools\adb.exe'

# ── 1) Work out the address the phone should use ──────────────────────
if ($ApiHost -eq '') {
    $addresses = @(
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.IPAddress -notlike '127.*' -and
                $_.IPAddress -notlike '169.254.*'
            } |
            ForEach-Object { $_.IPAddress }
    )
    if ($addresses.Count -eq 0) {
        throw 'No LAN IPv4 address found. Are you connected to Wi-Fi?'
    }
    # Prefer a real private-network address; fall back to the first one.
    $ApiHost = $addresses | Where-Object { $_ -match '^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)' } |
        Select-Object -First 1
    if (-not $ApiHost) { $ApiHost = $addresses[0] }
}

$port = 8080
$baseUrl = "http://${ApiHost}:${port}/api"

Write-Host ''
Write-Host '=== Phone test build ===' -ForegroundColor Cyan
Write-Host ("  LAN address : {0}" -f $ApiHost)
Write-Host ("  API base    : {0}" -f $baseUrl)

$allAddresses = @(
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        ForEach-Object { $_.IPAddress }
)
if ($allAddresses.Count -gt 1) {
    Write-Host ("  Other NICs  : {0}" -f ($allAddresses -join ', ')) -ForegroundColor Yellow
    Write-Host '  Using the first private address. Pass -ApiHost to override.' -ForegroundColor Yellow
}

# ── 2) Is the mock server actually reachable on that address? ─────────
# A wrong address here is the single most common reason "the app cannot
# connect", and it is invisible from the phone side.
try {
    $health = Invoke-RestMethod -Uri "http://${ApiHost}:${port}/api/health" -TimeoutSec 5
    Write-Host '  Server      : reachable' -ForegroundColor Green
}
catch {
    Write-Host '  Server      : NOT reachable on that address' -ForegroundColor Yellow
    Write-Host '    Start it first:  cd mock_server; $env:PORT=8080; node src/server.js' -ForegroundColor Gray
    Write-Host '    The build will continue, but the app will not be able to connect.' -ForegroundColor Gray
}

if ($CheckOnly) {
    Write-Host ''
    Write-Host 'Check-only mode: nothing was built.' -ForegroundColor Cyan
    exit 0
}

# ── 3) Build ──────────────────────────────────────────────────────────
Write-Host ''
$targets = switch ($App) {
    'user'  { @('user_app') }
    'admin' { @('admin_app') }
    default { @('user_app', 'admin_app') }
}

& cmd /c "tools\build-release.cmd $baseUrl $App"
if ($LASTEXITCODE -ne 0) {
    throw "Build failed (exit $LASTEXITCODE)"
}

# ── 4) Verify the address really is inside the APK ────────────────────
# Trusting the build log is not enough: the define could be dropped by a
# refactor and nothing would fail until the phone tried to connect.
Write-Host ''
Write-Host '=== Verifying the address is inside each APK ===' -ForegroundColor Cyan

Add-Type -AssemblyName System.IO.Compression.FileSystem

$needle = "${ApiHost}:${port}"
foreach ($t in $targets) {
    $apk = Join-Path $root "apps\$t\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"
    if (-not (Test-Path $apk)) {
        Write-Host ("  {0,-12} APK missing" -f $t) -ForegroundColor Red
        continue
    }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($apk)
    $found = $false
    try {
        foreach ($e in $zip.Entries) {
            if ($e.Name -ne 'libapp.so') { continue }
            $stream = $e.Open()
            $ms = New-Object System.IO.MemoryStream
            $stream.CopyTo($ms)
            $stream.Close()
            $text = [System.Text.Encoding]::ASCII.GetString($ms.ToArray())
            if ($text -match [regex]::Escape($needle)) { $found = $true }
            $ms.Close()
        }
    }
    finally {
        $zip.Dispose()
    }
    if ($found) {
        Write-Host ("  {0,-12} contains {1}" -f $t, $needle) -ForegroundColor Green
    }
    else {
        Write-Host ("  {0,-12} DOES NOT contain {1}" -f $t, $needle) -ForegroundColor Red
    }
}

# ── 5) Device status + install command ────────────────────────────────
Write-Host ''
Write-Host '=== Device ===' -ForegroundColor Cyan
$devices = @()
if (Test-Path $adb) {
    $devices = @(& $adb devices 2>&1 | Select-String -Pattern '\sdevice$')
}
if ($devices.Count -eq 0) {
    Write-Host '  No device connected.' -ForegroundColor Yellow
    Write-Host '  1. Phone: Settings > About > tap Build number 7x' -ForegroundColor Gray
    Write-Host '  2. Phone: Developer options > enable USB debugging' -ForegroundColor Gray
    Write-Host '  3. Plug in the cable, choose "File transfer", allow the prompt' -ForegroundColor Gray
}
else {
    Write-Host ("  {0} device(s) connected" -f $devices.Count) -ForegroundColor Green
}

Write-Host ''
Write-Host '=== Install ===' -ForegroundColor Cyan
foreach ($t in $targets) {
    $apk = Join-Path $root "apps\$t\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"
    Write-Host ("  & '{0}' install -r '{1}'" -f $adb, $apk) -ForegroundColor Gray
}
Write-Host ''
Write-Host ("  The app will talk to {0}" -f $baseUrl) -ForegroundColor Cyan
Write-Host '  Phone and PC must be on the SAME Wi-Fi.' -ForegroundColor Cyan
Write-Host ''
