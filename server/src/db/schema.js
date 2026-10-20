/**
 * 数据库 schema（迁移 001）。
 *
 * ## 方言处理
 *
 * 同一份 DDL 要能跑在 **SQLite（本机开发）** 与 **MySQL（生产）** 上。
 * 做法：这里写一套"两边都能接受"的写法，差异用 `dialect` 参数处理：
 *
 * | 项 | SQLite | MySQL |
 * |---|---|---|
 * | 主键自增 | `INTEGER PRIMARY KEY AUTOINCREMENT` | `BIGINT AUTO_INCREMENT PRIMARY KEY` |
 * | 字符串 | `TEXT` | `VARCHAR(n)` / `TEXT` |
 * | 时间 | `TEXT`（ISO 8601 字符串） | `DATETIME(3)` |
 * | 布尔 | `INTEGER`（0/1） | `TINYINT(1)` |
 *
 * ⚠️ **时间是全库一致的字符串（ISO 8601 含偏移）**，不用数据库的
 * 本地时区语义。理由：方案 §8.3 要求服务器时区 `Asia/Shanghai` 且 NTP 必须启用，
 * 但"依赖服务器时区正确"是个隐患 —— 时区错了，签到窗口会集体偏移。
 * 存字符串 + 由应用层统一解析，就不依赖数据库时区设置。
 *
 * ## 与方案 §4 数据模型的对应
 *
 * `activity` §4.1 · `participant` §4.3 · `checkin` §4.4 ·
 * `attendance_task` §4.5 · `invite_code`/`activity_grant` §4.7
 * `rule_snapshot` §5.2 · `change_log` §6.4.9
 */

/** 各表 DDL。键是表名，值是 `(dialect) => string`。 */
export const TABLES = {
  // ── 活动（方案 §4.1 字段字典 冻结版）────────────────────────────────
  activity: (d) => `
    CREATE TABLE IF NOT EXISTS activity (
      id ${d.pk()},
      -- 管理端的幂等键（必填、≤64）。同一 externalId 重复上报视为更新。
      external_id ${d.str(64)} NOT NULL,
      title ${d.str(60)} NOT NULL,
      organizer ${d.str(50)} NOT NULL,
      duration_hours ${d.decimal()} NOT NULL,
      start_time ${d.dt()} NOT NULL,
      end_time ${d.dt()} NOT NULL,
      signup_deadline ${d.dtNull()},
      location ${d.str(100)},
      -- 场地类型：只用于决定默认签到半径（室外 300 / 室内 150），不参与判定。
      location_type ${d.str(16)},
      -- 坐标一律 WGS-84（方案 §4.1）。GCJ-02/BD-09 必须先转换。
      geo_lat ${d.decimal()},
      geo_lng ${d.decimal()},
      checkin_radius ${d.int()},
      checkin_window_before ${d.int()},
      checkin_window_after ${d.int()},
      attendance_first_delay ${d.int()},
      attendance_interval ${d.int()},
      attendance_response_window ${d.int()},
      -- 抽查方式：auto=自动按间隔生成，manual=由发布者手动触发
      attendance_mode ${d.str(16)},
      quota ${d.intNull()},
      -- 只读派生值：由名单维护，不由 App 直接写。
      enrolled ${d.int()} NOT NULL DEFAULT 0,
      status ${d.str(16)} NOT NULL,
      tags ${d.text()},
      summary ${d.str(120)},
      description ${d.text()},
      contact ${d.str(50)},
      -- 场地网络白名单（O-17）：命中时参与评分加分（Wi-Fi +20 / 校园网 +10）。
      -- 存 JSON 数组文本；NULL 表示"未配置"，与"配置为空数组"语义不同
      --（未配置 = 不参与计分；空数组也等价于不参与，但显式表达"清空过"）。
      wifi_bssids ${d.text()},
      campus_ip_prefixes ${d.text()},
      -- 发布者身份。**归属隔离的依据**（方案 §9.2）。
      owner_id ${d.str(64)} NOT NULL,
      version ${d.int()} NOT NULL DEFAULT 1,
      -- 增量同步游标：单调递增序号（**不用时间戳**，同毫秒写入无法全序）。
      seq ${d.bigint()} NOT NULL DEFAULT 0,
      created_at ${d.dt()} NOT NULL,
      updated_at ${d.dt()} NOT NULL,
      published_at ${d.dtNull()},
      started_at ${d.dtNull()},
      finished_at ${d.dtNull()},
      cancelled_at ${d.dtNull()},
      -- 终态时刻：留存期从它开始算（终态 + 7 天）。
      terminal_at ${d.dtNull()},
      cancel_reason ${d.text()}
    )
  `,

  // ── 规则快照（方案 §5.2：发布即冻结）────────────────────────────────
  //
  // 存在的意义是**保护管理者**：判定依据不被事后改写，争议时有据可依。
  rule_snapshot: (d) => `
    CREATE TABLE IF NOT EXISTS rule_snapshot (
      id ${d.pk()},
      activity_id ${d.str(32)} NOT NULL,
      revision ${d.int()} NOT NULL,
      -- 冻结时的完整规则（JSON）。
      payload ${d.text()} NOT NULL,
      reason ${d.text()},
      changed_by ${d.str(64)},
      created_at ${d.dt()} NOT NULL
    )
  `,

  // ── 规则变更记录（方案 §5.2）────────────────────────────────────────
  change_log: (d) => `
    CREATE TABLE IF NOT EXISTS change_log (
      id ${d.pk()},
      activity_id ${d.str(32)} NOT NULL,
      field ${d.str(64)} NOT NULL,
      before_value ${d.text()},
      after_value ${d.text()},
      reason ${d.text()},
      revision ${d.int()},
      changed_by ${d.str(64)},
      changed_at ${d.dt()} NOT NULL
    )
  `,

  // ── 参与者 / 名单（方案 §4.3）───────────────────────────────────────
  participant: (d) => `
    CREATE TABLE IF NOT EXISTS participant (
      id ${d.pk()},
      activity_id ${d.str(32)} NOT NULL,
      user_no ${d.str(32)} NOT NULL,
      name ${d.str(64)},
      -- 完整手机号（内部存）；对外一律走掩码。
      phone ${d.str(20)},
      -- 二次校验用：手机号后四位。与完整号码分开存，
      -- 这样"核对身份"时不必把完整号码读进内存。
      phone_suffix ${d.str(8)},
      -- 学院/院系（可选）。按学院统计到场情况时要用，所以在名单上留一列。
      college ${d.str(64)},
      signup_status ${d.str(16)} NOT NULL,
      -- 软删除：保留记录，标注移出时间（方案 §12.1-4）。
      removed_at ${d.dtNull()},
      removed_by ${d.str(64)},
      grant_expires_at ${d.dtNull()},
      invite_code_used_at ${d.dtNull()},
      bound_device_id ${d.str(128)},
      created_at ${d.dt()} NOT NULL,
      updated_at ${d.dt()} NOT NULL
    )
  `,

  // ── 邀请码（方案 §4.7）──────────────────────────────────────────────
  invite_code: (d) => `
    CREATE TABLE IF NOT EXISTS invite_code (
      id ${d.pk()},
      activity_id ${d.str(32)} NOT NULL,
      user_no ${d.str(32)} NOT NULL,
      code ${d.str(32)} NOT NULL,
      expires_at ${d.dtNull()},
      used_at ${d.dtNull()},
      reissued ${d.int()} NOT NULL DEFAULT 0,
      created_at ${d.dt()} NOT NULL
    )
  `,

  // ── 活动授权（方案 §4.7：令牌绑定设备指纹）──────────────────────────
  activity_grant: (d) => `
    CREATE TABLE IF NOT EXISTS activity_grant (
      id ${d.pk()},
      activity_id ${d.str(32)} NOT NULL,
      user_no ${d.str(32)} NOT NULL,
      name ${d.str(64)},
      token ${d.str(128)} NOT NULL,
      device_id ${d.str(128)},
      expires_at ${d.dt()} NOT NULL,
      created_at ${d.dt()} NOT NULL,
      revoked_at ${d.dtNull()}
    )
  `,

  // ── 管理端会话 ──────────────────────────────────────────────────────
  admin_session: (d) => `
    CREATE TABLE IF NOT EXISTS admin_session (
      id ${d.pk()},
      owner_id ${d.str(64)} NOT NULL,
      token ${d.str(128)} NOT NULL,
      device_id ${d.str(128)} NOT NULL,
      created_at ${d.dt()} NOT NULL,
      expires_at ${d.dt()} NOT NULL,
      last_seen_at ${d.dtNull()}
    )
  `,

  // ── 登录审计（方案 §6.3：时间/设备/IP）──────────────────────────────
  login_audit: (d) => `
    CREATE TABLE IF NOT EXISTS login_audit (
      id ${d.pk()},
      owner_id ${d.str(64)},
      device_id ${d.str(128)},
      ip ${d.str(64)},
      success ${d.bool()} NOT NULL,
      reason ${d.text()},
      at ${d.dt()} NOT NULL
    )
  `,

  // ── 签到记录（方案 §4.4）────────────────────────────────────────────
  checkin: (d) => `
    CREATE TABLE IF NOT EXISTS checkin (
      id ${d.pk()},
      activity_id ${d.str(32)} NOT NULL,
      user_no ${d.str(32)} NOT NULL,
      name ${d.str(64)},
      -- 写入侧只用契约值 geo；读取侧兼容早期的 gps。
      method ${d.str(16)} NOT NULL,
      status ${d.str(16)} NOT NULL,
      reason ${d.text()},
      geo_lat ${d.decimal()},
      geo_lng ${d.decimal()},
      accuracy ${d.decimal()},
      score ${d.intNull()},
      -- 评分构成（JSON）：管理端复核时要看"为什么是这个分"。
      score_breakdown ${d.text()},
      distance_meters ${d.decimal()},
      mock_location_detected ${d.bool()} NOT NULL DEFAULT 0,
      -- 坐标异常判定（坐标系未转换等）。
      coordinate_verdict ${d.str(32)},
      client_time ${d.dtNull()},
      server_time ${d.dt()} NOT NULL,
      -- 设备与网络辅证。
      device_id ${d.str(128)},
      app_version ${d.str(32)},
      wifi_matched ${d.bool()} NOT NULL DEFAULT 0,
      campus_ip_matched ${d.bool()} NOT NULL DEFAULT 0,
      dwell_verified ${d.bool()} NOT NULL DEFAULT 0,
      -- 离线补传：**一律转待人工确认**（不因证据强而自动通过）。
      offline_backfill ${d.bool()} NOT NULL DEFAULT 0,
      reviewed_at ${d.dtNull()},
      reviewed_by ${d.str(64)},
      review_note ${d.text()},
      -- 现场核实标记：人工介入**不覆盖**原始 method。
      verified_by_owner ${d.bool()} NOT NULL DEFAULT 0,
      manual_by ${d.str(64)}
    )
  `,

  // ── 在岗抽查任务（方案 §4.5）────────────────────────────────────────
  attendance_task: (d) => `
    CREATE TABLE IF NOT EXISTS attendance_task (
      id ${d.pk()},
      activity_id ${d.str(32)} NOT NULL,
      user_no ${d.str(32)} NOT NULL,
      seq ${d.int()} NOT NULL,
      scheduled_at ${d.dt()} NOT NULL,
      deadline_at ${d.dt()} NOT NULL,
      status ${d.str(16)} NOT NULL,
      -- 「已通知」时刻：用于区分"人不在"与"通知没到"（方案 §13-A5）。
      notified_at ${d.dtNull()},
      reminded_at ${d.dtNull()},
      responded_at ${d.dtNull()},
      geo_lat ${d.decimal()},
      geo_lng ${d.decimal()},
      accuracy ${d.decimal()},
      distance_meters ${d.decimal()},
      needs_manual_review ${d.bool()} NOT NULL DEFAULT 0,
      review_note ${d.text()},
      manual_fill ${d.bool()} NOT NULL DEFAULT 0,
      filled_by ${d.str(64)},
      excused_at ${d.dtNull()},
      excused_reason ${d.text()},
      settled_at ${d.dtNull()}
    )
  `,

  // ── 全局序号（增量同步游标，方案 §6.4.9）────────────────────────────
  //
  // ⚠️ 为什么单独一张表，而不是用 `MAX(activity.seq) + 1`。
  //
  // 早期实现是后者，它能跑通，但有两个隐患：
  //
  // 1. **耦合**：序号一旦成为独立计数器，将来把序号用到别的实体
  //    （参与者、签到记录）时不必再改游标逻辑；而挂在 activity 上，
  //    换实体就要换游标语义。
  // 2. **并发**：`MAX()+1` 在并发写时可能读到同一个值（取决于隔离级别），
  //    而游标重复会让客户端**漏同步**——这是最难查的一类问题。
  //    这里用 `UPDATE ... WHERE id = 1` 的就地自增，靠行锁保证唯一。
  //
  // 单行表（`id` 固定为 1）是"显式计数器"的常见做法：
  // 没有删除风险，也不需要担心行数增长。
  seq_counter: (d) => `
    CREATE TABLE IF NOT EXISTS seq_counter (
      id ${d.int()} NOT NULL PRIMARY KEY,
      value ${d.bigint()} NOT NULL
    )
  `,

  // ── 幂等键（方案 §6.1：24h 去重窗口）────────────────────────────────
  idempotency: (d) => `
    CREATE TABLE IF NOT EXISTS idempotency (
      id ${d.pk()},
      scope ${d.str(128)} NOT NULL,
      key_value ${d.str(128)} NOT NULL,
      -- 请求指纹：同键不同内容视为冲突。
      request_hash ${d.str(64)} NOT NULL,
      response ${d.text()},
      created_at ${d.dt()} NOT NULL,
      expires_at ${d.dt()} NOT NULL
    )
  `,

  // ── 敏感导出审计（三条零成本底线之一，方案 §9.1）────────────────────
  export_audit: (d) => `
    CREATE TABLE IF NOT EXISTS export_audit (
      id ${d.pk()},
      activity_id ${d.str(32)},
      kind ${d.str(32)},
      requested_by ${d.str(64)},
      ip ${d.str(64)},
      row_count ${d.int()},
      includes_full_contact ${d.bool()} NOT NULL DEFAULT 0,
      at ${d.dt()} NOT NULL
    )
  `,
};

/**
 * 增量列（建表之后新增的列）。
 *
 * ## 为什么需要这个而不是只改建表语句
 *
 * `CREATE TABLE IF NOT EXISTS` 对**已存在的库不会做任何事** ——
 * 只改建表语句，老库永远拿不到新列，而报错是运行时的
 * `no such column: wifi_bssids`，看起来像代码写错了。
 *
 * 所以新增列必须单独走 ALTER，且要幂等（先查列是否存在）。
 * 这里是 O-17（场地网络白名单）落地时补的两列。
 */
export const COLUMN_ADDITIONS = [
  {
    table: 'activity',
    column: 'wifi_bssids',
    ddl: (d) => `ALTER TABLE activity ADD COLUMN wifi_bssids ${d.text()}`,
  },
  {
    table: 'activity',
    column: 'campus_ip_prefixes',
    ddl: (d) => `ALTER TABLE activity ADD COLUMN campus_ip_prefixes ${d.text()}`,
  },
  {
    /*
      学院字段是后加的。已有的 .db 不会因为改了 CREATE TABLE 就多出一列，
      所以用 ALTER TABLE 幂等补上（applyColumnAdditions 会先查 PRAGMA）。
      不补的话，老部署一升级就会 "no such column: p.college" —— 名单接口直接 500。
    */
    table: 'participant',
    column: 'college',
    ddl: (d) => `ALTER TABLE participant ADD COLUMN college ${d.str(64)}`,
  },
  {
    table: 'activity',
    column: 'attendance_mode',
    ddl: (d) => `ALTER TABLE activity ADD COLUMN attendance_mode ${d.str(16)}`,
  },
];

/**
 * 索引。
 *
 * 按方案 §4.8「规模与索引」的思路：列表页的筛选组合（状态 + 时间 + 部门）
 * 与"某活动下的签到/任务"是最高频的两类查询。
 */

export const INDEXES = [
  // 列表页：按状态与开始时间筛选，按 owner 隔离。
  `CREATE INDEX IF NOT EXISTS ix_activity_owner_status ON activity (owner_id, status)`,
  `CREATE INDEX IF NOT EXISTS ix_activity_start ON activity (start_time)`,
  `CREATE INDEX IF NOT EXISTS ix_activity_seq ON activity (seq)`,
  // 看板/考勤：按活动查名单与记录。
  `CREATE INDEX IF NOT EXISTS ix_participant_activity ON participant (activity_id)`,
  `CREATE INDEX IF NOT EXISTS ix_checkin_activity_user ON checkin (activity_id, user_no)`,
  `CREATE INDEX IF NOT EXISTS ix_attendance_activity_user ON attendance_task (activity_id, user_no)`,
  `CREATE INDEX IF NOT EXISTS ix_attendance_status ON attendance_task (status)`,
  `CREATE INDEX IF NOT EXISTS ix_grant_token ON activity_grant (token)`,
  `CREATE INDEX IF NOT EXISTS ix_admin_token ON admin_session (token)`,
  `CREATE INDEX IF NOT EXISTS ix_invite_code ON invite_code (activity_id, code)`,
  `CREATE INDEX IF NOT EXISTS ix_change_log_activity ON change_log (activity_id)`,
];