/**
 * 接口客户端。
 *
 * ## 契约要点（方案 §6.1）
 *
 *   * 成功：`{ code: 0, msg, data, errors: [], traceId, serverTime }`
 *   * 失败：`code` 非 0，HTTP 状态也**有意义**（不是恒 200）
 *   * 业务结果看 `code`，不要只看 HTTP 状态 —— 两者都可能变
 *
 * ## 关于错误码：**不要按码值反查原因**
 *
 * 方案只授权 8 个码值，而业务上有几十种细分错误，
 * 因此多个语义共享一个码。例如 `40301` 同时代表：
 * 无权操作该活动 / 不在名单 / 设备不符 / 二次校验失败 / 角色不符。
 *
 * 所以：
 *   * 判断"该做什么" → 用族级谓词（`isAuthFailure` 等）
 *   * 判断"具体为什么" → 读 `msg`
 *   * 定位"哪个字段" → 读 `errors[].field`
 *
 * 移动端阶段踩过这个坑：早先写 `if (code === 40301) 提示"你不在名单里"`，
 * 结果越权也被说成"不在名单里"。所以这里**不提供**按码值取文案的接口。
 */

import { ERROR_CODES, errorFamilies, PAGING } from '@contract/constants.js';

/**
 * 统一的接口异常。
 *
 * 携带足够的信息让调用方决定怎么呈现，而不是只给一句话。
 */
export class ApiError extends Error {
  constructor({ code, msg, errors = [], httpStatus = 0, traceId = null, cause = null }) {
    super(msg);
    this.name = 'ApiError';
    this.code = code;
    this.errors = errors;
    this.httpStatus = httpStatus;
    this.traceId = traceId;
    this.cause = cause;
  }

  /** 网络层失败（没拿到响应），而不是服务端返回了错误。 */
  get isNetworkError() {
    return this.httpStatus === 0;
  }

  /** 服务端明确说"未认证"。**只有这一类**才应清除登录态。 */
  get isAuthFailure() {
    return errorFamilies.isAuthFailure(this.code);
  }

  get isForbidden() {
    return errorFamilies.isForbidden(this.code);
  }

  get isNotFound() {
    return errorFamilies.isNotFound(this.code);
  }

  /** 面向用户的提示。带 traceId 便于对日志。 */
  get userMessage() {
    if (this.isNetworkError) {
      return '无法连接服务端。请确认网络正常，然后重试。';
    }
    return this.message || '请求失败，请重试。';
  }
}

/**
 * 建立客户端。
 *
 * @param {{baseUrl?: string, timeoutMs?: number, fetchImpl?: Function}} [opts]
 */
export function createApiClient(opts = {}) {
  // 默认同源 + `/api`。开发期由 Vite 代理转发，生产由 Nginx 转发
  //（方案 §8.2：前后端同域，规避 CORS）。**前端不硬编码服务端地址。**
  const baseUrl = opts.baseUrl ?? '/api';
  const timeoutMs = opts.timeoutMs ?? 12_000;
  const doFetch = opts.fetchImpl ?? globalThis.fetch;

  async function request(path, { method = 'GET', query, body, signal } = {}) {
    let url = `${baseUrl}${path}`;
    if (query) {
      const sp = new URLSearchParams();
      for (const [k, v] of Object.entries(query)) {
        if (v === undefined || v === null || v === '') {
          continue;
        }
        sp.append(k, String(v));
      }
      const qs = sp.toString();
      if (qs) {
        url += `?${qs}`;
      }
    }

    // 超时控制。用 AbortController 而不是自己 setTimeout 不管 ——
    // 后者在请求已返回后会留下悬挂的定时器，测试里表现为"进程不退出"。
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    // 外部传入的 signal 也要能取消（例如用户切换了筛选条件）。
    if (signal) {
      if (signal.aborted) {
        controller.abort();
      } else {
        signal.addEventListener('abort', () => controller.abort(), { once: true });
      }
    }

    let res;
    try {
      res = await doFetch(url, {
        method,
        headers: body ? { 'Content-Type': 'application/json' } : undefined,
        body: body ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      });
    } catch (e) {
      clearTimeout(timer);
      const aborted = e?.name === 'AbortError';
      throw new ApiError({
        code: aborted ? ERROR_CODES.SERVER_ERROR : -1,
        msg: aborted ? '请求超时' : '无法连接服务端',
        httpStatus: 0,
        cause: e,
      });
    } finally {
      clearTimeout(timer);
    }

    // 204 之类的空响应。
    const text = await res.text();
    let payload = null;
    if (text) {
      try {
        payload = JSON.parse(text);
      } catch {
        throw new ApiError({
          code: ERROR_CODES.SERVER_ERROR,
          msg: '服务端返回了无法解析的内容',
          httpStatus: res.status,
        });
      }
    }

    if (!payload) {
      if (res.ok) {
        return null;
      }
      throw new ApiError({
        code: ERROR_CODES.SERVER_ERROR,
        msg: `请求失败（HTTP ${res.status}）`,
        httpStatus: res.status,
      });
    }

    if (payload.code !== ERROR_CODES.OK) {
      throw new ApiError({
        code: payload.code,
        msg: payload.msg ?? payload.message ?? '请求失败',
        errors: payload.errors ?? [],
        httpStatus: res.status,
        traceId: payload.traceId ?? null,
      });
    }

    return payload.data;
  }

  return {
    baseUrl,
    get: (path, query, opts) => request(path, { method: 'GET', query, ...opts }),
    post: (path, body, opts) => request(path, { method: 'POST', body, ...opts }),
    patch: (path, body, opts) => request(path, { method: 'PATCH', body, ...opts }),
    delete: (path, opts) => request(path, { method: 'DELETE', ...opts }),
    _request: request,
  };
}

/** 默认实例（同源）。 */
export const api = createApiClient();

// ══════════════════════════════════════════════════════════════════════
// 活动接口
// ══════════════════════════════════════════════════════════════════════

/**
 * 查询活动列表。
 *
 * @param {{keyword?:string, organizer?:string, status?:string[], startFrom?:string,
 *          startTo?:string, sortBy?:string, sortDesc?:boolean, page?:number,
 *          size?:number}} params
 * @param {{signal?: AbortSignal, client?: object}} [opts]
 */
export function fetchActivities(params = {}, opts = {}) {
  const client = opts.client ?? api;
  const query = {
    keyword: params.keyword,
    organizer: params.organizer,
    // 状态多选用逗号分隔（契约：`status=a,b`）。
    status: Array.isArray(params.status) ? params.status.join(',') : params.status,
    startFrom: params.startFrom,
    startTo: params.startTo,
    sortBy: params.sortBy,
    sortDesc: params.sortDesc === undefined ? undefined : String(params.sortDesc),
    page: params.page ?? 1,
    size: params.size ?? PAGING.defaultSize,
  };
  return client.get('/activities', query, { signal: opts.signal });
}

/** 活动详情。 */
export function fetchActivity(id, opts = {}) {
  const client = opts.client ?? api;
  return client.get(`/activities/${encodeURIComponent(id)}`, undefined, {
    signal: opts.signal,
  });
}

/** 部门字典（筛选栏下拉）。 */
export function fetchOrganizers(opts = {}) {
  const client = opts.client ?? api;
  return client.get('/activities/organizers', undefined, { signal: opts.signal });
}

/** 健康检查。 */
export function fetchHealth(opts = {}) {
  const client = opts.client ?? api;
  return client.get('/health', undefined, { signal: opts.signal });
}
