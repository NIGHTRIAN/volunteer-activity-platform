# =====================================================================
#  把本仓库发布到 GitHub（建仓库 + 推送 + 上传 APK 到 Release）
# =====================================================================
#
#  ## 为什么需要它
#
#  这台机器上通常没有 gh、也没有配置 GitHub 凭据，所以"发布"没法自动化到
#  "点一下就好"。这个脚本把剩下的步骤压缩成：**填一次 token**。
#
#  ## 用法
#
#  双击 tools\publish-github.bat（会问你要 token，输入时不显示）
#
#  重复运行是**安全**的：仓库已存在就跳过创建，已是最新就跳过推送，
#  Release 已存在就只补传缺的附件。
#
#  ## Token 怎么弄（30 秒）
#
#  1. 打开 https://github.com/settings/tokens
#  2. **Generate new token (classic)** → 勾选 **repo**（整块勾上就行）
#     · Fine-grained token 也行，但它**不能替你新建仓库**；
#       那就先在网页上建一个空仓库（不要勾 README），脚本会自动识别并直接推送。
#  3. 复制生成的 token（ghp_ 开头），粘贴到提示里
#
#  安全：token 只在本次执行的命令行参数里用一次，**不写进 .git/config**，
#  也不会被打印出来。
#
#  ## 踩过的坑（别改回去）
#
#  最初这个脚本在 `$ErrorActionPreference = 'Stop'` 下直接调 `git push`。
#  **git 把进度信息写在 stderr 上**（"Everything up-to-date" 也是），
#  PowerShell 会把 stderr 当成 ErrorRecord → 在 `Stop` 下抛终止错误，
#  脚本当场退出。于是：代码其实推上去了，但后面的主题标签、Release 全没执行，
#  用户看到一大段红色报错以为失败了。
#
#  所以现在所有 git 调用都走 [Invoke-Git]：它把 EAP 临时降为 Continue，
#  只认 `$LASTEXITCODE`。这不是"容错"，是因为**在 PowerShell 里退出码才是
#  唯一可靠的成败信号**，stderr 有正常内容。
#
# =====================================================================

[CmdletBinding()]
param(
    [string]$User,                # GitHub 用户名（不给就用 token 查）
    [string]$Repo = 'volunteer-activity-platform',
    [string]$Description = '志愿活动信息平台：两个 Flutter App + Vue 网页 + 零依赖 Node 服务端，含现场签到、在岗抽查与考勤留痕',
    [switch]$Private,             # 私有仓库
    [string]$Token,               # 非交互传入
    [switch]$SkipRelease,         # 不传 APK
    [switch]$DryRun               # 只检查，不执行
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Step($t) { Say "  . $t" 'Cyan' }
function Ok($t) { Say "  + $t" 'Green' }
function Warn($t) { Say "  ! $t" 'Yellow' }
function Fail($t) { Say "  X $t" 'Red' }

<#
  执行 git 并返回 { Output, Code }。

  ⚠️ 必须临时关掉 ErrorActionPreference：git 的正常输出（进度、up-to-date、
  "To https://..."）走 stderr，EAP=Stop 下会被当成异常直接终止脚本。
#>
function Invoke-Git {
    param([string[]]$ArgsList, [switch]$Quiet)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git @ArgsList 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if (-not $Quiet) {
        $out | ForEach-Object { Say "      $_" 'DarkGray' }
    }
    return [pscustomobject]@{ Output = @($out); Code = $code }
}

function Ask-Secret($prompt) {
    $secure = Read-Host -Prompt $prompt -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Invoke-GitHub {
    param([string]$Method, [string]$Path, [hashtable]$Headers, [object]$Body)
    $params = @{
        Method      = $Method
        Uri         = "https://api.github.com$Path"
        Headers     = $Headers
        ContentType = 'application/json; charset=utf-8'
        TimeoutSec  = 30
    }
    if ($null -ne $Body) {
        $params['Body'] = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 6 -Compress))
    }
    try {
        return Invoke-RestMethod @params
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
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

Push-Location $Root
try {
    # -- 0. 预检 ----------------------------------------------------
    Step '检查本地仓库'
    if (-not (Test-Path (Join-Path $Root '.git'))) { Fail '这不是 git 仓库（找不到 .git）'; exit 1 }

    $branch = (Invoke-Git @('branch', '--show-current') -Quiet).Output
    $branch = "$branch".Trim()
    if (-not $branch) { $branch = 'main' }

    $commits = (Invoke-Git @('rev-list', '--count', 'HEAD') -Quiet).Output
    if (-not $commits -or [int]$commits -eq 0) { Fail '还没有任何提交，先 git add -A 再 git commit'; exit 1 }

    $files = (Invoke-Git @('-c', 'core.quotepath=false', 'ls-files') -Quiet).Output
    $bytes = 0
    foreach ($f in $files) {
        $p = Join-Path $Root $f
        if (Test-Path -LiteralPath $p) { $bytes += (Get-Item -LiteralPath $p).Length }
    }
    $sizeMb = [math]::Round($bytes / 1MB, 1)

    $dirtyLines = (Invoke-Git @('-c', 'core.quotepath=false', 'status', '--porcelain') -Quiet).Output |
        Where-Object { "$_".Trim() -ne '' }

    Say "    仓库      $Root" 'DarkGray'
    Say "    分支      $branch（$commits 次提交）" 'DarkGray'
    Say "    内容      $($files.Count) 个文件 / $sizeMb MB" 'DarkGray'
    if ($dirtyLines.Count -gt 0) {
        Warn "还有 $($dirtyLines.Count) 处未提交的改动，不会被推上去"
        Say '       （要一起推就关掉窗口，先 git add -A 再 git commit）' 'DarkGray'
    } else {
        Ok '工作区干净'
    }

    # -- 1. token ---------------------------------------------------
    if (-not $Token) {
        Say ''
        Say '  需要一个 GitHub 访问令牌（token）。' 'White'
        Say '  获取：https://github.com/settings/tokens → Generate new token (classic) → 勾 repo' 'DarkGray'
        Say '  （token 只在本机内存里用一次，不会存盘、不会打印）' 'DarkGray'
        $Token = Ask-Secret '  粘贴 token（输入时不显示）'
    }
    $Token = "$Token".Trim()
    if (-not $Token) { Fail '没有 token，退出'; exit 1 }

    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = 'application/vnd.github+json'
        'User-Agent'           = 'volunteer-platform-publisher'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    # -- 2. 校验身份 ------------------------------------------------
    Step '校验 token'
    $me = Invoke-GitHub -Method GET -Path '/user' -Headers $headers
    if ($me.__error) {
        Fail "token 无效或网络不通（$($me.Message)）"
        if ($me.Detail) { Say "    $($me.Detail)" 'DarkGray' }
        Say '    常见原因：token 少复制了几位 / 已过期 / 公司网络拦了 api.github.com' 'DarkGray'
        exit 1
    }
    if (-not $User) { $User = $me.login }
    Ok "已登录：$($me.login)"
    Say "    目标仓库  $User/$Repo（$(if ($Private) { '私有' } else { '公开' })）" 'White'

    if ($DryRun) { Say ''; Warn 'DryRun：不实际创建/推送'; exit 0 }

    # -- 3. 建仓库 --------------------------------------------------
    Step '创建仓库'
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
            Ok '仓库已存在，继续'
        } else {
            # 可能是 Fine-grained token 不能建仓库 —— 仓库已存在就还能继续
            $probe = Invoke-GitHub -Method GET -Path "/repos/$User/$Repo" -Headers $headers
            if ($probe.__error) {
                Fail "建仓库失败（HTTP $($created.Status)）"
                if ($created.Detail) { Say "    $($created.Detail)" 'DarkGray' }
                Say ''
                Say '    两个解法（选一个）：' 'White'
                Say '      1) 换成 classic token，勾选 repo 整块' 'DarkGray'
                Say "      2) 先在网页上建一个空仓库 https://github.com/new（名字填 $Repo，不要勾 README），再重跑本脚本" 'DarkGray'
                exit 1
            }
            Ok '仓库已存在，继续'
        }
    } else {
        Ok "已创建：$($created.html_url)"
    }

    # -- 4. 推送 ----------------------------------------------------
    Step '推送源码'
    $plainUrl = "https://github.com/$User/$Repo.git"
    $authUrl = "https://$User`:$Token@github.com/$User/$Repo.git"

    $remotes = (Invoke-Git @('remote') -Quiet).Output
    if ($remotes -contains 'origin') {
        Invoke-Git @('remote', 'set-url', 'origin', $plainUrl) -Quiet | Out-Null
    } else {
        Invoke-Git @('remote', 'add', 'origin', $plainUrl) -Quiet | Out-Null
    }

    # token 只在这一条命令里出现，不落进 .git/config
    $push = Invoke-Git @('push', $authUrl, "${branch}:${branch}")
    if ($push.Code -ne 0) {
        # 远端可能已有内容（建仓库时勾了 README / 之前推过别的东西）
        Warn '普通推送被拒，尝试覆盖远端历史…'
        $push = Invoke-Git @('push', $authUrl, "${branch}:${branch}", '--force')
    }
    if ($push.Code -ne 0) {
        Fail '推送失败'
        Say '    常见原因：' 'DarkGray'
        Say '      * token 没有 repo 权限（重新生成并整块勾上 repo）' 'DarkGray'
        Say '      * token 已过期' 'DarkGray'
        Say '      * 公司/校园网代理拦了 github.com（设 HTTPS_PROXY 后重试）' 'DarkGray'
        exit 1
    }
    if (($push.Output | Out-String) -match 'Everything up-to-date') {
        Ok '远端已是最新，无需推送'
    } else {
        Ok '推送完成'
    }

    # 设上游（不 fetch：私有仓库匿名取不到，fetch 会失败）
    Invoke-Git @('config', "branch.$branch.remote", 'origin') -Quiet | Out-Null
    Invoke-Git @('config', "branch.$branch.merge", "refs/heads/$branch") -Quiet | Out-Null

    # -- 5. 仓库元信息 ----------------------------------------------
    Step '设置简介与主题标签'
    $patched = Invoke-GitHub -Method PATCH -Path "/repos/$User/$Repo" -Headers $headers -Body @{
        description = $Description
        topics      = @('flutter', 'vue3', 'nodejs', 'sqlite', 'volunteer', 'attendance', 'geolocation', 'education')
    }
    if ($patched.__error) {
        Warn "主题标签没设置成功（HTTP $($patched.Status)），不影响代码"
    } else {
        Ok ('主题：' + ($patched.topics -join ', '))
    }

    # -- 6. Release + 附件 -----------------------------------------
    if (-not $SkipRelease) {
        Step '创建 Release 并上传安装包'
        $apkUser = Join-Path $Root 'apps\user_app\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
        $apkAdmin = Join-Path $Root 'apps\admin_app\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
        $bundleZip = Get-ChildItem (Join-Path $Root 'dist') -Filter '*.zip' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName

        $assets = @()
        foreach ($a in @($apkUser, $apkAdmin, $bundleZip)) {
            if ($a -and (Test-Path -LiteralPath $a)) { $assets += $a }
            elseif ($a) { Warn "找不到 $a" }
        }

        if ($assets.Count -eq 0) {
            Warn '没有可上传的产物，跳过。先跑 tools\build-release.cmd 和 tools\make-deploy-bundle.ps1'
        } else {
            $tag = 'v0.1.0'
            $release = Invoke-GitHub -Method POST -Path "/repos/$User/$Repo/releases" -Headers $headers -Body @{
                tag_name   = $tag
                name       = 'v0.1.0 · 首个可运行版本'
                body       = @'
## 这是什么

三端一服务：两个 Flutter App（管理端 / 用户端）+ Vue 3 只读网页 + 零依赖 Node 服务端。

## 最快看到效果（Windows）

1. 下载 `志愿活动平台-服务器整合包.zip` 并解压
2. 双击 `启动服务器.bat`（首次会弹 UAC 放行防火墙，点「是」）
3. 服务起来后会自动打开浏览器，看到活动列表就成功了
4. 手机装下面的 APK，管理端邀请码 `1111`

## 手机端

- `志愿活动-管理端.apk`：组织者用（建活动 / 名单 / 看板 / 复核 / 导出）
- `志愿活动-用户端.apk`：志愿者用（绑定活动 / 签到 / 在岗确认 / 查记录）

> 仅提供 arm64-v8a（覆盖近几年主流安卓机）。其他架构请从源码构建，见 README「方式三」。
'@
                draft      = $false
                prerelease = $false
            }

            if ($release.__error) {
                if ($release.Status -eq 422) {
                    # 重跑时 tag 已存在：取回已有的 Release，只补传缺的附件
                    $release = Invoke-GitHub -Method GET -Path "/repos/$User/$Repo/releases/tags/$tag" -Headers $headers
                    if ($release.__error) {
                        Warn "Release 取不回来（HTTP $($release.Status)），跳过上传"
                        $release = $null
                    } else {
                        Ok "Release $tag 已存在，检查附件"
                    }
                } else {
                    Warn "Release 没建成（HTTP $($release.Status)）"
                    if ($release.Detail) { Say "    $($release.Detail)" 'DarkGray' }
                    $release = $null
                }
            }

            if ($release) {
                if ($release.html_url) { Ok "Release：$($release.html_url)" }
                $existingNames = @()
                if ($release.assets) { $existingNames = @($release.assets | ForEach-Object { $_.name }) }
                $uploadUrl = ($release.upload_url -replace '\{\?name,label\}', '')

                foreach ($file in $assets) {
                    $name = Split-Path -LiteralPath $file -Leaf
                    if ($existingNames -contains $name) {
                        Ok "$name 已存在，跳过"
                        continue
                    }
                    Say "      上传 $name（$([math]::Round((Get-Item -LiteralPath $file).Length / 1MB, 1)) MB）…" 'DarkGray'
                    try {
                        $null = Invoke-RestMethod -Method POST `
                            -Uri "$uploadUrl?name=$([uri]::EscapeDataString($name))" `
                            -Headers $headers -ContentType 'application/octet-stream' `
                            -InFile $file -TimeoutSec 900
                        Ok "$name"
                    } catch {
                        Warn "$name 上传失败：$($_.Exception.Message)（可在网页上手动补传）"
                    }
                }
            }
        }
    }

    # -- 7. 收尾 ----------------------------------------------------
    Say ''
    Say '  ============================================================' 'Cyan'
    Say '   发布完成' 'Green'
    Say '  ============================================================' 'Cyan'
    Say "    仓库地址   $plainUrl" 'White'
    Say "    Releases   $plainUrl/releases" 'Gray'
    Say ''
    Say '    接下来可以做（可选）：' 'White'
    Say '      · Settings → Pages 可以托管一套在线说明文档' 'Gray'
    Say '      · 徽章可以换成你自己仓库的 Actions/Release 链接' 'Gray'
    Say ''
    try { Start-Process $plainUrl } catch { }
    Read-Host '  按回车关闭'
} finally {
    Pop-Location
}
