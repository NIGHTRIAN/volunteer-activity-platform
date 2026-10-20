# Start / stop / check the local dev stack (sync server + web frontend).
#
# ## Why this file is PowerShell and not a .cmd
#
# The previous version was a .cmd using `start /b`. That failed measurably
# in this environment:
#   * `start /b` needs a working stdin; under this harness stdin is
#     redirected, so it errored with
#     "Input redirection is not supported, exiting the process immediately";
#   * `npm` was not on PATH inside the spawned shell, so the frontend
#     never started.
#
# Start-Process with a node executable path works reliably and is explicit
# about what runs. The frontend is launched by calling Vite's JS entry
# directly (node node_modules/vite/bin/vite.js) instead of through npm,
# which removes the npm-on-PATH dependency entirely.
#
# Usage (from the repo root):
#   tools\dev-stack.ps1            start both
#   tools\dev-stack.ps1 stop       stop whatever holds 8080 / 5173
#   tools\dev-stack.ps1 status     show port state + reachability
#   tools\dev-stack.ps1 restart    stop then start
#
# NOTE ON ENCODING: keep this file ASCII-only, or save it WITH a UTF-8 BOM.
# Windows PowerShell 5.1 decodes .ps1 as the system ANSI codepage (GBK here),
# so non-ASCII text without a BOM gets mangled into invalid syntax.

[CmdletBinding()]
param(
    [ValidateSet('start', 'stop', 'status', 'restart')]
    [string]$Action = 'start'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$logDir = Join-Path $root '.logs'
$node = 'D:\dsh\resources\runtime\primary-runtime\dependencies\node\bin\node.exe'

$serverDir = Join-Path $root 'server'
$webDir = Join-Path $root 'web'
$viteEntry = Join-Path $webDir 'node_modules\vite\bin\vite.js'

function Assert-Prerequisites {
    if (-not (Test-Path $node)) {
        throw "Cannot find node at '$node'. Edit `$node in tools\dev-stack.ps1."
    }
    if (-not (Test-Path $viteEntry)) {
        throw "Cannot find Vite at '$viteEntry'. Run: tools\web.cmd install"
    }
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}

function Get-PortState([int]$Port) {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return [bool]$conn
}

function Show-Status {
    Write-Host ''
    Write-Host '=== Port status ===' -ForegroundColor Cyan
    $allUp = $true
    foreach ($port in 8080, 5173) {
        if (Get-PortState $port) {
            Write-Host ("  {0} : listening" -f $port) -ForegroundColor Green
        }
        else {
            Write-Host ("  {0} : NOT listening" -f $port) -ForegroundColor Yellow
            $allUp = $false
        }
    }

    Write-Host ''
    Write-Host '=== Reachability ===' -ForegroundColor Cyan
    try {
        $health = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/api/health' -TimeoutSec 5
        Write-Host ("  API      : ok (driver={0})" -f $health.data.driver) -ForegroundColor Green
    }
    catch {
        Write-Host '  API      : unreachable' -ForegroundColor Yellow
        $allUp = $false
    }
    try {
        $page = Invoke-WebRequest -Uri 'http://127.0.0.1:5173/' -TimeoutSec 5 -UseBasicParsing
        Write-Host ("  Frontend : HTTP {0}" -f $page.StatusCode) -ForegroundColor Green
    }
    catch {
        Write-Host '  Frontend : unreachable' -ForegroundColor Yellow
        $allUp = $false
    }

    Write-Host ''
    if ($allUp) {
        Write-Host '  Both up. Open http://127.0.0.1:5173/' -ForegroundColor Green
    }
    else {
        Write-Host '  Not fully up. Logs are in .logs\' -ForegroundColor Yellow
        Write-Host '  Manual fallback:' -ForegroundColor Gray
        Write-Host '    cd server && node src/server.js' -ForegroundColor Gray
        Write-Host '    cd web && node node_modules/vite/bin/vite.js' -ForegroundColor Gray
    }
    Write-Host ''
}

function Stop-Stack {
    Write-Host 'Stopping processes on ports 8080 and 5173...'
    foreach ($port in 8080, 5173) {
        $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        foreach ($c in $conns) {
            # NOTE: do NOT name this $pid. `$PID` is a read-only automatic
            # variable in PowerShell and assigning to it throws
            # "Cannot overwrite variable PID because it is read-only".
            $processId = $c.OwningProcess
            try {
                $p = Get-Process -Id $processId -ErrorAction Stop
                Write-Host ("  killing pid {0} ({1}) on port {2}" -f $processId, $p.ProcessName, $port)
                Stop-Process -Id $processId -Force -ErrorAction Stop
            }
            catch {
                Write-Host ("  could not kill pid {0} on port {1}: {2}" -f $processId, $port, $_.Exception.Message)
            }
        }
    }
    Start-Sleep -Seconds 1
    Write-Host 'Done.'
}

function Start-Stack {
    Assert-Prerequisites

    # `run-stack.cmd` handles output redirection and path normalisation inside
    # cmd.exe. Two problems are solved by that, both measured:
    #
    #   1. Redirection. `Start-Process -RedirectStandardOutput` makes the child
    #      inherit this script's pipes; the script then never exits (it hangs
    #      on those handles after printing its status).
    #   2. Quoting. This repo path contains a space ("VOLUNTEER SYSTEM").
    #      Passing it to `cmd.exe /c` without exact quoting fails with
    #      "'D:\VOLUNTEER' is not recognized as an internal or external command".
    #
    # So: set -WorkingDirectory to tools\ and pass the script name RELATIVE.
    # Nothing with a space ever crosses the cmd /c boundary.
    $toolsDir = Join-Path $root 'tools'

    if (Get-PortState 8080) {
        Write-Host 'Port 8080 already in use - leaving the existing server alone.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'Starting sync server on http://127.0.0.1:8080'
        Start-Process -FilePath 'cmd.exe' `
            -ArgumentList '/c', 'run-stack.cmd', 'server' `
            -WorkingDirectory $toolsDir `
            -WindowStyle Hidden
    }

    if (Get-PortState 5173) {
        Write-Host 'Port 5173 already in use - leaving the existing frontend alone.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'Starting web frontend on http://127.0.0.1:5173'
        Start-Process -FilePath 'cmd.exe' `
            -ArgumentList '/c', 'run-stack.cmd', 'web' `
            -WorkingDirectory $toolsDir `
            -WindowStyle Hidden
    }

    Write-Host 'Waiting for them to bind...'
    # Poll instead of a fixed sleep so the script finishes as soon as both are
    # actually up (Vite needs a few seconds to transform and serve).
    for ($i = 0; $i -lt 40; $i++) {
        if ((Get-PortState 8080) -and (Get-PortState 5173)) { break }
        Start-Sleep -Milliseconds 500
    }

    Show-Status
}

switch ($Action) {
    'stop'    { Stop-Stack }
    'status'  { Show-Status }
    'restart' { Stop-Stack; Start-Stack }
    default   { Start-Stack }
}
