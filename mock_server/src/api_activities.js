/**
 * 活动：发布、受限编辑、状态流转。
 *
 * 覆盖：
 *   * 发布活动 → 校验 → **冻结规则快照** → 对外可见（方案 §4.2、§4.3、验收 A5）
 *   * 发布后**受限编辑**：关键字段默认禁改，确需修改要填原因、记录前后值、
 *     通知志愿者、新快照**仅对未来生效**（方案 §4.5、验收 A6）
 *   * 状态流转：开始 / 宣布结束 / 取消（方案 §4.4、验收 A7）
 *   * 列表筛选 + 分页 + 统计（方案 §5.1）
 */

import {
  ACTIVITY_STATUS,
  CHECKIN_ALLOWED_STATUSES,
  DEFAULTS,
  ERR,
  FROZEN_FIELDS,
  TERMINAL_STATUSES,
} from './constants.js';
import {
  addMinutes,
  findVisibleActivity,
  isRetentionExpired,
  grantExpiryFor,
  iso,
  logRuleChange,
  newId,
  nextSeq,
  parseTime,
  store,
} from './store.js';
import { fail, requireOwnedActivity } from './api_auth.js';
import { CHECKIN_METHOD, PagingFields } from './constants.js';
import {
  buildAttendanceSummary,
  countTasks,
  regenerateAttendanceTasks,
  settleOverdueTasks,
} from './attendance_engine.js';
import { presentActivity } from './presenters.js';

// ─────────────────────────────────────────────────────────────────────────
// 录入校验（与服务端字段字典一致；App 侧有同名实现做即时校验）
// ─────────────────────────────────────────────────────────────────────────

const REQUIRED_FIELDS = [
  // 方案 §4.1：`externalId` 是**必填**的幂等键（≤64 字符），
  // 同一 externalId 重复上报视为更新（§5.4）。
  ['externalId', '外部唯一号'],
  ['title', '活动名称'],
  ['organizer', '组织部门'],
  ['startTime', '开始时间'],
  ['endTime', '结束时间'],
  ['durationHours', '志愿时长'],
  ['geoLat', '纬度'],
  ['geoLng', '经度'],
];

/**
 * 长度约束（方案 §4.1 字段字典）。
 *
 * 逐条给出上限而不是笼统一个数字：这些限制的存在意义是**保证列表页同构呈现**
 * （§4.2「同一列表内一律同构呈现，不得逐条差异化」），
 * 所以超限必须拦在录入侧，而不是靠前端截断。
 */
const LENGTH_LIMITS = [
  ['externalId', 64, '外部唯一号'],
  ['title', 60, '活动名称'],
  ['organizer', 50, '组织部门'],
  ['location', 100, '活动地点'],
  ['summary', 120, '活动简介'],
  ['contact', 50, '联系方式'],
];

/**
 * 校验活动录入。
 *
 * 服务端**必须重复校验**客户端的每一项——App 侧的即时校验只为了体验，
 * 不能作为数据正确性的依据（方案 §4.2）。
 */
export function validateActivityInput(body, { now = new Date() } = {}) {
  const errors = [];

  for (const [field, label] of REQUIRED_FIELDS) {
    const v = body[field];
    if (v == null || (typeof v === 'string' && v.trim() === '')) {
      errors.push({ field, message: `请填写${label}` });
    }
  }
  if (errors.length > 0) {
    return errors;
  }

  // ── 长度约束（方案 §4.1）───────────────────────────────────────────
  for (const [field, max, label] of LENGTH_LIMITS) {
    const v = body[field];
    if (typeof v === 'string' && v.trim().length > max) {
      errors.push({ field, message: `${label}不超过 ${max} 字` });
    }
  }

  const start = parseTime(body.startTime);
  const end = parseTime(body.endTime);
  if (!start) {
    errors.push({ field: 'startTime', message: '开始时间格式不正确' });
  }
  if (!end) {
    errors.push({ field: 'endTime', message: '结束时间格式不正确' });
  }
  if (start && end && end <= start) {
    errors.push({ field: 'endTime', message: '结束时间必须晚于开始时间' });
  }

  // 时长：方案 §4.1 为 decimal(4,1)、>0 且 ≤999.9、步长 0.5。
  const hours = Number(body.durationHours);
  if (!Number.isFinite(hours) || hours <= 0 || hours > DEFAULTS.DURATION_MAX_HOURS) {
    errors.push({
      field: 'durationHours',
      message: `志愿时长应大于 0 且不超过 ${DEFAULTS.DURATION_MAX_HOURS} 小时`,
    });
  } else if (Math.abs(hours / DEFAULTS.DURATION_STEP_HOURS - Math.round(hours / DEFAULTS.DURATION_STEP_HOURS)) > 1e-9) {
    errors.push({
      field: 'durationHours',
      message: `志愿时长步长为 ${DEFAULTS.DURATION_STEP_HOURS} 小时（如 1.5、2.0）`,
    });
  }

  // 签到半径：方案 §4.1 为 10～1000 米；未填时按场地类型取默认值。
  const hasRadius = body.checkinRadius != null && body.checkinRadius !== '';
  const radius = Number(
    hasRadius ? body.checkinRadius : defaultRadiusFor(body.locationType),
  );
  if (!Number.isFinite(radius)) {
    errors.push({ field: 'checkinRadius', message: '签到半径必须是数字' });
  } else if (radius < DEFAULTS.MIN_CHECKIN_RADIUS_M) {
    errors.push({
      field: 'checkinRadius',
      message: `签到半径不得小于 ${DEFAULTS.MIN_CHECKIN_RADIUS_M} 米（GPS 精度本身就有误差）`,
    });
  } else if (radius > DEFAULTS.MAX_CHECKIN_RADIUS_M) {
    errors.push({
      field: 'checkinRadius',
      message: `签到半径不得超过 ${DEFAULTS.MAX_CHECKIN_RADIUS_M} 米`,
    });
  }

  const lat = Number(body.geoLat);
  const lng = Number(body.geoLng);
  if (!Number.isFinite(lat) || lat < -90 || lat > 90) {
    errors.push({ field: 'geoLat', message: '纬度不在有效范围内' });
  }
  if (!Number.isFinite(lng) || lng < -180 || lng > 180) {
    errors.push({ field: 'geoLng', message: '经度不在有效范围内' });
  }
  if (lat === 0 && lng === 0) {
    errors.push({ field: 'geoLat', message: '坐标不能为 (0,0)，请在地图上选点' });
  }

  if (body.signupDeadline) {
    const dl = parseTime(body.signupDeadline);
    if (!dl) {
      errors.push({ field: 'signupDeadline', message: '报名截止格式不正确' });
    } else if (start && dl > start) {
      errors.push({ field: 'signupDeadline', message: '报名截止不得晚于活动开始时间' });
    }
  }

  const quota = body.quota;
  if (quota != null && (!Number.isInteger(Number(quota)) || Number(quota) <= 0)) {
    errors.push({ field: 'quota', message: '名额需为正整数，或留空表示不限' });
  }

  // 抽查参数组合必须能生成至少一次抽查（方案 §6.2）。
  if (start && end) {
    const windowMin = (end - start) / 60_000;
    const firstDelay = Number(body.attendanceFirstDelay ?? DEFAULTS.ATTENDANCE_FIRST_DELAY_MIN);
    const interval = Number(body.attendanceInterval ?? DEFAULTS.ATTENDANCE_INTERVAL_MIN);
    const lastAllowed = windowMin - DEFAULTS.ATTENDANCE_LAST_TASK_MARGIN_MIN;
    if (firstDelay >= windowMin) {
      errors.push({ field: 'attendanceFirstDelay', message: '首次抽查延迟不得超出活动时长' });
    } else if (interval <= 0) {
      errors.push({ field: 'attendanceInterval', message: '抽查间隔必须大于 0' });
    } else if (firstDelay > lastAllowed) {
      errors.push({
        field: 'attendanceInterval',
        message: '按当前参数不会生成任何在岗抽查，请调小首次延迟或延长活动',
      });
    }
  }

  return errors;
}

/**
 * 按场地类型取默认签到半径（方案 §4.1：室外 300、室内 150）。
 *
 * 室内默认更小，是因为室内定位精度差（方案 §13-A3 承认室内有 30～100m 漂移），
 * 半径给大了等于把"在楼外 200 米"也算成"在房间里"。
 */
function defaultRadiusFor(locationType) {
  return String(locationType ?? '').toLowerCase() === 'indoor'
    ? DEFAULTS.DEFAULT_CHECKIN_RADIUS_INDOOR_M
    : DEFAULTS.DEFAULT_CHECKIN_RADIUS_OUTDOOR_M;
}

/** 把入参规整为内部存储结构。 */
function normalizeActivity(body, { ownerId, existing = null }) {
  const now = new Date();
  const start = parseTime(body.startTime);
  const end = parseTime(body.endTime);
  const hasRadius = body.checkinRadius != null && body.checkinRadius !== '';
  return {
    id: existing?.id ?? newId('act-'),
    // 方案 §4.1：externalId 是管理端的幂等键，同一值重复上报视为更新。
    externalId: String(body.externalId ?? existing?.externalId ?? '').trim(),
    title: String(body.title).trim(),
    organizer: String(body.organizer).trim(),
    durationHours: Number(body.durationHours),
    startTime: iso(start),
    endTime: iso(end),
    signupDeadline: body.signupDeadline ? iso(parseTime(body.signupDeadline)) : null,
    location: String(body.location ?? existing?.location ?? '').trim(),
    // 场地类型：只用于决定默认半径，不参与判定。
    locationType: body.locationType ?? existing?.locationType ?? null,
    geoLat: Number(body.geoLat),
    geoLng: Number(body.geoLng),
    checkinRadius: Number(
      hasRadius ? body.checkinRadius : defaultRadiusFor(body.locationType ?? existing?.locationType),
    ),
    checkinWindowBefore: Number(body.checkinWindowBefore ?? DEFAULTS.CHECKIN_WINDOW_BEFORE_MIN),
    checkinWindowAfter: Number(body.checkinWindowAfter ?? DEFAULTS.CHECKIN_WINDOW_AFTER_MIN),
    attendanceFirstDelay: Number(
      body.attendanceFirstDelay ?? DEFAULTS.ATTENDANCE_FIRST_DELAY_MIN,
    ),
    attendanceInterval: Number(body.attendanceInterval ?? DEFAULTS.ATTENDANCE_INTERVAL_MIN),
    attendanceResponseWindow: Number(
      body.attendanceResponseWindow ?? DEFAULTS.ATTENDANCE_RESPONSE_WINDOW_MIN,
    ),
    quota: body.quota == null ? null : Number(body.quota),
    enrolled: existing?.enrolled ?? 0,
    // ── 网络辅证的**白名单配置**（评分表 +20 / +10 的判定依据）───────────
    //
    // 这两项必须由发布者在活动里配置，而不是"客户端上报了就给分" ——
    // 否则任何人填一个 BSSID 都能拿 20 分，辅证就失去意义。
    wifiBssids: Array.isArray(body.wifiBssids)
      ? body.wifiBssids.map(String)
      : (existing?.wifiBssids ?? []),
    campusIpPrefixes: Array.isArray(body.campusIpPrefixes)
      ? body.campusIpPrefixes.map(String)
      : (existing?.campusIpPrefixes ?? []),
    status: body.status ?? existing?.status ?? ACTIVITY_STATUS.DRAFT,
    tags: Array.isArray(body.tags) ? body.tags.map(String) : (existing?.tags ?? []),
    summary: String(body.summary ?? existing?.summary ?? '').trim(),
    description: String(body.description ?? existing?.description ?? ''),
    contact: body.contact == null ? (existing?.contact ?? null) : String(body.contact),
    ownerId: existing?.ownerId ?? ownerId,
    version: (existing?.version ?? 0) + 1,
    // 增量同步序号（网页方案 §6.4.9）。用**单调序号**而不是时间戳做游标：
    // 同毫秒内的多次写入用时间戳无法全序，会漏同步或反复下发。
    seq: nextSeq(),
    ruleSnapshot: existing?.ruleSnapshot ?? null,
    createdAt: existing?.createdAt ?? iso(now),
    updatedAt: iso(now),
    terminalAt: existing?.terminalAt ?? null,
    publishedAt: existing?.publishedAt ?? null,
    cancelReason: existing?.cancelReason ?? null,
    finishedAt: existing?.finishedAt ?? null,
  };
}

/**
 * 冻结规则快照（方案 §2「发布即冻结规则」、§4.5）。
 *
 * 存在的意义是**保护管理者**：判定依据不被事后改写，争议时有据可依。
 * `revision` 每次受限编辑 +1，新快照**仅对未来生效**。
 */
function freezeRuleSnapshot(activity, { reason = null, changedBy = null, revision = 1 } = {}) {
  return {
    frozenAt: iso(new Date()),
    startTime: activity.startTime,
    endTime: activity.endTime,
    durationHours: activity.durationHours,
    checkinRadius: activity.checkinRadius,
    checkinWindowBefore: activity.checkinWindowBefore,
    checkinWindowAfter: activity.checkinWindowAfter,
    attendanceFirstDelay: activity.attendanceFirstDelay,
    attendanceInterval: activity.attendanceInterval,
    attendanceResponseWindow: activity.attendanceResponseWindow,
    revision,
    reason,
    changedBy,
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 列表与详情
// ─────────────────────────────────────────────────────────────────────────

export function listActivities(ctx) {
  const {
    keyword,
    organizer,
    status,
    startFrom,
    startTo,
    page = '1',
    // 契约字段是 `size`（网页方案 §6.1）；`pageSize` 是早期写法，保留兼容。
    size,
    pageSize,
    sortBy = 'startTime',
    sortDesc = 'true',
    onlyMine,
  } = ctx.query;

  const now = new Date();
  let items = store.db.activities.filter((a) => !isRetentionExpiredLocal(a, now));

  // 管理端默认只看自己名下的活动（方案 §2 归属隔离）。
  const isAdmin = ctx.auth?.kind === 'admin';
  if (isAdmin && (onlyMine === 'true' || onlyMine == null)) {
    items = items.filter((a) => a.ownerId === ctx.auth.ownerId);
  } else if (isAdmin && onlyMine === 'false') {
    // 显式要求看全部：保留但不放开写权限。
  } else if (!isAdmin) {
    // 用户端只看对外可见的活动：草稿不可见（方案 §4.2「发布后对外可见」）。
    items = items.filter((a) => a.status !== ACTIVITY_STATUS.DRAFT);
  }

  if (organizer) {
    items = items.filter((a) => a.organizer.includes(organizer));
  }
  if (status) {
    const wanted = String(status)
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    if (wanted.length > 0) {
      items = items.filter((a) => wanted.includes(a.status));
    }
  }
  if (keyword) {
    const k = keyword.trim().toLowerCase();
    items = items.filter(
      (a) =>
        a.title.toLowerCase().includes(k) ||
        a.location.toLowerCase().includes(k) ||
        (a.summary ?? '').toLowerCase().includes(k) ||
        (a.tags ?? []).some((t) => String(t).toLowerCase().includes(k)),
    );
  }
  if (startFrom) {
    const from = parseTime(startFrom);
    if (from) {
      items = items.filter((a) => parseTime(a.startTime) >= from);
    }
  }
  if (startTo) {
    const to = parseTime(startTo);
    if (to) {
      items = items.filter((a) => parseTime(a.startTime) <= to);
    }
  }

  // 排序：默认 `startTime desc`（方案 §5.1）。
  const numericSort = ['durationHours', 'enrolled', 'version'].includes(sortBy);
  items = [...items].sort((a, b) => {
    let cmp;
    if (numericSort) {
      cmp = Number(a[sortBy]) - Number(b[sortBy]);
    } else {
      cmp = String(a[sortBy] ?? '').localeCompare(String(b[sortBy] ?? ''));
    }
    return sortDesc === 'true' ? -cmp : cmp;
  });

  // 统计：基于**筛选后**的全量结果，而不是当前页——否则翻页时图表会跳。
  const stats = {
    total: items.length,
    published: items.filter((a) => a.status === ACTIVITY_STATUS.PUBLISHED).length,
    ongoing: items.filter((a) => a.status === ACTIVITY_STATUS.ONGOING).length,
    finished: items.filter((a) => a.status === ACTIVITY_STATUS.FINISHED).length,
    cancelled: items.filter((a) => a.status === ACTIVITY_STATUS.CANCELLED).length,
    totalDurationHours: Number(
      items.reduce((s, a) => s + Number(a.durationHours ?? 0), 0).toFixed(2),
    ),
  };

  const total = items.length;
  const p = Math.max(1, Number(page));
  // 每页条数：契约字段是 `size`（网页方案 §6.1），上限 100。
  // 同时接受旧的 `pageSize` 以兼容早期客户端。
  const ps = Math.min(
    PagingFields.maxSize,
    Math.max(1, Number(size ?? pageSize ?? PagingFields.defaultSize)),
  );
  const slice = items.slice((p - 1) * ps, p * ps);

  return {
    items: slice.map((a) =>
      presentActivity(a, {
        forVolunteer: ctx.auth?.kind === 'volunteer' ? ctx.auth.userNo : null,
        now,
      }),
    ),
    total,
    page: p,
    // **回显 `size`**：客户端要据此算 hasMore 与下一页页码。
    // 不回显会让客户端只能靠自己记的值，一旦服务端把 size 压到上限
    //（例如请求 999 被压到 100），客户端算出的分页就会错位。
    size: ps,
    hasMore: p * ps < total,
    stats,
  };
}

function isRetentionExpiredLocal(activity, now) {
  if (!TERMINAL_STATUSES.includes(activity.status) || !activity.terminalAt) {
    return false;
  }
  const destroyAt = addMinutes(parseTime(activity.terminalAt), DEFAULTS.RETENTION_DAYS * 24 * 60);
  return now > destroyAt;
}

export function getActivity(ctx) {
  const activity = findVisibleActivity(ctx.params.id);
  if (!activity) {
    return fail('ACTIVITY_NOT_FOUND');
  }
  // 草稿仅发布者可见；志愿者访问草稿等价于不存在（不泄露草稿内容）。
  if (activity.status === ACTIVITY_STATUS.DRAFT) {
    if (ctx.auth?.kind !== 'admin' || activity.ownerId !== ctx.auth.ownerId) {
      return fail('ACTIVITY_NOT_FOUND');
    }
  }
  // 志愿者只能看自己被授权的活动详情（活动级授权，方案 §5.2）。
  if (ctx.auth?.kind === 'volunteer' && ctx.auth.activityId !== activity.id) {
    return fail('GRANT_EXPIRED', '你未获得该活动的访问授权');
  }
  return presentActivity(activity, {
    forVolunteer: ctx.auth?.kind === 'volunteer' ? ctx.auth.userNo : null,
  });
}

// ─────────────────────────────────────────────────────────────────────────
// 上报：POST /activities:upsert（网页方案 §6.4.1）
// ─────────────────────────────────────────────────────────────────────────

/**
 * 批量上报活动。
 *
 * 契约（网页方案 §6.4.1）：
 * ```
 * POST /api/v1/activities:upsert    X-Idempotency-Key
 * { "source":"admin-app", "batch":[ { "externalId":"ACT-2025-0001", ... } ] }
 * ```
 * 响应含 `accepted / created / updated / rejected[]`，
 * **部分失败仍返回 200**，非法条附原因。
 *
 * ## 为什么"部分失败仍返回 200"
 *
 * 这是**弱网场景的关键设计**：管理端可能一次上报 20 条，其中 3 条字段有问题。
 * 如果整批返回 4xx，客户端无法知道哪 3 条要修，只能全部重传；
 * 返回 200 + 逐条结果，客户端就能把出错的 3 条标红让发布者改。
 *
 * ## 幂等
 *
 * `externalId` 是幂等键（方案 §4.1）：已存在则**更新**（计入 `updated`），
 * 不存在则创建（计入 `created`）。因此重传同一批不会产生重复活动。
 *
 * ⚠️ 但**不允许通过重传覆盖服务端已流转的状态**（方案 §5.4）：
 * 处于 `ongoing` / `finished` / `cancelled` 的活动，上报只更新非状态字段。
 */
export function upsertActivities(ctx) {
  const body = ctx.body ?? {};

  // 支持 `{ batch: [...] }`（契约）与单条直传（便于手工调试）。
  const items = Array.isArray(body.batch)
    ? body.batch
    : Array.isArray(body.items)
      ? body.items
      : [body];

  if (items.length === 0) {
    return fail('BAD_REQUEST', 'batch 为空，没有可上报的活动');
  }

  const created = [];
  const updated = [];
  const rejected = [];

  for (let i = 0; i < items.length; i++) {
    const raw = items[i] ?? {};
    const errors = validateActivityInput(raw);
    if (errors.length > 0) {
      rejected.push({
        index: i,
        externalId: raw.externalId ?? null,
        title: raw.title ?? null,
        errors,
      });
      continue;
    }

    const existing = store.db.activities.find(
      (a) =>
        a.externalId === String(raw.externalId).trim() &&
        // 归属隔离：只能更新自己的活动（方案 §6.3）。
        a.ownerId === ctx.auth.ownerId,
    );

    if (existing) {
      const wasStatus = existing.status;
      const next = normalizeActivity(raw, {
        ownerId: ctx.auth.ownerId,
        existing,
      });

      // ⚠️ 不允许用重传覆盖已流转的状态（方案 §5.4）。
      // 客户端手上的 status 可能已经过期，照写会让"已结束"的活动回到"已发布"。
      if (wasStatus !== ACTIVITY_STATUS.DRAFT) {
        next.status = wasStatus;
      }
      Object.assign(existing, next);
      updated.push(existing.id);
      continue;
    }

    // 新建
    const activity = normalizeActivity(raw, { ownerId: ctx.auth.ownerId });
    const publish = raw.publish !== false;
    if (publish) {
      activity.status = ACTIVITY_STATUS.PUBLISHED;
      activity.publishedAt = iso(new Date());
      activity.ruleSnapshot = freezeRuleSnapshot(activity, { changedBy: ctx.auth.ownerId });
    }
    store.db.activities.push(activity);
    created.push(activity.id);
  }

  store.save();

  return {
    accepted: created.length + updated.length,
    created,
    updated,
    // 逐条给出 index + 原因，客户端据此把出错的条目标红。
    rejected,
    // 说明性文案：让客户端知道 200 不代表全部成功。
    note:
      rejected.length > 0
        ? `已受理 ${created.length + updated.length} 条，${rejected.length} 条被拒绝，请按 rejected 修正后重传`
        : '全部受理',
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 状态流转：POST /activities/{id}:transition（网页方案 §6.4.2）
// ─────────────────────────────────────────────────────────────────────────

/**
 * 状态流转。
 *
 * 契约（网页方案 §6.4.2）：
 * ```
 * POST /api/v1/activities/{id}:transition
 * { "from":"ongoing", "to":"finished", "reason":"现场活动已结束" }
 * ```
 *
 * `from` 是**乐观锁**：与当前状态不符时返回 `40901`，
 * 防止管理端拿着过期状态做流转（例如在两个设备上同时操作）。
 *
 * 非法转移一律 `40901`（方案 §5.1）。
 */
export function transitionActivity(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  const activity = owned;
  const body = ctx.body ?? {};
  const to = String(body.to ?? '').trim();
  const from = body.from == null ? null : String(body.from).trim();
  const reason = body.reason == null ? null : String(body.reason).trim();

  if (!to) {
    return fail('BAD_REQUEST', '缺少目标状态 to', [
      { field: 'to', message: '缺少目标状态' },
    ]);
  }

  // 乐观锁：客户端认知的 from 必须与服务端一致。
  if (from && from !== activity.status) {
    return fail(
      'VERSION_CONFLICT',
      `活动当前状态为「${activity.status}」，与请求的 from=「${from}」不一致，请刷新后重试`,
    );
  }

  // 合法转移表（方案 §5.1）。
  const ALLOWED = {
    [ACTIVITY_STATUS.DRAFT]: [ACTIVITY_STATUS.PUBLISHED, ACTIVITY_STATUS.CANCELLED],
    [ACTIVITY_STATUS.PUBLISHED]: [ACTIVITY_STATUS.ONGOING, ACTIVITY_STATUS.CANCELLED],
    [ACTIVITY_STATUS.ONGOING]: [ACTIVITY_STATUS.FINISHED, ACTIVITY_STATUS.CANCELLED],
    // 终态不可再流转。
    [ACTIVITY_STATUS.FINISHED]: [],
    [ACTIVITY_STATUS.CANCELLED]: [],
  };

  const allowed = ALLOWED[activity.status] ?? [];
  if (!allowed.includes(to)) {
    return fail(
      'ACTIVITY_STATE_INVALID',
      TERMINAL_STATUSES.includes(activity.status)
        ? `活动已${activity.status === ACTIVITY_STATUS.CANCELLED ? '取消' : '结束'}，为终态，不可再流转`
        : `不允许从「${activity.status}」流转到「${to}」`,
    );
  }

  const now = new Date();

  switch (to) {
    case ACTIVITY_STATUS.PUBLISHED: {
      // 发布即冻结规则快照（方案 §5.2、验收 A5）。
      activity.status = ACTIVITY_STATUS.PUBLISHED;
      activity.publishedAt = iso(now);
      activity.ruleSnapshot = freezeRuleSnapshot(activity, { changedBy: ctx.auth.ownerId });
      activity.updatedAt = iso(now);
      store.save();
      return { activity: presentActivity(activity), transitionedFrom: from, transitionedTo: to };
    }

    case ACTIVITY_STATUS.ONGOING: {
      activity.status = ACTIVITY_STATUS.ONGOING;
      activity.startedAt = activity.startedAt ?? iso(now);
      activity.updatedAt = iso(now);
      // 开始即按「已签到者」生成抽查任务（决策 D-6）。
      // 此刻通常还没人签到，所以这里多半生成 0 条；
      // 真正的生成发生在有人签到之后（见 submitCheckin 的钩子）。
      const createdCount = regenerateAttendanceTasks(activity, { preserveExisting: true });
      store.save();
      return {
        activity: presentActivity(activity),
        transitionedFrom: from,
        transitionedTo: to,
        attendanceTasksCreated: createdCount,
      };
    }

    case ACTIVITY_STATUS.FINISHED: {
      // 复用宣布结束的逻辑（含未响应任务结算、授权刷新、汇总）。
      return finishActivityCore(ctx, activity, reason);
    }

    case ACTIVITY_STATUS.CANCELLED: {
      // 复用取消逻辑（必填原因 ≥5 字、未发生任务置 excused）。
      return cancelActivityCore(ctx, activity, reason);
    }

    default:
      return fail('ACTIVITY_STATE_INVALID', `未知目标状态：${to}`);
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 单条创建（保留供内部复用与手工调试）
// ─────────────────────────────────────────────────────────────────────────

export function createActivity(ctx) {
  const errors = validateActivityInput(ctx.body ?? {});
  if (errors.length > 0) {
    return fail('BAD_REQUEST', '活动信息校验未通过', errors);
  }

  const activity = normalizeActivity(ctx.body, { ownerId: ctx.auth.ownerId });

  // 「发布」= 直接以 published 创建，并**立即冻结规则快照**（验收 A5）。
  const publish = ctx.body.publish !== false;
  if (publish) {
    activity.status = ACTIVITY_STATUS.PUBLISHED;
    activity.publishedAt = iso(new Date());
    activity.ruleSnapshot = freezeRuleSnapshot(activity, { changedBy: ctx.auth.ownerId });
  }

  store.db.activities.push(activity);
  store.save();

  return {
    activity: presentActivity(activity),
    // 逐条上报的语义：单条创建返回 created（方案 §6.4.1）。
    created: [activity.id],
    updated: [],
    rejected: [],
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 受限编辑（§4.5，验收 A6）
// ─────────────────────────────────────────────────────────────────────────

export function updateActivity(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  const activity = owned;
  const body = ctx.body ?? {};

  // 乐观锁：冲突由 `version` 处理（方案 §2）。
  if (body.version != null && Number(body.version) !== activity.version) {
    return fail(
      'VERSION_CONFLICT',
      `该活动已被更新（当前版本 ${activity.version}），请刷新后重试`,
    );
  }

  const frozen = activity.status !== ACTIVITY_STATUS.DRAFT;
  const changedFrozenFields = [];
  for (const field of FROZEN_FIELDS) {
    if (body[field] == null) {
      continue;
    }
    const incoming = field.endsWith('Time') ? iso(parseTime(body[field])) : body[field];
    const current = activity[field];
    const same =
      field.endsWith('Time')
        ? String(incoming) === String(current)
        : Number(incoming) === Number(current) || String(incoming) === String(current);
    if (!same) {
      changedFrozenFields.push({ field, before: current, after: incoming });
    }
  }

  if (frozen && changedFrozenFields.length > 0) {
    // 关键字段默认禁改，必须**填原因**（方案 §4.5）。
    const reason = (body.changeReason ?? '').trim();
    if (reason.length < 5) {
      return fail(
        'ACTIVITY_RULE_FROZEN',
        '已发布活动的关键字段不可直接修改；确需修改请填写不少于 5 字的修改原因',
        [
          {
            field: 'changeReason',
            message: '请填写修改原因（≥5 字），系统会记录前后值并通知志愿者',
          },
        ],
      );
    }

    // 应用改动。
    const next = normalizeActivity({ ...activity, ...body }, {
      ownerId: activity.ownerId,
      existing: activity,
    });
    Object.assign(activity, next);

    // 记录前后值 + 新快照（仅对未来生效）。
    const revision = (activity.ruleSnapshot?.revision ?? 0) + 1;
    activity.ruleSnapshot = freezeRuleSnapshot(activity, {
      reason,
      changedBy: ctx.auth.ownerId,
      revision,
    });
    for (const ch of changedFrozenFields) {
      logRuleChange(activity.id, {
        field: ch.field,
        before: String(ch.before),
        after: String(ch.after),
        reason,
        changedAt: iso(new Date()),
        changedBy: ctx.auth.ownerId,
        revision,
        notifiedCount: store.db.participants.filter(
          (p) => p.activityId === activity.id && p.boundDeviceId,
        ).length,
      });
    }

    // 时间变更后抽查重算（方案 §14.1-3）：已过期按原规则结案，新增时段补生成。
    regenerateAttendanceTasks(activity, { preserveExisting: true });

    store.save();
    return {
      activity: presentActivity(activity),
      frozenFieldsChanged: changedFrozenFields.map((c) => c.field),
      ruleChangeRecorded: true,
      revision,
      message: '修改已记录，新规则仅对未来生效；历史判定不变',
    };
  }

  // 非关键字段（简介、详情、联系方式、备注）可自由修改。
  const allowed = ['summary', 'description', 'contact', 'tags', 'title', 'organizer', 'location'];
  for (const key of allowed) {
    if (body[key] != null) {
      activity[key] = Array.isArray(body[key]) ? body[key].map(String) : String(body[key]);
    }
  }
  activity.version += 1;
  activity.updatedAt = iso(new Date());
  store.save();

  return { activity: presentActivity(activity) };
}

/** 规则变更记录（管理者的证据，而不是对他的审查）。 */
export function activityChanges(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  return {
    items: store.db.ruleChanges.filter((c) => c.activityId === ctx.params.id),
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 状态流转（§4.4，验收 A7）
// ─────────────────────────────────────────────────────────────────────────

/**
 * 宣布结束的核心逻辑。
 *
 * 被两条入口复用：
 *   * `POST /activities/{id}:transition`（契约主路径，网页方案 §6.4.2）
 *   * `POST /activities/{id}/finish`（REST 风格的便捷别名）
 *
 * 关闭签到与抽查、生成考勤汇总、通知已绑定志愿者。**不产生任何时长扣减**。
 */
function finishActivityCore(ctx, activity, reason = null) {
  if (activity.status === ACTIVITY_STATUS.CANCELLED) {
    return fail('ACTIVITY_STATE_INVALID', '活动已取消，无法宣布结束');
  }
  if (activity.status === ACTIVITY_STATUS.FINISHED) {
    return { activity: presentActivity(activity), alreadyFinished: true };
  }

  const now = new Date();
  activity.status = ACTIVITY_STATUS.FINISHED;
  activity.finishedAt = iso(now);
  activity.terminalAt = iso(now);
  activity.updatedAt = iso(now);
  if (reason) {
    activity.finishReason = reason;
  }

  // 已到响应截止仍未响应的任务立即结案为 missed（方案 §6.2）。
  settleOverdueTasks(activity, now);

  // 授权到期时间随终态刷新为「终态 + 7 天」（网页方案 §4.7）。
  refreshGrantExpiry(activity);

  store.save();
  return {
    activity: presentActivity(activity),
    attendanceSummary: buildAttendanceSummary(activity),
    dataDestroyAt: iso(addMinutes(now, DEFAULTS.RETENTION_DAYS * 24 * 60)),
    reminder: '请在 7 天内完成导出与对账，逾期不可恢复（方案 §14.1-6）',
  };
}

/**
 * 取消活动的核心逻辑。**不可逆**。
 *
 * 必填原因（≥5 字）+ 二次确认（客户端负责二次确认交互，服务端只认原因）。
 * 未发生的抽查置 `excused`，**不冤枉已到场的人**。
 */
function cancelActivityCore(ctx, activity, reason = null) {
  if (activity.status === ACTIVITY_STATUS.CANCELLED) {
    return fail('ACTIVITY_STATE_INVALID', '活动已取消，取消操作不可重复执行');
  }

  const text = String(reason ?? ctx.body?.reason ?? '').trim();
  if (text.length < DEFAULTS.CANCEL_REASON_MIN_LENGTH) {
    return fail('CANCEL_REASON_TOO_SHORT', undefined, [
      {
        field: 'reason',
        message: `请填写不少于 ${DEFAULTS.CANCEL_REASON_MIN_LENGTH} 字的取消原因`,
      },
    ]);
  }

  const now = new Date();
  activity.status = ACTIVITY_STATUS.CANCELLED;
  activity.cancelReason = text;
  activity.cancelledAt = iso(now);
  activity.terminalAt = iso(now);
  activity.updatedAt = iso(now);

  // 未发生的抽查置 excused；已发生（done/missed）的保留原状。
  let excused = 0;
  for (const t of store.db.attendanceTasks) {
    if (t.activityId === activity.id && t.status === 'pending') {
      t.status = 'excused';
      t.excusedAt = iso(now);
      t.excusedReason = '活动取消';
      excused += 1;
    }
  }

  refreshGrantExpiry(activity);
  store.save();

  return {
    activity: presentActivity(activity),
    excusedTasks: excused,
    notifiedCount: store.db.participants.filter(
      (p) => p.activityId === activity.id && p.boundDeviceId,
    ).length,
    irreversible: true,
    message: '活动已取消，此操作不可撤销',
  };
}

/**
 * 开始活动（REST 风格便捷别名）。
 *
 * 主路径是 `POST /activities/{id}:transition`；此别名让"只想到点开始"的
 * 调用方少写一个 `{from,to}` 体。
 */
export function startActivity(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  const activity = owned;
  if (TERMINAL_STATUSES.includes(activity.status)) {
    return fail(
      'ACTIVITY_STATE_INVALID',
      `活动已${activity.status === 'cancelled' ? '取消' : '结束'}，无法开始`,
    );
  }
  if (activity.status === ACTIVITY_STATUS.DRAFT) {
    return fail('ACTIVITY_STATE_INVALID', '草稿活动请先发布');
  }

  activity.status = ACTIVITY_STATUS.ONGOING;
  activity.startedAt = activity.startedAt ?? iso(new Date());
  activity.updatedAt = iso(new Date());

  // 开始即尝试生成抽查任务。此刻通常还没人签到，因此多半生成 0 条；
  // 真正的生成发生在有人签到之后（决策 D-6）。
  regenerateAttendanceTasks(activity, { preserveExisting: true });

  store.save();
  return { activity: presentActivity(activity), attendanceTasks: countTasks(activity.id) };
}

/** 宣布结束（REST 风格便捷别名）。 */
export function finishActivity(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  return finishActivityCore(ctx, owned, ctx.body?.reason);
}

/** 取消活动（REST 风格便捷别名）。 */
export function cancelActivity(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  return cancelActivityCore(ctx, owned, ctx.body?.reason);
}

// ─────────────────────────────────────────────────────────────────────────
// 抽查任务生成（§6.2、§14.1-3）—— 实现在 attendance_engine.js
// ─────────────────────────────────────────────────────────────────────────

/** 活动终态后刷新授权到期时间为「终态 + 7 天」。 */
function refreshGrantExpiry(activity) {
  const expiresAt = iso(grantExpiryFor(activity));
  for (const g of store.db.grants) {
    if (g.activityId === activity.id) {
      g.expiresAt = expiresAt;
    }
  }
  for (const p of store.db.participants) {
    if (p.activityId === activity.id) {
      p.grantExpiresAt = expiresAt;
    }
  }
}

export { CHECKIN_METHOD };

/**
 * `GET /activities/organizers` —— 部门字典（网页筛选栏下拉用）。
 *
 * ## 为什么这个接口必须有
 *
 * 网页的"按部门筛选"是验收项之一。没有字典接口时前端只能
 * 从当前页的活动里凑部门 —— 翻到第 2 页选项就变了，
 * 用户会以为筛选坏了。真服务端早有这个接口，mock 缺它导致
 * 「同一份前端连 mock 和连服务端行为不一致」，很难排查。
 *
 * 口径与真服务端一致：只返回**可见活动**上出现过的部门，去重排序。
 */
export function listOrganizers(ctx) {
  const now = new Date();
  const ownerId = ctx.auth?.kind === 'admin' ? ctx.auth.ownerId : null;
  const seen = new Set();

  for (const a of store.db.activities) {
    if (!a.organizer) {
      continue;
    }
    // 草稿不外泄，过期活动不参与字典。
    if (a.status === ACTIVITY_STATUS.DRAFT && (!ownerId || a.ownerId !== ownerId)) {
      continue;
    }
    if (isRetentionExpired(a, now)) {
      continue;
    }
    seen.add(a.organizer);
  }

  const items = [...seen].sort((x, y) => x.localeCompare(y, 'zh'));
  return { items, total: items.length };
}