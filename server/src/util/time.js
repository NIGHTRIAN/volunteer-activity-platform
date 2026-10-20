/**
 * 时间处理 —— 全库统一 **ISO 8601 含偏移的字符串**。
 *
 * ## 为什么不用数据库的时间类型
 *
 * 方案 §8.3 要求服务器时区为 `Asia/Shanghai` 且 NTP 必须启用 ——
 * 也就是说**时区是可能配错的**。而签到窗口与在岗响应窗口都是时间敏感的：
 * 时区错了，窗口会集体偏移，现场表现是"明明到点了却签不上"，
 * 而排查时几乎没人会先怀疑服务器时区。
 *
 * 存 ISO 字符串 + 应用层统一解析，就把这个风险从"静默错判"
 * 降为"一眼可见"（字符串里带着 `+08:00`，错了看得出来）。
 *
 * ## 解析宽容度
 *
 * 服务端要接受三种写法，因为它们都合法且都可能从客户端来：
 *   * `2026-10-16T09:00:00+08:00` —— 契约规定的传输格式；
 *   * `2026-10-16T09:00:00Z` —— UTC；
 *   * `2026-10-16 09:00` —— 人手工填入（管理端备注、种子数据）。
 *
 * 第三种按**本地时区**解释。这是刻意的：手工输入的人想的是墙上时钟，
 * 把它当成 UTC 会让时间偏 8 小时。
 */

/** 无偏移的 `YYYY-MM-DD HH:mm(:ss)?`。 */
const NAIVE_RE = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$/;

/**
 * 解析时间为 `Date`；无法解析返回 `null`。
 *
 * ⚠️ 返回 `null` 而不是抛异常：调用方需要区分"没填"与"填错"，
 * 抛异常会迫使每个调用点写 try/catch。
 */
export function parseTime(value) {
  if (value == null || value === '') {
    return null;
  }
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? null : value;
  }

  const s = String(value).trim();

  // 纯数字：按毫秒时间戳处理（测试与内部调用会用到）。
  if (/^\d{10,13}$/.test(s)) {
    const n = Number(s);
    const d = new Date(s.length === 10 ? n * 1000 : n);
    return Number.isNaN(d.getTime()) ? null : d;
  }

  const naive = NAIVE_RE.exec(s);
  if (naive) {
    const [, y, mo, d, h, mi, sec] = naive;
    // 注意：`new Date(y, mo-1, ...)` 用**本地时区** —— 见文件头说明。
    return new Date(
      Number(y),
      Number(mo) - 1,
      Number(d),
      Number(h),
      Number(mi),
      Number(sec ?? 0),
    );
  }

  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
}

/** 解析失败时抛异常（用于必须合法的场合，例如写库前）。 */
export function requireTime(value, field = '时间') {
  const d = parseTime(value);
  if (!d) {
    throw new Error(`${field}格式不正确：${value}`);
  }
  return d;
}

function pad(n, width = 2) {
  return String(n).padStart(width, '0');
}

/**
 * 转 ISO 8601（**带本地偏移**）。
 *
 * 例：`2026-10-16T09:00:00+08:00`
 *
 * 不用 `toISOString()`：那会转成 UTC（`...T01:00:00.000Z`），
 * 而契约要求带 `+08:00`。移动端早期就是直接 `toISOString()`，
 * 结果前端显示的时间比实际早 8 小时。
 */
export function toIso(value) {
  const d = value instanceof Date ? value : parseTime(value);
  if (!d) {
    return null;
  }
  const offsetMin = -d.getTimezoneOffset();
  const sign = offsetMin >= 0 ? '+' : '-';
  const abs = Math.abs(offsetMin);
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
    `T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}` +
    `${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`
  );
}

/** 当前时刻的 ISO 字符串。 */
export function nowIso() {
  return toIso(new Date());
}

/** 加分钟后的 ISO 字符串。 */
export function addMinutesIso(base, minutes) {
  const d = parseTime(base);
  if (!d) {
    return null;
  }
  return toIso(new Date(d.getTime() + minutes * 60_000));
}

/** 加天数后的 ISO 字符串。 */
export function addDaysIso(base, days) {
  return addMinutesIso(base, days * 24 * 60);
}

/** 加天数后的 `Date`（内部计算用）。 */
export function addDays(base, days) {
  const d = parseTime(base);
  if (!d) {
    return null;
  }
  return new Date(d.getTime() + days * 24 * 3600_000);
}

/** 两个时间相差的分钟数（`a - b`）。 */
export function minutesBetween(a, b) {
  const da = parseTime(a);
  const db = parseTime(b);
  if (!da || !db) {
    return null;
  }
  return (da.getTime() - db.getTime()) / 60_000;
}

/** 格式化为 `yyyy-MM-dd HH:mm`（展示用，方案 §8）。 */
export function formatDisplay(value) {
  const d = parseTime(value);
  if (!d) {
    return '';
  }
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}`
  );
}
