/**
 * HTTP 层的小工具：路由匹配、请求体读取、查询串解析。
 *
 * ## 路由匹配支持"动作后缀"
 *
 * 契约用的是 Google AIP 风格的动作后缀：`/activities:upsert`、
 * `/activities/{id}:transition`。**不能用简单的 `split('/')` 比较**，
 * 因为 `:transition` 是附着在参数段上的。
 *
 * 做法：把模板编译成正则，参数部分惰性匹配，动作后缀作为字面量。
 */

import { HEADERS } from '../contract.js';

/**
 * 解析路径片段模板，支持三种形态：
 *   * 字面量            `activities`
 *   * 参数              `:id`
 *   * 字面量 + 动作     `activities:upsert`
 *   * 参数 + 动作       `:id:transition`
 *
 * ## ⚠️ 关键：动作后缀要在判断"是不是参数"**之前**切开
 *
 * 最初我先判断 `seg.startsWith(':')` 再拆动作，于是
 * `activities:upsert` 被当成**字面量**整体转义成正则，
 * 结果它永远匹配不上 —— 而且失败方式是静默的：`match()` 返回 null，
 * 调用方只看到"接口不存在 404"，完全不会想到是路由解析的问题。
 *
 * 正确顺序：先按最后一个 `:` 拆出动作，再判断剩下的是参数还是字面量。
 */
function parseSegment(seg) {
  let name = seg;
  let action = null;

  // 用 `lastIndexOf` 而不是 `split(':')`：参数名本身不含冒号，
  // 动作后缀一定在最后。
  const colon = seg.lastIndexOf(':');
  if (colon > 0) {
    name = seg.slice(0, colon);
    action = seg.slice(colon + 1);
  }

  if (name.startsWith(':')) {
    return { param: name.slice(1), action };
  }
  return { literal: name, action };
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** 片段模板 → 正则片段。 */
function compileSegment(seg) {
  const p = parseSegment(seg);
  if (p.literal !== undefined) {
    return `${escapeRe(p.literal)}${p.action ? `:${escapeRe(p.action)}` : ''}`;
  }
  // 参数用惰性匹配：后面若有动作后缀，顺势让出。
  return p.action ? `([^/]+?):${escapeRe(p.action)}` : '([^/]+?)';
}

/**
 * 路由表。
 *
 * ## 统一前缀 `/api`（方案 §6.1：Base URL 形如 `https://host/api`）
 *
 * 同时接受不带前缀的写法 —— 只为让 `curl /health` 这种存活检查方便，
 * 契约本身是带前缀的。
 */
export function createRouter(prefix = '/api') {
  const routes = [];

  const add = (method, pattern, handler, opts = {}) => {
    routes.push({
      method,
      pattern,
      segments: pattern.split('/').filter(Boolean),
      handler,
      /** null | 'admin' | 'volunteer' | 'either' */
      auth: opts.auth ?? null,
    });
  };

  return {
    get: (p, h, o) => add('GET', p, h, o),
    post: (p, h, o) => add('POST', p, h, o),
    patch: (p, h, o) => add('PATCH', p, h, o),
    delete: (p, h, o) => add('DELETE', p, h, o),

    prefix,

    /** 已注册路由（契约自述与防漂移测试用）。 */
    table: () => routes.map((r) => ({ method: r.method, pattern: r.pattern, auth: r.auth })),

    /**
     * 匹配。
     *
     * @returns {{route:object, params:object, action:string|null}|null}
     */
    match(method, pathname) {
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
          if (p.param !== undefined) {
            params[p.param] = decodeURIComponent(m[++group]);
          }
          /*
            ⚠️ 动作后缀对**参数段与字面量段都要取**。

            `activities:upsert` 是字面量段带动作 —— 早期只在参数分支里
            取 action，于是这类路径虽然能匹配上，`action` 却是 null，
            handler 无法区分 `POST /activities` 与 `POST /activities:upsert`。
          */
          if (p.action) {
            action = p.action;
          }
        }
        return { route: r, params, action };
      }
      return null;
    },

    /** 去掉 `/api` 前缀（带或不带都接受）。 */
    stripPrefix(pathname) {
      if (pathname === prefix) {
        return '/';
      }
      if (pathname.startsWith(`${prefix}/`)) {
        return pathname.slice(prefix.length);
      }
      return pathname;
    },
  };
}

/** 解析查询串为普通对象（重复键取最后一个）。 */
export function parseQuery(url) {
  const idx = url.indexOf('?');
  const pathname = idx < 0 ? url : url.slice(0, idx);
  const query = {};
  if (idx >= 0) {
    const sp = new URLSearchParams(url.slice(idx + 1));
    for (const [k, v] of sp) {
      query[k] = v;
    }
  }
  return { pathname, query };
}

/**
 * 读取请求体。
 *
 * 有大小上限：默认 8MB —— 够导入大名单，又不至于被一个请求撑爆内存。
 * 超限时**立刻 destroy**，并且要给出明确错误，
 * 否则客户端只会看到连接被重置。
 */
export function readBody(req, { limit = 8 * 1024 * 1024 } = {}) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let tooLarge = false;

    req.on('data', (c) => {
      if (tooLarge) {
        return;
      }
      size += c.length;
      if (size > limit) {
        tooLarge = true;
        reject(new Error(`请求体超过上限（${Math.round(limit / 1024 / 1024)}MB）`));
        req.destroy();
        return;
      }
      chunks.push(c);
    });

    req.on('end', () => {
      if (tooLarge) {
        return;
      }
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

/** 从认证头取令牌（支持 `Bearer xxx` 与裸令牌）。 */
export function bearerToken(req) {
  const raw = req.headers[HEADERS.authorization.toLowerCase()] ?? '';
  const s = String(raw).trim();
  if (!s) {
    return null;
  }
  const m = /^Bearer\s+(.+)$/i.exec(s);
  return m ? m[1].trim() : s;
}

/**
 * 取客户端 IP。
 *
 * 优先 `X-Forwarded-For` 的第一段（生产在 Nginx 后面），
 * 否则用 socket 地址。**这个值只用于审计与限流，不用于鉴权** ——
 * 头部可以伪造，因此在没有可信代理的前提下不能作为安全边界。
 */
export function clientIp(req, { trustProxy = false } = {}) {
  if (trustProxy) {
    const xff = req.headers['x-forwarded-for'];
    if (xff) {
      const first = String(xff).split(',')[0].trim();
      if (first) {
        return first;
      }
    }
  }
  return req.socket?.remoteAddress ?? null;
}

/** 取设备指纹头。 */
export function deviceId(req) {
  const v = req.headers[HEADERS.deviceId.toLowerCase()];
  return v == null ? null : String(v).trim();
}

/** 取幂等键（头里的优先级高于请求体）。 */
export function idempotencyKey(req, body) {
  const fromHeader = req.headers[HEADERS.idempotencyKey.toLowerCase()];
  if (fromHeader) {
    return String(fromHeader).trim();
  }
  const fromBody = body?.idempotencyKey;
  return fromBody == null ? null : String(fromBody).trim();
}
