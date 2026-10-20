/**
 * 响应信封与错误（方案 §6.1）。
 *
 * ## 这个文件存在的核心原因：线码值只有 8 个
 *
 * 方案只授权 8 个错误码，而业务上有几十种细分错误。因此
 * **多个语义共享一个码值**，于是：
 *
 *   * 客户端**不能**按码值反查原因（不可逆）；
 *   * 服务端**不能**按码值反查文案或 HTTP 状态
 *     —— 那会让"不在名单中"被发成 400 而不是 403。
 *
 * 正确做法：服务端内部用**语义名**（`NOT_IN_PARTICIPANT_LIST`），
 * 由一张表把语义名映射到「线码值 + 文案 + HTTP 状态」。
 * 客户端用族级谓词判断该做什么、用 `msg` 判断为什么。
 *
 * 移动端阶段正是踩过这个坑：早先用 `ERR_HTTP[code]` 反查状态，
 * 同码值的细分互相覆盖。这里从结构上避免：**没有** `byCode` 之类的反查表。
 */

import { ERROR_CODES } from '../contract.js';

/**
 * 语义错误目录 —— 服务端内部的**唯一**错误定义处。
 *
 * 每条给出：线码值（8 个之一）、面向用户的文案、HTTP 状态。
 *
 * ⚠️ 新增错误时**必须**选一个已有的线码值，不能新造数字。
 */
export const CATALOG = Object.freeze({
  OK: { code: ERROR_CODES.OK, message: '成功', http: 200 },

  // ── 40001 参数错误 / 业务性拒绝 ─────────────────────────────────────
  BAD_REQUEST: { code: ERROR_CODES.BAD_REQUEST, message: '请求参数有误', http: 400 },
  IDEMPOTENCY_CONFLICT: {
    code: ERROR_CODES.BAD_REQUEST,
    message: '重复请求且内容不一致',
    http: 400,
  },
  API_VERSION_UNSUPPORTED: {
    code: ERROR_CODES.BAD_REQUEST,
    message: '当前版本过旧，请升级应用',
    http: 400,
  },
  OUTSIDE_CHECKIN_WINDOW: {
    code: ERROR_CODES.BAD_REQUEST,
    message: '不在签到时段内',
    http: 400,
  },
  CANCEL_REASON_TOO_SHORT: {
    code: ERROR_CODES.BAD_REQUEST,
    message: '取消原因至少 5 个字',
    http: 400,
  },

  // ── 40101 未认证 ────────────────────────────────────────────────────
  UNAUTHORIZED: { code: ERROR_CODES.UNAUTHORIZED, message: '登录状态已失效', http: 401 },
  ADMIN_CODE_INVALID: {
    code: ERROR_CODES.UNAUTHORIZED,
    message: '邀请码错误',
    http: 401,
  },
  ADMIN_CODE_LOCKED: {
    code: ERROR_CODES.UNAUTHORIZED,
    message: '错误次数过多，请在 10 分钟后重试',
    // 423 Locked 比 401 更准确：这不是"凭证错误"，而是"暂时不允许尝试"。
    http: 423,
  },
  INVITE_CODE_INVALID: {
    code: ERROR_CODES.UNAUTHORIZED,
    message: '邀请码无效或已被使用',
    http: 401,
  },
  GRANT_EXPIRED: {
    code: ERROR_CODES.UNAUTHORIZED,
    message: '本次活动授权已过期',
    http: 401,
  },
  ADMIN_TOKEN_EXPIRED: {
    code: ERROR_CODES.UNAUTHORIZED,
    message: '管理端登录已过期，请重新登录',
    http: 401,
  },

  // ── 40301 越权 ──────────────────────────────────────────────────────
  FORBIDDEN: { code: ERROR_CODES.FORBIDDEN, message: '无权操作该活动', http: 403 },
  NOT_IN_PARTICIPANT_LIST: {
    code: ERROR_CODES.FORBIDDEN,
    message: '你不在本次活动名单中',
    http: 403,
  },
  IDENTITY_MISMATCH: {
    code: ERROR_CODES.FORBIDDEN,
    message: '姓名或手机号后四位不匹配',
    http: 403,
  },
  DEVICE_ALREADY_BOUND: {
    code: ERROR_CODES.FORBIDDEN,
    message: '该身份已绑定其他设备',
    http: 403,
  },
  DEVICE_MISMATCH: {
    code: ERROR_CODES.FORBIDDEN,
    message: '设备校验未通过，请重新绑定',
    http: 403,
  },
  ROLE_NOT_ALLOWED: {
    code: ERROR_CODES.FORBIDDEN,
    message: '当前身份无权访问',
    http: 403,
  },

  // ── 40401 不存在 ────────────────────────────────────────────────────
  ACTIVITY_NOT_FOUND: {
    code: ERROR_CODES.NOT_FOUND,
    message: '活动不存在或已过留存期',
    http: 404,
  },
  EXPORT_NOT_FOUND: {
    code: ERROR_CODES.NOT_FOUND,
    message: '导出文件不存在或已过期',
    http: 404,
  },
  ATTENDANCE_TASK_NOT_FOUND: {
    code: ERROR_CODES.NOT_FOUND,
    message: '在岗任务不存在',
    http: 404,
  },

  // ── 40901 状态冲突 ──────────────────────────────────────────────────
  ACTIVITY_STATE_INVALID: {
    code: ERROR_CODES.CONFLICT,
    message: '当前活动状态不支持该操作',
    http: 409,
  },
  VERSION_CONFLICT: {
    code: ERROR_CODES.CONFLICT,
    message: '状态已更新，请重试',
    http: 409,
  },
  ACTIVITY_RULE_FROZEN: {
    code: ERROR_CODES.CONFLICT,
    message: '已发布活动的关键字段不可修改',
    http: 409,
  },
  ALREADY_CHECKED_IN: {
    code: ERROR_CODES.CONFLICT,
    message: '你已完成签到',
    http: 409,
  },
  PARTICIPANT_DUPLICATED: {
    code: ERROR_CODES.CONFLICT,
    message: '名单中已存在该学号',
    http: 409,
  },
  QUOTA_EXCEEDED: { code: ERROR_CODES.CONFLICT, message: '活动名额已满', http: 409 },
  ATTENDANCE_TASK_CLOSED: {
    code: ERROR_CODES.CONFLICT,
    message: '该在岗确认已结束',
    http: 409,
  },

  // ── 42901 / 50001 ───────────────────────────────────────────────────
  TOO_MANY_REQUESTS: {
    code: ERROR_CODES.RATE_LIMITED,
    message: '操作过于频繁，请稍后重试',
    http: 429,
  },
  SERVER_ERROR: {
    code: ERROR_CODES.SERVER_ERROR,
    message: '服务暂时不可用，请稍后重试',
    http: 500,
  },
});

/** 取语义错误的文案。**不要**按码值反查 —— 那张表会互相覆盖。 */
export function msgOf(name) {
  return CATALOG[name]?.message ?? CATALOG.SERVER_ERROR.message;
}

/**
 * 构造业务错误。
 *
 * 用法：`throw new ApiError('NOT_IN_PARTICIPANT_LIST')`
 * 或 `return fail('BAD_REQUEST', '自定义文案', [{field, message}])`
 */
export class ApiError extends Error {
  /**
   * @param {string} name CATALOG 里的语义名
   * @param {string|null} [message] 覆盖默认文案（带上具体上下文，如剩余次数）
   * @param {Array<{field:string,message:string,row?:number}>} [errors] 字段级错误
   * @param {number|null} [httpStatus] 覆盖默认 HTTP 状态
   */
  constructor(name, message = null, errors = [], httpStatus = null) {
    const def = CATALOG[name] ?? CATALOG.SERVER_ERROR;
    super(message ?? def.message);
    this.name = 'ApiError';
    this.semantic = CATALOG[name] ? name : 'SERVER_ERROR';
    this.code = def.code;
    this.errors = Array.isArray(errors) ? errors : [];
    this.httpStatus = httpStatus ?? def.http;
  }

  /** 序列化为响应体片段。 */
  toEnvelope() {
    return {
      code: this.code,
      msg: this.message,
      errors: this.errors,
    };
  }
}

/**
 * 构造错误对象（不抛）。便于 handler 里 `return fail(...)`。
 */
export function fail(name, message = null, errors = [], httpStatus = null) {
  return new ApiError(name, message, errors, httpStatus);
}

/**
 * 发送统一响应。
 *
 * ⚠️ 契约字段是 **`msg`**；同时下发 `message`（同值）只为兼容早期客户端，
 * 新代码只应读 `msg`。
 *
 * @param {number} [status] HTTP 状态。**必须在 writeHead 之前确定** ——
 *   早期版本的写法是"先 writeHead(200) 再改 res.statusCode"，
 *   那是无效的（头已经发出去了），实测表现为所有错误都返回 200。
 */
export function sendEnvelope(
  res,
  { code, msg, data = null, errors = [], traceId, serverTime, status = 200 },
) {
  const body = {
    code,
    // 契约字段。
    msg,
    // 兼容字段：早期客户端读的是 message。
    message: msg,
    data,
    errors,
    traceId: traceId ?? res.traceId ?? null,
    serverTime: serverTime ?? new Date().toISOString(),
  };
  const payload = Buffer.from(JSON.stringify(body), 'utf8');
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': payload.length,
    'Access-Control-Allow-Origin': res.corsOrigin ?? '*',
    'Access-Control-Allow-Headers':
      'Content-Type, Authorization, X-Idempotency-Key, X-Device-Id, X-Api-Version, X-Client-Version',
    'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
    'X-Api-Version': 'v1',
  });
  res.end(payload);
}

/** 成功响应（HTTP 200，业务结果看 `code`）。 */
export function sendOk(res, data, extra = {}) {
  sendEnvelope(res, { code: ERROR_CODES.OK, msg: '成功', data, status: 200, ...extra });
}

/**
 * 错误响应。
 *
 * ⚠️ HTTP 状态用**语义名对应的**那个，不能用 `码值 → 状态` 反查：
 * `40301` 同时代表越权/不在名单/设备不符/二次校验失败，
 * 反查必然让其中几个发错状态。
 */
export function sendError(res, error) {
  const e = error instanceof ApiError ? error : new ApiError('SERVER_ERROR');
  sendEnvelope(res, {
    code: e.code,
    msg: e.message,
    errors: e.errors,
    // 状态在同一处确定，避免"设了但没生效"。
    status: e.httpStatus,
  });
}
