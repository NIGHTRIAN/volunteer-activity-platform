/**
 * 日志 —— 出站日志的**唯一出口**，且默认脱敏。
 *
 * ## 为什么必须有单一出口
 *
 * README §3.3 底线②要求「日志不含完整手机号 / 学号」。
 * 如果允许各处 `console.log(obj)`，那么只要有人在某处打了一个
 * 参与者对象，完整手机号就落进了日志文件 —— 而这种疏漏
 * **不会在测试里暴露**，只会在某次事故复盘时才发现。
 *
 * 因此：业务代码不直接用 `console`，一律走这里；这里在写出前
 * 统一过一遍脱敏。
 *
 * ## 脱敏是"保守"的
 *
 * 只掩码**确定是手机号/学号**的东西（11 位手机号、带标签的学号），
 * 不碰通用数字 —— 早期版本把 13 位时间戳也掩码成了 `179****000000`，
 * 那会让日志失去排查价值。
 */

import { maskPhone, maskUserNo, maskToken } from './sanitize.js';

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };

/** 敏感键名 → 掩码函数。命中即掩码，不看值长什么样。 */
const SENSITIVE_KEYS = new Map([
  ['phone', maskPhone],
  ['mobile', maskPhone],
  ['phoneNumber', maskPhone],
  ['phoneSuffix', () => '****'],
  ['userNo', maskUserNo],
  ['studentNo', maskUserNo],
  ['idCard', () => '****'],
  ['token', maskToken],
  ['authorization', maskToken],
  ['inviteCode', maskToken],
  ['password', () => '****'],
  ['secret', () => '****'],
]);

/**
 * 递归脱敏一个值，用于日志输出。
 *
 * @param {*} value
 * @param {number} [depth] 防止循环引用把栈打爆。
 */
export function redactForLog(value, depth = 0) {
  if (depth > 6) {
    return '[深度截断]';
  }
  if (value == null) {
    return value;
  }
  if (typeof value === 'string') {
    return value.length > 500 ? `${value.slice(0, 500)}…[截断]` : value;
  }
  if (typeof value !== 'object') {
    return value;
  }
  if (Array.isArray(value)) {
    // 只记前若干个，避免一次日志写进上千条名单。
    const head = value.slice(0, 20).map((v) => redactForLog(v, depth + 1));
    return value.length > 20 ? [...head, `…共 ${value.length} 项`] : head;
  }
  if (value instanceof Error) {
    return { name: value.name, message: value.message };
  }

  const out = {};
  for (const [k, v] of Object.entries(value)) {
    const mask = SENSITIVE_KEYS.get(k);
    if (mask) {
      out[k] = typeof v === 'string' ? mask(v) : '****';
      continue;
    }
    out[k] = redactForLog(v, depth + 1);
  }
  return out;
}

function formatLine(level, message, meta) {
  const ts = new Date().toISOString();
  const parts = [`[${ts}]`, level.toUpperCase().padEnd(5), message];
  if (meta !== undefined) {
    let rendered;
    try {
      rendered = JSON.stringify(redactForLog(meta));
    } catch {
      rendered = '[无法序列化]';
    }
    parts.push(rendered);
  }
  return parts.join(' ');
}

/**
 * 创建 logger。
 *
 * @param {{level?: string, sink?: (line: string) => void}} [opts]
 */
export function createLogger(opts = {}) {
  const threshold = LEVELS[opts.level ?? 'info'] ?? LEVELS.info;
  // 默认写 stderr：容器里 stdout/stderr 都会被收集，而把日志与
  // 业务输出分开更利于排查。测试里可以传入自己的 sink 收集。
  const sink = opts.sink ?? ((line) => process.stderr.write(`${line}\n`));

  const emit = (level, message, meta) => {
    if (LEVELS[level] < threshold) {
      return;
    }
    sink(formatLine(level, message, meta));
  };

  return {
    debug: (m, meta) => emit('debug', m, meta),
    info: (m, meta) => emit('info', m, meta),
    warn: (m, meta) => emit('warn', m, meta),
    error: (m, meta) => emit('error', m, meta),
    /** 子 logger：自动带上固定字段（例如 requestId）。 */
    child(fields) {
      const wrapped = {};
      for (const level of Object.keys(LEVELS)) {
        wrapped[level] = (m, meta) =>
          emit(level, m, meta === undefined ? fields : { ...fields, ...meta });
      }
      wrapped.child = () => wrapped;
      return wrapped;
    },
  };
}
