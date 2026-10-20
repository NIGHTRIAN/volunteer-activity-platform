/**
 * 活动接口（方案 §6.2 接口清单 / §6.4 关键接口）。
 *
 * ## 只读与写入分开处理
 *
 * Web 前端**只读**（方案 §2：两个 App 双向，Web 前端只读）。
 * 因此读接口不需要鉴权就能看到已发布的活动 —— 那是刻意的设计
 * （§1.4：Web 浏览端没有账号体系，公开只读）。
 *
 * 但**草稿永远不可见**：草稿只属于发布者。
 *
 * ## 分页字段是 `size`（契约 §6.1）
 *
 * 同时接受 `pageSize` 作为兼容输入，但响应里统一回显 `size` ——
 * 早期实现不回显，导致客户端在服务端把 size 压到上限时算错分页。
 */

import {
  ACTIVITY_STATUS,
  PAGING,
  TERMINAL_STATUSES,
  DISCLAIMER,
} from '../contract.js';
import { fail, ApiError } from '../http/envelope.js';
import { parseQuery } from '../http/router.js';

/** 从查询串里取分页参数（带边界钳制）。 */
export function parsePaging(query) {
  const rawSize = query[PAGING.size] ?? query.pageSize;
  const size = Math.min(
    PAGING.maxSize,
    Math.max(1, Number.parseInt(rawSize ?? PAGING.defaultSize, 10) || PAGING.defaultSize),
  );
  const page = Math.max(1, Number.parseInt(query[PAGING.page] ?? '1', 10) || 1);
  return { page, size };
}

/** 解析逗号分隔的状态多选。 */
function parseStatuses(query) {
  const raw = query.status ?? query.statuses;
  if (!raw) {
    return null;
  }
  const known = new Set(Object.values(ACTIVITY_STATUS));
  const list = String(raw)
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s && known.has(s));
  return list.length > 0 ? list : null;
}

/** 解析布尔查询参数。 */
function parseBool(v, fallback = false) {
  if (v == null || v === '') {
    return fallback;
  }
  return ['1', 'true', 'yes', 'on'].includes(String(v).toLowerCase());
}

/**
 * 构造读接口的筛选条件。
 *
 * 公开读（Web）只看已发布及之后的状态，**排除草稿**。
 */
function buildFilters(query, { includeDrafts = false, ownerId = null } = {}) {
  const statuses = parseStatuses(query);
  return {
    keyword: query.keyword ? String(query.keyword).trim() : null,
    organizer: query.organizer ? String(query.organizer).trim() : null,
    // 归属隔离：管理端只应看到自己名下的活动（见 listActivities 的说明）。
    ownerId: ownerId ?? null,
    // 未显式筛状态时：公开视图排除草稿。
    statuses: statuses ?? (includeDrafts ? null : [
      ACTIVITY_STATUS.PUBLISHED,
      ACTIVITY_STATUS.ONGOING,
      ACTIVITY_STATUS.FINISHED,
      ACTIVITY_STATUS.CANCELLED,
    ]),
    startFrom: query.startFrom ? String(query.startFrom) : null,
    startTo: query.startTo ? String(query.startTo) : null,
    sortBy: query.sortBy ? String(query.sortBy) : 'startTime',
    sortDesc: parseBool(query.sortDesc, true),
  };
}

/** 请求上下文里取仓储。 */
function repos(ctx) {
  return ctx.repos;
}

/**
 * `GET /activities` —— 活动列表（方案 §7.1 列表页）。
 *
 * 响应同时带 `stats`（按状态的计数）。**统计基于筛选后的全量**，
 * 不随翻页跳动 —— 这一点放在仓储层保证（见 `countByStatus`）。
 */
export async function listActivities(ctx) {
  const { page, size } = parsePaging(ctx.query);
  const isAdmin = ctx.auth?.kind === 'admin';

  /*
    ## 归属隔离：管理端只能看到自己名下的活动

    管理端首页写的是「**我发布的**活动」，而客户端确实带了 `onlyMine=true`。
    但服务端早期**完全忽略**这个参数，于是任何管理员都能看到
    其他组织的活动 —— 单发布者试点时看不出来，一旦支持多发布者
    就是实实在在的越权（能看到别的部门的活动标题、地点、联系方式）。

    这里选择「只要身份是管理员就一律按 owner 过滤」，而不是
    信任客户端的 `onlyMine`：这个产品里管理端不存在"浏览他人活动"
    的场景（网页端才做公开浏览，且它是匿名请求），
    所以按身份强制隔离既更安全，也少一个可被篡改的参数。
  */
  const filters = buildFilters(ctx.query, {
    includeDrafts: isAdmin,
    ownerId: isAdmin ? ctx.auth.ownerId : null,
  });

  const { items, total } = await repos(ctx).activities.search({
    ...filters,
    page,
    size,
  });

  // 统计：与列表同一套筛选条件，避免"列表 3 条、图里 5 条"。
  const counts = await repos(ctx).activities.countByStatus(filters);

  return {
    [PAGING.items]: items,
    [PAGING.total]: total,
    [PAGING.page]: page,
    // 回显 size：服务端可能把 size 钳到上限，客户端需要知道实际值。
    [PAGING.size]: size,
    [PAGING.hasMore]: page * size < total,
    [PAGING.stats]: {
      total,
      byStatus: counts,
      // 图表用：按状态分组的数组形式，前端不必再转一次。
      byStatusList: Object.entries(counts).map(([status, count]) => ({ status, count })),
    },
  };
}

/**
 * `GET /activities/{id}` —— 详情。
 *
 * 草稿只对发布者可见：对其他人一律当作"不存在"（不泄露草稿内容）。
 */
export async function getActivity(ctx) {
  const a = await repos(ctx).activities.findById(ctx.params.id);
  if (!a) {
    throw fail('ACTIVITY_NOT_FOUND');
  }
  if (a.status === ACTIVITY_STATUS.DRAFT) {
    const isOwner = ctx.auth?.kind === 'admin' && ctx.auth.ownerId === a.ownerId;
    if (!isOwner) {
      // 刻意返回"不存在"而不是"无权限"：后者会泄露"这里有一个草稿"。
      throw fail('ACTIVITY_NOT_FOUND');
    }
  }

  /*
    ⚠️ 同时给"扁平"和"包裹"两种形状 —— 这是**刻意**的兼容层。

    ## 为什么会有两种形状

    * **网页端**（先做）读的是 `data.activity` + `data.disclaimer`；
    * **手机端**把 `data` 直接当 `Activity.fromJson` 的输入（扁平）；
    * mock 服务端一直是扁平，真服务端一直是包裹 ——
      两边各自与自己那侧客户端联调通过，**互相之间从未对过**。

    结果是在真机上暴露：活动详情页显示「未知状态 / 1970-01-01」。
    原因是 App 拿到的 data 里没有 `id/status/startTime`（它们在 `activity` 下），
    而 `Activity.fromJson` 对缺字段一律给默认值 —— **不报错，只是全空**。

    这个兼容层让两代客户端都能正确解析：
      `{...活动字段, activity: {...}, disclaimer}`
    将来若只保留一种形状，应先统一两个客户端，而不是先删这里。
  */
  return {
    ...a,
    activity: a,
    disclaimer: DISCLAIMER,
  };
}

/** `GET /activities/organizers` —— 部门字典（筛选栏下拉）。 */
export async function listOrganizers(ctx) {
  const list = await repos(ctx).activities.organizers();
  return { items: list, total: list.length };
}

/** `GET /health` —— 存活检查（不查库，避免把健康检查变成压力源）。 */
export async function health(ctx) {
  return {
    status: 'ok',
    service: 'volunteer-server',
    apiVersion: 'v1',
    env: ctx.config.env,
    driver: ctx.db.driver,
    serverTime: new Date().toISOString(),
  };
}

/**
 * `GET /contract` —— 契约自述。
 *
 * 让三端开发者不必翻文档就能确认服务端实现了哪些路径、
 * 判定阈值是什么。这也是防漂移测试的依据（自述必须与真实路由一致）。
 */
export async function contractSelfDescription(ctx) {
  return {
    apiVersion: 'v1',
    baseUrl: '/api',
    envelope: {
      success: '{ code: 0, msg, data, errors: [], traceId, serverTime }',
      failure: '{ code: <非0>, msg, data: null, errors: [{ field, message, row? }] }',
      note: '契约字段是 msg；同时下发 message（同值）仅兼容早期客户端。',
    },
    paging: {
      request: ['page 从 1 起', 'size 默认 20、上限 100'],
      response: ['items', 'total', 'page', 'size', 'hasMore', 'stats'],
    },
    errorCodes: {
      authorized: [0, 40001, 40101, 40301, 40401, 40901, 42901, 50001],
      note:
        '方案只授权 8 个码值，业务细分共享码值，因此**码值反查不可逆**：' +
        '请用族级谓词判断该做什么、用 msg 判断具体原因。',
    },
    endpoints: ctx.router.table().map((r) => [r.method, r.pattern, r.auth ?? '公开']),
    clientNotes: [
      'Web 前端只读；两个 App 双向。',
      '草稿只对发布者可见，对其他人一律返回"不存在"（不泄露草稿）。',
      '活动终态 + 7 天后不可访问（业务数据视为已销毁）。',
      '签到判定完全在服务端；客户端不得自行判定通过。',
      '在岗抽查只为**已签到者**生成。',
      '考勤结果仅作现场管理参考，不自动产生任何时长扣减。',
    ],
  };
}

export { parseQuery, ApiError, TERMINAL_STATUSES };
