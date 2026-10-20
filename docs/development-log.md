# 开发记录（原 README）

> 这份文档是开发过程中的**进度与验收记录**，保留下来是为了让后来者看到
> "当时做到哪一步、依据是什么、哪些地方还没验证"。
>
> 面向使用者的说明请回到根目录 [README.md](../README.md)；
> 面向部署的说明见 [部署说明](../tools/deploy/部署说明.md)。

---
# 志愿活动信息平台

本仓库包含**两个阶段**的成果：

| 阶段 | 内容 | 文档 |
|---|---|---|
| **移动端** | 管理端 App（软件一）+ 用户端 App（软件二）+ 服务端 Mock | 本文档 |
| **网页端与服务端** | 同步服务（Node.js）+ Web 只读前端（Vue 3）+ 部署包 | [`docs/web-server.md`](docs/web-server.md) |

> 移动端按《移动端应用开发方案（最终版）》开发；网页端按《网页开发方案（最终版）》开发。
> 两者共用 [`contract/constants.js`](contract/constants.js) 这一份契约定义。

---

# 第一部分 · 移动端

> 服务端尚未就绪时，本仓库自带一个**按契约实现的服务端 Mock**，
> 两端 App 可以完全独立开发与联调（方案 §1.4）。

---

## 一、当前进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| **环境** | Flutter 3.47.7 / Dart 3.13.5、JDK 17、Android SDK 36 | ✅ 已就绪 |
| **服务端 Mock** | 全部端点 + 判定逻辑 + **159 项**回归测试 | ✅ 已完成 |
| **共享内核** | 领域模型、契约常量、错误码、坐标/时间口径（**154 项**测试） | ✅ 已完成 |
| **契约对齐** | 路径、报文、错误码、分页全面对齐《网页开发方案》§6 | ✅ 已完成 |
| **A1** | 设计系统 + 应用骨架（主题、状态映射、DI、导航、权限、离线横条） | ✅ 已完成 |
| **构建** | 两端 release APK 均在 **37s** 内构建成功 | ✅ 已验证 |
| **A3** | 用户端 App：绑定 / 活动 / 签到 / 在岗确认 / 我的记录 | ✅ 已完成 |
| **A2** | 管理端 App：工作台 / 看板 / 名单与导入 / 复核 / 考勤 / 导出 | ✅ 已完成 |
| **A4** | 权限拒绝路径、弱网与离线、脚本可复现 | ✅ 已完成（真机项待确认） |
| **A5** | 内部测试版 APK（release 分 ABI，15–19 MB） | ✅ 已完成 |

**测试总览**：
Mock **159** · shared_core **154**（含 30 项端到端联调）· shared_ui **33** ·
user_app **16** · admin_app **19**
（`analyze --fatal-infos` 在全部 5 个包/应用上零告警）

**验收对照**：A1 – A23 共 23 条**全部有对应测试**
（含 A22「默认邀请码 1111」），逐条映射见
[`docs/acceptance-checklist.md`](docs/acceptance-checklist.md)。

**内部测试版产物**（release，`--split-per-abi`）：

| 应用 | armeabi-v7a | arm64-v8a | x86_64 |
|---|---|---|---|
| 用户端 | 15.2 MB | **17.7 MB** | 19.1 MB |
| 管理端 | 15.3 MB | **17.8 MB** | 19.2 MB |

> debug 包是 178 MB（全架构 + 调试符号）。**分发务必用 release**，体积差十倍。

一键构建（自动核对权限）：

```powershell
tools\build-release.cmd http://<开发机局域网IP>:8080/api both
```

**构建产物权限（实测 `aapt2 dump permissions`）**：

| 权限 | 用户端 | 管理端 |
|---|---|---|
| `INTERNET` / `ACCESS_NETWORK_STATE` / `ACCESS_WIFI_STATE` | ✅ | ✅ |
| `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` | ✅ | ❌ 显式移除 |
| `ACCESS_BACKGROUND_LOCATION` | ❌ | ❌ |

> 后台定位在两端都不存在 —— 这是方案 §7「只按需采集，不做持续轨迹」
> 在**构建产物层面**的证据，不只是文档承诺。

> **验收对照表见 `docs/acceptance-checklist.md`**（A1–A23 逐条对到可执行的测试）。
> 设计与骨架见 `docs/a1-design-system.md`；管理端见 `docs/a2-admin-app.md`；
> 构建环境问题见 `docs/build-environment.md`。


### App 里有什么

**用户端**（三个底部标签）

| 标签 | 内容 |
|---|---|
| **活动** | 活动信息 + 签到入口（窗口未开/已关时给出原因与下一步） |
| **在岗** | 在岗抽查确认，**一个按钮、零输入**，带服务端时间校正的倒计时 |
| **记录** | 签到/抽查记录 + **逐条列出**的待上传队列（含失败原因与手动重试） |

**管理端**（列表 → 工作台 → 功能页三层）

| 页面 | 内容 |
|---|---|
| **活动列表** | 进行中活动置顶，点击进工作台 |
| **工作台** | 活动状态、签到概况、状态流转（发布/开始/结束/取消）、五个功能入口 |
| **现场看板** | 四态计数（可点击筛选）、名单、免责声明、留存期提醒；20 秒前台轮询 |
| **名单** | 粘贴式批量导入（逐行报告）、发一次性邀请码（明文仅一次）、软删除 |
| **签到复核** | 评分构成摊开、距离与精度并排、驳回必须填原因 |
| **考勤汇总** | 分类计数、每行完成率、"证据不足"与"缺席"严格分开 |
| **导出** | 直接下载 CSV 的地址与用法说明（默认脱敏） |

### 端到端联调层

`packages/shared_core/test/` 下的 `e2e_*_test.dart` 用
**真实 Dart 客户端**打**真实 Mock 进程**，不做任何 mock，覆盖
用户端与管理端的全部关键流程。

这一层不是形式主义：**已发现的 9 个缺陷里有 7 个是它找到的**，
而这些问题在单测里全是绿的——因为它们验证的是"我的解析逻辑自洽"，
验证不了"我发的报文服务端真的认"。

（Mock 未启动时这些测试整体跳过，不报失败。）



---

## 二、目录结构

```
├── apps/
║   ├── admin_app/            管理端 App（软件一）
║   └── user_app/             用户端 App（软件二）
├── packages/
│   ├── shared_core/          领域模型 + 契约常量（纯 Dart，零 Flutter 依赖）
│   ├── shared_ui/            设计系统、应用骨架与通用组件
│   └── shared_platform/      定位、安全存储、设备指纹、网络状态
├── mock_server/              服务端 Mock（零依赖 Node）
├── docs/
│   ├── decisions.md                     ★ 已拍板的决策及其影响
│   ├── a1-design-system.md              ★ A1 设计系统与骨架说明
│   ├── build-environment.md             ★ 构建环境问题与处置（镜像/Kotlin）
│   ├── contract-alignment-web-plan.md   ★ 与网页方案的契约对齐记录
│   ├── contract-assumptions.md          推导与待确认清单（多已被网页方案回答）
│   ├── open-issues-app.md               方案内部矛盾与空白
│   └── web-development-plan.md          《网页开发方案》存档（下一阶段开发依据）
└── tools/
    ├── env.ps1               环境变量（需先解除执行策略限制）
    ├── flutter.cmd           Flutter 命令包装
    └── dart.cmd              Dart 命令包装
```

> **契约依据**：《接口契约》尚未提供，但《网页开发方案》§6 已给出报文级约定
> （响应信封、错误码、鉴权、分页、关键接口），因此**以它为准**。
> 已据此改正 6 处实现缺陷，详见 `docs/contract-alignment-web-plan.md`。

---

## 三、构建须知：网络与镜像

本机实测 `services.gradle.org` **不可达**（下载停滞在 0 MB），
`maven.google.com` 也不可达，而 AGP / AndroidX / Kotlin 插件全在 Google 的
Maven 仓库里。因此仓库内已固定以下配置：

| 项 | 配置 |
|---|---|
| Gradle 发行包 | `mirrors.cloud.tencent.com/gradle/gradle-9.3.1-bin.zip`（130MB，取代官方 224MB 的 `-all`） |
| Maven 仓库 | 阿里云 `google` / `central` / `gradle-plugin` 镜像在前，官方源在后作兜底 |
| Kotlin 编译 | `in-process` 执行 + `incremental=false`（绕开 Windows 上的增量缓存占用） |

配置位置：`apps/*/android/gradle/wrapper/gradle-wrapper.properties`、
`apps/*/android/settings.gradle.kts`、`apps/*/android/build.gradle.kts`、
`apps/*/android/gradle.properties`。

**不要改回官方源**：那会让首次构建静默卡住（没有任何报错，只是长时间不动）。

### 构建命令

```bash
# 用户端（连本机 Mock；模拟器用 10.0.2.2 指向宿主机）
flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:8080/api

# 真机：换成开发机的局域网 IP
flutter build apk --debug --dart-define=API_BASE_URL=http://192.168.x.x:8080/api
```

> `API_BASE_URL` **必须带 `/api` 后缀**（契约的 Base URL 形如 `https://host/api`）。
> 少了它所有请求都会 404，而提示会是"接口不存在"这种误导性信息。
> App 启动时会自检这一项，并在界面上明确显示问题（见 `AppServices.selfCheck`）。




### 为什么 `shared_core` 不依赖 Flutter

领域模型、错误码、坐标系与时间口径是**三端共用**的（服务端也用它）。
让它保持纯 Dart，就能：
* 在 Mock 与单元测试里直接复用，不必拉起 Flutter 环境；
* 从机制上防止"顺手把某个 Widget 依赖写进模型层"。

---

## 三、快速开始

### 1. 环境准备

工具链装在 `D:\dev-tools`（Flutter、JDK 17、Android SDK 36）。
路径集中配置在 `tools/flutter.cmd` 与 `tools/env.ps1`，换机器只改这两处。

> ⚠️ 本机 PowerShell 执行策略禁止运行 `.ps1`，所以**用 `.cmd` 包装器**：
> ```powershell
> tools\flutter.cmd --version
> tools\flutter.cmd doctor
> ```

### 2. 启动服务端 Mock

```powershell
node mock_server/src/server.js
```

启动后会打印**可用于真机联调的局域网地址**和对应的 `--dart-define` 参数。
详见 `mock_server/README.md`。

### 3. 跑两端 App

```powershell
cd apps\user_app
..\..\tools\flutter.cmd run --dart-define=API_BASE_URL=http://192.168.x.x:8080
```

### 4. 跑测试

```powershell
node mock_server/test/smoke.js                    # 服务端判定逻辑，107 项
cd packages\shared_core ; ..\..\tools\dart.cmd test   # 共享内核单测
```

---

## 四、服务端地址配置（方案 §1.4 硬性要求）

**服务端地址是构建配置项，代码中不得硬编码域名、IP、端口。**

App 通过 `--dart-define` 接收，并支持 dev / test / prod 三环境切换：

```powershell
# 开发（本机 Mock）
tools\flutter.cmd run --dart-define=ENV=dev --dart-define=API_BASE_URL=http://10.0.2.2:8080

# 联调（局域网真机）
tools\flutter.cmd run --dart-define=ENV=test --dart-define=API_BASE_URL=http://192.168.1.5:8080

# 生产（服务器租用后，只需换参数，不改代码）
tools\flutter.cmd build apk --release --dart-define=ENV=prod --dart-define=API_BASE_URL=https://api.example.edu.cn
```

`10.0.2.2` 是 Android 模拟器访问宿主机的固定地址。

同时预留接口版本协商头 `X-Api-Version` / `X-Client-Version`（方案 §1.4）。

---

## 五、三条不可协商的实现约束

这三条是方案里明确写了、且违反会造成现场事故的，已落实到代码注释与测试中：

### 1. 签到判定权在服务端

方案 §2：「**一律服务端判定**，客户端只上报证据」。

* 客户端**不得**复制评分逻辑；`shared_core` 里没有任何判定函数；
* 服务端返回前，界面只能显示「提交中」（验收 A15）；
* 管理端复核时展示的评分构成（`scoreBreakdown`）来自服务端，不是客户端算的。

### 2. 坐标一律 WGS-84

方案 §6.1。改用高德/腾讯/百度 SDK 时必须先转换——混用会让围栏整体偏移
50～500m，直接导致签到误判（§13-A7、验收 A14）。

* 转换集中在 `GeoTransform`；
* `GeoPoint.fromSystem()` 要求在构造时声明来源坐标系；
* 偏移异常识别在 `CoordinateShiftDetector`，并有单测覆盖。

### 3. 位置按需采集，不做轨迹

方案 §7：「位置**仅在签到与抽查时刻按需采集，不采集轨迹、不后台持续定位**」。

* 不申请 `Always` 定位权限，只用「使用时」；
* 定位只在点击签到/响应抽查的那一刻采集（3 次采样约 3 秒）；
* 不引入任何后台定位能力。

---

## 六、已确认决策与需要你确认的事项

**已拍板的决策**记录在 `docs/decisions.md`：

| 决策 | 内容 | 影响 |
|---|---|---|
| D-1 | 末次抽查留白 **30 分钟** | 2 小时活动=3 次（依验收 A20） |
| D-2 | **不启用动态签到码** | ⚠️ 验收 A16 预期文本需改 |
| D-3 | 导出**默认脱敏**，可显式开启完整号码并留审计 | 新增 `GET /auth/admin/export-audits` |
| D-4 | 以《网页开发方案》§6 作为契约依据 | 已改正 4 处实现差异 |
| D-5 | 签到窗口 **提前 30 / 延后 60 分钟** | 采用网页方案冻结版字段字典 |
| D-6 | 抽查任务**只为已签到者生成** | 采用网页方案；引入"先签到后抽查"时序约束 |
| D-7 | 考勤 `partial` 阈值 **完成率 ≥ 0.7** | 采用网页方案 §6.4.7 |
| D-8 | 接口路径与报文结构**全部对齐网页方案** | **进行中** |

**仍需《接口契约》确认的**：见 `docs/contract-assumptions.md`。
（其中响应信封、错误码、分页、签到窗口、抽查对象、汇总阈值已由网页方案回答。）

### D-8 待办：路径与报文对齐

| 我当前实现 | 网页方案 |
|---|---|
| `POST /activities` + `PATCH /activities/{id}` | `POST /activities:upsert`（含 `batch[]`） |
| `POST /activities/{id}/start\|finish\|cancel` | `POST /activities/{id}:transition` |
| `/activities/{id}/attendance/tasks/{tid}/respond` | `POST /attendances/{taskId}:confirm` |
| `POST /activities/{id}/exports`（建任务→轮询） | `GET /activities/{id}/export?format=csv` |
| 扁平签到报文 | 嵌套 `location`/`network`/`device`；`method: geo` |
| 无前缀 | 统一 `/api` 前缀 |
| — | `GET /changes?since=`（增量同步） |


---

## 七、免责与定位

本平台是**活动发布与参与的协作平台**，**不作为志愿时长统计与认定的权威依据**。

因此：
* 数据的**准确性必须保证**（否则组织者无法协调现场）；
* **保密性按「合理即可」处理**；
* **考勤结果只作现场管理参考，不自动产生任何时长扣减或权益影响**。

方案已明确承认的三条局限（不是缺陷，是取舍）：
1. GPS 可被模拟定位工具伪造 —— 处理方式是「检测到即强制转人工」，而不是假装不存在；
2. 室内定位精度不足（30～100m 漂移）—— 需实测（V-6）后决定是否降级；
3. **不启用推送** —— 志愿者需主动打开 App 查看待确认任务；整场未打开 App 时，
   抽查会全部记为未响应，所以考勤结果只作参考，且必须保留人工复核与现场补录。

---

# 第二部分 · 网页端与服务端

按《网页开发方案（最终版）》开发，与移动端共用 `contract/constants.js`。

> **本阶段不搭建生产服务器**（方案 §8 开篇）。开发与联调在本地完成，
> 生产服务器后续租用；届时按 §8 的对接规格执行，**代码与配置无需改动**。

## 一、当前进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| **契约层** | `contract/constants.js`：错误码、枚举、默认值、文案（三端共用，无逻辑） | ✅ 已完成 |
| **服务端** | Node.js 同步服务：配置化、存储抽象层、SQLite 适配器、迁移与种子 | ✅ 已完成 |
| **只读接口** | 列表（筛选/分页/统计）、详情、部门字典、健康检查、契约自述 | ✅ 已完成 |
| **导出** | 服务端 CSV 导出（UTF-8 BOM、RFC 5987 中文名、默认脱敏） | ✅ 已完成 |
| **服务端测试** | **63 项**，含配置校验、schema 地基、信封、错误码、留存期、CSV 转义、防漂移 | ✅ 全通过 |
| **Web 前端** | Vue 3 + Element Plus + ECharts：列表页 / 折叠详情 / **收藏页** / NotFound | ✅ 已完成 |
| **响应式** | ≥1200 / 768–1199 / <768（移动端卡片化） | ✅ 实测无横向溢出 |
| **可部署包** | `docker-compose.yml` + `.env.example` + Nginx 配置 + 部署文档 | ✅ 已提供（**未验证**，见下）|
| **无硬编码扫描** | 方案 §11.1 验收项 | ✅ 通过（并用故意违规文件验证过扫描器有效）|

**测试总览**：服务端 **63** · 构建产物首屏 **约 109 kB（gzip）**
（方案 §8.4 的预算是约 400 kB）

## 二、怎么跑

```powershell
Copy-Item .env.example .env
cd server
node scripts/migrate.mjs      # 建表（幂等）
node scripts/seed.mjs         # 演示数据（覆盖各状态）
node src/server.js            # 启动，横幅会打印局域网地址
```

另开一个终端：

```powershell
tools\web.cmd run dev         # 前端，打开 http://127.0.0.1:5173/
```

**零额外依赖**：不需要 Docker、不需要装 MySQL、不需要编译原生模块 ——
存储用 Node 22+ 内置的 `node:sqlite`。

```powershell
cd server && npm run check    # 导入完整性 + 无硬编码 + 全部测试
```

![活动列表页](docs/images/web-list.png)

## 三、已验证 / 未验证

| 项 | 状态 |
|---|---|
| 服务端（SQLite）迁移、种子、63 项测试、四个检查脚本 | ✅ **本机实测通过** |
| 只读接口全部行为 | ✅ **本机实测通过** |
| 前端列表页 / 详情页 / 筛选 / 分页 / 统计图 / 收藏页 | ✅ **实测通过**（无头浏览器渲染验证） |
| 导出 CSV（BOM、中文文件名、默认脱敏、筛选一致） | ✅ **实测通过** |
| 响应式（390px 与 1440px，无横向溢出） | ✅ **实测通过**（CDP 量布局） |
| **MySQL 适配器** | ⚠️ **未验证** —— 本机没有 MySQL |
| **`docker-compose up`** | ⚠️ **未验证** —— 本机没有 Docker |
| **Nginx 配置** | ⚠️ **未验证** —— 本机没有 Nginx |

> 未验证的三项是**按方案写好的配置**，需要你在有相应环境的机器上首次执行时复核。
> 方案 §11.1「可部署性验收」要求的正是这个环节。
> 详见 [`docs/web-server.md`](docs/web-server.md)。

## 四、尚缺的功能

| 缺口 | 说明 |
|---|---|
| **写入接口** | P1 只做只读。上报、状态流转、名单、签到、复核、考勤属 **P2**，尚未实现 |
| **打印为 PDF** | `base.css` 已有 `@media print` 规则，但没有实际打印验证过 |
| **导出完整联系方式** | 方案 §9.1 的"显式开启才给完整值"属**管理端**能力，需同时写 `export_audit`。Web 端是公开只读，**永远只给脱敏值** |

> **关于导出**：服务端 CSV 导出已实现并实测通过 ——
> `GET /api/activities/export`（跟随列表筛选）与
> `GET /api/activities/{id}/export`（单条，字段/值两列）。
> 带 UTF-8 BOM（否则 Excel 中文乱码）、RFC 5987 中文文件名、
> 默认脱敏（实测不含完整手机号）。

