# =====================================================================
#  等服务器真正能响应了，再打开网页
# =====================================================================
#
#  ## 为什么要单独一个脚本
#
#  启动器原来是 `cmd /c timeout /t 2 & start "" "<url>"` —— "等 2 秒然后开"。
#  2 秒是个猜的数：
#    * 机器慢一点，服务端还没监听 → 浏览器打开是"无法访问"的空页面，
#      用户以为服务坏了（实际再刷新就好）；
#    * 机器快一点，白等 2 秒。
#
#  这里改成**轮询 /api/health**：一旦返回 ok 立刻开网页，最多等 45 秒。
#  超时也照样打开（可能只是慢，刷新一下就行），并打印提示。
#
#  ## 用法
#
#    open-web.ps1 -Url http://127.0.0.1:8080/
#    open-web.ps1 -Url http://127.0.0.1:8080/ -DryRun   只打印，不开浏览器（测试用）
#
# =====================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Url = 'http://127.0.0.1:8080/',

    # 最多等多久（秒）
    [int]$TimeoutSeconds = 45,

    # 只打印结果，不真的打开浏览器（便于测试）
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

# 由 URL 推出健康检查地址：http://host:port/ → http://host:port/api/health
$base = $Url.TrimEnd('/')
$healthUrl = "$base/api/health"

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$ready = $false

while ((Get-Date) -lt $deadline) {
    try {
        $r = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 1 -Method Get -ErrorAction Stop
        # 服务端 health 返回 { code: 0, data: { status: 'ok' } }
        if ($null -ne $r) {
            $ready = $true
            break
        }
    } catch {
        # 还没起来：正常，继续等
    }
    Start-Sleep -Milliseconds 400
}

if ($DryRun) {
    if ($ready) { Write-Output "READY $Url" } else { Write-Output "TIMEOUT $Url" }
    exit 0
}

if (-not $ready) {
    # 超时也打开：可能是慢，用户刷新一下就能用；总比什么都不发生强。
    Write-Output "（等待 $TimeoutSeconds 秒仍未就绪，仍然尝试打开 $Url）"
}

try {
    Start-Process $Url -ErrorAction Stop
    exit 0
} catch {
    # 打不开浏览器（没有默认浏览器 / 被策略拦）就交给用户手动点
    Write-Output "（自动打开浏览器失败：$($_.Exception.Message)）请手动访问 $Url"
    exit 1
}
