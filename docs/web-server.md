# 网页端与服务端：运行、验证与部署

对应《网页开发方案》的 P1–P3。本文档是**交付文档**，目标读者是接手的人：
照着做能跑起来、能验证、能在有服务器时部署。

---

## 0. 只想发给别人验收？用打包脚本

```powershell
node tools\build-package.mjs
```

产物在 `dist-package\`，两个 ZIP：

| 文件 | 大小 | 适用 |
|---|---|---|
| `志愿活动信息平台-网页验收包-<日期>.zip` | **33.8 MB** | **推荐**。内置 Node 运行时，对方**不用装任何东西**，解压双击 `START.cmd` 即可 |
| `同前缀-需自备Node.zip` | **0.5 MB** | 对方已装 Node 22+ 时用 |

包内结构：

```
START.cmd            双击启动（会自动打开浏览器）
server/              同步服务源码（零外部依赖）
web/dist/            已构建的前端（对方不需要 build）
contract/            契约常量
data/                空目录，首次启动自动建库并写入演示数据
node/                Node 运行时（仅"含运行时"版本）
docs/                部署与验证文档
使用说明.md          给验收人看的中文说明
```

**为什么要把 Node 一起打包**：`node:sqlite` 需要 Node 22+。
让验收人装 Node 并把版本配对，会把"验收"变成"配置环境"，
这是最现实的失败点。33.8 MB 换"双击就能跑"，值得。

### 打包脚本做了什么自检

它不只是压缩文件 —— 它会**用打好的包真实启动一次**并请求页面，
因此下面这些坑不会流到验收人手里：

```
✅ API /api/health 正常（driver=sqlite）
✅ 首页 HTML 由包内静态服务返回
✅ 前端资源可加载：/assets/index-*.js
✅ 首次启动自动写入演示数据（6 条可见）
✅ 演示数据覆盖四种状态
✅ 路径穿越被拒绝
✅ CSV 导出可用（含表头）
✅ CSV 含中文表头（UTF-8 编码正确）
✅ 契约自述可用（7 个端点）
```

这套自检抓到了三个真问题（都修掉了）：
`node.exe` 实际在 `node\bin\` 而不是 `node\`；
首启后是空库、验收人只能看到空页面；
以及自动播种最初把 `test` 环境也算进去，导致 4 个测试失败。

### 服务端顺便发静态文件

`STATIC_DIR` 指向 `web/dist` 后，同步服务会**同时提供页面与 API** ——
只暴露一个端口、天然同域、不需要 CORS 也不需要 Nginx。
这正是"发给别人验收"能做到单进程单端口的原因。

生产部署仍建议 Nginx 直发静态资源（性能更好），把 `STATIC_DIR` 设为 `off` 即可。

### 首次启动会自动写入演示数据

| 环境 | 是否自动写入 | 理由 |
|---|---|---|
| `dev` | **是** | 验收/演示需要看得到东西；空页面无法验收筛选、统计、导出 |
| `test` | **否** | 测试要断言空库行为；自动播种会让 4 个用例失败 |
| `prod` | **否** | 真实部署凭空多出假活动会污染数据 |

只写**空库**，已有数据绝不动。`SEED_ON_START=true/false` 可覆盖。

实测确认：

```
场景1 dev  + 空库 → 活动数 6   （自动播种生效）
场景2 prod + 空库 → 活动数 0   （不播种，符合预期）
```

---

> ## ⚠️ 先说清楚哪些经过验证、哪些没有
>
> 这一节不是免责套话 —— 它决定了你该信任什么、该重点复核什么。
>
> | 项 | 状态 |
> |---|---|
> | 服务端（SQLite）迁移、种子、63 项测试 | ✅ **本机实测通过** |
> | 只读接口（列表 / 详情 / 统计 / 部门 / 健康 / 契约自述） | ✅ **本机实测通过** |
> | CSV 导出（BOM、中文文件名、默认脱敏、筛选一致） | ✅ **本机实测通过** |
> | Web 前端列表页、详情页、收藏页、筛选、分页、统计图、导出按钮 | ✅ **本机实测通过**（无头浏览器渲染验证） |
> | 响应式（≥1200 / 768–1199 / <768） | ✅ 实测无横向溢出（390px 与 1440px） |
> | 无硬编码凭据扫描 | ✅ **本机实测通过**（并用故意违规的文件验证过扫描器有效） |
> | **MySQL 适配器**（DDL 与查询） | ❌ **未验证** —— 本机没有 MySQL |
> | **`docker-compose up`** | ❌ **未验证** —— 本机没有 Docker |
> | **Nginx 配置** | ❌ **未验证** —— 本机没有 Nginx |
> | 生产环境 HTTPS / 域名 / 备份 | ❌ 随服务器租用后执行 |
>
> 前四项有实测依据；后四项是**按方案写好的配置**，需要你在有相应环境的机器上
> 首次执行时重点复核。方案 §11.1 的"可部署性验收"要求的正是后者。

---

## 1. 组件结构

```
contract/constants.js        三端共用契约（唯一来源，无逻辑）
        ▲
        │  import（同一份文件）
        │
server/  同步服务（Node.js）  ──►  web/  Vue 3 只读前端
        │                          │
        └──► SQLite（开发）        └──► ECharts（统计图）
             MySQL（生产）
```

| 目录 | 作用 |
|---|---|
| `contract/` | 契约常量：错误码、枚举、默认值、文案。服务端与前端 import **同一份文件** |
| `server/` | 同步服务。存储抽象层 + SQLite/MySQL 双适配器 |
| `web/` | Vue 3 + Element Plus + ECharts，**只读** |
| `deploy/` | Nginx 配置、MySQL 初始化 |
| `mock_server/` | 移动端阶段的 Mock（仍在用，与 `server/` 是两套独立实现） |

> **为什么服务端与前端共用 `contract/` 而不是各写一份**
>
> 移动端阶段踩过：服务端下发 `success`、客户端枚举期望 `checked_in`，
> 结果**看板上所有已签到的人都显示成"未知"** —— 不报错，只是安静地显示错的东西。
> 同一份文件 import 之后，词表不一致在结构上就不可能发生。

---

## 2. 本机跑起来（零额外依赖）

只需要 Node 22+。**不需要 Docker，不需要装 MySQL。**

```powershell
# 仓库根目录
Copy-Item .env.example .env

# 1) 建表
cd server
node scripts/migrate.mjs

# 2) 写演示数据（覆盖各状态，便于验证筛选与统计）
node scripts/seed.mjs

# 3) 启动
node src/server.js
```

启动横幅会打印可直接用的地址：

```
  志愿活动信息平台 · 同步服务
  监听          http://0.0.0.0:8080
  存储          sqlite（D:\VOLUNTEER SYSTEM\server\data\volunteer.db）
  接口前缀      /api

  局域网地址（手机与电脑需在同一网络）：
    http://10.3.215.117:8080/api
```

前端：

```powershell
# 仓库根目录（tools\web.cmd 会把 node 加进 PATH —— 本机 node 默认不在 PATH 上）
tools\web.cmd run dev
```

打开 **http://127.0.0.1:5173/**。

### 一条命令起停整套（推荐）

```powershell
tools\dev-stack.ps1            # 启动两个服务并显示状态
tools\dev-stack.ps1 status     # 只查状态（端口 + 可达性）
tools\dev-stack.ps1 stop       # 停掉占用 8080 / 5173 的进程
tools\dev-stack.ps1 restart    # 停 → 起
```

实测：`restart` 约 **3.8 秒**完成，退出码 0，两个服务均 `listening` 且可达。

> **为什么需要这个脚本**
>
> 我起初把两个服务当作"后台任务"启动，结果它们跟着那一轮会话一起结束了 ——
> 用户打开网址时发现打不开，而数据与依赖其实都好好的。
> 这个脚本用 `Start-Process` 把它们启动成**脱离启动器**的进程，
> 启动器退出后服务继续运行。
>
> 写这个脚本时踩了三个坑，都记在脚本注释里，因为它解释了为什么代码长那样：
>
> 1. `cmd /c start /b` 在本环境不成立（stdin 被重定向，报
>    "Input redirection is not supported"）；
> 2. `Start-Process -RedirectStandardOutput` 会让子进程继承启动器的管道，
>    于是**启动器在打印完状态后挂住不退出**（实测卡满超时）；
> 3. 本仓库路径含空格（`VOLUNTEER SYSTEM`），把含空格的路径传给
>    `cmd.exe /c` 而没精确加引号，会得到
>    `'D:\VOLUNTEER' 不是内部或外部命令` —— 而服务因此根本起不来。
>
> 最终做法：把重定向与路径规范化都放进 `tools\run-stack.cmd`，
> 启动器只 `-WorkingDirectory tools\` + 传相对名 `run-stack.cmd`，
> **不让任何带空格的路径穿过 `cmd /c` 边界**。

> **为什么前端不直接请求 `http://127.0.0.1:8080`**
>
> 那会触发跨域，而服务端不该为了开发方便就放开 CORS。
> 开发期由 Vite 代理 `/api` → `8080`，浏览器只看到同源；
> 生产由 Nginx 做同样的事。**开发与生产同域**，前端代码不必区分环境
> （方案 §8.2 的要求）。

---

## 3. 怎么验证它真的在工作

### 3.1 服务端

```powershell
cd server
node --test "test/**/*.test.mjs"     # 63 项
node scripts/check-imports.mjs       # 每个模块能否解析
node scripts/check-hardcoded.mjs     # 无硬编码地址/端口/凭据
node scripts/db-smoke.mjs            # schema、唯一约束、事务、序号游标
```

一条命令跑完：`npm run check`

### 3.2 前端

```powershell
tools\web.cmd run build              # 生产构建
```

构建后应看到（实测值）：

```
dist/assets/index-*.js              150.77 kB │ gzip:  59.37 kB
dist/assets/ActivityListPage-*.js   266.91 kB │ gzip:  83.18 kB
dist/assets/StatsChart-*.js         458.56 kB │ gzip: 154.25 kB   ← 异步，不在首屏
dist/assets/el-button-*.js           34.32 kB │ gzip:  12.00 kB
```

**首屏关键路径约 106 kB（gzip）**，低于方案 §8.4 的 ~400 kB 预算。

> ⚠️ 这三行数字要盯着。中途有过两个把预算撑爆的写法，都是实测才发现的：
> `manualChunks: { element: ['element-plus'] }` 会让 barrel 文件被整体打包
> （element chunk gzip **335 kB**）；从主入口 `import { ElMessage }`
> 会拉进整个组件库。详见 `web/vite.config.js` 里的说明。

### 3.3 界面（无头浏览器渲染验证）

只跑 `vite build` 成功**不等于**页面能用 —— 组件名写错、运行时编译缺失这类问题
构建期看不出来。用无头浏览器实际渲染一次：

```powershell
# Edge/Chrome 的 headless 模式，DOM 里应出现真实活动标题
& "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" `
    --headless=new --disable-gpu --virtual-time-budget=10000 `
    --user-data-dir="$env:TEMP\vol-edge" `
    --dump-dom 'http://127.0.0.1:5173/' | Select-String '图书馆书架整理'
```

更可靠的方式是用 CDP 量布局与截图（本项目就是这样发现并修掉了
窄屏日期选择器被撑到 250px 高的问题）：

```powershell
# 用 CDP 的 Emulation.setDeviceMetricsOverride 精确设置视口，
# 再 Page.captureScreenshot。**不要**用 --window-size ——
# 实测它的视口宽度与窗口宽度不一致（390 的窗口量出 494 的视口），
# 会得出错误的"溢出"结论。
```

---

## 4. 部署到服务器

### 4.1 有 Docker 的机器

```bash
cp .env.example .env
# 至少改：DB_PASSWORD（若用 MySQL）、TOKEN_SECRET

docker compose up -d                    # SQLite 模式，起来就能用
docker compose --profile mysql up -d    # MySQL 模式（方案 §3 指定的生产库）

docker compose logs -f server
curl http://127.0.0.1:8080/api/health
```

> ⚠️ **这一段未在本机验证**（没有 Docker）。首次执行请留意：
> * 镜像基于 `node:22-bookworm-slim`（不是 alpine）—— 因为 `node:sqlite`
>   需要 Node 22+，且避免 musl 上的额外验证；
> * 容器内 `TZ=Asia/Shanghai` 已设 —— 方案 §8.3 注明时区错误会让
>   **签到窗口集体偏移**，这是必须在前面的项；
> * MySQL 的建表由 `scripts/migrate.mjs` 在每次启动时幂等执行，
>   `deploy/mysql-init/` 只做字符集与授权。

### 4.2 按方案的对接规格（§8.2–§8.5）

| 项 | 要求 | 本项目的对应 |
|---|---|---|
| 端口 443 | HTTPS（Nginx）对外 | `deploy/nginx.conf` |
| 端口 8080 | 同步服务，**仅内网** | `PORT` 可配置；compose 默认映射到宿主机便于联调，生产应去掉该映射 |
| 前后端同域 | 规避 CORS | 前端用相对路径 `/api`；Nginx 反代 |
| 时区 | `Asia/Shanghai` + **NTP 必须启用** | 容器已设 TZ；**NTP 需在宿主机配置** |
| 数据库 | MySQL 5.7/8.0，`utf8mb4` | `deploy/mysql-init/01-init.sql` |
| 容量 | 2 核 4G / 40G SSD / ≥5Mbps | 见 §8.4 的两条红线 |

> **两条红线**（方案 §8.4 明确）：**2 核 2G 不足**（Nginx + 服务 + MySQL ≈ 2G，
> 易 OOM）；**1 Mbps 不足**（首屏约 400 KB，数人同时打开即打满）。

### 4.3 可移植性要求（方案 §8.1，本阶段就必须满足）

| 要求 | 状态 | 证据 |
|---|---|---|
| 地址/端口/凭据全走配置，代码不硬编码 | ✅ | `check-hardcoded.mjs` 通过；21 个文件全扫 |
| 提供 `docker-compose.yml`，一条命令拉起 | ✅ 已提供 / ⚠️ 未验证 | `docker-compose.yml` |
| 提供 `.env.example` 与部署文档 | ✅ | `.env.example`、本文档 |
| 数据库初始化脚本随仓库 | ✅ | `server/src/db/schema.js`（单一 DDL 来源）+ `deploy/mysql-init/` |
| 本地/容器/云服务器同一套命令 | ✅ | 都是 `node src/server.js`（容器里 `CMD` 相同） |
| **端口与配置可不改代码变更** | ✅ | `PORT`/`HOST` 等全部读环境变量；有测试断言 |

---

## 5. 与移动端的契约一致性

`server/` 与 `mock_server/` 是**两套独立实现**，但共用同一份契约：

| 项 | 一致性保证 |
|---|---|
| 错误码 | `contract/constants.js` 只授权 8 个；服务端有测试断言只使用这 8 个 |
| 响应信封 | `msg` + `data` + `errors` + `traceId` + `serverTime`；有测试断言 `msg === message` |
| 分页 | `page` 从 1 起、`size` 默认 20 上限 100；有测试断言超限时**回显钳后值** |
| 状态词表 | 服务端 `checkin.status` 与名单行 `checkinStatus` **同一套值** |
| 时间格式 | 一律 ISO 8601 含偏移（`+08:00`），有测试断言不以 `Z` 结尾 |
| 留存期 | 终态 + 7 天不可访问，列表与详情**同一口径** |

### ⚠️ 一处**不能**照抄移动端的做法

`mock_server` 是"按契约实现、用于独立开发"的 Mock，它有两个**不能带进生产**的性质：

1. **管理员密码明文比较**（其源码注释里已标明"仅开发用"）；
2. 错误处理不够严（为对外服务设计时需更谨慎）。

因此 `server/` 不是把 `mock_server` 改名 —— 判定逻辑与路由契约可以参考，
但**存储与鉴权是重写的**。这一点在方案 §11.1 的验收里也有对应：

> App 包体静态扫描确认无任何内置长期密钥、**无硬编码默认邀请码**

---

## 6. 已知缺口与后续

| 缺口 | 说明 |
|---|---|
| **写入接口未实现** | P1 只做了只读（列表 / 详情 / 统计 / **导出**）。上报、状态流转、名单、签到、复核、考勤属 **P2**，尚未实现 |
| MySQL 适配器未验证 | 需要一台有 MySQL 的机器跑 `DB_DRIVER=mysql npm run migrate && npm test`。DDL 已做静态检查（0 问题），但未在真实 MySQL 上执行过 |
| `docker-compose up` 未验证 | 需要一台有 Docker 的机器按 §4.1 执行 |
| Nginx 配置未验证 | 需要证书文件才能启动 |
| 打印为 PDF 未验证 | `base.css` 已有 `@media print` 规则（隐藏交互控件、避免分页截断），但没有实际打印过 |
| 导出完整联系方式未做 | 方案 §9.1 的"显式开启才给完整值"属**管理端**能力，且必须同时写 `export_audit`。Web 端公开只读，**永远只给脱敏值** |

### 导出已实现（附实测结果）

| 接口 | 用途 |
|---|---|
| `GET /api/activities/export` | 导出活动列表，**跟随列表页的全部筛选参数** |
| `GET /api/activities/{id}/export` | 导出单条活动（字段 / 值两列，便于贴进文档） |

实测（对运行中的服务直接请求）：

```
HTTP 200
Content-Type: text/csv; charset=utf-8
Content-Disposition: attachment; filename="activities-2026-10-16.csv";
                     filename*=UTF-8''%E5%BF%97%E6%84%BF%E6%B4%BB%E5%8A%A8-2026-10-16.csv
BOM 字节: ef bb bf
行数: 7（1 行表头 + 6 条数据）
含完整手机号: false
含掩码号码: true
```

三处细节是踩过才知道要做的：

1. **UTF-8 BOM（`ef bb bf`）** —— 没有它，中文 Windows 的 Excel 会把
   UTF-8 中文读成乱码，使用者第一反应是"导出坏了"。有测试直接断言
   **原始字节**，而不是解码后的字符串（BOM 的意义就在字节层面）。
2. **RFC 5987 双文件名** —— `filename=` 只放 ASCII 兜底，
   中文名放 `filename*=UTF-8''...`。只写前者中文名丢失，
   只写后者老客户端拿到空文件名。
3. **CSV 转义** —— 活动标题带逗号、说明带换行都会让整行**列错位**，
   而 Excel 不报错，只是把数据摊到错误的列里 —— 那比直接失败更糟，
   因为使用者不会发现。测试覆盖逗号、双引号、换行三种情况。

> 另外踩过**路由顺序**：`/activities/export` 必须注册在 `/activities/:id`
> **之前**，否则 `export` 被当成活动 id，返回 404「活动 export 不存在」——
> 而那个错误信息看起来完全合理，很难联想到是注册顺序问题。
> 已加测试钉住（`路由：/activities/export 不被 /activities/:id 抢先匹配`）。

### 收藏页已实现

`/#/favorites`（方案 §7.3）。两个刻意的设计：

* **界面明示"仅保存在本机浏览器"** —— 这是方案里明确要求的措辞。
  不说清的话，用户换设备后找不到收藏会当成缺陷报上来。
* **失效收藏单独成组并说明原因** —— 活动有 7 天留存期，
  过期后不可访问是**正常**行为。直接混在列表里会让用户困惑
  （"这个活动怎么点不开"），而显示成"加载失败"又会诱导用户
  反复重试一个永远不会成功的请求。

实测（注入一条有效 + 一条不存在的收藏）：

```
徽标数字: 2
有效卡片数: 1
有效卡片标题: 图书馆书架整理志愿服务
失效分组标题: 已失效的收藏（1）
失效原因: 活动已不存在（可能已超过 7 天留存期，按隐私设计销毁）
```

> 这里也修了一个真 bug：模块级的收藏状态在**首次 import 时**
> 只读一次 `localStorage`，于是另一个标签页里收藏的活动在本页看不到 ——
> 表现是"收藏了但收藏页是空的"，而数据其实好好地存在。
> 已加 `reload()`，收藏页每次进入都先重读存储。

---

## 7. 换环境要改什么（唯一清单）

全部在 `.env` 里，**不需要改任何代码**：

```ini
HOST=0.0.0.0              # 监听地址
PORT=8080                 # 端口
NODE_ENV=prod             # 运行环境（prod 会收紧校验）
DB_DRIVER=mysql           # sqlite → mysql
DB_HOST=... DB_USER=... DB_PASSWORD=... DB_DATABASE=...
TOKEN_SECRET=...          # prod 必须 ≥32 字符
ADMIN_INVITE_CODE=...     # 默认 1111（方案 §12.1 既定）
CORS_ORIGIN=...           # prod 不能是 *
```

改完重启即可生效 —— 这条有测试守着
（`配置：端口可改，且不需要修改代码`）。
