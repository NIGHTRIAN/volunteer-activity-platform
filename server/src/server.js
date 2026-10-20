/**
 * 同步服务入口。
 *
 * ## 启动顺序
 *
 *   1. 读配置（全部走环境变量，方案 §8.1）
 *   2. 自检配置 —— **配置错误必须让进程起不来**，而不是等用户点到某个页面
 *   3. 连数据库 + 建表
 *   4. 装配仓储与路由
 *   5. 监听
 *
 * ## 为什么自检失败要直接退出
 *
 * 方案 §11.1 有一条验收：
 *   > 端口与配置可在不修改代码的前提下变更（改配置 + 重启即生效）
 *
 * 如果配置错了却"勉强启动"，用户看到的是运行期各种奇怪错误；
 * 而明确的启动失败 + 原因，才是可运维的。
 */

import http from 'node:http';
import os from 'node:os';
import { pathToFileURL } from 'node:url';

import { loadConfig, validateConfig } from './config.js';
import { createLogger } from './logger.js';
import { connect, migrate, close } from './db/index.js';
import { activityRepo } from './stores/activity.js';
import { createRouter, parseQuery, readBody, bearerToken, clientIp, deviceId } from './http/router.js';
import { serveStatic } from './http/static.js';
import { sendOk, sendError, ApiError } from './http/envelope.js';
import {
  listActivities,
  getActivity,
  listOrganizers,
  health,
  contractSelfDescription,
} from './api/activities.js';
import { exportActivities, exportActivity } from './api/export.js';
import { adminLogin, bindActivity, resolveAuth, adminMe, volunteerMe } from './api/auth.js';
import {
  upsertActivities,
  transitionActivity,
  listParticipants,
  addParticipant,
  removeParticipant,
  importParticipants,
  issueInviteCodes,
  listInviteCodes,
  listChanges,
  manualAttendance,
} from './api/manage.js';
import {
  submitCheckin,
  listCheckins,
  myCheckin,
  reviewCheckin,
  listAttendanceTasks,
  confirmAttendance,
  attendanceReport,
  activityBoard,
} from './api/checkin.js';
import {
  adminSessionRepo,
  loginAuditRepo,
  inviteCodeRepo,
  grantRepo,
  participantRepo,
} from './stores/auth.js';
import { HEADERS } from './contract.js';

/**
 * 装配路由表。
 *
 * 路径风格遵循契约（方案 §6.2）：动作后缀用 `:verb`。
 */
function buildRouter() {
  const r = createRouter('/api');

  r.get('/health', health);
  r.get('/contract', contractSelfDescription);

  // ── 鉴权（手机端的前置门槛）─────────────────────────────────────────
  //
  // 没有这两个接口，手机端每个请求都会 40101：
  // App 启动先取令牌，拿不到就停在登录/绑定页。
  // 服务端之前的 7 个只读接口只让网页能看，手机端无法"用起来"。
  r.post('/auth/admin/login', adminLogin);
  r.post('/auth/bind', bindActivity);
  r.get('/auth/admin/me', adminMe);
  r.get('/auth/me', volunteerMe);

  // ── 管理端写入 ──────────────────────────────────────────────────────
  //
  // 顺序同样重要：这些必须排在 `/activities/:id`（只读详情）**之前**，
  // 否则 `participants` 会被当成活动 id 吃掉，表现为"名单接口 404 活动不存在"
  // —— 错误信息看起来完全合理，很难联想到是路由顺序问题。
  r.post('/activities:upsert', upsertActivities);
  r.post('/activities/:id:transition', transitionActivity);
  r.get('/activities/:id/participants', listParticipants);
  r.post('/activities/:id/participants', addParticipant);
  r.post('/activities/:id/participants:import', importParticipants);
  r.delete('/activities/:id/participants/:userNo', removeParticipant);
  r.post('/activities/:id/invite-codes', issueInviteCodes);
  r.get('/activities/:id/invite-codes', listInviteCodes);

  // ── 签到 / 在岗 / 看板 / 复核 ───────────────────────────────────────
  //
  // 判定一律走 `scoring.js`（与 mock、与离线演示引擎同一套权重）。
  // 同样要排在 `/activities/:id` 之前 —— 否则 `checkins` / `board`
  // 会被当成活动 id。
  r.post('/activities/:id/checkins', submitCheckin);
  r.get('/activities/:id/checkins/mine', myCheckin);
  r.get('/activities/:id/checkins', listCheckins);
  r.get('/activities/:id/attendance/tasks', listAttendanceTasks);
  r.get('/activities/:id/attendance', attendanceReport);
  r.get('/activities/:id/board', activityBoard);
  r.post('/activities/:id/attendance/manual', manualAttendance);
  /*
    ⚠️ 这两个动作后缀的写法**不一样**，不是笔误：

      * 复核是**路径段**：`/checkins/{id}/review`
        （客户端 `CheckinPaths.review` 就是这么拼的，mock 也是这么注册的）
      * 在岗确认是**动作后缀**：`/attendances/{id}:confirm`
        （客户端 `AttendancePaths.confirm` 用的是 `:confirm` 形式）

    我一开始把复核也写成了 `:review`，于是它永远匹配不上 `/checkins/5/review`
    —— 报错是 404「接口不存在」，而人工通过签到恰恰是管理端的核心动作。
    这类问题的根因是**测试里手写了路径**，与生产拼出来的不一致，
    两边一起错、互相印证。现在由 `test/routes.test.mjs` 用客户端的真实
    路径字符串逐个校验，防止再漂移。
  */
  r.post('/checkins/:checkinId/review', reviewCheckin);
  r.post('/attendances/:taskId:confirm', confirmAttendance);

  // ── 只读：活动（Web 前端与两个 App 都用）────────────────────────────
  //
  // ⚠️ 注册顺序有讲究：`/activities/organizers` 与 `/activities/export`
  // 必须排在 `/activities/:id` **之前**。
  //
  // 路由是按注册顺序线性匹配的，`/activities/:id` 会把 `export`
  // 当成一个活动 id 吃掉，于是导出请求变成"活动 export 不存在" 404 ——
  // 而错误信息看起来完全合理，很难联想到是路由顺序问题。
  // （`organizers` 同理，那个是先写的所以没踩到。）
  r.get('/activities/organizers', listOrganizers);
  r.get('/activities/export', exportActivities);
  r.get('/changes', listChanges);
  r.get('/activities', listActivities);
  r.get('/activities/:id/export', exportActivity);
  r.get('/activities/:id', getActivity);

  return r;
}

/**
 * 构建服务（不监听端口）。
 *
 * 抽出来是为了让测试可以直接拿到 `handle`，不必真的开端口 ——
 * 这样测试跑得快、也不会撞端口。
 */
export async function createServer(config = loadConfig()) {
  const problems = validateConfig(config);
  if (problems.length > 0) {
    throw new Error(`配置有误：\n  - ${problems.join('\n  - ')}`);
  }

  const logger = createLogger({ level: config.logLevel });
  const db = await connect(config);
  await migrate(db);

  const repos = {
    activities: activityRepo(db),
    adminSession: adminSessionRepo(db),
    loginAudit: loginAuditRepo(db),
    inviteCodes: inviteCodeRepo(db),
    grants: grantRepo(db),
    participants: participantRepo(db),
  };

  /*
    空库时自动写入演示数据。

    ## 为什么这不该只是个便利功能

    这个服务要能被**打包发给别人验收**。空库意味着接收方打开网页
    看到的是"暂时没有已发布的活动" —— 一个空页面无法验收筛选、统计图、
    详情、导出中的任何一项。于是"验收包"变成了"能启动但看不出东西"。

    ## 三种环境三种答案

      * **dev**  → 开。这是验收/演示的场景。
      * **test** → **关**。测试要断言空库行为；自动播种会让
        4 个用例因为"库里凭空多出 8 条"而失败，且失败信息指向业务逻辑。
      * **prod** → 关。真实部署凭空多出假活动会污染数据。

    只写**空库**，已有数据一律不动（不会覆盖真实数据）。
    `SEED_ON_START=true/false` 可显式覆盖以上默认。
  */
  const shouldSeed = config.seedOnStart ?? config.env === 'dev';
  if (shouldSeed) {
    try {
      /*
        启动时的种子用**展示档**（2 个活动），不是测试用的 8 条。

        演示/验收时列表里堆 8 条反而不知道看哪个；而测试需要"各状态都有、
        跨多个月份"的丰富数据，所以两套分开：这里用 showcase，测试用 demo。
      */
      const { seedShowcaseData } = await import('./seed/demo.js');
      const result = await seedShowcaseData(repos, db, (m) => logger.info(m));
      if (result.inserted > 0) {
        logger.info(
          `已写入 ${result.inserted} 条演示数据（空库自动导入；` +
            '生产环境请设置 SEED_ON_START=false）',
        );
      }
    } catch (e) {
      // 演示数据写失败不该让服务起不来 —— 那是便利功能，不是核心。
      logger.warn('演示数据写入失败（不影响服务运行）', e);
    }
  }

  const router = buildRouter();

  const handle = async (req, res) => {
    const startedAt = Date.now();
    res.traceId = `t-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
    res.corsOrigin = config.corsOrigin;

    const { pathname, query } = parseQuery(req.url ?? '/');

    // CORS 预检。
    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Origin': config.corsOrigin,
        'Access-Control-Allow-Headers':
          'Content-Type, Authorization, X-Idempotency-Key, X-Device-Id, X-Api-Version, X-Client-Version',
        'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
        'Access-Control-Max-Age': '600',
      });
      res.end();
      return;
    }

    const path = router.stripPrefix(pathname);

    /*
      静态资源优先，但**不接管 /api**。

      顺序很重要：先试静态文件，再走 API 路由。
      若反过来，`/api/...` 会被静态服务当成"找不到的文件"，
      API 请求于是返回 404 而不是 JSON 错误 ——
      客户端只会看到一个空响应，很难判断出了什么事。

      显式排除 `/api` 前缀，而不是只靠"磁盘上不存在"：
      万一有人把前端产物放在一个恰好叫 `api` 的子目录里，
      靠巧合判断会出难以预料的行为。
    */
    if (
      config.staticDir &&
      (req.method === 'GET' || req.method === 'HEAD') &&
      !path.startsWith('/api/') &&
      path !== '/api'
    ) {
      const handled = serveStatic(req, res, {
        root: config.staticDir,
        urlPath: path,
        exposeSourcemaps: config.exposeSourcemaps,
      });
      if (handled) {
        return;
      }
    }

    const matched = router.match(req.method ?? 'GET', path);
    if (!matched) {
      sendError(res, new ApiError('ACTIVITY_NOT_FOUND', `接口不存在：${req.method} ${pathname}`));
      return;
    }

    let body = {};
    if (req.method !== 'GET' && req.method !== 'DELETE') {
      try {
        body = await readBody(req, { limit: config.maxBodyBytes });
      } catch (e) {
        sendError(res, new ApiError('BAD_REQUEST', e.message));
        return;
      }
    }

    const ctx = {
      req,
      res,
      config,
      db,
      repos,
      router,
      // handler 里需要记警告/审计时用（例如导出达到行数上限）。
      logger,
      params: matched.params,
      query,
      body,
      headers: req.headers,
      ip: clientIp(req),
      traceId: res.traceId,
      // 由 `resolveAuth` 在下面填充（可能是 `{}`，表示匿名）。
      //
      // 保持"永远是对象、不是 null"：任何 `ctx.auth.kind` 读取都不会抛异常，
      // 这也是让"允许匿名"的接口能安心忽略它的前提。
      auth: {},
      token: bearerToken(req),
      deviceId: deviceId(req),
    };

    /*
      解析令牌 → `ctx.auth`。

      放在 handler 之前、且**不因令牌无效而报错**：
      「公开活动列表」这类接口允许匿名，一个过期令牌不该让首页都打不开
      —— 而首页恰恰是用户想"重新登录"的入口。
      要不要强制身份，由每个 handler 自己决定（`requireAdmin` 等）。

      坏令牌导致的异常也要吞掉：鉴权存储（库）出问题不应让只读接口全挂。
    */
    try {
      ctx.auth = await resolveAuth(ctx);
    } catch (e) {
      logger.warn('解析令牌失败，按匿名处理', { error: e.message, traceId: ctx.traceId });
      ctx.auth = {};
    }

    try {
      const result = await matched.route.handler(ctx);
      if (result === undefined) {
        // handler 已自行响应（例如文件下载）。
        return;
      }
      sendOk(res, result);
    } catch (e) {
      if (e instanceof ApiError) {
        sendError(res, e);
      } else {
        // 未预期的异常：日志留全量，响应只说"服务异常"（不外泄堆栈）。
        logger.error(`${req.method} ${path} 处理失败`, e);
        sendError(res, new ApiError('SERVER_ERROR'));
      }
    } finally {
      if (config.accessLog) {
        logger.debug(`${req.method} ${pathname} ${res.statusCode} ${Date.now() - startedAt}ms`, {
          traceId: res.traceId,
          ip: ctx.ip,
        });
      }
    }
  };

  const server = http.createServer((req, res) => {
    handle(req, res).catch((e) => {
      logger.error('处理请求时未捕获异常', e);
      try {
        sendError(res, new ApiError('SERVER_ERROR'));
      } catch {
        // 响应可能已经发出。
      }
    });
  });

  /*
    ⚠️ 返回值必须包含 `repos`。

    最初只返回 `{ server, handle, db, config, router, logger }`，
    漏了 `repos`。测试里用 `app.repos.activities.create(...)` 造数据，
    结果是十几个用例齐刷刷 `Cannot read properties of undefined
    (reading 'activities')` —— 报错位置指向业务用例，
    而真正的问题是装配函数的返回值不完整。

    仓储是**服务的公开装配结果**（和 db / router 同级），
    测试与将来的管理脚本都需要它，应当一并交出。
  */
  return { server, handle, db, config, router, logger, repos };
}

/** 监听并打印启动信息。 */
export async function start(config = loadConfig()) {
  const { server, db, config: cfg, logger } = await createServer(config);

  await new Promise((resolve) => server.listen(cfg.port, cfg.host, resolve));

  // 启动横幅：把所有"跑起来才知道"的关键信息一次说清。
  //
  // 尤其是**局域网地址** —— 真机测试时需要它，而每次手工查 IP 很烦。
  const lines = [
    '',
    '  志愿活动信息平台 · 同步服务',
    `  监听          http://${cfg.host}:${cfg.port}`,
    `  环境          ${cfg.env}`,
    `  存储          ${db.driver}${db.driver === 'sqlite' ? `（${cfg.db.sqliteFile}）` : `（${cfg.db.host}:${cfg.db.port}/${cfg.db.database}）`}`,
    `  接口前缀      /api`,
    '',
    '  局域网地址（手机与电脑需在同一网络）：',
  ];
  for (const ip of localAddresses()) {
    lines.push(`    http://${ip}:${cfg.port}/api`);
  }
  lines.push(
    '',
    '  App 侧构建参数：',
    `    --dart-define=API_BASE_URL=http://${localAddresses()[0] ?? '127.0.0.1'}:${cfg.port}/api`,
    '',
  );
  for (const l of lines) {
    logger.info(l);
  }

  // 优雅退出：让连接关干净，避免 SQLite 的 WAL 留下未合并文件。
  const shutdown = async (signal) => {
    logger.info(`收到 ${signal}，正在关闭…`);
    server.close();
    await close(db);
    process.exit(0);
  };
  process.on('SIGINT', () => void shutdown('SIGINT'));
  process.on('SIGTERM', () => void shutdown('SIGTERM'));

  // 兜底：任何未捕获异常都不应让进程静默退出。
  // 开发期尤其重要 —— 一次崩溃会让所有人都以为是自己写错了。
  process.on('uncaughtException', (e) => logger.error('未捕获异常（服务继续运行）', e));
  process.on('unhandledRejection', (e) => logger.error('未处理的 Promise 拒绝', e));

  return { server, db };
}

/**
 * 本机可用的局域网 IPv4 地址。
 *
 * 启动横幅要打印它，原因很实际：真机测试时手机需要连到电脑的
 * **局域网地址**（`127.0.0.1` 在手机上指向手机自己）。每次手工
 * `ipconfig` 查 IP 很烦，而且很容易填错一个数字后排查半天。
 *
 * 排除回环与链路本地（169.254.x.x，那是 DHCP 失败时的自分配地址）。
 */
export function localAddresses() {
  const out = [];
  const nets = os.networkInterfaces();
  for (const list of Object.values(nets)) {
    for (const net of list ?? []) {
      if (net.family !== 'IPv4' || net.internal) {
        continue;
      }
      if (String(net.address).startsWith('169.254.')) {
        continue;
      }
      out.push(net.address);
    }
  }
  return out;
}

// 直接运行时启动。
/**
 * 是否作为入口直接运行（而不是被 import）。
 *
 * ## 为什么不能写 `import.meta.url === `file://${process.argv[1]}``
 *
 * 实测踩过：那种写法在 Windows 上会**静默失败** —— 条件为假，
 * `start()` 不被调用，事件循环随即清空，进程以 **退出码 0 正常退出**，
 * 且不打任何日志。表现是"服务启动了但立刻消失，没有任何错误"，
 * 排查方向极易跑偏（会去怀疑端口占用、配置错误、防火墙）。
 *
 * 原因：`process.argv[1]` 是平台路径（`D:\...\server.js`），
 * 而 `import.meta.url` 是 file URL（`file:///D:/.../server.js`）。
 * 手工拼 `file://` 前缀无法可靠地把前者转成后者 ——
 * 盘符前的第三个斜杠、空格转义、反斜杠方向都要处理。
 *
 * 正确做法是用 `pathToFileURL` 做这个转换：它存在的意义就是这件事。
 */
function isMainModule() {
  const entry = process.argv[1];
  if (!entry) {
    return false;
  }
  try {
    return import.meta.url === pathToFileURL(entry).href;
  } catch {
    return false;
  }
}

// 直接运行时启动。
if (isMainModule()) {
  start().catch((e) => {
    process.stderr.write(`启动失败：${e.message}\n`);
    process.exit(1);
  });
}

export { buildRouter, HEADERS };
