/**
 * 分配一个单调递增的全局序号。
 *
 * ## 为什么增量同步需要它
 *
 * 增量接口（网页方案 §6.4.9）用游标表示"同步到哪儿了"。**时间戳不能当游标**：
 * 同一毫秒内可以发生多次写入（种子数据一次性写了 5 个活动，时间戳完全相同），
 * 于是 `updatedAt > cursor` 要么漏掉同毫秒的记录、要么为了不漏而整体回退，
 * 两种都不对。
 *
 * 实测踩到过：把游标回退 1ms 后，5 个共享同一时间戳的种子活动会被反复下发；
 * 不回退则同毫秒内新建的记录永久漏同步。
 *
 * 因此改用**全局单调序号**：每次写入 +1，天然全序、不可能并列。
 * 真实服务端用数据库自增 ID 或 `ROWVERSION` 也能达到同样效果。
 *
 * 注意：序号只在 `store.save()` 里 +1 一次，但同一次保存可能改了多条记录，
 * 它们共享同一个序号 —— 这没问题，因为游标语义是 `>`（或 `>=` 由调用方决定），
 * 同批写入要么整批被看到、要么整批跳过，不会只看到一半。
 */
export function nextSeq() {
  store.db.meta.seq = (store.db.meta.seq ?? 0) + 1;
  return store.db.meta.seq;
}

/** 当前全局序号。 */
export function currentSeq() {
  return store.db.meta.seq ?? 0;
}

/**
 * 数据存储：JSON 文件持久化，零外部依赖。
 *
 * 为什么不用 SQLite：Mock 的唯一职责是**让两端 App 在服务端未就绪时能独立开发**。
 * 单文件 JSON 便于查看、重置、以及把某个状态快照直接贴给对方排查问题。
 * 生产实现由《网页开发方案》决定，本 Mock 不承担性能目标。
 *
 * 持久化策略：内存为唯一真源，写操作后立即落盘（同步写 + 原子替换）。
 * 注意：本 Mock **不实现** 7 天留存期的数据销毁，只在接口层面按留存期
 * 隐藏过期活动（验收用例 A21 的行为可验证）。
 */

import fs from 'node:fs';
import path from 'node:path';
import { DEFAULTS, TERMINAL_STATUSES } from './constants.js';
/** 生成短 ID。 */
export function newId(prefix = '') {
  const rand = Math.random().toString(36).slice(2, 10);
  const t = Date.now().toString(36);
  return `${prefix}${t}${rand}`;
}

/** ISO-8601 带本地时区偏移，与 App 侧 TimeFormat.toIso8601 口径一致。 */
export function iso(date) {
  const d = date instanceof Date ? date : new Date(date);
  if (Number.isNaN(d.getTime())) {
    return null;
  }
  const pad = (n, w = 2) => String(n).padStart(w, '0');
  const offMin = -d.getTimezoneOffset();
  const sign = offMin < 0 ? '-' : '+';
  const abs = Math.abs(offMin);
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}` +
    `${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`
  );
}

/** 解析时间，兼容 ISO 串、毫秒/秒时间戳。 */
export function parseTime(v) {
  if (v == null) {
    return null;
  }
  if (v instanceof Date) {
    return Number.isNaN(v.getTime()) ? null : v;
  }
  if (typeof v === 'number') {
    return new Date(v > 1e12 ? v : v * 1000);
  }
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
}

/** 加分钟。 */
export function addMinutes(date, minutes) {
  return new Date(date.getTime() + minutes * 60_000);
}

const DATA_DIR = process.env.MOCK_DATA_DIR
  ? path.resolve(process.env.MOCK_DATA_DIR)
  : path.resolve(import.meta.dirname, '..', '.data');
const DATA_FILE = path.join(DATA_DIR, 'mock-db.json');

/** 空库结构。 */
function emptyDb() {
  return {
    meta: {
      createdAt: iso(new Date()),
      seedVersion: 1,
    },
    /** 管理员账号（按 ownerId 隔离，方案 §2）。 */
    admins: [],
    /** 管理员登录审计（方案 §2 缓解措施③）。 */
    loginAudits: [],
    /** 登录失败计数：{ ip: { count, lockedUntil } }。 */
    loginFailures: {},
    /** 活动。 */
    activities: [],
    /** 名单条目：{ activityId, userNo, ... }。 */
    participants: [],
    /** 一次性邀请码：{ activityId, userNo, code, ... }。 */
    inviteCodes: [],
    /** 志愿者设备授权。 */
    grants: [],
    /** 签到记录。 */
    checkins: [],
    /** 在岗任务。 */
    attendanceTasks: [],
    /** 幂等键记录：{ key, endpoint, requestHash, response }。 */
    idempotency: {},
    /** 规则变更记录（§4.5）。 */
    ruleChanges: [],
    /** 导出任务。 */
    exports: [],
    /** 动态码签发历史（降级手段，§6.3）。 */
    codes: [],
  };
}

/**
 * 存储单例。
 *
 * 所有写操作都经过 {@link Store.save}，保证落盘。
 */
class Store {
  constructor() {
    /** @type {ReturnType<typeof emptyDb>} */
    this.db = emptyDb();
    this.dirty = false;
  }

  /** 从磁盘加载；文件不存在则建空库。 */
  load() {
    try {
      if (fs.existsSync(DATA_FILE)) {
        const raw = fs.readFileSync(DATA_FILE, 'utf8');
        const parsed = JSON.parse(raw);
        // 合并到空库结构上，保证新增集合不会因旧文件缺失而 undefined。
        this.db = { ...emptyDb(), ...parsed };
        this.db.meta = { ...emptyDb().meta, ...(parsed.meta ?? {}) };
        return true;
      }
    } catch (err) {
      // 文件损坏时**不静默丢数据**：改名备份后从空库启动，并明确报错。
      const backup = `${DATA_FILE}.corrupt-${Date.now()}`;
      try {
        fs.renameSync(DATA_FILE, backup);
        console.error(`[store] 数据文件损坏，已备份到 ${backup}：${err.message}`);
      } catch {
        console.error(`[store] 数据文件损坏且备份失败：${err.message}`);
      }
    }
    this.db = emptyDb();
    this.save();
    return false;
  }

  /** 落盘（原子替换，避免写一半断电留下半个文件）。 */
  save() {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    const tmp = `${DATA_FILE}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.db, null, 2), 'utf8');
    fs.renameSync(tmp, DATA_FILE);
    this.dirty = false;
  }

  /**
   * 标记变更并分配新序号，然后落盘。
   *
   * 所有**业务写入**都应调用它而不是裸 `save()`，这样增量同步的游标才能推进。
   * 保留裸 `save()` 是给"只落盘、没有业务变更"的场景（例如惰性结算）。
   */
  commit() {
    const seq = (this.db.meta.seq ?? 0) + 1;
    this.db.meta.seq = seq;
    this.save();
    return seq;
  }

  /** 清空并重建（测试用）。 */
  reset() {
    this.db = emptyDb();
    this.save();
  }

  /** 数据文件路径，启动日志里打印，方便运维定位。 */
  get filePath() {
    return DATA_FILE;
  }
}

export const store = new Store();

// ─────────────────────────────────────────────────────────────────────────
// 查询 helper
// ─────────────────────────────────────────────────────────────────────────

/** 按 ID 找活动。 */
export function findActivity(id) {
  return store.db.activities.find((a) => a.id === id) ?? null;
}

/**
 * 按 ID 找活动，并应用留存期可见性规则。
 *
 * 活动进入终态 7 天后，业务数据应在接口层面视为已销毁（验收用例 A21）。
 * Mock 只隐藏，不真正删除——便于反复验证同一份数据。
 */
export function findVisibleActivity(id, now = new Date()) {
  const a = findActivity(id);
  if (!a) {
    return null;
  }
  if (isRetentionExpired(a, now)) {
    return null;
  }
  return a;
}

/** 是否已过留存期（终态 + 7 天）。 */
export function isRetentionExpired(activity, now = new Date()) {
  if (!TERMINAL_STATUSES.includes(activity.status) || !activity.terminalAt) {
    return false;
  }
  const destroyAt = addMinutes(parseTime(activity.terminalAt), DEFAULTS.RETENTION_DAYS * 24 * 60);
  return now.getTime() > destroyAt.getTime();
}

/** 留存销毁时刻。 */
export function retentionDestroyAt(activity) {
  if (!activity.terminalAt) {
    return null;
  }
  return addMinutes(parseTime(activity.terminalAt), DEFAULTS.RETENTION_DAYS * 24 * 60);
}

/** 某活动的有效名单（不含已移出）。 */
export function activeParticipants(activityId) {
  return store.db.participants.filter(
    (p) => p.activityId === activityId && p.signupStatus !== 'cancelled' && !p.removedAt,
  );
}

/** 某活动的全部名单（含已移出，用于看板标注）。 */
export function allParticipants(activityId) {
  return store.db.participants.filter((p) => p.activityId === activityId);
}

/** 找名单条目。 */
export function findParticipant(activityId, userNo) {
  return (
    store.db.participants.find((p) => p.activityId === activityId && p.userNo === userNo) ?? null
  );
}

/** 某活动的签到记录。 */
export function activityCheckins(activityId) {
  return store.db.checkins.filter((c) => c.activityId === activityId);
}

/** 某人在某活动的有效签到（一条有效签到的约束，§6.1）。 */
export function findEffectiveCheckin(activityId, userNo) {
  return (
    store.db.checkins.find(
      (c) =>
        c.activityId === activityId &&
        c.userNo === userNo &&
        (c.status === 'success' || c.status === 'pending_review'),
    ) ?? null
  );
}

/** 某活动的在岗任务。 */
export function activityTasks(activityId) {
  return store.db.attendanceTasks.filter((t) => t.activityId === activityId);
}

/** 某人的在岗任务。 */
export function userTasks(activityId, userNo) {
  return store.db.attendanceTasks.filter((t) => t.activityId === activityId && t.userNo === userNo);
}

/** 找邀请码。 */
export function findInviteCode(activityId, code) {
  return (
    store.db.inviteCodes.find((c) => c.activityId === activityId && c.code === code) ?? null
  );
}

/** 找授权（按令牌）。 */
export function findGrantByToken(token) {
  return store.db.grants.find((g) => g.token === token) ?? null;
}

/** 找管理员（按令牌）。 */
export function findAdminByToken(token) {
  return store.db.admins.find((a) => a.token === token) ?? null;
}

/**
 * 记录登录审计（方案 §2 缓解措施③）。
 *
 * ⚠️ 隐私底线：审计只记时间/设备/IP，**不记完整手机号或学号**
 * （README §3.3 底线②）。
 */
export function auditLogin({ deviceId, ip, success, failureReason = null, ownerId = null }) {
  store.db.loginAudits.unshift({
    at: iso(new Date()),
    deviceId: deviceId ?? '',
    ip: ip ?? null,
    success,
    failureReason,
    ownerId,
  });
  // 只保留最近 500 条，避免 Mock 数据文件无限膨胀。
  if (store.db.loginAudits.length > 500) {
    store.db.loginAudits.length = 500;
  }
}

/** 记录规则变更（§4.5）。 */
export function logRuleChange(activityId, entry) {
  store.db.ruleChanges.unshift({ activityId, ...entry });
}

/**
 * 活动级授权到期时间（方案 §5.2）。
 *
 * 规则：`grant.expiresAt = 活动终态 + 7 天`。
 *
 * 活动尚未进入终态时没有确切的终态时刻，因此给一个**保守上限**：
 * 预计结束时间 + 留存期。活动真正结束时由服务端把授权刷新为「终态 + 7 天」。
 * 放在 store 层是因为 auth、activities、checkin 三处都要用同一套算法——
 * 分散实现迟早会算出不同的到期时间。
 */
export function grantExpiryFor(activity) {
  const retentionMs = DEFAULTS.RETENTION_DAYS * 24 * 60 * 60_000;
  if (TERMINAL_STATUSES.includes(activity.status) && activity.terminalAt) {
    return new Date(parseTime(activity.terminalAt).getTime() + retentionMs);
  }
  return new Date(parseTime(activity.endTime).getTime() + retentionMs);
}
