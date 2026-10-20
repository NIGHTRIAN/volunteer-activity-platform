/**
 * 格式化与脱敏（前端侧）。
 *
 * ## 时间显示口径（方案 §4.2 / §8）
 *
 * 传输用 ISO 8601 含偏移，**展示一律 `yyyy-MM-dd HH:mm`**。
 * 不显示秒 —— 活动时间精确到分钟就够，多出来的两位只是噪声。
 *
 * ## 关于脱敏
 *
 * 服务端已经做了脱敏（Web 端只读，拿到的 `contact` 本应是掩码后的）。
 * 但前端**仍然再过一遍** —— 理由不是不信任服务端，而是：
 * 前端可能被接到一个未脱敏的数据源（联调期直连 Mock、
 * 或者将来某个接口忘了脱敏）。多一层廉价的防护，
 * 代价只是几行代码，而漏一次就是完整手机号出现在公网上。
 */

/** 把 ISO 时间格成 `yyyy-MM-dd HH:mm`。 */
export function formatDateTime(value) {
  const d = toDate(value);
  if (!d) {
    return '';
  }
  const p = (n) => String(n).padStart(2, '0');
  return (
    `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
    `${p(d.getHours())}:${p(d.getMinutes())}`
  );
}

/** 只要日期 `yyyy-MM-dd`。 */
export function formatDate(value) {
  const d = toDate(value);
  if (!d) {
    return '';
  }
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/**
 * 时间范围。
 *
 * 同一天时合并日期，避免重复：
 *   `2026-10-16 09:00 ~ 13:00`（同一天）
 *   `2026-10-16 09:00 ~ 2026-10-17 12:00`（跨天）
 *
 * 这是列表里最常见的字段，重复的日期每天都在浪费读者的注意力。
 */
export function formatRange(start, end) {
  const s = toDate(start);
  const e = toDate(end);
  if (!s) {
    return '';
  }
  if (!e) {
    return formatDateTime(start);
  }
  const sameDay =
    s.getFullYear() === e.getFullYear() &&
    s.getMonth() === e.getMonth() &&
    s.getDate() === e.getDate();
  if (sameDay) {
    const p = (n) => String(n).padStart(2, '0');
    return (
      `${formatDateTime(s)} ~ ` +
      `${p(e.getHours())}:${p(e.getMinutes())}`
    );
  }
  return `${formatDateTime(s)} ~ ${formatDateTime(e)}`;
}

/** 时长：`3` → `3 小时`；`1.5` → `1.5 小时`。 */
export function formatDuration(hours) {
  const n = Number(hours);
  if (!Number.isFinite(n) || n <= 0) {
    return '';
  }
  // 整数不显示 `.0`（`3 小时` 比 `3.0 小时` 自然）。
  return `${Number.isInteger(n) ? n : n} 小时`;
}

/**
 * 相对时间（"3 天后"、"已结束 2 天"）。
 *
 * 只在**辅助位置**使用（例如"即将开始"提示），
 * 主时间一律用绝对时间：相对时间需要读者自己换算，
 * 而活动时间是必须精确的信息。
 */
export function formatRelative(value, now = new Date()) {
  const d = toDate(value);
  if (!d) {
    return '';
  }
  const diffMs = d.getTime() - now.getTime();
  const absMin = Math.abs(diffMs) / 60_000;
  const future = diffMs > 0;

  if (absMin < 1) {
    return future ? '即将开始' : '刚刚';
  }
  if (absMin < 60) {
    return future ? `${Math.round(absMin)} 分钟后` : `${Math.round(absMin)} 分钟前`;
  }
  const hours = absMin / 60;
  if (hours < 24) {
    return future ? `${Math.round(hours)} 小时后` : `${Math.round(hours)} 小时前`;
  }
  const days = hours / 24;
  if (days < 30) {
    return future ? `${Math.round(days)} 天后` : `${Math.round(days)} 天前`;
  }
  return formatDate(d);
}

/** 宽松解析时间；失败返回 `null`。 */
export function toDate(value) {
  if (!value) {
    return null;
  }
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? null : value;
  }
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
}

// ══════════════════════════════════════════════════════════════════════
// 脱敏
// ══════════════════════════════════════════════════════════════════════

const PHONE_RE = /(?<!\d)(1[3-9]\d)(\d{4})(\d{4})(?!\d)/g;

/**
 * 掩码手机号：`13800001234` → `138****1234`。
 *
 * 保留前 3 后 4 是为了让发布者能核对"是不是这个人",
 * 又不足以还原完整号码。
 */
export function maskPhone(value) {
  if (value == null || value === '') {
    return '';
  }
  return String(value).replace(PHONE_RE, (_m, head, _mid, tail) => `${head}****${tail}`);
}

/**
 * 掩码学号：`2023001` → `202****`。
 *
 * 学号本身不算强隐私，但配合姓名就能定位到人。
 */
export function maskUserNo(value) {
  const s = String(value ?? '').trim();
  if (!s) {
    return '';
  }
  if (s.length <= 3) {
    return '***';
  }
  if (s.length <= 6) {
    return `${s.slice(0, 2)}${'*'.repeat(s.length - 2)}`;
  }
  return `${s.slice(0, 3)}${'*'.repeat(Math.max(3, s.length - 3))}`;
}

/**
 * 掩码联系人：既可能是手机号，也可能是"张老师"这类称呼。
 *
 * 只有看起来像手机号时才掩码 —— 把"张老师"掩成"张**"没有意义，
 * 反而让联系人信息失去作用。
 */
export function maskContact(value) {
  const s = String(value ?? '').trim();
  if (!s) {
    return '';
  }
  if (/^1[3-9]\d{9}$/.test(s)) {
    return maskPhone(s);
  }
  return s;
}

/**
 * 截断长文本（列表项用）。
 *
 * ⚠️ 截断会丢失内容，因此**必须**保证完整内容在别处可达 ——
 * 本项目里就是折叠详情。纯 CSS 截断也可以，这个函数用于
 * 需要在 JS 里判断长度的场合（例如决定是否显示"查看详情"）。
 */
export function truncate(text, max = 120) {
  const s = String(text ?? '').trim();
  if (s.length <= max) {
    return s;
  }
  return `${s.slice(0, max).trimEnd()}…`;
}

/**
 * 取纯文本摘要（用于列表与 meta description）。
 *
 * 去掉换行与多余空白：`description` 里常带换行，
 * 直接塞进列表项会出现诡异的空洞。
 */
export function toPlainSummary(text, max = 120) {
  const s = String(text ?? '')
    .replace(/\s+/g, ' ')
    .trim();
  return truncate(s, max);
}

/** 距离：`< 1km` 用米，否则用公里。 */
export function formatDistance(meters) {
  const n = Number(meters);
  if (!Number.isFinite(n)) {
    return '';
  }
  if (n < 1000) {
    return `${Math.round(n)} 米`;
  }
  return `${(n / 1000).toFixed(1)} 公里`;
}

/** 百分比（0–1 → `85%`）。`null` 表示无数据，不是 0%。 */
export function formatRate(rate) {
  if (rate === null || rate === undefined || !Number.isFinite(Number(rate))) {
    // ⚠️ 「无数据」与「0%」必须区分开：把没数据画成 0%，
    // 看起来像"这个人一次都没到"，那是对人的错误指控。
    return null;
  }
  return `${Math.round(Number(rate) * 100)}%`;
}
