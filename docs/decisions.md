# 已确认决策

> 本文件记录**用户已明确拍板**的事项，以及每项决策对方案原文、已交付代码与
> 验收用例的实际影响。与 `docs/contract-assumptions.md`（我的推导、待后端确认）
> 和 `docs/open-issues-app.md`（方案内部矛盾）区分开：
> **这里的内容不再需要讨论，是被决定了的。**

---

## D-1　末次抽查留白：30 分钟

| | |
|---|---|
| **决策** | 以「2 小时活动 3 次」为准 → 末次抽查距活动结束保留 **30 分钟** |
| **背景** | 方案 §6.2 自相矛盾：既说「末次不晚于 `endTime − 15min`」，又说「2 小时活动 3 次」。留白取 15 会算出 4 次 |
| **影响** | 抽查次数：1.5h→2 次、2h→**3 次**、3h→5 次、4h→7 次 |

**已同步实现**（无需再改）：

* `packages/shared_core/lib/src/contract/field_dictionary.dart` → `attendanceLastTaskMargin = 30min`
* `mock_server/src/constants.js` → `ATTENDANCE_LAST_TASK_MARGIN_MIN: 30`
* 两侧的 `plannedAttendanceSlots()` / `planSlots()` 与对应单测

**残留影响**：`docs/open-issues-app.md` 的 O-2 可标记为已决。

---

## D-2　不启用动态签到码 ⚠️ 影响验收用例 A16

| | |
|---|---|
| **决策** | **不实现**方案 §6.3 的动态签到码（签到码 5 分钟 / 在岗码 60 秒轮换、管理端全屏展示、预取续播） |
| **背景** | 方案 §6.3 把它定位为"降级手段"，用于室内精度不足、拒定位权限、管理端断网等情形 |

### 影响面（已全部落地）

| 位置 | 变更 |
|---|---|
| `shared_core` 的 `CheckinMethod` | 移除 `code`，保留 `gps` / `adminScan` / `manual` |
| `shared_core` 的 `CheckinCodePurpose`、`CheckinCode`、`CheckinCodeFields`、三项轮换常量 | **整体删除** |
| `CheckinDraft.checkinCode` | 删除 |
| Mock 的 `/activities/:id/checkin-code`（两个端点） | **删除**，契约自述里也移除了 |
| 错误码 `40302 checkinCodeInvalid` | 删除（App 侧与 Mock 侧同步） |
| Mock 的 `submitCheckin` | 收到 `method=gps` 以外的值 → 明确报 `10001`，**不静默按 GPS 处理** |

### ⚠️ 这会改变验收用例 A16 的预期

方案 §12-A16 原文：

> 拒绝定位权限 → 提供降级路径，不出现死路

原文列举的降级路径是三条：**动态码 / 管理端反向扫码 / 人工补录**。
去掉动态码后只剩两条，且**都在管理端**：

1. **现场核实**：发布者在看板上调用 `POST /activities/:id/checkins/manual`，
   把志愿者的 `pending_review` **升级为** `success`；
2. **人工补录**：同一端点，用于设备故障、事后补录。

**"不出现死路"这条要求仍然满足**：志愿者拒定位后提交签到，服务端不会驳回，
而是转 `pending_review`（因为无坐标 → 转人工，不是 reject），发布者现场就能救回来。
这一条已有测试覆盖（`验收 A16：拒定位权限的降级路径 —— 发布者现场核实`）。

**建议**：把 A16 的预期文本改为
「拒绝定位权限 → 转待人工确认，由发布者现场核实或人工补录，不出现死路」。

### 关于人工补录的语义（实现中修正过一处）

现场核实**不能新插一条签到记录**——那会让同一个人出现两条有效签到，
违反方案 §6.1「同一活动 + 同一用户一条有效签到」。

正确做法是**升级原记录**，并注意两个字段的分工：

* `method` 保留**原始采集方式**（例如 `gps`），不要改成 `manual`，
  否则审计里看不出"这条最初是怎么报上来的"；
* 人工介入用独立字段标记：`verifiedByOwner: true` + `reviewedBy` + `reviewedAt`。

---

## D-3　导出脱敏：默认脱敏 + 可显式开启完整号码（并留审计）

| | |
|---|---|
| **决策** | 导出**默认**脱敏手机号；发布者可显式勾选「包含完整联系方式」；该操作**计入审计** |
| **背景** | README §3.3 底线②要求"日志与崩溃上报不含完整手机号/学号"，但它没说导出件。发布者现场打电话催人需要完整号码，一份全掩码的名单在"催人"场景下没用 |

### 实现

| 行为 | 说明 |
|---|---|
| 默认 | `includeFullContact` 缺省为 `false`，手机号输出 `138****1234` |
| 开启 | 请求体传 `includeFullContact: true`；CSV 与 `notice` 都会明确标注「含完整联系方式」 |
| 权限 | **仅管理端**可开启。志愿者请求 → `40301` |
| 审计 | 写入 `store.db.exportAudits`，记录 `at / exportId / activityId / requestedBy / ip / rowCount`，可查 `GET /auth/admin/export-audits` |
| 默认脱敏导出 | **不进**敏感审计，避免审计日志被正常操作淹没 |

### 遗留待定

CSV 里的完整手机号一旦被转发就收不回来。当前措施是"默认关 + 显式开 + 留痕"，
但**是否还需要更硬的技术限制**（例如导出件加时效水印、每次下载都记审计而不只是生成时记）
需要你后续决定。

---

## D-4　契约文档：《接口契约》稍后提供

| | |
|---|---|
| **决策** | 用户稍后提供《接口契约》；**在此之前以《网页开发方案》§6 为契约依据**（它已给出报文级约定） |
| **影响** | 已据网页方案改正 4 处实现差异（信封字段、幂等键头、错误码、分页字段） |

**风险已被隔离**：所有契约相关代码集中在

* `packages/shared_core/lib/src/contract/`（错误码、信封、字段字典、时间与坐标口径）
* `mock_server/src/constants.js`（同一份契约的 JS 镜像）

业务代码只引用**枚举名与常量名**，不写字面量。因此换码值、改字段名时，
改动量被限制在这几个文件内，UI 与业务流程不受影响。

详见 `docs/contract-alignment-web-plan.md`。

---

## D-5　签到窗口：提前 30 / 延后 60 分钟

| | |
|---|---|
| **决策** | 采用**网页方案 §4.1**（冻结版字段字典）：`checkinWindowBefore = 30`、`checkinWindowAfter = 60` |
| **冲突** | 移动端方案 §4.2 写 15 / 15 |
| **理由** | §4.1 是标注"冻结版"的字段字典，权威性更高；移动端方案未为 15/15 给出理由；宽容窗口对现场更友好（迟到 20 分钟仍能签到） |

**影响**：志愿者可签到的时间区间从 `[开始−15, 结束+15]` 变为 `[开始−30, 结束+60]`。

**已同步**：`field_dictionary.dart`、`constants.js`。

---

## D-6　在岗抽查：只为「已签到」的人生成任务

| | |
|---|---|
| **决策** | 采用**网页方案 §4.5**：只为「已签到且在名单中」的参与者创建抽查任务 |
| **冲突** | 移动端方案 §6.2 写「为所有名单成员生成」 |
| **理由** | ① 抽查的目的是确认「到场的人没有中途离开」，没到场的人根本没来，给他记一串 `missed` 毫无信息量；② 会给考勤分母灌水，而方案 §13-A5 已承认抽查可能误判（"通知没到"被记成"人不在"），分母越大越容易冤枉人；③ 与网页方案 §6.4.7 的汇总口径更自洽 |

**影响面（重要）**：

* **时序要求**：必须先有签到，才有抽查任务。任何"先生成任务再签到"的实现都是错的。
  种子数据与测试夹具都已按此顺序调整。
* `success` 与 `pending_review` 都算"已签到"（后者是"证据不足待人工确认"，
  人在场是大概率；若不生成抽查，人工复核一慢这人就完全不被覆盖）。
* 没签到的人不再进入在岗明细，其在岗表现由签到状态直接判定。

**已同步**：`attendance_engine.js`、`seed.js`、测试夹具（新增 `checkedIn` 开关）。

---

## D-7　考勤汇总：`partial` 阈值为 0.7

| | |
|---|---|
| **决策** | 采用**网页方案 §6.4.7**：`full`（无 missed）/ `partial`（完成率 ≥ 0.7）/ `insufficient` / `absent` |
| **冲突** | 移动端方案 §4.8 的判据是「有 missed 且 done>0 → partial」，无阈值 |
| **理由** | "3 次里完成 1 次"（0.33）与"10 次里完成 8 次"（0.8）的风险程度明显不同，不该同列 |

**完成率的分母只算已定案任务**（`done + missed`）：`pending` 尚未发生、
`excused` 被豁免，两者都不计入分母（网页方案 §5.3：「未发生的任务置 excused，**不计入分母**」）。

**已同步**：`attendance_engine.js`（新增 `attendanceRate` 字段）、测试（新增 0.6/0.8 两侧边界用例）。

---

## 决策对验收用例的影响汇总

| 用例 | 原预期 | 现状 |
|---|---|---|
| **A16** | 拒绝定位权限 → 提供降级路径（动态码 / 管理端反向扫码 / 人工补录） | ⚠️ **需改文本**：降级路径缩为后两条（现场核实 + 人工补录），"不死路"仍成立 |
| A20 | 2 小时活动 3 次抽查 | ✅ 一致（依 D-1 取 30 分钟留白） |
| A18 | 在岗抽查超时 → `missed` | ✅ 仍成立，但**只针对已签到者**（依 D-6） |
| 其余 A1–A23 | — | ✅ 未受影响；`40302` 已从错误码表移除，无用例引用它 |

**⚠️ 依 D-6，A18/A19 的适用前提变了**：原文没有说明"谁会被抽查"。
建议在用例里补一句「（仅对已签到的参与者生成抽查任务）」。

## 已移除的用例（原方案 §12 无对应编号，但属于 §6.3 的验收内容）

* 签到码 5 分钟 / 在岗码 60 秒轮换
* 预取续播（管理端断网续播）
* 动态码完成签到（`method=code`）

对应测试已替换为：**拒绝 `method=code`** 与 **拒定位权限的两级降级路径**。

---

## D-8　接口路径与报文结构对齐（✅ 已完成）

网页方案 §6.2/§6.4 采用的路径风格与报文结构与我此前的 REST 风格不同：

| 我原实现 | 现实现（网页方案） |
|---|---|
| `POST /activities` + `PATCH /activities/{id}` | `POST /activities:upsert`（含 `batch[]`，幂等键 `externalId`） |
| `POST /activities/{id}/start\|finish\|cancel` | `POST /activities/{id}:transition` `{from,to,reason}` |
| `POST /activities/{id}/attendance/tasks/{tid}/respond` | `POST /attendances/{taskId}:confirm`（**全局资源路径**） |
| `POST /activities/{id}/exports`（建任务→轮询） | `GET /activities/{id}/export?format=csv`（**直接下载**） |
| `GET /attendances/{id}/summary` | `GET /activities/{id}/attendance` |
| `POST /activities/{id}/participants/import` | `POST /activities/{id}/participants:import` |
| `DELETE .../participants/{userNo}` | `DELETE .../participants/{pid}` |
| — | `GET /changes?since=&limit=`（增量同步，**新增**） |
| — | `GET /export/activities`（按时间段批量导出，**新增**） |
| Base URL 无前缀 | 统一 `/api` 前缀（Mock 同时接受无前缀，便于探活） |
| 扁平签到报文 | 嵌套 `location` / `network` / `device` |
| `method: "gps"` | `method: "geo"`（`gps` 保留为兼容别名） |
| 半径默认 300、无下限 | 10～1000，按场地类型默认（室外 300 / 室内 150） |
| 无长度约束 | externalId ≤64、title ≤60、organizer ≤50、location ≤100、summary ≤120、contact ≤50 |
| 时长为 0.5～24 | `>0` 且 ≤999.9，步长 0.5 |

**实现方式**：路径常量集中到 `api_paths.dart`（Dart 侧）与
`router.js` 的路由表（JS 侧）；字段字典集中在 `field_dictionary.dart`
与 `constants.js`。业务逻辑未改。

**新增测试**：契约自述与真实路由的**防漂移检查**（改路由忘改文档会直接失败）。

### D-8 过程中发现并修掉的 6 个真实缺陷

这些都不是"对齐时顺手改的"，而是对齐后才暴露出来的 bug：

| # | 缺陷 | 症状 | 根因 |
|---|---|---|---|
| 1 | **Wi-Fi / 校园网辅证永远拿不到分** | 评分表写了 +20/+10，实际从不生效 | `buildScoreContext` 忘了填 `wifiMatched`/`campusIpMatched`，而 `scoreCheckin` 只读这两个标志、不读请求体 |
| 2 | **`/export` 全部 403** | 导出功能整个不可用 | 路由漏写 `auth`，`ctx.auth` 为空对象 |
| 3 | **`ctx.auth` 为 `null` 时崩溃** | 一个 `TypeError` 让**整个 Mock 进程退出**，客户端只看到 `ECONNRESET` | 公开路由下 `ctx.auth` 是 `null`；且错误分支引用了未导入的 `msgFor` |
| 4 | **移出名单永远失败** | 报"名单中不存在该学号"，但人明明在 | 路由参数从 `:userNo` 改名 `:pid` 后，handler 仍读 `ctx.params.userNo`（得到 `undefined`） |
| 5 | **增量同步漏数据** | 新建的活动永久同步不到 | 用毫秒时间戳当游标，同一毫秒内多条写入无法全序。**改用全局单调序号** |
| 6 | **列表不回显 `size`** | 客户端算错分页 | `size` 被压到上限时客户端不知道实际页大小 |

**关于缺陷 3 的处置**：除了修 `ctx.auth`，还加了 `process.on('uncaughtException')`
兜底。开发用的 Mock 尤其不能崩——联调时它同时服务多个客户端，
一次崩溃会让所有人以为是自己写错了。

**关于缺陷 5 的处置**：游标从 `c<毫秒>` 改为 `s<序号>`，
由 `store.nextSeq()` 分配。真实服务端用自增 ID / `ROWVERSION` 同理。
`GET /changes` 仍接受 ISO 时间作为**降级**输入（方案 §6.4.9 把"时间窗拉取"
写成降级方案），此时响应里 `approximateCursor: true` 明确标出不精确。

### 新增的联调层测试

新增 `packages/shared_core/test/e2e_mock_server_test.dart`：
**真实 Dart 客户端**打**真实 Mock 进程**，不做任何 mock。

存在的理由：单测用手写假 HTTP 客户端，验证的是"我的解析逻辑自洽"，
**验证不了**"我发的报文服务端真的认"——而路径/字段/嵌套层级的错误
恰恰全都能让单测保持全绿。上面 6 个缺陷里有 5 个是这一层发现的。

（Mock 未启动时该文件整体跳过，不报失败。）

