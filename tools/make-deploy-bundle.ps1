# =====================================================================
#  打包「志愿活动平台-服务器整合包」
# =====================================================================
#  用法（在仓库根目录执行）：
#
#      powershell -ExecutionPolicy Bypass -File tools\make-deploy-bundle.ps1
#
#  产出：
#      dist\志愿活动平台-服务器\                  （目录，可直接拷走）
#      dist\志愿活动平台-服务器整合包.zip          （交付物）
#
#  设计要点：
#    1. **自带 Node 运行时**（node/node.exe）—— 目标电脑不用装任何东西
#    2. 服务端零第三方依赖（SQLite 用 Node 内置 node:sqlite）
#    3. 网页 dist 由服务端直接托管，手机 App 连同一个端口
#    4. 两个 APK 放进 web/dist/apk/，手机浏览器可直接下载安装
#    5. 打包前清掉 .env 与数据库，保证交付的是"首次运行"状态
# =====================================================================

[CmdletBinding()]
param(
    [string]$NodeExe = '',
    [switch]$SkipZip,
    # 打包时丢弃旧包的 .env 与数据库（想要"首次运行"状态的干净包时用）
    [switch]$Fresh
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Dist = Join-Path $Root 'dist'
$Bundle = Join-Path $Dist '志愿活动平台-服务器'
$ZipPath = Join-Path $Dist '志愿活动平台-服务器整合包.zip'

function Step($msg) { Write-Host "  · $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "    ✓ $msg" -ForegroundColor Green }
function Die($msg) { Write-Host "    ✗ $msg" -ForegroundColor Red; exit 1 }

Write-Host ''
Write-Host '  打包：志愿活动平台-服务器整合包' -ForegroundColor White
Write-Host ''

# ── 0. 找 Node 运行时 ────────────────────────────────────────────────
if (-not $NodeExe) {
    $candidates = @(
        (Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
        'D:\dsh\resources\runtime\primary-runtime\dependencies\node\bin\node.exe'
    ) | Where-Object { $_ -and (Test-Path $_) }
    $NodeExe = $candidates | Select-Object -First 1
}
if (-not $NodeExe -or -not (Test-Path $NodeExe)) {
    Die '找不到 node.exe。请用 -NodeExe 指定一个 Node 22.5+ 的可执行文件。'
}
$nodeVer = & $NodeExe --version 2>&1
Step "运行时：$NodeExe（$nodeVer）"
if (-not ($nodeVer -match '^v(\d+)\.(\d+)')) { Die "无法执行 node.exe：$nodeVer" }
if ([int]$Matches[1] -lt 22) { Die "Node 版本过低（$nodeVer），需要 22.5+（node:sqlite 内置）" }

# ── 1. 前置检查 ──────────────────────────────────────────────────────
Step '检查前端与后端产物'
foreach ($p in @('server\src\server.js', 'web\dist\index.html', 'contract\constants.js')) {
    if (-not (Test-Path (Join-Path $Root $p))) { Die "缺少 $p" }
}
$apks = @{
    '志愿活动-用户端.apk' = (Get-ChildItem (Join-Path $Root 'apps\user_app\build\app\outputs') -Recurse -Filter 'app-arm64-v8a-release.apk' -ErrorAction SilentlyContinue | Select-Object -First 1)
    '志愿活动-管理端.apk' = (Get-ChildItem (Join-Path $Root 'apps\admin_app\build\app\outputs') -Recurse -Filter 'app-arm64-v8a-release.apk' -ErrorAction SilentlyContinue | Select-Object -First 1)
}
foreach ($k in $apks.Keys) {
    if (-not $apks[$k]) { Die "找不到 APK：$k（先执行 flutter build apk --release --split-per-abi）" }
}
$webSrc = Get-ChildItem (Join-Path $Root 'web\src') -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$webDist = Get-ChildItem (Join-Path $Root 'web\dist') -Recurse -File | Where-Object { $_.FullName -notmatch '\\apk\\' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($webSrc -and $webDist -and $webSrc.LastWriteTime -gt $webDist.LastWriteTime) {
    Write-Host '    ⚠ web/src 比 web/dist 新，建议先重建网页：' -ForegroundColor Yellow
    Write-Host '      pnpm -C web build' -ForegroundColor Yellow
}
Ok '产物齐全'

# ── 2. 组装目录（**先备份旧包的运行时数据**）──────────────────────────
Step '组装整合包目录'

<#
  ⚠️ 这一步以前直接 Remove-Item 整个旧包目录 —— 会把 **已有的数据库
  （server\data\volunteer.db）和 .env（含 TOKEN_SECRET）一起删掉**。
  那是一次真实的教训：重新打包等于把测试数据清空。

  所以：先把它们复制到临时目录，组装完再放回去。
  想让包里是"全新首次运行"状态时，请手工删掉这两个，或用 -Fresh 参数。
#>
$backup = Join-Path ([System.IO.Path]::GetTempPath()) ('bundle-data-' + [guid]::NewGuid().ToString('N'))
$hasBackup = $false
if ((Test-Path $Bundle) -and -not $Fresh) {
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($f in @('.env', '服务器地址.txt')) {
        $src2 = Join-Path $Bundle $f
        if (Test-Path $src2) { Copy-Item $src2 $backup -Force; $hasBackup = $true }
    }
    $oldData = Join-Path $Bundle 'server\data'
    if (Test-Path $oldData) {
        Copy-Item $oldData (Join-Path $backup 'data') -Recurse -Force
        if (Get-ChildItem (Join-Path $backup 'data') -File -Recurse -ErrorAction SilentlyContinue) {
            $hasBackup = $true
        }
    }
    if ($hasBackup) { Ok '已备份旧包的 .env 与数据库（重建后原样恢复）' }
}

if (Test-Path $Bundle) { Remove-Item $Bundle -Recurse -Force }
New-Item -ItemType Directory -Path $Bundle -Force | Out-Null

$nodeDir = Join-Path $Bundle 'node'
New-Item -ItemType Directory -Path $nodeDir -Force | Out-Null
Copy-Item $NodeExe (Join-Path $nodeDir 'node.exe')
Ok 'node.exe'

Copy-Item (Join-Path $Root 'server\src') (Join-Path $Bundle 'server\src') -Recurse
# scripts/：清理演示数据的脚本（部署到别人电脑上也能自己重置）
if (Test-Path (Join-Path $Root 'server\scripts')) {
  Copy-Item (Join-Path $Root 'server\scripts') (Join-Path $Bundle 'server\scripts') -Recurse
}
Copy-Item (Join-Path $Root 'server\package.json') (Join-Path $Bundle 'server\package.json')
New-Item -ItemType Directory -Path (Join-Path $Bundle 'server\data') -Force | Out-Null
Ok 'server/src + server/data'

Copy-Item (Join-Path $Root 'contract') (Join-Path $Bundle 'contract') -Recurse
Ok 'contract（server 的契约常量来源）'

Copy-Item (Join-Path $Root 'web\dist') (Join-Path $Bundle 'web\dist') -Recurse
$apkDir = Join-Path $Bundle 'web\dist\apk'
New-Item -ItemType Directory -Path $apkDir -Force | Out-Null
foreach ($k in $apks.Keys) { Copy-Item $apks[$k].FullName (Join-Path $apkDir $k) }
Ok 'web/dist + apk/（手机可下载）'

Copy-Item (Join-Path $Root 'tools\deploy\start.ps1') (Join-Path $Bundle 'start.ps1')
# 等服务器就绪后自动开网页（start.ps1 会调用它）
Copy-Item (Join-Path $Root 'tools\deploy\open-web.ps1') (Join-Path $Bundle 'open-web.ps1')
Copy-Item (Join-Path $Root 'tools\deploy\启动服务器.bat') (Join-Path $Bundle '启动服务器.bat')
Copy-Item (Join-Path $Root 'tools\deploy\部署说明.md') (Join-Path $Bundle '部署说明.md')
Copy-Item (Join-Path $Root 'tools\deploy\手机连接指南.md') (Join-Path $Bundle '手机连接指南.md')
Ok '启动器与说明文档（单入口：防火墙已合并进启动器）'

# start.ps1 / open-web.ps1 必须带 BOM，否则 Windows PowerShell 5.1 会把中文读成乱码
$ps1 = Join-Path $Bundle 'open-web.ps1'
$txt = [System.IO.File]::ReadAllText($ps1, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($ps1, $txt, (New-Object System.Text.UTF8Encoding($true)))
$ps1 = Join-Path $Bundle 'start.ps1'
$text = [System.IO.File]::ReadAllText($ps1, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($ps1, $text, (New-Object System.Text.UTF8Encoding($true)))
Ok 'start.ps1 转为 UTF-8 BOM'

# ── 3. 清理运行时残留（交付物必须是"首次运行"状态）──────────────────
Step '清理运行时残留'
Remove-Item (Join-Path $Bundle '.env') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $Bundle '服务器地址.txt') -Force -ErrorAction SilentlyContinue
Get-ChildItem (Join-Path $Bundle 'server\data') -File -ErrorAction SilentlyContinue | Remove-Item -Force
Ok '无 .env、无数据库'

# ── 3.5 恢复旧包的运行时数据（不能因为重新打包就丢数据）──────────────
if ($hasBackup) {
    Step '恢复原有运行时数据'
    foreach ($f in @('.env', '服务器地址.txt')) {
        if (Test-Path (Join-Path $backup $f)) { Copy-Item (Join-Path $backup $f) $Bundle -Force }
    }
    if (Test-Path (Join-Path $backup 'data')) {
        Get-ChildItem (Join-Path $backup 'data') -File -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $Bundle 'server\data') -Force }
    }
    Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
    Ok '已恢复 .env 与数据库（新包可直接接着用，数据未丢）'
}

# ── 4. 统计 ──────────────────────────────────────────────────────────
$total = (Get-ChildItem $Bundle -Recurse -File | Measure-Object Length -Sum).Sum
Step ("整合包大小：" + [math]::Round($total / 1MB, 1) + " MB")

# ── 5. 压缩 ──────────────────────────────────────────────────────────
if (-not $SkipZip) {
    Step '压缩中…'
    if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Compress-Archive -Path $Bundle -DestinationPath $ZipPath -CompressionLevel Optimal
    $sw.Stop()
    Ok ("已生成 " + (Split-Path $ZipPath -Leaf) + "  " + [math]::Round((Get-Item $ZipPath).Length / 1MB, 1) + " MB（" + [math]::Round($sw.Elapsed.TotalSeconds, 1) + " 秒）")
}

Write-Host ''
Write-Host '  完成。把整合包拷到目标电脑，解压后双击「启动服务器.bat」即可。' -ForegroundColor White
Write-Host ''
