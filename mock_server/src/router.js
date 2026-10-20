/**
 * 路由与统一响应信封。
 *
 * 契约假设（**需在 A0 与后端对齐**）：所有接口返回
 *   `{ code, message, data, errors, traceId, serverTime }`
 *
 * 为什么每个响应都带 `serverTime`：动态签到码倒计时必须**以服务端时间为基准**
 * （方案 §6.3），且方案 §9 要求识别「设备时间不准」。客户端时钟不可信。
 *
 * 若后端最终采用「裸 body + HTTP 状态码」，只需改 `send` 与
 * `packages/shared_core/lib/src/contract/api_envelope.dart` 两处。
 */

import { CATALOG, DEFAULTS, ERR, msgOf } from './constants.js';
import * as api from './api.js';

/** 路由表：`METHOD /path/pattern` → handler。`:name` 为路径参数。 */
const routes = [];
function route(method, pattern, handler, opts = {}) {
  routes.push({
    method,
    pattern,
    segments: pattern.split('/').filter(Boolean),
    handler,
    auth: opts.auth ?? null, // null | 'admin' | 'volunteer' | 'either'
  });
}

/**
 * 已注册的路由表（只读快照）。
 *
 * 暴露出来是给**契约自述一致性测试**用的：契约自述是手写的"活的契约"，
 * 没有任何机制保证它与真实路由同步。实测踩到过——自述里还写着
 * `POST /activities` 和 `message`，而路由早已改成 `:upsert` 与 `msg`。
 * 有了这个导出，测试就能把两者绑起来，改路由忘改文档会直接失败。
 */
export function routeTable() {
  return routes.map((r) => ({ method: r.method, pattern: r.pattern, auth: r.auth }));
}

// ─────────────────────────────────────────────────────────────────────────
// 注册路由
//
// 路径风格遵循《网页开发方案》§6.2 / §6.4：
//   * 动作后缀用 `:verb`（Google AIP 风格），例如 `:upsert` / `:transition` / `:confirm`；
//   * 在岗确认是**全局资源**路径 `/attendances/{taskId}:confirm`，
//     不挂在活动下 —— 因为确认动作的主体是"某次抽查任务"，不是"某活动"；
//   * 导出是 `GET .../export?format=csv` 直接下载，不做"建任务→轮询"。
//
// 统一前缀 `/api` 由 `API_PREFIX` 常量加在匹配之前（见 handleRequest），
// 因此这里写的是**去掉前缀后**的相对路径。
// ─────────────────────────────────────────────────────────────────────────

// 健康检查与契约自述
route('GET', '/health', api.health);
route('GET', '/contract', api.contractSelfDescription);

// ── 认证与身份（网页 §6.3）─────────────────────────────────────────────
route('POST', '/auth/admin/login', api.adminLogin);
route('GET', '/auth/admin/me', api.adminMe, { auth: 'admin' });
route('GET', '/auth/admin/audits', api.adminAudits, { auth: 'admin' });
route('GET', '/auth/admin/export-audits', api.exportAudits, { auth: 'admin' });
route('POST', '/auth/bind', api.volunteerBind);
route('GET', '/auth/me', api.volunteerMe, { auth: 'volunteer' });

// ── 活动（网页 §6.4.1 上报 / §6.4.2 流转）─────────────────────────────
//
// `optional` 鉴权：网页端匿名浏览公开列表，管理端带令牌则只看自己名下的。
//
// ⚠️ 这里原来**没有 auth**，导致 `ctx.auth` 恒为空对象，
// `listActivities` 里的归属过滤整段失效 —— 管理员能看到所有发布者的活动
//（真机实测：另一个 owner 的管理员拿到了 6 条不属于他的活动）。
// 详见 `api_auth.authenticate` 里 `optional` 模式的说明。
// 部门字典必须排在 /activities/:id **之前**，否则 organizers 会被
// 当成一个活动 id 吃掉，表现为 404「活动不存在」。
route('GET', '/activities/organizers', api.listOrganizers, { auth: 'optional' });
route('GET', '/activities', api.listActivities, { auth: 'optional' });
route('GET', '/activities/:id', api.getActivity);

// 上报：含 batch[]，幂等键 externalId（方案 §6.4.1）。
// 部分失败仍返回 200，逐条给出 created/updated/rejected。
route('POST', '/activities:upsert', api.upsertActivities, { auth: 'admin' });

// 状态流转：`{from,to,reason}`（方案 §6.4.2）。
// 保留 `PATCH /activities/:id` 用于**非关键字段**的自由编辑（简介/详情/联系方式）。
route('POST', '/activities/:id:transition', api.transitionActivity, { auth: 'admin' });
route('PATCH', '/activities/:id', api.updateActivity, { auth: 'admin' });

// 规则变更记录（管理者的争议证据，方案 §5.2）
route('GET', '/activities/:id/changes', api.activityChanges, { auth: 'admin' });

// ── 名单与邀请码（网页 §6.4.3 / §6.4.4）───────────────────────────────
route('GET', '/activities/:id/participants', api.listParticipants, { auth: 'admin' });
route('POST', '/activities/:id/participants', api.addParticipant, { auth: 'admin' });
route('POST', '/activities/:id/participants:import', api.importParticipants, {
  auth: 'admin',
});
// 软删。`pid` 可以是 userNo（本 Mock 用 userNo 作活动内唯一键，方案 §4.3）。
route('DELETE', '/activities/:id/participants/:pid', api.removeParticipant, { auth: 'admin' });
route('POST', '/activities/:id/invite-codes', api.issueInviteCodes, { auth: 'admin' });
route('GET', '/activities/:id/invite-codes', api.listInviteCodes, { auth: 'admin' });

// ── 签到（网页 §6.4.5）────────────────────────────────────────────────
route('POST', '/activities/:id/checkins', api.submitCheckin, { auth: 'volunteer' });
route('GET', '/activities/:id/checkins', api.listCheckins, { auth: 'admin' });
route('GET', '/activities/:id/checkins/mine', api.myCheckin, { auth: 'volunteer' });
route('POST', '/checkins/:checkinId/review', api.reviewCheckin, { auth: 'admin' });
route('POST', '/activities/:id/checkins/manual', api.manualCheckin, { auth: 'admin' });

// ── 在岗确认（网页 §6.4.6）────────────────────────────────────────────
route('GET', '/activities/:id/attendance/tasks', api.listAttendanceTasks, {
  auth: 'either',
});
// 确认是全局资源路径：主体是任务，不是活动。
route('POST', '/attendances/:taskId:confirm', api.respondAttendance, {
  auth: 'volunteer',
});
route('POST', '/attendances/:taskId:remind', api.remindAttendance, { auth: 'admin' });
route('POST', '/activities/:id/attendance/manual', api.manualAttendance, { auth: 'admin' });

// ── 看板与考勤汇总（网页 §6.4.7）──────────────────────────────────────
route('GET', '/activities/:id/board', api.activityBoard, { auth: 'admin' });
route('GET', '/activities/:id/attendance', api.attendanceSummaryReport, {
  auth: 'admin',
});

// ── 增量同步（网页 §6.4.9）────────────────────────────────────────────
// 游标 7 天幂等窗口；降级方案为时间窗拉取。
//
// `optional` 鉴权：handler 里按 `ctx.auth.kind` 做可见性过滤
// （草稿仅发布者可见 / 志愿者只看被授权活动 / 留存期外不可见）。
// 这里原先没有 auth，`ctx.auth` 恒为空对象，那三段过滤全都退化成"公开可见"。
route('GET', '/changes', api.changes, { auth: 'optional' });

// ── 导出（网页 §6.4.8：统一入口，直接下载）────────────────────────────
route('GET', '/activities/:id/export', api.exportActivity, { auth: 'either' });
route('GET', '/export/activities', api.exportActivities, { auth: 'admin' });
// 保留任务式导出的下载（供大文件异步场景），但主路径是上面的 GET。
route('GET', '/exports/:exportId/download', api.downloadExport, { auth: 'either' });

// ── 维护（仅开发用）───────────────────────────────────────────────────
route('POST', '/dev/reset', api.devReset);
route('POST', '/dev/time-travel-example', api.devTimeTravelExample);

// ─────────────────────────────────────────────────────────────────────────
// 匹配与分发
// ─────────────────────────────────────────────────────────────────────────

/**
 * 解析一个路径片段模板，支持三种形态：
 *   * 字面量          `activities`
 *   * 参数            `:id`
 *   * 参数 + 动作后缀 `:taskId:confirm`（Google AIP 风格）
 *
 * @returns {{literal?:string, name?:string, action?:string|null}}
 */
function parseSegment(seg) {
  if (!seg.startsWith(':')) {
    return { literal: seg };
  }
  const parts = seg.slice(1).split(':');
  return { name: parts[0], action: parts.length > 1 ? parts[1] : null };
}

/**
 * 匹配路由。
 *
 * 支持动作后缀（`/activities/{id}:transition`、`/attendances/{taskId}:confirm`）。
 * 做法是把模板编译成正则，动作后缀作为**字面量**参与匹配，
 * 参数部分用 `([^/]+?)` 惰性匹配。
 *
 * @returns {{route:object, params:object, action:string|null}|null}
 */
function matchRoute(method, pathname) {
  for (const r of routes) {
    if (r.method !== method) {
      continue;
    }
    const re = new RegExp(`^/${r.segments.map(compileSegment).join('/')}/?$`);
    const m = re.exec(pathname);
    if (!m) {
      continue;
    }
    const params = {};
    let action = null;
    let group = 0;
    for (const seg of r.segments) {
      const p = parseSegment(seg);
      if (p.name) {
        params[p.name] = decodeURIComponent(m[++group]);
        if (p.action) {
          action = p.action;
        }
      }
    }
    return { route: r, params, action };
  }
  return null;
}

/** 把片段模板编译成正则片段（参数部分捕获）。 */
function compileSegment(seg) {
  const p = parseSegment(seg);
  if (p.literal) {
    // 字面量里的正则元字符要转义（当前没有，但别留坑）。
    return p.literal.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }
  // 参数名本身不入正则：`([^/]+?)` 惰性匹配，后面若有动作后缀则顺势让出。
  return p.action
    ? `([^/]+?):${p.action.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`
    : '([^/]+?)';
}

/** API 前缀。方案 §6.1：Base URL 为 `https://{domain}/api`。 */
const API_PREFIX = '/api';

/** 读取并解析请求体。 */
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    const limit = 8 * 1024 * 1024; // 8MB：足够导入大名单，又不至于被撑爆
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(new Error('请求体过大'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error('请求体不是合法 JSON'));
      }
    });
    req.on('error', reject);
  });
}

/** 解析查询串。 */
function parseQuery(pathname) {
  const idx = pathname.indexOf('?');
  const q = {};
  if (idx < 0) {
    return { path: pathname, query: q };
  }
  const search = pathname.slice(idx + 1);
  for (const [k, v] of new URLSearchParams(search)) {
    q[k] = v;
  }
  return { path: pathname.slice(0, idx), query: q };
}

/**
 * 统一响应发送。
 *
 * ## 响应信封：《网页开发方案》§6.1（权威）
 *
 * > 统一响应：`{"code":0,"msg":"ok","data":{...}}`
 *
 * 因此字段名是 **`msg`**。（早期版本我写成了 `message` 并标注"待确认"，
 * 网页方案已明确。为减少联调摩擦，这里**同时**下发 `message`，
 * 但契约字段是 `msg`，新代码只应读 `msg`。）
 *
 * `errors` / `traceId` / `serverTime` 是我方扩展，方案只规定了三个字段。
 * 它们不下发也不会让客户端失败。
 */
export function send(
  res,
  status,
  { code, message, msg, data = null, errors = [], traceId, serverTime },
) {
  // 文案优先用调用方给的；没有时退回"服务异常"的通用文案，
  // **不能**按码值反查（同码值的细分会互相覆盖）。
  const text = msg ?? message ?? CATALOG.SERVER_ERROR.message;
  const body = JSON.stringify({
    code,
    // 契约字段。
    msg: text,
    // 兼容字段：早期客户端读的是 message。
    message: text,
    data,
    errors: errors ?? [],
    traceId: traceId ?? res.traceId,
    serverTime: serverTime ?? new Date().toISOString(),
  });
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    // 开发期允许任意来源，方便 Web 端调试；生产实现必须收紧。
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': '*',
    'Access-Control-Allow-Methods': 'GET,POST,PATCH,DELETE,OPTIONS',
    'X-Api-Version': DEFAULTS.API_VERSION,
  });
  res.end(body);
}

/**
 * 业务错误 → 响应。
 *
 * 兼容两种形状：
 *   * `{ __error: { code, message, errors, httpStatus } }` —— `fail()` 的返回值；
 *   * `{ code, message, errors }` —— 裸对象（历史上 `authenticate` 用过）。
 *
 * 为什么要兼容：鉴权路径早期直接返回裸对象，而 handler 路径用 `fail()`。
 * 混用会让某一路的错误响应丢掉 `httpStatus`，从而把 401 发成 400。
 */
export function sendError(res, error) {
  const e = error.__error ?? error;
  const code = e.code ?? ERR.SERVER_ERROR;
  // 逐细分查 HTTP 状态。**不能**用 `ERR_HTTP[code]`——线码值只有 8 个，
  // 同码值的细分会互相覆盖（例如"不在名单"会被发成 400 而不是 403）。
  const status = e.httpStatus ?? 500;
  send(res, status, {
    code,
    msg: e.message ?? CATALOG.SERVER_ERROR.message,
    errors: e.errors ?? [],
  });
}

function ok(res, data, extra = {}) {
  send(res, 200, { code: ERR.OK, msg: '成功', data, ...extra });
}

/**
 * 请求入口。
 * @param {import('node:http').IncomingMessage} req
 * @param {import('node:http').ServerResponse} res
 */
export async function handleRequest(req, res, meta = {}) {
  res.traceId = `t-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  const { path: rawPath, query } = parseQuery(req.url ?? '/');

  // CORS 预检
  if (req.method === 'OPTIONS') {
    send(res, 204, { code: ERR.OK, msg: 'ok' });
    return;
  }

  // ── 统一前缀 `/api`（方案 §6.1）─────────────────────────────────────
  //
  // 接受带前缀与不带前缀两种写法：带前缀是契约要求，不带前缀便于
  // 用 curl / 浏览器直接戳 `/health` 做存活检查。
  const path = rawPath.startsWith(API_PREFIX)
    ? rawPath.slice(API_PREFIX.length) || '/'
    : rawPath;

  const matched = matchRoute(req.method ?? 'GET', path);
  if (!matched) {
    send(res, 404, {
      code: ERR.ACTIVITY_NOT_FOUND,
      msg: `接口不存在：${req.method} ${rawPath}`,
    });
    return;
  }

  const { route: r, params } = matched;

  // 接口版本协商（方案 §1.4 预留头）。
  const clientVersion = req.headers['x-api-version'];
  if (clientVersion && clientVersion !== DEFAULTS.API_VERSION) {
    send(res, 400, {
      code: ERR.API_VERSION_UNSUPPORTED,
      msg: `客户端接口版本 ${clientVersion} 不受支持，当前为 ${DEFAULTS.API_VERSION}`,
    });
    return;
  }

  let body = {};
  if (req.method !== 'GET' && req.method !== 'DELETE') {
    try {
      body = await readBody(req);
    } catch (err) {
      send(res, 400, { code: ERR.BAD_REQUEST, msg: err.message });
      return;
    }
  }

  const ctx = {
    req,
    res,
    params,
    query,
    body,
    headers: req.headers,
    // ⚠️ 必须是**空对象**而不是 `null`。
    //
    // 早期这里是 `auth: null`，而导出路由是公开路由（不做鉴权分发），
    // 于是 `prepareExport` 里的 `ctx.auth.kind` 直接抛
    // "Cannot read properties of null"。对"未登录"的判定应当是
    // `auth.kind` 为空值，而不是 `auth` 本身为 null —— 这样任何 handler
    // 读 `ctx.auth.kind` 都安全。
    auth: {},
    ip: clientIp(req),
    traceId: res.traceId,
    startedAt: meta.startedAt ?? Date.now(),
  };

  // 鉴权
  if (r.auth) {
    const authResult = api.authenticate(ctx, r.auth);
    if (authResult) {
      sendError(res, authResult);
      return;
    }
  }

  try {
    const result = await r.handler(ctx);
    if (result === undefined) {
      // handler 已自行响应（例如文件下载）。
      return;
    }
    if (result && typeof result === 'object' && '__error' in result) {
      sendError(res, result.__error);
      return;
    }
    if (result && typeof result === 'object' && '__status' in result) {
      const { __status, ...rest } = result;
      send(res, __status, rest);
      return;
    }
    ok(res, result);
  } catch (err) {
    // 未预期的异常：**返回 500 但不泄露堆栈**，服务端日志留全量。
    console.error(`[mock] ${req.method} ${path} 处理失败：`, err);
    send(res, 500, {
      code: ERR.SERVER_ERROR,
      msg: msgOf('SERVER_ERROR'),
    });
  }
}

/** 取客户端 IP，兼容反向代理。 */
function clientIp(req) {
  const fwd = req.headers['x-forwarded-for'];
  if (typeof fwd === 'string' && fwd.length > 0) {
    return fwd.split(',')[0].trim();
  }
  return req.socket?.remoteAddress ?? null;
}
