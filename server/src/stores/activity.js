/**
 * 活动数据访问（方案 §4.1 字段字典）。
 *
 * ## 为什么要显式写列名映射，而不是 `SELECT *` + 自动驼峰转换
 *
 * 自动转换看起来省事，但它把"数据库列名"变成了隐含契约：
 * 改一次列名就会静默影响接口字段名。这里每个字段都显式列出，
 * 改动时「库 → 接口」的映射一眼可见。
 *
 * 另外，**下发给客户端的字段名必须与契约完全一致**
 * （`geoLat` 不是 `geo_lat`，`durationHours` 不是 `duration_hours`）。
 * 显式映射是保证这一点的最省事方式。
 */

import { ACTIVITY_STATUS, TERMINAL_STATUSES } from '../contract.js';
import { toJsonText, parseJsonObject, parseJsonArray, parseCsv } from '../util/json.js';
import { toIso, parseTime, addDays } from '../util/time.js';

/**
 * 数组 → JSON 文本；null / 非数组 → null。
 *
 * 
ull 与 [] 在这里**不是**一回事：
 *   * 
ull = 这个活动没配白名单（服务端不参与网络辅证计分）；
 *   * []   = 明确配置为空（当前也不计分，但语义上"配置过又被清空"）。
 * 存成 JSON 而不是逗号分隔，是因为 BSSID / IP 前缀里可能出现逗号，
 * 而 CSV 序列化遇到这种值会静默丢数据。
 */
function toJsonArray(value) {
  return Array.isArray(value) ? toJsonText(value) : null;
}

/** 表的列名（写库用）。顺序与 INSERT 语句绑定，改这里要同步改 SQL。 */
const COLUMNS = [
  'external_id',
  'title',
  'organizer',
  'duration_hours',
  'start_time',
  'end_time',
  'signup_deadline',
  'location',
  'location_type',
  'geo_lat',
  'geo_lng',
  'checkin_radius',
  'checkin_window_before',
  'checkin_window_after',
  'attendance_first_delay',
  'attendance_interval',
  'attendance_response_window',
  'attendance_mode',
  'quota',
  'enrolled',
  'status',
  'tags',
  'summary',
  'description',
  'contact',
  // 场地网络白名单（O-17）：JSON 数组文本。
  'wifi_bssids',
  'campus_ip_prefixes',
  'owner_id',
  'version',
  'seq',
  'created_at',
  'updated_at',
  'published_at',
  'started_at',
  'finished_at',
  'cancelled_at',
  'terminal_at',
  'cancel_reason',
];

/**
 * 行 → 领域对象（**接口字段名**）。
 *
 * 注意几处刻意的处理：
 *   * `tags` 库里是逗号分隔文本，出参是数组；
 *   * 时间一律转成带偏移的 ISO 字符串；
 *   * `enrolled` 是只读派生值，不作为可写字段暴露；
 *   * 布尔在 SQLite 里是 0/1，要转成真正的布尔。
 */
export function rowToActivity(row, { includeRuleSnapshot = false } = {}) {
  if (!row) {
    return null;
  }
  const a = {
    // id 一律以**字符串**下发：契约里 id 是字符串，
    // 而 SQLite 的自增主键是数字。不转的话客户端 `jsonStringOr` 拿到空串，
    // 表现为"列表能看到活动、点进去却说活动不存在"。
    id: String(row.id),
    externalId: row.external_id,
    title: row.title,
    organizer: row.organizer,
    durationHours: Number(row.duration_hours),
    startTime: row.start_time,
    endTime: row.end_time,
    signupDeadline: row.signup_deadline ?? null,
    location: row.location ?? '',
    locationType: row.location_type ?? null,
    geoLat: row.geo_lat == null ? null : Number(row.geo_lat),
    geoLng: row.geo_lng == null ? null : Number(row.geo_lng),
    checkinRadius: row.checkin_radius == null ? null : Number(row.checkin_radius),
    checkinWindowBefore: Number(row.checkin_window_before ?? 30),
    checkinWindowAfter: Number(row.checkin_window_after ?? 60),
    attendanceFirstDelay: Number(row.attendance_first_delay ?? 15),
    attendanceInterval: Number(row.attendance_interval ?? 30),
    attendanceResponseWindow: Number(row.attendance_response_window ?? 5),
    // 抽查方式：老数据没有这一列 → 按 auto 处理（保持既有行为）
    attendanceMode: row.attendance_mode ?? 'auto',
    quota: row.quota == null ? null : Number(row.quota),
    enrolled: Number(row.enrolled ?? 0),
    status: row.status,
    tags: parseCsv(row.tags),
    summary: row.summary ?? '',
    description: row.description ?? '',
    contact: row.contact ?? null,
    // 场地网络白名单：库里是 JSON 数组文本，出参是数组。
    wifiBssids: parseJsonArray(row.wifi_bssids),
    campusIpPrefixes: parseJsonArray(row.campus_ip_prefixes),
    ownerId: row.owner_id,
    version: Number(row.version ?? 1),
    seq: Number(row.seq ?? 0),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    publishedAt: row.published_at ?? null,
    startedAt: row.started_at ?? null,
    finishedAt: row.finished_at ?? null,
    cancelledAt: row.cancelled_at ?? null,
    terminalAt: row.terminal_at ?? null,
  };

  // 签到窗口是**派生值**（开始前 N 分钟 ~ 结束后 M 分钟）。
  // 放在这里算，而不是让每个调用方各算一遍 —— 那是窗口口径
  // 出现分歧的经典来源。
  a.checkinOpensAt = toIso(
    new Date(parseTime(a.startTime).getTime() - a.checkinWindowBefore * 60_000),
  );
  a.checkinClosesAt = toIso(
    new Date(parseTime(a.endTime).getTime() + a.checkinWindowAfter * 60_000),
  );

  // 留存期终点（仅终态活动有）。
  if (a.terminalAt) {
    a.dataDestroyAt = toIso(new Date(parseTime(a.terminalAt).getTime() + 7 * 24 * 3600_000));
  } else {
    a.dataDestroyAt = null;
  }

  if (includeRuleSnapshot) {
    a.ruleSnapshot = parseJsonObject(row.rule_snapshot_payload);
  }

  return a;
}

/**
 * 领域对象 → 写库的值数组（顺序与 [COLUMNS] 一致）。
 *
 * ⚠️ 两个刻意的处理，都是踩过坑的：
 *
 * 1. **`undefined` 一律转 `null`**。`node:sqlite` 拒绝绑定 `undefined`
 *    （报 `Provided value cannot be bound to SQLite parameter N`），
 *    而 `undefined` 在 JS 里极易混进来 —— 一个没写的字段、一次对象展开、
 *    一个可选参数。逐个字段写 `?? null` 也能解决，但**只要漏一处就会在
 *    运行期炸，且报错不告诉你是哪个字段**。在出口统一兜住更可靠。
 *
 * 2. **数组字段序列化成文本**。`tags` 是数组，SQLite 不能直接绑数组；
 *    这里统一 `join(',')`，读取侧由 `parseCsv` 还原。
 */
export function activityToValues(a) {
  const raw = [
    a.externalId,
    a.title,
    a.organizer,
    a.durationHours,
    a.startTime,
    a.endTime,
    a.signupDeadline,
    a.location,
    a.locationType,
    a.geoLat,
    a.geoLng,
    a.checkinRadius,
    a.checkinWindowBefore,
    a.checkinWindowAfter,
    a.attendanceFirstDelay,
    a.attendanceInterval,
    a.attendanceResponseWindow,
    a.attendanceMode ?? 'auto',
    a.quota,
    a.enrolled,
    a.status,
    // 数组 → 逗号分隔文本。
    Array.isArray(a.tags) ? a.tags.join(',') : (a.tags ?? ''),
    a.summary,
    a.description,
    a.contact,
    // 白名单存 JSON 数组文本；NULL 表示"未配置"。
    toJsonArray(a.wifiBssids),
    toJsonArray(a.campusIpPrefixes),
    a.ownerId,
    a.version,
    a.seq,
    a.createdAt,
    a.updatedAt,
    a.publishedAt,
    a.startedAt,
    a.finishedAt,
    a.cancelledAt,
    a.terminalAt,
    a.cancelReason,
  ];

  return raw.map((v, i) => {
    if (v === undefined) {
      /*
        ⚠️ 三个 NOT NULL 列需要**有意义的默认值**，不能一律 null。

        `enrolled` / `version` / `seq` 在 schema 里是 `NOT NULL`，
        因为它们在业务上总有确定的值：已报名人数从 0 开始、
        版本从 1 开始、序号从 0 开始（等待分配）。
        如果这里统一给 null，写库会报
        "NOT NULL constraint failed: activity.enrolled" ——
        而那个报错不会告诉你是哪个字段没传，排查成本很高。

        其余列允许 null（"未填"与"填了空"在业务上等价），
        所以只有这三个需要兜底。
      */
      const column = COLUMNS[i];
      if (column === 'enrolled' || column === 'version' || column === 'seq') {
        return column === 'version' ? 1 : 0;
      }
      /*
        `created_at` / `updated_at` 也是 NOT NULL。它们漏传通常意味着
        调用方忘了走 `makeActivity()` 补默认值 —— 这里兜住，
        而不是让写库报一个不指明字段的 NOT NULL 错误。
      */
      if (column === 'created_at' || column === 'updated_at') {
        return toIso(new Date());
      }
      return null;
    }
    if (v === null) {
      return null;
    }
    if (typeof v === 'boolean') {
      // SQLite 的布尔是 0/1。
      return v ? 1 : 0;
    }
    if (typeof v === 'number') {
      // NaN / Infinity 不是合法绑定值，且通常意味着上游算错了。
      return Number.isFinite(v) ? v : null;
    }
    if (typeof v === 'string') {
      return v;
    }
    // 对象/数组漏到这里说明映射有遗漏。报出来比静默写坏数据好。
    throw new TypeError(
      `活动字段含不可写库的值（${typeof v}）：${String(JSON.stringify(v)).slice(0, 80)}。` +
        '请检查 activityToValues 的映射是否漏了某个字段。',
    );
  });
}

/** 生成 `INSERT INTO activity (...) VALUES (?,?,...)`。 */
function insertSql() {
  const cols = COLUMNS.join(', ');
  const marks = COLUMNS.map(() => '?').join(', ');
  return `INSERT INTO activity (${cols}) VALUES (${marks})`;
}

/** 生成 `UPDATE activity SET col = ?, ... WHERE id = ?`。 */
function updateSql() {
  const sets = COLUMNS.map((c) => `${c} = ?`).join(', ');
  return `UPDATE activity SET ${sets} WHERE id = ?`;
}

/**
 * 活动仓储。
 *
 * 只暴露**领域方法**（`create` / `findById` / `search`），
 * 不暴露 SQL —— 这样换存储实现时调用方不需要改。
 */
export function activityRepo(conn) {
  return {
    /** 插入一条。返回新 id。 */
    async create(a) {
      const r = await conn.execute(insertSql(), activityToValues(a));
      return r.lastInsertId;
    },

    /** 按 id 覆盖更新（按序列名逐一写）。 */
    async update(id, a) {
      const values = [...activityToValues(a), id];
      await conn.execute(updateSql(), values);
    },

    /**
     * 按 id 查找。
     *
     * 默认**过滤掉已过留存期的活动** —— 方案 §9.3 / 验收要求
     * 「活动终态 +7 天后不可访问（业务数据视为已销毁）」。
     *
     * 这个过滤放在仓储层而不是每个 handler 里：漏一处的后果是
     * 过期数据被读出来，而那是隐私问题，不能靠"记得加"。
     */
    async findById(id, { includeExpired = false } = {}) {
      const row = await conn.queryOne('SELECT * FROM activity WHERE id = ?', [id]);
      const a = rowToActivity(row);
      if (!a) {
        return null;
      }
      if (!includeExpired && isExpired(a)) {
        return null;
      }
      return a;
    },

    /** 按 (owner_id, external_id) 查找 —— 上报接口的幂等键。 */
    async findByExternalId(ownerId, externalId) {
      const row = await conn.queryOne(
        'SELECT * FROM activity WHERE owner_id = ? AND external_id = ?',
        [ownerId, externalId],
      );
      return rowToActivity(row);
    },

    /**
     * 查询列表（方案 §4.2 / §7.1 的筛选条件）。
     *
     * 支持：关键词（标题/简介）、部门、状态（多选）、开始时间范围、
     * 排序、分页。
     *
     * ⚠️ **统计基于筛选后的全量，不随翻页跳动**。这一点很容易写错：
     * 先分页再统计，翻到第 2 页时计数会变 —— 而用户会以为数据错了。
     */
    async search({
      ownerId = null,
      keyword = null,
      organizer = null,
      statuses = null,
      startFrom = null,
      startTo = null,
      sortBy = 'startTime',
      sortDesc = true,
      page = 1,
      size = 20,
      includeExpired = false,
    } = {}) {
      const where = [];
      const params = [];

      if (ownerId) {
        where.push('owner_id = ?');
        params.push(ownerId);
      }
      if (keyword) {
        // 关键词命中标题或简介。用 LIKE 而非全文索引：
        // 本项目的活动量级（每学期数百条）不需要全文索引，
        // 而 LIKE 在 SQLite 与 MySQL 上语义一致。
        where.push('(title LIKE ? OR summary LIKE ? OR organizer LIKE ?)');
        const like = `%${keyword}%`;
        params.push(like, like, like);
      }
      if (organizer) {
        where.push('organizer = ?');
        params.push(organizer);
      }
      if (statuses && statuses.length > 0) {
        where.push(`status IN (${statuses.map(() => '?').join(', ')})`);
        params.push(...statuses);
      }
      if (startFrom) {
        where.push('start_time >= ?');
        params.push(startFrom);
      }
      if (startTo) {
        where.push('start_time <= ?');
        params.push(startTo);
      }

      // 已过留存期的活动一律不可见（方案 §9.3）。
      //
      // 判定口径与 `isExpired()` **必须一致**，否则会出现
      // "详情页说不存在、列表里却看得到"这种矛盾。
      // 这里用同一个 7 天常量把它表达成 SQL：
      //   未终结（terminal_at IS NULL）→ 可见
      //   终结了但 terminal_at + 7 天 > 现在 → 仍可见
      // 两边都是"字符串比较"，因为时间统一存 ISO 8601 含偏移，
      // 同一时区下的字符串序 == 时间序。
      if (!includeExpired) {
        const cutoff = toIso(new Date(Date.now() - 7 * 24 * 3600_000));
        where.push('(terminal_at IS NULL OR terminal_at > ?)');
        params.push(cutoff);
      }

      const whereSql = where.length ? `WHERE ${where.join(' AND ')}` : '';

      // 排序字段白名单 —— 绝不让用户输入直接进 ORDER BY（SQL 注入）。
      const SORTABLE = {
        startTime: 'start_time',
        endTime: 'end_time',
        createdAt: 'created_at',
        updatedAt: 'updated_at',
        title: 'title',
        seq: 'seq',
      };
      const col = SORTABLE[sortBy] ?? 'start_time';
      const dir = sortDesc ? 'DESC' : 'ASC';
      // 次级排序用 id：没有它的话，同 start_time 的记录在两次查询里
      // 顺序可能不同，翻页时会看到重复或漏掉的行。
      const orderSql = `ORDER BY ${col} ${dir}, id ${dir}`;

      const totalRow = await conn.queryOne(
        `SELECT COUNT(*) AS c FROM activity ${whereSql}`,
        params,
      );
      const total = Number(totalRow?.c ?? 0);

      const offset = (page - 1) * size;
      const rows = await conn.query(
        `SELECT * FROM activity ${whereSql} ${orderSql} LIMIT ? OFFSET ?`,
        [...params, size, offset],
      );

      return {
        items: rows.map((r) => rowToActivity(r)),
        total,
      };
    },

    /** 部门字典（筛选栏用）：取所有出现过的组织部门。 */
    async organizers(ownerId = null) {
      const where = ownerId ? 'WHERE owner_id = ?' : '';
      const params = ownerId ? [ownerId] : [];
      const rows = await conn.query(
        `SELECT DISTINCT organizer FROM activity ${where} ORDER BY organizer`,
        params,
      );
      return rows.map((r) => r.organizer).filter(Boolean);
    },

    /**
     * 状态计数（方案 §7.1 统计图区）。
     *
     * 与 [search] 用**同一套 where 条件**，否则会出现
     * "列表显示 3 条，饼图说 5 条"的矛盾。
     */
    async countByStatus(filters = {}) {
      // 复用 search 的过滤逻辑：先取全量 id + status。
      const { items } = await this.search({
        ...filters,
        page: 1,
        size: 100000,
      });
      const counts = {};
      for (const a of items) {
        counts[a.status] = (counts[a.status] ?? 0) + 1;
      }
      return counts;
    },

    /** 增量同步（方案 §6.4.9）：按 seq 取变更。 */
    async changesSince(seq, { limit = 200, ownerId = null, visibleOnly = true } = {}) {
      const where = ['seq > ?'];
      const params = [seq];
      if (ownerId) {
        where.push('owner_id = ?');
        params.push(ownerId);
      }
      if (visibleOnly) {
        // 草稿不对未授权视图开放。
        where.push("status <> 'draft'");
      }
      if (!visibleOnly) {
        where.push('1 = 1');
      }
      const rows = await conn.query(
        `SELECT * FROM activity WHERE ${where.join(' AND ')}
         ORDER BY seq ASC LIMIT ?`,
        [...params, limit],
      );
      return rows.map((r) => rowToActivity(r));
    },

    /** 全部可见活动的 id（全量对齐用）。 */
    async allIds({ ownerId = null } = {}) {
      const where = ["status <> 'draft'"];
      const params = [];
      if (ownerId) {
        where.push('owner_id = ?');
        params.push(ownerId);
      }
      const rows = await conn.query(
        `SELECT id, seq FROM activity WHERE ${where.join(' AND ')} ORDER BY seq`,
        params,
      );
      return rows.map((r) => ({ id: r.id, seq: Number(r.seq) }));
    },
  };
}

/**
 * 是否已过留存期（终态 + 7 天）。
 *
 * 抽成函数而不是内联，是为了让"7 天"这个口径只有一处。
 */
export function isExpired(activity, now = new Date()) {
  if (!activity || !TERMINAL_STATUSES.includes(activity.status)) {
    return false;
  }
  if (!activity.terminalAt) {
    return false;
  }
  const t = parseTime(activity.terminalAt);
  if (!t) {
    return false;
  }
  return now.getTime() > addDays(t, 7).getTime();
}

/** 供测试与种子用：构造一个活动对象（含默认值）。 */
export function makeActivity(input) {
  const now = toIso(new Date());
  return {
    externalId: input.externalId,
    title: input.title,
    organizer: input.organizer,
    durationHours: input.durationHours,
    startTime: input.startTime,
    endTime: input.endTime,
    signupDeadline: input.signupDeadline ?? null,
    location: input.location ?? '',
    locationType: input.locationType ?? null,
    geoLat: input.geoLat ?? null,
    geoLng: input.geoLng ?? null,
    checkinRadius: input.checkinRadius ?? null,
    checkinWindowBefore: input.checkinWindowBefore ?? 30,
    checkinWindowAfter: input.checkinWindowAfter ?? 60,
    attendanceFirstDelay: input.attendanceFirstDelay ?? 15,
    attendanceInterval: input.attendanceInterval ?? 30,
    attendanceResponseWindow: input.attendanceResponseWindow ?? 5,
    attendanceMode: input.attendanceMode ?? 'auto',
    quota: input.quota ?? null,
    enrolled: 0,
    status: input.status ?? ACTIVITY_STATUS.DRAFT,
    tags: input.tags ?? [],
    summary: input.summary ?? '',
    description: input.description ?? '',
    contact: input.contact ?? null,
    ownerId: input.ownerId,
    version: 1,
    seq: input.seq ?? 0,
    createdAt: now,
    updatedAt: now,
    publishedAt: null,
    startedAt: null,
    finishedAt: null,
    cancelledAt: null,
    terminalAt: null,
    cancelReason: null,
  };
}

export { toJsonText };
