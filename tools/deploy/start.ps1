# =====================================================================
#  志愿活动信息平台 · 服务器启动器（一键：放行防火墙 + 启动 + 复制地址）
# =====================================================================
#  一般只需要双击「启动服务器.bat」，不用直接跑这个脚本。
#
#    启动服务器.bat                 一键启动（防火墙 + 服务 + 复制地址）
#    启动服务器.bat -Port 9000      换端口
#    启动服务器.bat -NoBrowser      不自动打开浏览器
#    启动服务器.bat -FirewallOnly   只放行防火墙，不启动服务
#    启动服务器.bat -SkipFirewall   跳过防火墙步骤（已放行过 / 无人值守时）
#
#  这个脚本做五件事：
#    1. 首次运行自动生成 .env（随机 TOKEN_SECRET、端口、管理员邀请码）
#    2. **自动放行 Windows 防火墙**（需要管理员，会弹一次 UAC，请点「是」）
#    3. 探测本机局域网 IP，算出「手机 App 服务器地址」
#    4. **自动把该地址复制到剪贴板**，并写成「服务器地址.txt」
#       —— 所以不需要在命令行里选字复制
#    5. 启动服务端（前台运行，Ctrl+C 停止），并自动打开网页
# =====================================================================

[CmdletBinding()]
param(
    [int]$Port = 8080,
    [switch]$SkipFirewall,
    [switch]$NoBrowser,
    [switch]$FirewallOnly
)

$ErrorActionPreference = 'Stop'

# 有没有真人坐在窗口前（被脚本/服务调用时不要"按任意键"卡住）
$Interactive = $true
try { $Interactive = -not [Console]::IsInputRedirected } catch { }

# ── 控制台：UTF-8 + **关掉 QuickEdit** ─────────────────────────────────
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    chcp 65001 > $null
} catch { }

<#
  这里**故意关掉** QuickEdit（早期版本是打开它）。

  真实反馈：
    > 点一下那个 cmd 程序，程序就退出了

  QuickEdit 下的真实行为是：**鼠标一划拉就进入选择状态，进程被挂起**，
  日志停住不动。用户看到"不动了"，以为程序死了，再点几下、或按到 Ctrl+C
  —— 服务就真的停了。

  而"从窗口里选字复制"这个需求已经不存在了：
    * 手机 App 的服务器地址**自动进剪贴板**；
    * 同一份地址还写在「服务器地址.txt」里，随时能打开复制。
  所以宁可让窗口点不动，也不要让它一碰就卡。
#>
function Disable-QuickEdit {
    try {
        if (-not ('Win32.ConsoleMode' -as [type])) {
            Add-Type -Namespace Win32 -Name ConsoleMode -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@
        }
        $h = [Win32.ConsoleMode]::GetStdHandle(-11)
        $mode = [uint32]0
        if ([Win32.ConsoleMode]::GetConsoleMode($h, [ref]$mode)) {
            # 0x0040 = ENABLE_QUICK_EDIT_MODE, 0x0080 = ENABLE_EXTENDED_FLAGS
            [void][Win32.ConsoleMode]::SetConsoleMode($h, ($mode -bor 0x0080) -band (-bnot 0x0040))
        }
    } catch {
        # 改不了也能用，只是点窗口时可能会"暂停"（按 Esc 即可恢复）
    }
}
if ($Interactive) { Disable-QuickEdit }

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$NodeExe = Join-Path $Root 'node\node.exe'
$ServerDir = Join-Path $Root 'server'
$EnvFile = Join-Path $Root '.env'
$DataDir = Join-Path $ServerDir 'data'
$AddrFile = Join-Path $Root '服务器地址.txt'
$IpMemoFile = Join-Path $DataDir '.last-ip'
$PortExplicit = $PSBoundParameters.ContainsKey('Port')

function Say($text, $color = 'Gray') {
    Write-Host $text -ForegroundColor $color
}

function Pause-IfInteractive {
    if (-not $Interactive) { return }
    Say ''
    Say '  按任意键关闭窗口…' 'DarkGray'
    try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
}

function Fail($text) {
    Say ''
    Say '  ✗ 启动失败' 'Red'
    Say "    $text" 'Red'
    Pause-IfInteractive
    exit 1
}

# ── 剪贴板（三级回退：Set-Clipboard → clip.exe → 失败时只提示文件）────
function Set-ClipboardText([string]$text) {
    try {
        Set-Clipboard -Value $text -ErrorAction Stop
        return $true
    } catch { }
    try {
        $text | & clip.exe
        if ($LASTEXITCODE -eq 0) { return $true }
    } catch { }
    return $false
}

# ── 环境自检 ─────────────────────────────────────────────────────────
if (-not (Test-Path $NodeExe)) {
    Fail "找不到自带的运行环境：$NodeExe`n    整合包可能没解压完整，请重新解压后再试。"
}
if (-not (Test-Path (Join-Path $ServerDir 'src\server.js'))) {
    Fail "找不到服务端程序：$ServerDir\src\server.js`n    整合包可能没解压完整。"
}
if (-not (Test-Path (Join-Path $Root 'web\dist\index.html'))) {
    Fail '找不到网页文件：web\dist\index.html。整合包不完整。'
}
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

# 自带 node 能否运行（杀软拦截时会在这里暴露，比后面报"端口未监听"清楚得多）
$nodeVersion = & $NodeExe --version 2>&1
if ($LASTEXITCODE -ne 0 -or -not ($nodeVersion -match '^v\d')) {
    Fail "自带运行环境无法执行（可能被杀毒软件拦截）。`n    输出：$nodeVersion"
}

# ── 首次运行：生成 .env ──────────────────────────────────────────────
$firstRun = -not (Test-Path $EnvFile)
if ($firstRun) {
    $bytes = New-Object 'byte[]' 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $secret = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''

    $lines = @(
        '# ============================================================',
        '#  志愿活动信息平台 · 服务器配置',
        '#  本文件由启动器在首次运行时自动生成。改完后重启服务生效。',
        '# ============================================================',
        '',
        '# 运行模式。prod = 生产口径（要求 TOKEN_SECRET，CORS 不允许 *)',
        'NODE_ENV=prod',
        '',
        "# 监听端口。改了之后要用「启动服务器.bat -Port $Port」或同步改这里。",
        "PORT=$Port",
        '',
        '# 令牌签名密钥（首次运行随机生成，请勿外传；更换会让所有已登录失效）',
        "TOKEN_SECRET=$secret",
        '',
        '# 允许的跨域来源。网页与接口同源，手机 App 不走浏览器，保持本机即可。',
        "CORS_ORIGIN=http://127.0.0.1:$Port",
        '',
        '# 管理员登录邀请码（发布者用它登录管理端 App）',
        'ADMIN_INVITE_CODE=1111',
        '',
        '# 空库时是否写入演示活动（方便第一次打开就有内容看；正式使用请改 false）',
        'SEED_ON_START=true',
        '',
        '# 数据库：sqlite 无需额外安装，文件放在 server/data/ 下',
        'DB_DRIVER=sqlite',
        ''
    )
    [System.IO.File]::WriteAllLines($EnvFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

# 端口：命令行显式指定时，用环境变量覆盖 .env（环境变量优先级更高）
if ($PortExplicit) {
    $env:PORT = "$Port"
} else {
    foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
        if ($line -match '^\s*PORT\s*=\s*(\d+)') { $Port = [int]$Matches[1] }
    }
}
$env:ENV_FILE = $EnvFile

# 读出管理员邀请码用于横幅展示（找不到就用默认值，不因缺一行配置就失败）
$inviteCode = '1111'
foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
    if ($line -match '^\s*ADMIN_INVITE_CODE\s*=\s*(.+?)\s*$') { $inviteCode = $Matches[1] }
}

# ── 探测局域网 IP ────────────────────────────────────────────────────
function Get-LanAddress {
    try {
        $all = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.)' -and
                $_.IPAddress -ne '255.255.255.255'
            }
        $best = $null
        $bestRank = 99
        foreach ($a in $all) {
            $ip = $a.IPAddress
            $rank = 9
            if ($ip -like '192.168.*') { $rank = 0 }
            elseif ($ip -like '10.*') { $rank = 1 }
            elseif ($ip -match '^172\.(1[6-9]|2[0-9]|3[01])\.') { $rank = 2 }
            # 常见虚拟网卡（VMware / VirtualBox / Hyper-V / Docker / WSL）排在后面
            $alias = ''
            try { $alias = (Get-NetAdapter -InterfaceIndex $a.InterfaceIndex -ErrorAction Stop).InterfaceDescription } catch { }
            if ($alias -match 'VMware|VirtualBox|Hyper-V|Docker|WSL|Loopback|TAP|TUN') {
                $rank = 5
            }
            if ($rank -lt $bestRank) { $bestRank = $rank; $best = $ip }
        }
        return $best
    } catch {
        return $null
    }
}

$lanIp = Get-LanAddress
$apiUrl = if ($lanIp) { "http://${lanIp}:$Port/api" } else { $null }
$webUrl = "http://127.0.0.1:$Port/"

# ── 放行防火墙（合并进本脚本，不需要单独的管理员脚本）────────────────
$RuleName = "VolunteerPlatform-$Port"

function Test-FirewallRule {
    try {
        if (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue) {
            return $true
        }
    } catch { }
    # 回退：老系统没有 NetSecurity 模块时用 netsh 查
    try {
        $out = (netsh advfirewall firewall show rule name="$RuleName" 2>&1) -join "`n"
        if ($out -match [regex]::Escape($RuleName)) { return $true }
    } catch { }
    return $false
}

$firewallState = 'skipped'   # skipped / already / added / failed
if (-not $SkipFirewall) {
    if (Test-FirewallRule) {
        $firewallState = 'already'
    } else {
        Say ''
        Say '  正在放行防火墙（会弹出一次“是否允许”，请点「是」）…' 'Yellow'
        $fwArgs = @(
            'advfirewall', 'firewall', 'add', 'rule',
            "name=$RuleName", 'dir=in', 'action=allow',
            'protocol=TCP', "localport=$Port"
        )
        # 已经是管理员就直接执行（不再弹 UAC）；否则只为这一步提权一次
        $isAdmin = $false
        try {
            $wp = New-Object Security.Principal.WindowsPrincipal(
                [Security.Principal.WindowsIdentity]::GetCurrent())
            $isAdmin = $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch { }
        try {
            if ($isAdmin) {
                & netsh @fwArgs 2>&1 | Out-Null
            } else {
                Start-Process -FilePath 'netsh' -ArgumentList $fwArgs -Verb RunAs -Wait -ErrorAction Stop
            }
        } catch {
            # 用户点了「否」或没有管理员权限 —— 下面统一按"失败"处理
        }
        if (Test-FirewallRule) {
            $firewallState = 'added'
            Say '  ✓ 防火墙已放行。' 'Green'
        } else {
            $firewallState = 'failed'
        }
    }
}

# 只放行防火墙（不启动服务）—— 用于"手机连不上，想单独修一下"
if ($FirewallOnly) {
    Say ''
    switch ($firewallState) {
        'already' { Say "  ✓ 端口 $Port 的防火墙规则已存在，无需再放行。" 'Green' }
        'added' { Say "  ✓ 已放行端口 $Port。" 'Green' }
        'skipped' { Say '  已跳过（-SkipFirewall）。' 'DarkGray' }
        default {
            Say '  ✗ 未能放行防火墙。' 'Red'
            Say '    请确认在弹出的窗口里点了「是」；' 'Red'
            Say '    或者右键「启动服务器.bat」→「以管理员身份运行」。' 'Red'
        }
    }
    Say ''
    Pause-IfInteractive
    exit 0
}

# ── 端口占用：如果跑的就是本服务，就直接把地址再复制一次 ──────────────
function Test-OwnServer {
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/health" -TimeoutSec 3 -ErrorAction Stop
        return ($r.data.status -eq 'ok')
    } catch {
        return $false
    }
}

$portBusy = $false
try {
    $portBusy = [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
} catch { }

if ($portBusy) {
    if (Test-OwnServer) {
        # 服务已经在跑 —— 用户很可能只是想要那个地址，不要报错，直接把地址给他
        try { Clear-Host } catch { }
        Say ''
        Say '  ============================================================' 'Cyan'
        Say '        服务已经在运行中（无需重复启动）' 'Cyan'
        Say '  ============================================================' 'Cyan'
        Say ''
        if ($apiUrl) {
            Say "    手机 App 服务器地址  $apiUrl" 'Green'
            Say "    网页（这台电脑）    $webUrl" 'White'
            Say "    网页（其他设备）    http://${lanIp}:$Port/" 'White'
        } else {
            Say '    未探测到局域网 IP（这台电脑可能没连网络）。' 'Yellow'
            Say "    网页（这台电脑）    $webUrl" 'White'
        }
        Say ''
        $copied = if ($apiUrl) { Set-ClipboardText $apiUrl } else { $false }
        if ($copied) {
            Say '  ✓ 手机服务器地址已复制到剪贴板，到 App 的「服务器地址」里粘贴即可。' 'Green'
        } elseif ($apiUrl) {
            Say "  地址：$apiUrl" 'White'
            Say '  （自动复制失败，请从上面的「服务器地址.txt」里复制）' 'Yellow'
        }
        Say ''
        Say '  想停掉服务：回到那个黑窗口按 Ctrl+C，或直接关掉它。' 'DarkGray'
        Pause-IfInteractive
        exit 0
    }
    Fail "端口 $Port 已被其他程序占用（PID=$($portBusy.OwningProcess)）。`n    换个端口：启动服务器.bat -Port 8081`n    或先关掉占用它的程序。"
}

# ── 写地址文件 + 复制到剪贴板 ────────────────────────────────────────
$ipChanged = $false
$lastIp = ''
if (Test-Path $IpMemoFile) {
    try { $lastIp = ([System.IO.File]::ReadAllText($IpMemoFile)).Trim() } catch { }
}
if ($lanIp -and $lastIp -and $lastIp -ne $lanIp) { $ipChanged = $true }
if ($lanIp) {
    try { [System.IO.File]::WriteAllText($IpMemoFile, $lanIp, (New-Object System.Text.UTF8Encoding($false))) } catch { }
}

$addrLines = @(
    '# 志愿活动信息平台 · 服务器地址（每次启动自动更新）',
    '',
    "手机 App 服务器地址（填这个）：$apiUrl",
    '',
    "网页（这台电脑）：$webUrl",
    $(if ($lanIp) { "网页（其他设备）：http://${lanIp}:$Port/" } else { '网页（其他设备）：未探测到局域网 IP' }),
    '',
    "管理员邀请码：$inviteCode",
    '',
    "# 手机 App 里：右上角「服务器地址」→ 粘贴上面的地址 → 「连接并测试」",
    '# 注意：结尾要带 /api；不要填 127.0.0.1（那是手机自己）'
)
try {
    [System.IO.File]::WriteAllLines($AddrFile, $addrLines, (New-Object System.Text.UTF8Encoding($false)))
} catch { }

$copied = $false
if ($apiUrl) { $copied = Set-ClipboardText $apiUrl }

# 控制台标题也带上地址：窗口最小化时也能看到
try {
    if ($apiUrl) { $Host.UI.RawUI.WindowTitle = "志愿活动平台 · $apiUrl" }
    else { $Host.UI.RawUI.WindowTitle = '志愿活动平台 · 服务器' }
} catch { }

# ── 启动横幅 ─────────────────────────────────────────────────────────
try { Clear-Host } catch { }
Say ''
Say '  ============================================================' 'Cyan'
Say '        志愿活动信息平台 · 本机已作为服务器启动' 'Cyan'
Say '  ============================================================' 'Cyan'
Say ''
Say '  打开手机 App → 右上角「服务器地址」→ 粘贴 → 「连接并测试」' 'DarkGray'
Say ''
if ($apiUrl) {
    Say "    手机 App 服务器地址" 'White'
    Say "    $apiUrl" 'Green'
    if ($copied) {
        Say '    ✓ 已自动复制到剪贴板，手机上直接粘贴即可' 'Green'
    } else {
        Say '    （自动复制失败，请从「服务器地址.txt」里复制）' 'Yellow'
    }
    Say ''
}
Say "    网页（这台电脑）    $webUrl" 'White'
if ($lanIp) {
    Say "    网页（其他设备）    http://${lanIp}:$Port/" 'White'
} else {
    Say '    未探测到局域网 IP（这台电脑可能没连网络）。' 'Yellow'
    Say '    手机暂时无法连接；连上 Wi-Fi/网线后重启本程序即可。' 'Yellow'
}
Say ''
Say "    管理员邀请码        $inviteCode" 'White'
Say '  ------------------------------------------------------------' 'DarkGray'
switch ($firewallState) {
    'already' { Say '    防火墙              已放行（此前配置过）' 'Gray' }
    'added' { Say '    防火墙              本次已放行' 'Gray' }
    'skipped' { Say '    防火墙              已跳过（-SkipFirewall）' 'Gray' }
    default { Say '    防火墙              ⚠ 未放行，手机可能连不上' 'Red' }
}
Say "    数据文件            server\data\volunteer.db" 'Gray'
Say "    配置                 .env（改完重启生效）" 'Gray'
Say "    地址留存             服务器地址.txt（可随时打开复制）" 'Gray'
Say '    手机怎么连          见「手机连接指南.md」' 'Gray'
Say '    停止服务            在本窗口按 Ctrl+C' 'Gray'
Say '    窗口别关            关掉窗口 = 停止服务；只是点一下窗口不会停' 'Gray'
Say '  ============================================================' 'Cyan'

if ($firewallState -eq 'failed') {
    Say ''
    Say '  ⚠ 防火墙没放行成功，手机将连不上。最简单的修法：' 'Yellow'
    Say '     再双击一次「启动服务器.bat」，在弹窗里点「是」。' 'Yellow'
    Say '     （若还是不行：右键「启动服务器.bat」→「以管理员身份运行」）' 'Yellow'
}
if ($ipChanged) {
    Say ''
    Say "  ⚠ 本机 IP 变了（$lastIp → $lanIp），手机上的服务器地址要按新地址重填。" 'Yellow'
}
if ($firstRun) {
    Say ''
    Say '  首次启动已生成配置 .env，并会自动写入演示活动（便于直接看效果）。' 'DarkGray'
    Say '  正式使用前请把 .env 里的 SEED_ON_START 改成 false，并修改 ADMIN_INVITE_CODE。' 'DarkGray'
}
Say ''
Say '  服务端日志如下（这一行之后是程序自己打印的）：' 'DarkGray'
Say ''

# ── 自动打开网页（等服务器真的能响应再开）─────────────────────────────
#
# 为什么要"等"：早期是延迟 2 秒就开。机器慢的时候，浏览器打开的是
# "无法访问"的空页，用户以为服务没起来；机器快的时候又白等 2 秒。
# 现在交给 open-web.ps1 轮询 /api/health，一就绪立刻开，最多等 45 秒。
#
# 用后台 job 拉起：不阻塞前台日志，node 仍在下面前台运行。
if (-not $NoBrowser) {
    $opener = Join-Path $Root 'open-web.ps1'
    try {
        if (Test-Path $opener) {
            # 用 -ExecutionPolicy Bypass 起子进程：组策略可能限制 .ps1 直接执行
            $null = Start-Job -ScriptBlock {
                param($Script, $Url)
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -Url $Url
            } -ArgumentList $opener, $webUrl
            Say '  网页会自动打开（服务就绪后）。没弹出的请手动访问上面的地址。' 'DarkGray'
        } else {
            Say '  （没有找到 open-web.ps1，请手动访问上面的地址）' 'DarkGray'
        }
    } catch {
        Say '  （自动打开浏览器失败，请手动访问上面的地址）' 'DarkGray'
    }
}

# ── 前台运行服务端 ───────────────────────────────────────────────────
Push-Location $ServerDir
try {
    & $NodeExe 'src/server.js'
} finally {
    Pop-Location
    Say ''
    Say '  服务已停止。' 'DarkGray'
    Pause-IfInteractive
}
