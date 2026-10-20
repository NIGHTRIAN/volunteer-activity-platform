# 志愿活动信息平台 · 构建环境变量
#
# 用法（每个新开的终端都要先执行一次）：
#     . .\tools\env.ps1
#
# 本文件只设置**当前进程**的环境变量，不写注册表、不改系统 PATH。
# 换机器时只需要改下面四个路径。

$ErrorActionPreference = 'Stop'

# ── 工具链路径 ────────────────────────────────────────────────────────────
$DevTools = 'D:\dev-tools'
$env:FLUTTER_ROOT = Join-Path $DevTools 'flutter'
$env:JAVA_HOME    = Join-Path $DevTools 'jdk\jdk-17.0.20.1+1'
$env:ANDROID_HOME = Join-Path $DevTools 'android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME

# Flutter 会调用 git 取版本号；构建工具目录里有 DSH 自带的 node/pnpm。
$env:Path = @(
  (Join-Path $env:FLUTTER_ROOT 'bin')
  (Join-Path $env:JAVA_HOME 'bin')
  (Join-Path $env:ANDROID_HOME 'platform-tools')
  (Join-Path $env:ANDROID_HOME 'cmdline-tools\latest\bin')
  (Join-Path $env:ANDROID_HOME 'emulator')
  'C:\Program Files\Git\cmd'
  'C:\Users\19563\dsh-build-tools'
  $env:Path
) -join ';'

# 国内网络下 Flutter 拉取依赖经常超时，默认走官方源；
# 如遇下载缓慢，取消下面两行的注释改用镜像（注意：镜像不覆盖所有包）。
# $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
# $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'

Write-Host '构建环境已就绪：' -ForegroundColor Green
Write-Host "  FLUTTER_ROOT  = $env:FLUTTER_ROOT"
Write-Host "  JAVA_HOME     = $env:JAVA_HOME"
Write-Host "  ANDROID_HOME  = $env:ANDROID_HOME"
