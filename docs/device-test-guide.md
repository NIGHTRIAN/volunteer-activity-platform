# 真机验证手册（内部测试版）

> 📄 **本手册是操作步骤。** 2026-10-17 的完整真机测试结果、发现的 6 个缺陷
> 与逐项证据见 [`docs/device-test-report.md`](device-test-report.md)。
>
> 💡 **构建 APK 前先跑 `tools\build-mobile-test.ps1`**：它会自动检测当前
> 局域网 IP、写入 APK、并**验证地址真的进了包**。手动填 IP 极易过期 ——
> 本次测试期间 IP 就从 `10.3.215.117` 变成了 `192.168.72.34`（DHCP），
> 用旧包装上去只会显示"连不上服务器"，看不出是地址错了。

本机实测环境：

| 项 | 值 |
|---|---|
| 本机局域网 IP | `192.168.72.34` ⚠️ **每次换网络都会变，务必用脚本自动检测** |
| Mock 服务端 | `0.0.0.0:8080`，健康检查从局域网 IP 可达 |
| adb | `D:\dev-tools\android-sdk\platform-tools\adb.exe`（v1.0.41 / 37.0.1） |
| 管理员邀请码 | `1111`（默认，未设 `ADMIN_INVITE_CODE`） |
| 实测机型 | Redmi Note 12T Pro / Android 15 / HyperOS V816 / arm64-v8a |

> ⚠️ **小米/红米机型装不上？** 需要开「开发者选项」里的**三个**开关，
> 不是两个：`USB 调试` → `USB 调试（安全设置）` → **`USB 安装`**。
> 第三个是装 APK 的关键，不开会报 `INSTALL_FAILED_USER_RESTRICTED`。
> 详见测试报告的 §2。

> ⚠️ 本机**没有 8080 的防火墙入站规则**，三个配置文件都是 `Enabled=True`。
> 这大概率是第一个会卡住的地方。**方案 A 可以完全绕过它**（见下）。
>
> 另外：手机若**自己是热点**（PC 连它的 Wi-Fi），Android 的客户端隔离会
> 让手机 **ping 不通** PC，但 **TCP 是通的** —— 排查时用
> `nc -z <PC_IP> 8080` 而不是 ping，否则会误判成网络不通。

---

## 第 0 步：接线（两选一）

### 方案 A：`adb reverse`（推荐，绕过防火墙）

让手机的 `127.0.0.1:8080` 转发到电脑的 `8080`。
好处：**不需要防火墙规则、不需要手机和电脑同网段**，
也不受公司/校园网"客户端隔离"影响。

```powershell
# 1) 手机用 USB 连电脑，开启「开发者选项 → USB 调试」
#    手机弹「允许 USB 调试吗？」→ 勾选"一律允许" → 确定
cd 'D:\VOLUNTEER SYSTEM'
& 'D:\dev-tools\android-sdk\platform-tools\adb.exe' devices -l

# 2) 建立端口反向转发
& 'D:\dev-tools\android-sdk\platform-tools\adb.exe' reverse tcp:8080 tcp:8080

# 3) 构建并安装（注意 API_BASE_URL 用 127.0.0.1）
tools\build-release.cmd http://127.0.0.1:8080/api user
& 'D:\dev-tools\android-sdk\platform-tools\adb.exe' install -r 'apps\user_app\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
```

> ⚠️ `adb reverse` 在**拔掉数据线后失效**。断开 USB 就没法联网了。
> 所以：如果要做"拔线走动签到"这类测试，用方案 B。

### 方案 B：走局域网（能拔线，但要开防火墙）

```powershell
# 以「管理员身份」打开 PowerShell，执行一次即可（长期生效）：
New-NetFirewallRule -DisplayName "Volunteer Mock 8080" `
  -Direction Inbound -Protocol TCP -LocalPort 8080 `
  -Action Allow -Profile Private,Domain

# 然后构建（API_BASE_URL 用局域网 IP）
cd 'D:\VOLUNTEER SYSTEM'
tools\build-release.cmd http://192.168.72.34:8080/api user
& 'D:\dev-tools\android-sdk\platform-tools\adb.exe' install -r 'apps\user_app\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
```

> 手机需与电脑连**同一个 Wi-Fi**。
> 若访客网络开了"客户端隔离"，手机连不上电脑——那就只能用方案 A。

**验证手机能连上**（不装 App 也能先测）：
手机浏览器打开 `http://192.168.72.34:8080/api/health`，
应看到一段 JSON（`{"code":0,"msg":"成功",...}`）。
打不开就是防火墙或同网段问题。

### 准备好管理端与用户端

```powershell
# 管理端也要装（它负责发邀请码、看看板、做复核）
tools\build-release.cmd http://192.168.72.34:8080/api admin
& 'D:\dev-tools\android-sdk\platform-tools\adb.exe' install -r 'apps\admin_app\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
```

---

## 第 1 步：把现场"造"出来（现在已经有界面了）

真机验证需要一个人真的站在签到点附近。为此管理端已补上**新建活动页**
（`apps/admin_app/lib/create_activity_page.dart`），入口是工作台右下角的
**「新建活动」浮动按钮**。

### 推荐流程：在任何地方都能测

1. 打开**管理端 App**，用邀请码 `1111` 登录；
2. 点右下角 **「新建活动」**；
3. 点最上面的 **「用当前位置作为签到点」** ——
   它会取手机 GPS 填入经纬度，并显示精度（例如"精度约 ±12 米"）；
4. 填活动名称、组织部门、一句话简介（其余可留空）；
5. 时间默认是"现在开始、2 小时后结束"，可改；
6. 确认 **「立即发布」** 开关是打开的；
7. 点底部 **「发布活动」**。

创建后工作台会刷新，SnackBar 会显示活动编号（形如 `M-261017-1345-123`）。

> ⚠️ **精度很重要**：如果显示"精度较差"（>100 米），说明你在室内或信号不好。
> 那种精度做签到点会让判定失去意义 —— 到室外再取一次。

### 不填坐标会怎样

**提交会被拒绝**，字段下方提示"请在地图上选择活动位置"。

这是有意的：没有坐标的活动，志愿者**能看到却永远签不上**，
比创建失败更难排查。坐标必填与方案 §4.1 的差异记录在
`docs/open-issues-app.md` 的 O-11。

### 备选：用种子活动

种子里已有一个**进行中**的活动「图书馆书架整理志愿服务」，
签到点在**南湖校区图书馆**（`34.2175, 117.1425`，半径 200m）。
如果你正好在图书馆，可以直接用它测。

---

## 第 2 步：10 项真机验证（逐条给结论）

每条都要求写出**观察到的具体数值或现象**，不要只写"正常"。

| # | 验证项 | 怎么测 | 要记录什么 | 结论 |
|---|---|---|---|---|
| 1 | **冷启动首次签到耗时** | 杀掉 App，重新打开 → 进活动 → 点「开始签到」 | 从点按钮到出结果的**秒数**（目标 < 10s） | |
| 2 | **站在签到点签** | 站在你设的签到点上签 | 结果（`已签到`/`待确认`）+ **评分** | |
| 3 | **走远再签** | 走到 1.5 倍半径外（450m）签 | 是否 `未通过`，提示是否给出距离 | |
| 4 | **室内签到** ⭐ | 走进楼里（如图书馆/教学楼）签 | **精度数值范围**、落到"待确认"的比例 | |
| 5 | **弱网补传** | 开飞行模式 → 签到（应提示"已保存在本机"）→ 关飞行模式 | 是否**自动**上传、状态是否变"待确认" | |
| 6 | **拒绝定位权限** | 系统设置里关掉本应用定位权限 → 签到 | 是否给出「**发布者现场核实**」的出路 | |
| 7 | **永久拒绝** | 权限里选"拒绝且不再询问" → 签到 | 「打开系统设置」按钮是否**真的跳到本应用设置页** | |
| 8 | **在岗确认** | 管理端制造一次抽查（等 T+首次延迟）→ 用户端点「我在现场」 | 耗时、**倒计时是否与服务端一致** | |
| 9 | **改手机时间** | 手机时间调快 5 分钟 → 看倒计时 | 倒计时是否仍以服务端时间为准 | |
| 10 | **管理端登出重进** | 管理端退出登录 → 重新打开 | 是否要求重新输入邀请码 | |

### ⭐ 第 4 项最关键

自动通过的门槛是 **60 分**，而我的测试显示：
**单次采样只能拿到围栏分 40 分**（围栏内 +40），落在"待确认"区间。

三次采样 + Wi-Fi 辅证 + 校园网辅证才能到 70 分自动通过。

**这意味着现场可能有大量签到落到"待确认"** —— 而每一条都要发布者手动复核。
如果比例过高，发布者的负担会失控，这个功能在现场就不可用。

**请重点记录第 4 项的：**
- 室内定位的**精度数值**通常是多少米？
- 一次活动里大约**多少比例**的签到落到"待确认"？

如果比例过高，需要调整的方向有两个（都很简单，等你数据出来再定）：
1. 把自动通过门槛从 60 降到 50；
2. 给"围栏内 + 精度良好"更重的分（当前只给 40）。

> 这个数字我**无法在模拟器上得出**：模拟器是注入坐标，没有真实的多径与冷启动行为。

---

## 第 3 步：管理端侧要一起看的

用管理端 App 配合做：

| 验证项 | 怎么测 |
|---|---|
| 看板四态计数正确 | 用户端签几个人后，看「已签到 / 待确认 / 尚未签到」是否与预期一致 |
| 看板自动刷新 | 停在看板页 20 秒以上，观察是否自动更新（不手动刷新） |
| 名单导入 | 从 Excel 复制两列粘贴进「批量导入」，看逐行报告 |
| 发邀请码 | 生成后用码在用户端绑定；**再开列表确认只显示掩码** |
| 签到复核 | 对"待确认"的记录复核通过/驳回；驳回不填原因应被拦 |
| 考勤汇总 | 查看每行的完成率与"证据不足/缺席"是否分开显示 |

---

## 遇到问题时看哪里

**App 里连不上服务端** → 界面顶部会有一条红色**「构建配置有问题」**提示
（如果 `API_BASE_URL` 少了 `/api`）。否则看是否 404 / 连接超时。

**想看服务端日志**：

```powershell
Get-Content 'D:\VOLUNTEER SYSTEM\mock_server\.data-phone\o.log' -Tail 30
Get-Content 'D:\VOLUNTEER SYSTEM\mock_server\.data-phone\e.log' -Tail 30
```

**重置演示数据**（把手机上的数据和服务端都归零）：

```powershell
# 停掉 Mock
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -like '*server.js*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 删数据目录后重启，会重新写入种子数据
Remove-Item -Recurse -Force 'D:\VOLUNTEER SYSTEM\mock_server\.data-phone'
cd 'D:\VOLUNTEER SYSTEM\mock_server'
$env:MOCK_DATA_DIR = 'D:\VOLUNTEER SYSTEM\mock_server\.data-phone'
node src/server.js
```

手机上再「解除绑定」即可回到绑定页。

**看 App 的运行日志**（release 包没有调试输出，需要时用 debug 包）：

```powershell
& 'D:\dev-tools\android-sdk\platform-tools\adb.exe' logcat -s flutter:* ActivityManager:E
```

---

## 需要我做什么

你在真机上跑完后，把结果告诉我（**第 2 步表格里的 10 行**，尤其是第 4 项的精度与比例）。

我会据此：
- 如果有功能性问题 → 直接修；
- 如果"待确认"比例过高 → 调整评分门槛或权重，并同步更新测试；
- 如果一切正常 → 更新 `docs/acceptance-checklist.md`，把真机项从"待确认"改成"已验证"。

---

## 附：连不上时的排查顺序

1. `adb devices -l` 是否能看到设备（看不到 → 数据线/驱动/USB 调试）
2. 手机浏览器能否打开 `http://192.168.72.34:8080/api/health`
3. 不能打开 → 检查防火墙规则是否加成功：
   `Get-NetFirewallRule -DisplayName "Volunteer Mock 8080"`
4. 仍不行 → 改用 `adb reverse` 方案 A
5. App 内报"接口不存在" → `API_BASE_URL` 少了 `/api` 后缀
6. App 内报"没有权限" → 用的是别的设备指纹登录的活动（归属隔离），
   请确认管理端与用户端是同一台电脑的同一个 Mock
