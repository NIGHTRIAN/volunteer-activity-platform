# 服务端 Mock · 使用说明

> 目的：**让两端 App 在真实服务端就绪前就能独立开发与联调**（《移动端应用开发方案》§1.4）。
> 零外部依赖，只用 Node 内置模块——任何需要 `npm install` 的东西都会拖慢这个目标。

---

## 一、启动

```powershell
# 在仓库根目录
node mock_server/src/server.js
```

启动后会打印：

```
  志愿活动信息平台 · 服务端 Mock
  监听          http://0.0.0.0:8080
  接口版本      v1
  管理员邀请码  1111（默认值，可用 ADMIN_INVITE_CODE 覆盖）
  数据文件      D:\VOLUNTEER SYSTEM\mock_server\.data\mock-db.json

  真机联调用地址（手机与电脑需在同一网络）：
    http://192.168.x.x:8080

  App 侧对应构建参数：
    --dart-define=API_BASE_URL=http://192.168.x.x:8080
```

### 可配置项（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | `8080` | 监听端口 |
| `HOST` | `0.0.0.0` | 监听地址。默认全网卡，真机才能访问 |
| `ADMIN_INVITE_CODE` | `1111` | 管理端邀请码。对应方案 §13-A1「日后收紧」的路径 |
| `MOCK_DATA_DIR` | `mock_server/.data` | 数据文件目录。换目录＝换一套独立数据 |

### 数据

* 全部数据在 `mock_server/.data/mock-db.json`，**可以直接打开看、可以手改、可以删掉重置**。
* 首次启动会写入演示数据（5 个不同状态的活动、名单、邀请码、签到、在岗记录）。
* 落盘采用「写临时文件 + 原子替换」，不会出现写一半断电留下半个文件。

---

## 二、演示数据与登录凭证

### 管理端

* 邀请码：**`1111`**
* 需要带一个设备标识（`X-Device-Id`），首次登录会绑定该设备并签发令牌。

### 进行中的活动（可直接演示签到）

| 项 | 值 |
|---|---|
| 活动 | 图书馆书架整理志愿服务（校图书馆） |
| 时段 | 当前时刻前 45 分钟 ~ 后 135 分钟，**此刻就在签到窗口内** |
| 围栏中心 | WGS-84 `34.2175, 117.1425`，半径 200 m |
| 名单 | 2021001 张伟 / 2021002 李娜 / 2021003 王强 / 2021004 刘洋 / 2021005 陈静 |
| 邀请码 | `2021001 → K7M2P9QX`，`2021002 → R4T8W3NY` |

> 时间锚定在**启动时刻**而不是固定钟点。用固定钟点（比如"今天 9 点"）的话，
> 下午启动就变成"签到时段已结束"，演示和联调会莫名其妙地失败。

### 其他状态的活动（覆盖各条分支）

| 活动 | 状态 | 用途 |
|---|---|---|
| 校园文明劝导志愿活动 | 已发布 | 验证「不在签到时段内」 |
| （草稿）敬老院陪伴服务 | 草稿 | 验证「草稿对外不可见」 |
| 实验室安全巡查志愿岗 | 已结束 | 验证导出、考勤汇总、留存倒计时 |
| 运动会志愿服务 | 已取消 | 验证 `excused` 与取消原因 |

---

## 三、接口契约

### 响应信封

**成功**
```json
{
  "code": 0,
  "message": "成功",
  "data": { },
  "errors": [],
  "traceId": "t-xxxxxxxx",
  "serverTime": "2026-10-16T15:30:00+08:00"
}
```

**失败**
```json
{
  "code": 40301,
  "message": "无权操作该活动",
  "data": null,
  "errors": [{ "field": "reason", "message": "请填写不少于 5 字的取消原因" }],
  "traceId": "t-xxxxxxxx",
  "serverTime": "2026-10-16T15:30:00+08:00"
}
```

> 每个响应都带 `serverTime`：服务端时间是**唯一可信的时间基准**（方案 §6.3 的
> 动态码倒计时已取消，但在岗抽查的 5 分钟响应窗口仍依赖它），且方案 §9 要求
> 识别「设备时间不准」。客户端时钟不可信。

### 请求头

| 头 | 用途 |
|---|---|
| `Authorization: Bearer <token>` | 管理端令牌 / 志愿者设备令牌 |
| `X-Api-Version` | 版本协商。不是 `v1` 会返回 `10005` |
| `X-Client-Version` | 客户端版本，便于定位现场问题 |
| `Idempotency-Key` | **签到与在岗响应必带**，保证重传不产生重复记录 |
| `X-Device-Id` | 设备指纹，用于绑定校验与「同设备多账号」风险判定 |

### 端点一览

运行中随时可以拿到自述：

```powershell
curl http://127.0.0.1:8080/contract
```

它返回**已实现的全部路径、判定阈值、抽查参数、留存规则**——不用翻文档。

分类概览：

| 分类 | 端点 |
|---|---|
| 认证与身份 | `POST /auth/admin/login`、`GET /auth/admin/me`、`GET /auth/admin/audits`、`POST /auth/bind`、`GET /auth/me` |
| 活动 | `GET/POST /activities`、`GET/PATCH /activities/:id`、`POST /activities/:id/start\|finish\|cancel`、`GET /activities/:id/changes` |
| 名单 | `GET/POST /activities/:id/participants`、`POST .../participants/import`、`DELETE .../participants/:userNo` |
| 邀请码 | `POST/GET /activities/:id/invite-codes` |
| 签到 | `POST/GET /activities/:id/checkins`、`GET .../checkins/mine`、`POST /checkins/:id/review`、`POST .../checkins/manual` |
| 在岗 | `GET .../attendance/tasks`、`POST .../attendance/tasks/:id/respond\|remind`、`POST .../attendance/manual`、`GET .../attendance/summary` |
| 看板 | `GET /activities/:id/board` |
| 导出 | `POST /activities/:id/exports`、`GET /exports/:id`、`GET /exports/:id/download` |
| 审计 | `GET /auth/admin/audits`（登录）、`GET /auth/admin/export-audits`（含完整联系方式的导出） |

> ⚠️ **本平台不启用动态签到码**（决策 D-2，见 `docs/decisions.md`）。
> 方案 §6.3 设计的 `/checkin-code` 端点**未实现**。拒定位权限时的降级路径只有两条，
> 都在管理端：现场核实与人工补录（`POST .../checkins/manual`）。

---

## 四、判定逻辑与服务端一致

Mock **不是**「随便返回成功」的桩。签到判定、抽查生成、留存期这些会直接影响
现场行为的逻辑，都在这里按方案 §6.1/§6.2 实现了一遍：

| 规则 | 实现位置 |
|---|---|
| 风险评分（围栏距离、网络辅证、停留验证、反作弊扣分） | `src/scoring.js` |
| 模拟定位命中即**强制转人工** | `src/scoring.js` |
| 坐标系偏移识别（GCJ-02 特征） | `src/scoring.js` |
| 抽查时段生成（幂等键 `activityId+userNo+seq`） | `src/attendance_engine.js` |
| 超时判定在 `deadline + 2min`，保留通知记录 | `src/attendance_engine.js` |
| 发布即冻结规则快照；关键字段受限编辑 | `src/api_activities.js` |
| 逐行导入报告；软删除保留历史 | `src/api_participants.js` |
| 幂等键、离线补传转人工 | `src/api_checkin.js` |

### 已发现的方案内部矛盾（已按验收用例取舍）

方案 §6.2 同时给了两条约束：

* (a)「末次不晚于 `endTime − 15min`」
* (b)「2 小时活动 3 次（T+15 / T+45 / T+75）」

若留白取 15 分钟，2 小时活动的可用区间是 `[15, 105]`，30 分钟间隔会产出
**4 次**，与 (b) 矛盾；取 **30 分钟**则恰好 3 次。

**当前实现以 (b) 为准**（`ATTENDANCE_LAST_TASK_MARGIN_MIN = 30`），
因为验收用例 A20 可判定，而 (a) 是描述性表述。
**此项需后端确认**，见 `docs/contract-assumptions.md`。

---

## 五、测试

```powershell
node mock_server/test/smoke.js
```

**107 项**用例，直接调 handler 层（不占端口），覆盖方案 §12 验收用例中
服务端可验证的部分：

| 验收用例 | 覆盖情况 |
|---|---|
| A1 / A2 / A3 | 默认邀请码登录、登录审计、5 次失败锁定 |
| A4 | `ownerId` 越权隔离（含取消/结束/名单改动的越权） |
| A5 / A6 | 规则快照冻结、受限编辑记录前后值 + 新快照 |
| A7 | 取消活动：未发生任务 `excused`、已发生保留 |
| A8 | 逐行导入报告（含重复、格式错误、缺列、二次校验冲突） |
| A9 / A10 | 绑定成功、非名单用户拒绝、邀请码一对一配对 |
| A11 | 围栏内 `success` 且评分 ≥60 |
| A12 | 1.5 倍半径外 `rejected`，原因含距离与半径 |
| A13 | 模拟定位强制转人工 |
| A14 | GCJ-02 未转换被识别 |
| A15 | 离线补传转人工，且不显示为成功 |
| A17 / A18 / A19 | 在岗零输入完成、超时 `missed` 保留通知记录、无证据不通过 |
| A20 | 2 小时活动 3 次抽查 |
| A21 | 终态 +7 天后不可访问 |
| A23 | 幂等键不产生重复记录 |

测试用例**自带夹具并自行清理**。早期版本让用例共用种子里那个「进行中」的活动，
结果一个用例失败就把状态留给下一个，产生一串看不出真实原因的错误。

---

## 六、开发调试技巧

### 模拟「离线补传超窗」

```powershell
curl -X POST http://127.0.0.1:8080/dev/time-travel-example `
  -H 'Content-Type: application/json' `
  -d '{"activityId":"<活动ID>","minutesAgo":120}'
```

它返回一个 `clientTime` 值。把这个值填进签到请求的 `clientTime` 并把
`offlineBackfill` 设为 `true`，服务端就会走「转人工确认」分支。

### 重置数据

```powershell
curl -X POST http://127.0.0.1:8080/dev/reset `
  -H 'Content-Type: application/json' -d '{"confirm":"RESET"}'
```

需要显式确认参数，避免把 Mock 暴露到公网后被随手清库。删掉 `.data` 目录也一样。

### 让两台设备用不同数据

```powershell
$env:MOCK_DATA_DIR = 'D:\temp\mock-a'; node mock_server/src/server.js
$env:MOCK_DATA_DIR = 'D:\temp\mock-b'; node mock_server/src/server.js
```

---

## 七、⚠️ 这个 Mock 不能做什么

必须在文档里写清楚，避免有人误以为它已经具备生产能力：

1. **没有身份真实性**。管理员邀请码默认 `1111`，且设备指纹绑定在 Mock 里
   只是"换设备就新建一个 owner"，没有人员识别。
2. **没有并发与性能**。单进程、单文件 JSON、全量内存操作。不能用来压测，
   也验证不了「300 并发签到」这类指标。
3. **不实现动态签到码**（决策 D-2）。方案 §6.3 把它列为降级手段，本项目不做：
   码证明不了"人在现场"（可以被转发），且会引入轮换 / 预取 / 断网续播一整套
   额外故障点。拒定位权限时靠管理端现场核实与人工补录兜底。
4. **模拟定位检测只是提高门槛**。服务端无法真正读取 Android 的
   `isFromMockProvider`；这里的交叉验证（坐标/精度/时间戳自洽性）只能识别
   粗糙的伪造。方案 §13-A2 已承认这是 GPS 主判据的固有短板。
5. **留存期只做接口层隐藏**，不真正销毁数据，方便反复验证同一份数据。
6. **导出是同步生成的**。真实实现应为异步任务（先返回 `50002` 让客户端轮询）。

---

## 八、目录结构

```
mock_server/
├── package.json
├── README.md              本文件
├── src/
│   ├── server.js          入口：HTTP 服务、优雅退出、局域网地址打印
│   ├── router.js          路由匹配、统一信封、鉴权分发
│   ├── constants.js       契约常量镜像（与 shared_core 的 field_dictionary.dart 对齐）
│   ├── store.js           JSON 持久化、查询 helper、登录审计
│   ├── scoring.js         ★ 服务端签到判定与风险评分（§6.1）
│   ├── attendance_engine.js ★ 抽查生成与结算（§6.2）
│   ├── presenters.js      DTO 序列化 + 统一脱敏
│   ├── api_auth.js        认证与身份
│   ├── api_activities.js  活动发布、受限编辑、状态流转
│   ├── api_participants.js 名单与邀请码
│   ├── api_checkin.js     签到、在岗、人工核实/补录、导出
│   ├── api.js             处理器注册表
│   ├── seed.js            演示数据
│   └── seed_codes.js      演示用固定邀请码
└── test/
    └── smoke.js           107 项回归测试
```

`★` 标记的两个文件是**判定权的实现**。App 侧不得复制这些逻辑——方案 §2 明确
「签到判定权一律在服务端，客户端只上报证据」。
