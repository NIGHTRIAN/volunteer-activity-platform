# =====================================================================
#  把本仓库发布到 GitHub（建仓库 + 推送 + 可选上传 APK 到 Release）
# =====================================================================
#
#  ## 为什么需要它
#
#  这台机器上没有安装 gh、也没有配置任何 GitHub 凭据，所以"发布"没法自动化到
#  "点一下就好"。这个脚本把剩下的步骤压缩成：**填一次 token**。
#
#  ## 用法
#
#  双击 tools\publish-github.bat（会问你要 token）
#
#  或命令行：
#    powershell -ExecutionPolicy Bypass -File tools\publish-github.ps1 `
#        -User 你的GitHub用户名 -Repo volunteer-activity-platform -Private
#
#  ## Token 怎么弄（30 秒）
#
#  1. 打开 https://github.com/settings/tokens
#  2. "Generate new token" → 勾选 **repo**（Fine-grained 也行，给 Contents: Read/Write
#     与 Administration: Read/Write 就够建仓库）
#  3. 复制生成的 token（ghp_ 开头），粘贴到下面提示里
#
#  安全说明：token 只在本次执行的命令行参数里用一次，**不写进 .git/config**，
#  也不会被打印出来。
#
# =====================================================================

[CmdletBinding()]
param(
    # GitHub 用户名（不给就用 token 查）
    [string]$User,

    # 仓库名
    [string]$Repo = 'volunteer-activity-platform',

    # 仓库简介
    [string]$Description = '志愿活动信息平台：两个 Flutter App + Vue 网页 + 零依赖 Node 服务端，含现场签到、在岗抽查与考勤留痕',

    # 设为私有仓库
    [switch]$Private,

    # 直接给 token（不交互）
    [string]$Token,

    # 跳过 Release（不传 APK）
    [switch]$SkipRelease,

    # 只打印将要做什么，不真的执行
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Say($text, $color = 'Gray') {
    Write-Host $text -ForegroundColor $color
}

function Ask-Secret($prompt) {
    $secure = Read-Host -Prompt $prompt -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Invoke-GitHub {
    param(
        [string]$Method,
        [string]$Path,
        [hashtable]$Headers,
        [object]$Body
    )
    $uri = "https://api.github.com$Path"
    $params = @{
        Method      = $Method
        Uri         = $uri
        Headers     = $Headers
        ContentType = 'application/json; charset=utf-8'
        TimeoutSec  = 30
    }
    if ($null -ne $Body) {
        $params['Body'] = ([System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 6 -Compress)))
    }
    try {
        return Invoke-RestMethod @params
    } catch {
        $status = $null
        try { $status = $_.Exception.Response.StatusCode.value__ } catch { }
        $detail = ''
        try {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $detail = $reader.ReadToEnd()
        } catch { }
        return [pscustomobject]@{ __error = $true; Status = $status; Detail = $detail; Message = $_.Exception.Message }
    }
}

Say ''
Say '  ============================================================' 'Cyan'
Say '   发布到 GitHub' 'White'
Say '  ============================================================' 'Cyan'
Say ''

# ── 0. 仓库状态检查 ──────────────────────────────────────────────────
Push-Location $Root
try {
    if (-not (Test-Path (Join-Path $Root '.git'))) {
        Say '  ✗ 这不是一个 git 仓库（找不到 .git）。' 'Red'
        exit 1
    }
    $dirty = (& git -c core.quotepath=false status --porcelain) | Measure-Object
    if ($dirty.Count -gt 0) {
        Say "  注意：还有 $($dirty.Count) 处未提交的改动，它们不会被推上去。" 'Yellow'
        Say '        （要一起推就先 git add -A && git commit）' 'DarkGray'
        Say ''
    }
    $branch = & git branch --show-current
    if (-not $branch) { $branch = 'main' }
    Say "  本地仓库：$Root" 'Gray'
    Say "  分支：$branch" 'Gray'

    # ── 1. token ────────────────────────────────────────────────────
    if (-not $Token) {
        Say ''
        Say '  需要一个 GitHub 访问令牌（token）。' 'White'
        Say '  获取：https://github.com/settings/tokens → Generate new token → 勾选 repo' 'DarkGray'
        $Token = Ask-Secret '  粘贴 token（输入时不显示）'
    }
    $Token = $Token.Trim()
    if (-not $Token) { Say '  ✗ 没有 token，退出。' 'Red'; exit 1 }

    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = 'application/vnd.github+json'
        'User-Agent'           = 'volunteer-platform-publisher'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    # ── 2. 确认身份 ─────────────────────────────────────────────────
    Say ''
    Say '  校验 token…' 'Gray'
    $me = Invoke-GitHub -Method GET -Path '/user' -Headers $headers
    if ($me.__error) {
        Say "  ✗ token 无效或没网：$($me.Message)" 'Red'
        if ($me.Detail) { Say "    $($me.Detail)" 'DarkGray' }
        exit 1
    }
    if (-not $User) { $User = $me.login }
    Say "  已登录：$($me.login)" 'Green'
    Say "  目标仓库：$User/$Repo" 'White'
    Say ("  可见性：" + $(if ($Private) { '私有' } else { '公开' })) 'White'
    Say ''

    if ($DryRun) {
        Say '  （DryRun：不实际创建/推送）' 'Yellow'
        exit 0
    }

    # ── 3. 建仓库（已存在则跳过）─────────────────────────────────────
    Say '  创建仓库…' 'Gray'
    $created = Invoke-GitHub -Method POST -Path '/user/repos' -Headers $headers -Body @{
        name        = $Repo
        description = $Description
        private     = [bool]$Private
        has_issues  = $true
        has_wiki    = $false
        auto_init   = $false
    }
    if ($created.__error) {
        if ($created.Status -eq 422) {
            Say '  仓库已存在，直接推送。' 'DarkGray'
        } else {
            Say "  ✗ 建仓库失败（HTTP $($created.Status)）：$($created.Message)" 'Red'
            if ($created.Detail) { Say "    $($created.Detail)" 'DarkGray' }
            exit 1
        }
    } else {
        Say "  ✓ 已创建：$($created.html_url)" 'Green'
    }

    # ── 4. 推送 ─────────────────────────────────────────────────────
    Say ''
    Say '  推送源码…（首次约 10–20 MB，视网络 30 秒到 2 分钟）' 'Gray'
    $plainUrl = "https://github.com/$User/$Repo.git"
    $authUrl = "https://$User`:$Token@github.com/$User/$Repo.git"

    $existing = (& git remote) 2>&1
    if ($existing -contains 'origin') {
        & git remote set-url origin $plainUrl 2>&1 | Out-Null
    } else {
        & git remote add origin $plainUrl 2>&1 | Out-Null
    }
    # 用带凭据的 URL 推一次：token 只在这一条命令里出现，不落进 .git/config
    & git push $authUrl "${branch}:${branch}" --force-with-lease 2>&1 | ForEach-Object { "    $_" }
    if ($LASTEXITCODE -ne 0) {
        Say '  ✗ 推送失败。常见原因：' 'Red'
        Say '    * token 没有 repo 权限（重新生成，勾选 repo / Contents: Read and write）' 'DarkGray'
        Say '    * token 已过期' 'DarkGray'
        Say '    * 网络代理拦截（设 HTTPS_PROXY 后重试）' 'DarkGray'
        exit 1
    }
    & git branch --set-upstream-to "origin/$branch" $branch 2>&1 | Out-Null
    Say '  ✓ 推送完成' 'Green'
    Say "    $plainUrl" 'White'

    # ── 5. 仓库元信息：主页、主题标签 ───────────────────────────────
    Say ''
    Say '  设置简介与主题标签…' 'Gray'
    $patched = Invoke-GitHub -Method PATCH -Path "/repos/$User/$Repo" -Headers $headers -Body @{
        description = $Description
        homepage    = ''
        topics      = @('flutter', 'vue3', 'nodejs', 'sqlite', 'volunteer', 'attendance', 'geolocation', 'education')
    }
    if ($patched.__error) { Say "  （元信息没设置成功：HTTP $($patched.Status)，不影响代码）" 'Yellow' }
    else { Say '  ✓ 已完成' 'Green' }

    # ── 6. Release + APK ───────────────────────────────────────────
    if (-not $SkipRelease) {
        Say ''
        Say '  创建 Release 并上传 APK…' 'Gray'
        $assets = @(
            (Join-Path $Root 'apps\user_app\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'),
            (Join-Path $Root 'apps\admin_app\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'),
            (Get-ChildItem (Join-Path $Root 'dist') -Filter '*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
        ) | Where-Object { Test-Path $_ }

        if ($assets.Count -eq 0) {
            Say '  （没有找到可上传的产物，跳过。先跑 tools\build-release.cmd 与 tools\make-deploy-bundle.ps1）' 'Yellow'
        } else {
            $tag = 'v0.1.0'
            $release = Invoke-GitHub -Method POST -Path "/repos/$User/$Repo/releases" -Headers $headers -Body @{
                tag_name         = $tag
                name             = 'v0.1.0 · 首个可运行版本'
                body             = @'
## 这是什么

三端一服务：两个 Flutter App（管理端/用户端）+ Vue 3 只读网页 + 零依赖 Node 服务端。

## 直接用它（Windows）

1. 下载 `志愿活动平台-服务器整合包.zip`，解压
2. 双击 `启动服务器.bat`（首次会弹 UAC 放行防火墙，点「是」）
3. 服务起来后会自动打开浏览器
4. 手机装下面的 APK，管理端邀请码 `1111`

## 手机端

- `志愿活动-用户端.apk`：志愿者用（绑定活动、签到、在岗确认、查记录）
- `志愿活动-管理端.apk`：组织者用（建活动、名单、看板、复核、导出）

> 仅提供 arm64-v8a（覆盖近几年的主流安卓机）。其他架构请从源码构建。
'@
                draft            = $false
                prerelease       = $false
            }
            if ($release.__error) {
                Say "  （Release 没建成：HTTP $($release.Status)）" 'Yellow'
                if ($release.Detail) { Say "    $($release.Detail)" 'DarkGray' }
            } else {
                Say "  ✓ Release：$($release.html_url)" 'Green'
                $uploadUrl = ($release.upload_url -replace '\{\?name,label\}', '')
                foreach ($file in $assets) {
                    $name = Split-Path $file -Leaf
                    Say "    上传 $name（$([math]::Round((Get-Item $file).Length / 1MB, 1)) MB）…" 'Gray'
                    try {
                        $up = Invoke-RestMethod -Method POST -Uri "$uploadUrl?name=$([uri]::EscapeDataString($name))" `
                            -Headers $headers -ContentType 'application/octet-stream' `
                            -InFile $file -TimeoutSec 900
                        Say "    ✓ $name" 'Green'
                    } catch {
                        Say "    ✗ $name 上传失败：$($_.Exception.Message)" 'Yellow'
                    }
                }
            }
        }
    }

    # ── 7. 收尾 ─────────────────────────────────────────────────────
    Say ''
    Say '  ============================================================' 'Cyan'
    Say '   完成' 'Green'
    Say '  ============================================================' 'Cyan'
    Say "    仓库地址    $plainUrl" 'White'
    Say "    网页版      https://$User.github.io/$Repo/（如启用了 GitHub Pages）" 'Gray'
    Say '    记着：README 里的截图来自 docs/shots/，Releases 里放安装包。' 'DarkGray'
    Say ''
    Read-Host '  按回车关闭'
} finally {
    Pop-Location
}
