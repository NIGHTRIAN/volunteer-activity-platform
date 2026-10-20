# 构建环境记录（Windows）

记录本机把 Flutter 项目构建成 APK 的过程中实际踩到的问题与处置。
**这些问题不是推测，都是实测复现过的**，因此绕行方案写死进了仓库配置。

| # | 问题 | 症状 | 处置 |
|---|---|---|---|
| 1 | `services.gradle.org` 不可达 | Gradle 下载停滞在 **0 MB**（45 秒零增长），无任何报错 | 换腾讯云镜像 + 改用 `-bin`（130MB 取代 224MB） |
| 2 | `maven.google.com` 不可达 | 依赖解析极慢，首次构建长时间无输出 | 阿里云 Maven 镜像（google / central / gradle-plugin）在前 |
| 3 | `workmanager 0.5.2` 编译失败 | `Unresolved reference 'shim'`、`PluginRegistrantCallback`、`ShimPluginRegistry` | **移除该依赖**（见下） |
| 4 | Kotlin 增量缓存无法关闭 | `Could not close incremental caches ... class-fq-name-to-source.tab` | `kotlin.incremental=false` + `in-process` 执行策略 |
| 5 | **脚本文件编码** | `'.cmd' 不是内部或外部命令`、`A parameter with the name 'Debug' was defined multiple times` | 脚本改为**纯 ASCII**；参数改名（见下） |

---

## 问题 5：脚本里的中文会被当成命令执行（两个子问题）

这一类问题很隐蔽：**文件本身"看起来"完全正常**，
编辑器里中文显示得好好的，但执行时行为完全不对。

### 子问题 A：`.cmd` / `.ps1` 的非 ASCII 字符

`cmd.exe` 用 **OEM/ANSI 代码页**（中文 Windows 上是 GBK）解码 `.cmd` 文件，
**不是** UTF-8。Windows PowerShell 5.1 读 `.ps1` 同样按 ANSI。

于是文件里的中文注释被解码成乱码字节，而 `rem` 行里的乱码**不总是**
被当成注释——实测症状是明明写在 `rem` 里的中文变成了要执行的命令：

```
'.cmd' is not recognized as an internal or external command,
operable program or batch file.
'get' is not recognized as an internal or external command,
```

最讽刺的一处：错误信息里出现 `'略管不到的。'` —— 那是我写在
`tools\flutter.cmd` 里的一句中文说明。**这个脚本从写下那天起就一直是坏的**，
只是当时没有端到端跑过它，所以没人发现。

**处置**：`tools/` 下所有 `.cmd` 与 `.ps1` 改为**纯 ASCII**，
并在文件头写明"不要加中文或 emoji"。面向用户的说明放在本文档里。

> 如果确实需要非 ASCII，必须**带 UTF-8 BOM 保存**，
> 这样 PowerShell 5.1 与 7 都能正确解码。

### 子问题 B：`-Debug` 是 PowerShell 的保留参数名

```powershell
# ❌ 整个脚本无法加载
param([switch]$Debug)
```

报错是 `A parameter with the name 'Debug' was defined multiple times`。
原因是 `-Debug` 属于 PowerShell 的**通用参数**（控制 `Write-Debug` 输出），
不能在自己的 `param()` 里重复声明。`-Verbose`、`-ErrorAction` 等同理。

**处置**：改名为 `-DebugBuild`。

### 顺带确认的一件事

这三个包装脚本（`flutter.cmd` / `dart.cmd` / `build-release.cmd`）
现已逐个实测通过：

```
tools\flutter.cmd --version   → Flutter 3.47.7 • Dart 3.13.5
tools\dart.cmd --version      → Dart SDK version: 3.13.5
tools\build-release.cmd <url> user
    → √ app-arm64-v8a-release.apk (17.7MB)
      user_app     background location: absent [ok]
```

`tools\env.ps1` 仍含非 ASCII，但它只在**交互式** `powershell` 里
被 dot-source 使用，且已注明"本机执行策略禁止直接运行"。
若要脚本化使用，需要按上面子问题 A 的方式处理。

---

## 问题 1 & 2：网络与镜像

```
services.gradle.org   → HEAD 请求超时，下载 0 MB
maven.google.com      → 不可达
dl.google.com         → 可达
maven.aliyun.com      → 可达
mirrors.cloud.tencent.com → 可达（130MB 文件 176ms 响应）
```

AGP、AndroidX、Kotlin 插件全在 Google 的 Maven 仓库里，
而这个仓库恰好不可达——所以不换源的话首次构建会**静默卡住**：
没有任何错误，只是长时间不动。这比直接报错更难排查。

**已固定的配置：**

| 文件 | 内容 |
|---|---|
| `android/gradle/wrapper/gradle-wrapper.properties` | `distributionUrl=…tencent…/gradle-9.3.1-bin.zip` |
| `android/settings.gradle.kts` | `pluginManagement.repositories` 镜像在前 |
| `android/build.gradle.kts` | `allprojects.repositories` 镜像在前 |

版本必须保持 `9.3.1`：AGP 9.1.0 / Kotlin 2.4.0 对 Gradle 有下限要求。

**不要改回官方源。** 官方源留在列表末尾作兜底（镜像同步有延迟，缺包时还能构建）。

---

## 问题 3：移除 `workmanager`

`shared_platform` 原先声明了 `workmanager: ^0.5.2`，但它**从未被任何代码引用**——
只是当初"离线补传可能需要后台任务"的想法留下的空声明。

它无法用 Kotlin 2.4 / AGP 9.1 编译：该版本仍在使用 Flutter 的 **v1 嵌入 API**
（`PluginRegistrantCallback`、`ShimPluginRegistry`、`io.flutter.view.FlutterMain`），
而这些在 Flutter 3.47 已移除。

### 移除它不只是"绕过编译错误"

更重要的是**它与方案 §6.2 的取向相悖**：

> 不启用推送，由 App 前台轮询拉取；**App 不承担任何定时判定**。

后台任务正是"App 承担定时职责"的典型形态。而离线证据的补传**已经**被
`OfflineQueue` 完整覆盖，且三条路径都是**前台**的：

1. **网络恢复时自动补传** —— `AppShell` 订阅 `ConnectivityService`，
   只在"离线 → 在线"这个**边沿**触发（每次状态回调都 flush 会在网络抖动时反复发请求）；
2. **App 下次启动时补传** —— `AppShell._bootstrap`；
3. **用户手动重试** —— 「我的记录」里的重试入口。

前台补传可预期、可解释，也不需要后台执行权限。
附带好处是少了 `RECEIVE_BOOT_COMPLETED` 之类的权限与厂商省电策略的坑
（国产 ROM 对后台任务的限制差异极大，很容易出现"某品牌手机上补传不工作"）。

---

## 问题 4：Kotlin 增量编译缓存

```
e: Daemon compilation failed
Caused by: java.lang.AssertionError:
  Could not close incremental caches in .../build/device_info_plus/kotlin/
  compileDebugKotlin/cacheable/caches-jvm/jvm/kotlin:
  class-fq-name-to-source.tab, source-to-classes.tab, internal-name-to-source.tab
```

失败的三个模块（`device_info_plus` / `network_info_plus` / `package_info_plus`）
都是 pub.dev 上的第三方插件，与我们的代码无关。
这是 Kotlin 增量编译缓存在 Windows 上被占用 / 无法关闭导致的，
常见诱因是杀毒软件实时扫描、索引服务，或遗留的 Kotlin daemon 仍持有句柄。

**处置**（写入 `android/gradle.properties`）：

```properties
kotlin.compiler.execution.strategy=in-process
kotlin.incremental=false
```

* `in-process`：Kotlin 编译在 Gradle daemon 内进行，不再另起 daemon，
  少一处文件句柄竞争；
* `kotlin.incremental=false`：**有损取舍**——改 Kotlin 代码要全量编译该模块。
  但本项目几乎不改原生代码（只有插件与 Flutter 生成的胶水层），
  而增量缓存导致的失败会直接阻断构建。两害相权取其轻。

若将来原生代码变多、编译时间成为瓶颈，可以先把 `kotlin.incremental`
改回 `true` 试试。

---

## 构建结果

| 项 | 结果 |
|---|---|
| 修复前 | `BUILD FAILED in 14m 9s`（4 个 Kotlin 任务失败） |
| 修复后（debug） | `√ Built build\app\outputs\flutter-apk\app-debug.apk`，**154.7s** |
| 修复后（release） | `√ Built ... app-arm64-v8a-release.apk`，**36.9s** |

### 体积对照（内部测试分发务必用 release）

| 构建 | 体积 |
|---|---|
| debug（全架构单包） | **178.1 MB** |
| release `--split-per-abi` · armeabi-v7a | **15.2 MB** |
| release `--split-per-abi` · arm64-v8a | **17.7 MB** |
| release `--split-per-abi` · x86_64 | **19.1 MB** |

体积差十倍以上，主要来自 debug 包保留了全架构原生库与调试符号。
内部测试分发一律用 `--split-per-abi`。

### 一键构建

```powershell
# 用户端（内部测试）
tools\build-release.cmd http://192.168.1.100:8080/api user

# 两端都构建，并顺带核对权限
tools\build-release.cmd https://vol.cumt.edu.cn/api both
```

脚本会自动：检查 `API_BASE_URL` 是否以 `/api` 结尾、
构建后列出产物体积、用 `aapt2` **核对权限**（方案 §7 的底线）。

首次构建还需要下载 Android CMake 3.22.1（`jni` 相关插件依赖 NDK 构建），
SDK 会自动安装，无需手工干预。

---

## 遗留警告（不阻塞）

```
WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP):
device_info_plus, network_info_plus, package_info_plus, safe_device
Future versions of Flutter will fail to build if your app uses plugins that apply KGP.
```

这是 Flutter 在提示：这些插件尚未迁移到 "Built-in Kotlin"。
**当前可正常构建**，但未来版本的 Flutter 会拒绝它们。

处置选项：

1. 等插件作者发布支持 Built-in Kotlin 的版本，届时升级；
2. 若某个插件长期不更新，考虑替换（例如自己写一个最小的 Android 端实现）。
   `network_info_plus` 只是取 Wi-Fi BSSID 与 IP（评分表的辅证项，
   不参与判定），自己实现的成本很低，是最稳妥的候选。

**A4 阶段（加固与真机适配）需要复查这一项。**
