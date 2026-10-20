# 契约对齐记录：《网页开发方案》作为契约依据

| 项目 | 内容 |
|---|---|
| 触发 | 收到《网页开发方案》（`docs/web-development-plan.md`） |
| 结论 | **它的 §6 是报文级契约**，比我此前的推导更权威。已据此改正实现 |
| 为什么重要 | 《接口契约》文档仍未提供，但网页方案 §6 已明确响应信封、错误码、鉴权、分页与关键接口报文。**继续按推导开发会大面积返工** |

---

## 一、已改正的差异（全部落地并回归通过）

| # | 项 | 我此前的推导 | 网页方案规定 | 影响文件 |
|---|---|---|---|---|
| 1 | 响应字段 | `message` | **`msg`** | `api_envelope.dart`、`router.js` |
| 2 | 幂等键头 | `Idempotency-Key` | **`X-Idempotency-Key`**（24h 去重） | `field_dictionary.dart`、`api_client.dart`、`router.js` |
| 3 | 错误码 | 自造 `10001/20001/30001…` | **`40001/40101/40301/40401/40901/42901/50001`** | `error_codes.dart`、`constants.js`、全部 `fail()` 调用 |
| 4 | 分页字段 | `pageSize` | **`size`**（默认 20、上限 100） | `paging.dart`、`constants.js` |

### 3 的连带影响：错误码反查变成不可逆

方案只授权 **8 个码值**，而业务有几十种细分，因此多个枚举共享同一个 `value`：

```
40301 = forbidden（越权）| notInParticipantList（不在名单）
      | identityMismatch（二次校验失败）| deviceMismatch（设备不符）| …
```

**后果**：客户端**无法**从码值还原精确原因。三层应对（均已实现）：

1. **族级谓词**：`isAuthFailure` / `isForbidden` / `isConflict` / `isRateLimited` …
   判断"该做什么"用谓词，不用 `==` 比拼具体枚举名；
2. **精确原因读 `msg`**：服务端文案是唯一可靠的细分来源；
3. **`errors[].field`**：字段级定位（方案 §7.2 要求），用于把错误挂到输入框。

Dart 侧的 `ApiErrorCode.fromValue()` 现在用**显式族代表表**，
不再依赖枚举声明顺序——否则改枚举顺序会静默改变错误族，极难排查。

JS 侧同理：新增 `CATALOG`（语义名 → `{code, message, http}`），
`fail('NOT_IN_PARTICIPANT_LIST')` 取代 `fail(ERR.XXX)`。
**这是必要的**：线码合并后 `ERR_HTTP[code]` 会互相覆盖，
导致"不在名单"被发成 400 而不是 403。

---

## 二、已解决的三处方案冲突（均采用网页方案）

| # | 冲突 | 采用 | 决策编号 |
|---|---|---|---|
| 1 | 签到窗口：移动端 §4.2 **15/15** vs 网页 §4.1 **30/60** | **30 / 60** | D-5 |
| 2 | 在岗任务对象：移动端 §6.2「所有名单成员」 vs 网页 §4.5「已签到且在名单中」 | **只为已签到者生成** | D-6 |
| 3 | 汇总 `partial` 判据：移动端 §4.8「有 missed 且 done>0」 vs 网页 §6.4.7「完成率 ≥ 0.7」 | **0.7 阈值** | D-7 |

**均已落地并通过回归**（115 项）。连带影响：

* **冲突 2 引入时序约束**：必须先签到、再生成抽查任务。
  种子数据与测试夹具都已按此顺序调整；测试夹具新增 `checkedIn` 开关，
  以便同时覆盖"已签到"与"未签到"两种场景。
* **冲突 3 新增** `attendanceRate` 字段（完成率，0–1，无已定案任务时为 `null`），
  避免前端为展示一个百分比而重算一遍。
* **冲突 2 使 `absent` 的判定更干净**：没签到的人不再进入在岗明细，
  其缺席由签到状态直接决定，不再靠"抽查全 missed"推断。

---

## 三、尚未对齐的部分（工作量较大，待决策后统一处理）

### 3.1 接口路径风格

| 我的实现（REST 风格） | 网页方案（AIP 动作后缀） |
|---|---|
| `POST /activities` + `PATCH /activities/{id}` | **`POST /activities:upsert`**（含 `batch[]` 批量） |
| `POST /activities/{id}/start\|finish\|cancel` | **`POST /activities/{id}:transition`** `{from,to,reason}` |
| `POST /activities/{id}/participants/import` | `POST /activities/{id}/participants:import` |
| `DELETE /activities/{id}/participants/{userNo}` | `DELETE /activities/{id}/participants/{pid}` |
| `POST /activities/{id}/attendance/tasks/{tid}/respond` | **`POST /attendances/{taskId}:confirm`** |
| `POST /activities/{id}/exports`（建任务→轮询） | **`GET /activities/{id}/export?format=csv`** |
| `GET /attendances/{id}/summary` | `GET /activities/{id}/attendance` |
| — | **`GET /changes?since=&limit=`**（增量同步，我没有） |

统一前缀：方案 Base URL 是 `https://{domain}/api`，示例里写 `/api/v1/...`。
我当前无前缀，需要加。

**我的建议**：全部对齐（成本约 1 个工作单元，改动集中在 `mock_server` 路由层
与 `api_client` 的路径常量）。理由：这是三端共用的契约，不一致的代价是后端要写两套路由。

### 3.2 签到报文结构

网页方案 §6.4.5 用的是**嵌套结构**，我是扁平结构：

```jsonc
// 网页方案（权威）
{ "method":"geo",
  "location":{ "lat":34.2172, "lng":117.1438, "accuracy":18.5,
               "provider":"gps", "samples":3, "sampledAt":"…" },
  "network":{ "wifiBssids":["a4:2b:8c:11:22:33"], "sourceIp":"202.119.x.x" },
  "device":{ "deviceId":"…", "mockLocationDetected":false },
  "clientTime":"…" }
```

与我的差异：
* `method`：`gps` → **`geo`**（枚举值也变了）；
* 坐标：`geoLat`/`geoLng` → **`lat`/`lng`**（在 `location` 里）；
* 网络辅证：**复数** `wifiBssids[]`（我只发单个 `wifiBssid`）；
* `samples` 是**数量**（int），我发的是采样数组；
* 证据包收进 `evidence`（§4.4 的 `checkin.evidence`）。

**注意**：`samples` 从"数组"变"数量"意味着网页方案不打算让服务端看到逐次采样，
但我用采样一致性做模拟定位交叉验证（`+10` 评分项也依赖"多次采样一致"）。
**这条需要澄清**：是保留完整采样（我的做法，反作弊更强）还是只报数量？

### 3.3 活动字段字典的差异

| 项 | 我的实现 | 网页方案 §4.1 |
|---|---|---|
| `externalId` | 无 | **必填**，≤64 字符，幂等键 |
| `checkinRadius` | 默认 200、范围 1–1000 | 范围 **10–1000**；室外默认 **300**、室内默认 **150** |
| `title` | ≤60 | ≤60（一致） |
| `organizer` | 无长度限制 | ≤50 |
| `summary` | 无长度限制 | ≤120 |
| `durationHours` | >0 且 ≤24 | >0 且 ≤999.9，**步长 0.5** |
| `quota` | 正整数或 null | ≥0 |

---

## 四、建议的下一步

1. **你先定 §二 的三处冲突**（尤其冲突 1 与 2，是用户可感知的）；
2. 我再统一做 §三 的路径与报文对齐（一次性改完，避免改两轮）；
3. §3.2 的 `samples` 问题需要你或后端明确。

`docs/contract-assumptions.md` 里那份"待确认清单"现已大部分被网页方案回答，
我会在该文件里标注哪些已由网页方案确定、哪些仍待《接口契约》补充。
