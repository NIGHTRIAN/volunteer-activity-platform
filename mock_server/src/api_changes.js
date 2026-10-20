/**
 * 增量同步：`GET /changes?since=&limit=`（《网页开发方案》§6.4.9）。
 *
 * ## 契约
 *
 * ```
 * GET /api/v1/changes?since=<cursor>&limit=200
 *   → { nextCursor, hasMore, items:[{op,id,...}] }
 * ```
 * 「游标 7 天幂等窗口；降级方案为时间窗拉取。」
 *
 * ## 为什么需要它
 *
 * 方案 §6.5 要求「端到端同步延迟 ≤ 60s」。用户端是**无限滚动 + 前台轮询**的形态，
 * 如果每次都全量拉列表，活动多了以后流量和延迟都不可接受。
 * 增量接口让客户端用一条轻量请求问"自上次以来有什么变了"。
 *
 * ## 游标的两种形态
 *
 * `since` 接受：
 *   * **游标**（本 Mock 返回的 `nextCursor`，形如 `c<毫秒时间戳>`）——优先；
 *   * **ISO 时间**（降级方案：客户端只记得大概时间时用）。
 *
 * 两种都支持是刻意的：方案把"时间窗拉取"写成降级方案，说明它允许客户端
 * 在丢失游标时退化为按时间拉。只支持游标会让"游标丢失"变成死路。
 *
 * ## 7 天幂等窗口
 *
 * 早于 `now - 7 天` 的游标一律按「超出窗口」处理，从头给出**当前快照的 id 列表**。
 * 理由：方案说窗口是 7 天，超过窗口的差异记录已无意义（活动本身也该销毁了），
 * 此时让客户端"重新对齐一次"比返回一个巨大的差异集更合理。
 */

import { CATALOG, DEFAULTS, TERMINAL_STATUSES } from './constants.js';
import { store, iso, parseTime } from './store.js';

/** 7 天幂等窗口（与留存期同口径）。 */
const CURSOR_WINDOW_MS = DEFAULTS.RETENTION_DAYS * 24 * 60 * 60 * 1000;

/** 默认与最大 limit。方案给的示例是 200。 */
const DEFAULT_LIMIT = 200;
const MAX_LIMIT = 500;

/**
 * 把**序号**编码成游标。
 *
 * ⚠️ 曾经用毫秒时间戳做游标（`c<ms>`），实测失败：
 * 同一次 `store.save()` 写入的多条记录时间戳**完全相同**，于是
 * `updatedAt > cursor` 要么漏掉同毫秒的记录、要么为了不漏而整体回退，
 * 后者会让那批记录被反复下发。时间戳根本不构成全序，不能当游标。
 *
 * 改用 `store.nextSeq()` 分配的**全局单调序号**：写入一次 +1，天然全序。
 * 真实服务端用数据库自增 ID / ROWVERSION 也是同样道理。
 */
function encodeCursor(seq) {
  return `s${seq}`;
}

/**
 * 解析 `since`，返回 `{ seq }` 或 `null`（表示首次对齐）。
 *
 * 接受三种形态：
 *   * `s<序号>` —— 本接口返回的游标（**首选**，天然全序、不会并列）；
 *   * ISO 时间  —— 降级方案（方案 §6.4.9 说"时间窗拉取"是降级手段）。
 *     按时间换算成"该时刻之前的写入都算已见"，即 seq 取 0 并配合时间过滤；
 *   * 非法值     —— 当成首次对齐。
 */
function parseSince(raw) {
  if (raw == null || raw === '') {
    return null;
  }
  const s = String(raw).trim();

  // 序号游标
  if (s.startsWith('s')) {
    const seq = Number(s.slice(1));
    if (Number.isFinite(seq) && seq >= 0) {
      return { seq, timeMs: null };
    }
  }

  // 时间窗形态（降级方案）
  const t = parseTime(s);
  if (t) {
    return { seq: null, timeMs: t.getTime() };
  }

  return null;
}

/**
 * 增量变更查询。
 *
 * 每个变更条目形如 `{ op, id, ... }`：
 *   * `op`：`upsert`（新增或更新）/ `delete`（软删）
 *   * `id`：活动 ID
 *   * 附带轻量字段，够客户端更新列表项即可（不带 `description` 等大字段）
 */
export function changes(ctx) {
  const now = new Date();
  const limit = Math.min(
    MAX_LIMIT,
    Math.max(1, Number(ctx.query.limit ?? DEFAULT_LIMIT) || DEFAULT_LIMIT),
  );

  const since = parseSince(ctx.query.since);
  const windowStart = now.getTime() - CURSOR_WINDOW_MS;

  // 时间窗形态：早于 7 天窗口的时间点视为"无法增量"，走全量对齐。
  const timeCursorStale =
    since != null && since.timeMs != null && since.timeMs < windowStart;

  // 需要全量对齐的三种情况：首次、时间游标超窗、游标非法。
  const needsFullSnapshot = since == null || timeCursorStale;

  const isAdmin = ctx.auth?.kind === 'admin';
  const isVolunteer = ctx.auth?.kind === 'volunteer';

  // 可见性过滤：草稿仅发布者可见；志愿者只看自己被授权的活动；
  // 已过留存期的活动一律不可见（验收 A21）。
  const visible = store.db.activities.filter((a) => {
    if (isExpired(a, now)) {
      return false;
    }
    if (isAdmin) {
      return a.ownerId === ctx.auth.ownerId;
    }
    if (isVolunteer) {
      return a.id === ctx.auth.activityId && a.status !== 'draft';
    }
    return a.status !== 'draft';
  });

  if (needsFullSnapshot) {
    const items = visible.map((a) => toChangeItem(a, 'upsert'));
    const page = items.slice(0, limit);
    return {
      // 全量快照也要分页：活动可能上千条，一次吐完会撑爆客户端。
      items: page,
      hasMore: items.length > limit,
      // 游标取**已返回数据里的最大 seq**（不是全局 seq）。
      // 取全局 seq 会把"本次快照没返回、但 seq 更小"的记录永久跳过
      //（分页时就会发生），而取已返回数据的最大值则保证：下一页必然
      // 从"还没返回过的最小 seq"继续。
      nextCursor: encodeCursor(maxSeqOf(page)),
      // 明确告诉客户端这次是**全量对齐**而不是增量，便于它决定是否替换整个列表。
      fullSnapshot: true,
      reason:
        since == null
          ? '未提供 since，返回当前快照'
          : `时间游标早于 ${DEFAULTS.RETENTION_DAYS} 天窗口，已重新对齐`,
      limit,
      windowDays: DEFAULTS.RETENTION_DAYS,
      serverTime: iso(now),
    };
  }

  // ── 增量 ──────────────────────────────────────────────────────────
  //
  // 两种游标各按各的方式过滤：
  //   * seq 游标：`a.seq > since.seq` —— 全序，不会漏也不会重；
  //   * 时间游标（降级）：`updatedAt > since.timeMs`，可能因同毫秒并列而
  //     多返回或少返回，因此**只作为降级路径**，并明确告知客户端不是精确增量。
  const isTimeCursor = since.timeMs != null;

  const changed = visible
    .filter((a) => {
      if (isTimeCursor) {
        const updated = parseTime(a.updatedAt ?? a.createdAt);
        return updated != null && updated.getTime() > since.timeMs;
      }
      // `seq` 可能缺失（手工造的数据）——按 0 处理，让它们必然被下发一次。
      return (a.seq ?? 0) > since.seq;
    })
    .sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0));

  const page = changed.slice(0, limit);

  return {
    items: page.map((a) => toChangeItem(a, 'upsert')),
    hasMore: changed.length > limit,
    nextCursor: encodeCursor(
      page.length > 0 ? maxSeqOf(page) : Math.max(since.seq ?? 0, 0),
    ),
    fullSnapshot: false,
    // 时间游标是降级路径，明确标出来让客户端知道"这次可能不精确"。
    approximateCursor: isTimeCursor,
    // 软删/过期的活动：本 Mock 不做物理删除，因此额外下发 id 让客户端摘掉。
    removedIds: store.db.activities
      .filter((a) => isAdmin && a.ownerId === ctx.auth.ownerId && isExpired(a, now))
      .map((a) => a.id),
    limit,
    windowDays: DEFAULTS.RETENTION_DAYS,
    serverTime: iso(now),
  };
}

/** 条目里最大的 `seq`。 */
function maxSeqOf(items) {
  let max = 0;
  for (const it of items) {
    const s = Number(it.seq ?? 0);
    if (s > max) {
      max = s;
    }
  }
  return max;
}

/** 变更条目里最大的 `updatedAt`；无条目时退回 `now`。 */
function maxUpdatedAt(items, now) {
  let max = 0;
  for (const it of items) {
    const ms = parseTime(it.updatedAt)?.getTime() ?? 0;
    if (ms > max) {
      max = ms;
    }
  }
  return max > 0 ? max : now.getTime();
}

/** 是否已过留存期（终态 + 7 天）。 */
function isExpired(activity, now) {
  if (!TERMINAL_STATUSES.includes(activity.status) || !activity.terminalAt) {
    return false;
  }
  const destroyAt =
    parseTime(activity.terminalAt).getTime() + DEFAULTS.RETENTION_DAYS * 24 * 60 * 60 * 1000;
  return now.getTime() > destroyAt;
}

/**
 * 变更条目。
 *
 * **只带列表页需要的字段**（方案 §4.2 的列表展示项），
 * 不带 `description` / `contact` 等大字段——增量接口会被高频调用，
 * 把详情塞进来会让"轻量同步"失去意义。客户端要看详情就单独请求详情接口。
 */
function toChangeItem(a, op) {
  return {
    op,
    id: a.id,
    // 增量游标（客户端不解析，只回传）。
    seq: a.seq ?? 0,
    externalId: a.externalId ?? null,
    title: a.title,
    organizer: a.organizer,
    durationHours: a.durationHours,
    startTime: a.startTime,
    endTime: a.endTime,
    status: a.status,
    tags: a.tags ?? [],
    summary: a.summary ?? '',
    updatedAt: a.updatedAt,
  };
}

export { CATALOG };
