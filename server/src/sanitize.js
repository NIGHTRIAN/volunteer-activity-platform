/**
 * 脱敏 —— 服务端侧的单一实现。
 *
 * ## 设计取向：**保守**
 *
 * 早期版本过于激进：它把 13 位时间戳也当成手机号掩码成了
 * `179****000000`，还截断了长度超过阈值的任意数字串。结果是
 * 日志里的时间戳全废了 —— 而排查问题时最需要的恰恰就是时间戳。
 *
 * 现在的规则是：**只掩码能确定是隐私的东西**。
 *   * 11 位、以 1 开头的中国大陆手机号 → 掩码中间四位；
 *   * 带标签的学号/工号（`userNo=2023001`）→ 掩码后几位；
 *   * 令牌类 → 只保留首尾各 4 位。
 *
 * 拿不准的数字（时间戳、ID、距离、评分）**一律不动**。
 */

const PHONE_RE = /(?<!\d)(1[3-9]\d)(\d{4})(\d{4})(?!\d)/g;
const LABELED_ID_RE =
  /((?:userNo|studentNo|学号|工号)\s*[=:：]\s*)([A-Za-z0-9]{4,20})/gi;

/**
 * 掩码手机号：`13800001234` → `138****1234`。
 *
 * 保留前 3 后 4 是为了让发布者能核对"是不是这个人"，
 * 又不足以还原完整号码。
 */
export function maskPhone(value) {
  if (value == null) {
    return value;
  }
  const s = String(value);
  if (s === '') {
    return s;
  }
  return s.replace(PHONE_RE, (_m, head, _mid, tail) => `${head}****${tail}`);
}

/**
 * 掩码学号/工号：`2023001` → `202****`。
 *
 * 学号本身不是强隐私，但配合姓名就能定位到人，
 * 因此在**导出与日志**里默认掩码；看板上仍显示完整学号
 * （发布者需要用它核对身份，且那是授权范围内的界面）。
 */
export function maskUserNo(value) {
  if (value == null) {
    return value;
  }
  const s = String(value).trim();
  if (s.length <= 3) {
    return '***';
  }
  if (s.length <= 6) {
    return `${s.slice(0, 2)}${'*'.repeat(s.length - 2)}`;
  }
  return `${s.slice(0, 3)}${'*'.repeat(Math.max(3, s.length - 3))}`;
}

/** 掩码令牌：只留首尾各 4 位，长度也一并隐藏。 */
export function maskToken(value) {
  if (value == null) {
    return value;
  }
  const s = String(value);
  if (s.length <= 8) {
    return '****';
  }
  return `${s.slice(0, 4)}****${s.slice(-4)}`;
}

/**
 * 掩码联系方式。
 *
 * ## 为什么不能一律按手机号掩码
 *
 * 活动联系人既可能是手机号，也可能是"张老师""教务处"这类**称呼**。
 * 把"张老师"掩成"张**"没有意义 —— 它本来就不是隐私，
 * 而且会让导出/展示里的这一列失去作用（发布者要靠它联系）。
 *
 * 所以只有**看起来确实是手机号**时才掩码，其余原样保留。
 * 这个判断故意写得保守（严格的 11 位 1 开头），避免把
 * 某个恰好形似数字的编号误当手机号。
 */
export function maskContact(value) {
  if (value == null) {
    return value;
  }
  const s = String(value).trim();
  if (s === '') {
    return s;
  }
  if (/^1[3-9]\d{9}$/.test(s)) {
    return `${s.slice(0, 3)}****${s.slice(-4)}`;
  }
  return s;
}

/**
 * 粗化坐标（用于统计与日志）。
 *
 * 精确坐标能定位到具体的人，而统计只关心"哪个校区/哪片区域"。
 * 保留约 1km 精度（小数点后 2 位）足够画分布图。
 */
export function coarsenCoordinate(value, decimals = 2) {
  const n = Number(value);
  if (!Number.isFinite(n)) {
    return null;
  }
  const f = 10 ** decimals;
  return Math.round(n * f) / f;
}

/**
 * 文本脱敏（用于日志与错误信息）。
 *
 * 把内嵌的手机号与带标签的学号掩掉，其余原样保留。
 */
export function sanitizeText(value) {
  if (value == null) {
    return value;
  }
  let s = String(value);
  s = maskPhone(s);
  s = s.replace(LABELED_ID_RE, (_m, label, id) => `${label}${maskUserNo(id)}`);
  return s;
}

/**
 * 深拷贝并脱敏一个对象（用于写审计与日志）。
 *
 * 与 `logger.redactForLog` 的区别：这个按**键名**精确掩码，
 * 用于需要保留结构（供接口返回）的场合；logger 那个还会做深度截断。
 */
export function sanitizeObject(value, sensitiveKeys = []) {
  const keys = new Set([
    'phone',
    'mobile',
    'phoneSuffix',
    'token',
    'inviteCode',
    'password',
    'secret',
    ...sensitiveKeys,
  ]);

  const walk = (v) => {
    if (v == null) {
      return v;
    }
    if (typeof v === 'string') {
      return sanitizeText(v);
    }
    if (typeof v !== 'object') {
      return v;
    }
    if (Array.isArray(v)) {
      return v.map(walk);
    }
    const out = {};
    for (const [k, val] of Object.entries(v)) {
      if (keys.has(k)) {
        out[k] = typeof val === 'string' ? maskToken(val) : '****';
      } else if (k === 'userNo') {
        out[k] = typeof val === 'string' ? maskUserNo(val) : val;
      } else {
        out[k] = walk(val);
      }
    }
    return out;
  };

  return walk(value);
}
