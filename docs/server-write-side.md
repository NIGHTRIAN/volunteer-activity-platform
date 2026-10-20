# 服务端写入侧接口（P1 补齐）

> 状态：**已完成**。手机端现在可以连真服务器完整走通
> 「登录 → 建活动 → 加名单 → 发码 → 绑定 → 签到 → 在岗 → 复核 → 看板」。

---

## 1. 为什么这一块是关键路径

在此之前 `server/` 只有 7 个**只读**接口 —— 网页能看，但手机端
**一个请求都发不出去**：App 启动先要令牌，拿不到就停在登录页。
所以写入侧不是"功能增强"，而是"能不能用"的分界线。

---

## 2. 接口清单

### 鉴权（手机端前置门槛）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/auth/admin/login` | 邀请码 + 设备标识 → 管理端令牌 |
| POST | `/auth/bind` | 活动编号 + 学号 + 邀请码 → 活动授权令牌 |

### 管理端写入

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/activities:upsert` | 批量上报（部分成功语义） |
| POST | `/activities/{id}:transition` | 状态流转（只允许契约内的转换） |
| GET | `/activities/{id}/participants` | 名单 |
| POST | `/activities/{id}/participants` | 加人 |
| POST | `/activities/{id}/participants:import` | 批量导入 |
| DELETE | `/activities/{id}/participants/{userNo}` | 移出（软删 + 作废授权） |
| POST | `/activities/{id}/invite-codes` | 发码（重发走 UPDATE） |

### 签到 / 在岗 / 看板 / 复核

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/activities/{id}/checkins` | 签到提交（服务端判定） |
| GET | `/activities/{id}/checkins` | 管理端查看记录 |
| GET | `/activities/{id}/checkins/mine` | 本人记录 |
| POST | `/checkins/{id}:review` | 人工复核 |
| GET | `/activities/{id}/attendance/tasks` | 在岗任务 |
| POST | `/attendances/{id}:confirm` | 在岗确认 |
| GET | `/activities/{id}/attendance` | 考勤汇总 |
| GET | `/activities/{id}/board` | 现场看板 |

---

## 3. 判定语义（与 mock、离线演示引擎**同一套**）

权重与阈值统一放在 `contract/constants.js` 的 `DEFAULTS`，
`server/src/scoring.js` 与 `mock_server/src/scoring.js` 都从那里取 ——
**只有一套数字**，避免三边漂移。

评分表：

```
围栏内（精度 ≤50m）   +40      精度 >100m → 该证据不计分
围栏内（50–半径）     +25      围栏外 1.5 倍半径内 → 0 分
Wi-Fi 命中白名单      +20      围栏外更远 → 0 分
校园网 IP 命中原籍     +10
多次采样一致          +10
────────────────────────────────
≥60 自动通过 ／ 30–59 转人工 ／ <30 驳回
模拟定位 −60 且**一票否决**（即使总分高也转人工）
```

真机测试修正过、必须保留的三条：

1. **模拟定位**要求"坐标与精度都完全一致 **且** 精度 ≤5m"。
   早期只要"采样一致"就判伪造，误杀了室内静止的真实用户。
2. **精度 >100m 是不计分，不是驳回** —— 设备定位劣化是常态，
   直接驳回会让志愿者没有申诉通道。
3. **在岗确认窗口两侧都要校验**。真机发现过可以"提前把所有未来抽查
   一次性点掉"—— 只校验了 deadline 没校验 scheduled_at。

另外：**离线补传一律转待人工确认**，即使证据满分
（补传时间与现场时间不一致，无法排除事后补造）。

---

## 4. 踩过的坑（都有测试钉住）

| 坑 | 现象 | 修法 |
|---|---|---|
| `activity.id` 是数字、子表 `activity_id` 是文本 | 邀请码明明对却报"无效" | 查子表前统一 `String(id)` |
| `invite_code` 在 (活动,学号) 上唯一 | 第二次发码 `UNIQUE constraint failed` | 重发改成 UPDATE（`reissued+1`） |
| 详情返回形状两端不一致 | App 显示「未知状态 / 1970-01-01」 | 同时给扁平字段与 `{activity, disclaimer}` |
| `CREATE TABLE IF NOT EXISTS` 不加列 | 老库 `no such column: wifi_bssids` | 增量列单独 ALTER（幂等） |

> 详情形状那条特别值得记：网页读 `data.activity`，手机端把 `data`
> 直接当 `Activity.fromJson` 的输入。两个客户端各随自己那侧的 mock
> 联调通过，**互相之间从没对过**，于是真机上静默显示全空
> —— `Activity.fromJson` 对缺字段一律给默认值，不报错。

---

## 5. 测试

| 包 | 项数 | 覆盖 |
|---|---|---|
| `server/test/auth.test.mjs` | 22 | 登录、锁定、绑定幂等、换设备、令牌解析 |
| `server/test/manage.test.mjs` | 20 | 上报、冻结、流转、名单、发码、越权、全链路 |
| `server/test/checkin.test.mjs` | 21 | 评分纯函数、门槛、签到、在岗、复核、越权 |
| 原有只读测试 | 64 | 回归 |
| **合计** | **127** | |

真机验证（连真服务器）：

```
登录 → 建活动 → 加名单 → 发码 → 绑定
→ 签到：距签到点 0m，评分 60，已签到（自动通过）
→ 管理端看板：已签到 1 人 / 待确认 0 / 名单 张伟 已签到 / 在岗抽查 3 条
```

---

## 6. 下一步

1. **多发布者**：现在 `ownerId` 由配置固定（单发布者试点）。
   支持多组织时需要「邀请码 → ownerId」映射表，接口形态不用变。
2. **令牌续期**：`adminTokenTtlMinutes` 默认 12 小时，
   到期后 App 只能重新登录。可加 refresh 机制减少打扰。
3. **导出权限**：`/activities/{id}/export` 已存在，
   但写入侧新增的字段（白名单）尚未进导出列。
