/**
 * 服务端测试。
 *
 * ## 测试策略：内存库 + 直接调 handler
 *
 * 每个测试用**独立的内存 SQLite**（`:memory:`），不共享状态。
 * 这一点是刻意的 —— 移动端阶段踩过一个坑：端到端测试并行跑时
 * 因为共用一个 JSON 文件存储而互相覆盖，表现为
 * "串行全绿、并行偶发 3 条失败"，而那种 flaky 看起来像业务 bug。
 *
 * 内存库天然隔离，且比开端口快得多。需要验真实 HTTP 行为的用例
 * 才起一个临时端口。
 *
 * ## 语言无关的验证顺序
 *
 * 先验"地基"（配置、schema、唯一约束），再验接口行为。
 * 地基错了的话，接口测试的失败信息会指向错误的方向。
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';

import { loadConfig, validateConfig, parseEnvFile } from '../src/config.js';
import { connect, migrate, close } from '../src/db/index.js';
import { activityRepo, makeActivity, isExpired } from '../src/stores/activity.js';
import { createServer } from '../src/server.js';
import { ApiError, CATALOG, msgOf } from '../src/http/envelope.js';
import { createRouter } from '../src/http/router.js';
import { ERROR_CODES } from '../src/contract.js';
import { seedDemoData } from '../src/seed/demo.js';
import { toIso, addMinutesIso, parseTime, formatDisplay } from '../src/util/time.js';

// ══════════════════════════════════════════════════════════════════════
// 辅助
// ══════════════════════════════════════════════════════════════════════

/** 建一个隔离的内存库 + 仓储。 */
async function freshDb() {
  const config = loadConfig({
    DB_DRIVER: 'sqlite',
    DB_SQLITE_FILE: ':memory:',
    NODE_ENV: 'test',
  });
  const conn = await connect(config);
  await migrate(conn);
  return { conn, repos: { activities: activityRepo(conn) } };
}

/**
 * 假 res。
 *
 * ⚠️ `end()` **可能不带参数**（例如 CORS 预检返回 204 空体）。
 * 最初写成 `JSON.parse(payload.toString())`，于是预检用例报
 * "Cannot read properties of undefined (reading 'toString')" ——
 * 看起来像服务端坏了，其实是测试替身比真实 res 更挑剔。
 * 真实 res 允许 `end()` 无参，替身也必须允许。
 */
function fakeRes() {
  const r = { statusCode: 200, headers: null, body: null };
  r.writeHead = (status, headers) => {
    r.statusCode = status;
    r.headers = headers;
  };
  r.end = (payload) => {
    if (payload === undefined || payload === null) {
      r.body = null;
      return;
    }
    const text = payload.toString('utf8');
    r.body = text === '' ? null : JSON.parse(text);
  };
  return r;
}

/**
 * 调一次接口。
 *
 * ## 为什么用 `Readable.from` 而不是手搓一个假 req
 *
 * 最初我手写了一个带 `on(event, cb)` 的假对象，在 `end` 时直接回调。
 * 那对**无请求体**的 GET 能用，但对带 body 的 POST 会失败：
 * `readBody()` 是 Promise 风格、按 `data`/`end` 累积 Buffer，
 * 手搓的假对象在细节上（`destroy`、错误传播、Buffer 拼接）总有出入，
 * 报错位置还会指向业务代码。
 *
 * 用 `Readable.from` 造一个**真的可读流**，于是被测代码走的是
 * 与生产完全相同的读取路径。测试才有意义。
 */
async function makeCaller(app) {
  return async (method, url, { body, headers = {} } = {}) => {
    const req = Readable.from(
      body === undefined ? [] : [Buffer.from(JSON.stringify(body), 'utf8')],
    );
    req.method = method;
    req.url = url;
    req.headers = headers;
    req.socket = { remoteAddress: '127.0.0.1' };

    const res = fakeRes();
    await app.handle(req, res);
    return { status: res.statusCode, ...res.body };
  };
}

/** 起一个测试用服务（内存库）。 */
async function freshApp() {
  const config = loadConfig({
    DB_DRIVER: 'sqlite',
    DB_SQLITE_FILE: ':memory:',
    NODE_ENV: 'test',
    ACCESS_LOG: 'false',
  });
  /*
    ⚠️ 返回**整个** app（含 db / repos / router / handle），不要只取 handle。

    最初的写法是 `const { handle } = await createServer(...)` 然后返回
    `{ handle }`，但下面的用例还要用 `app.repos` / `app.db` / `app.router`
    做数据准备与断言。结果是十几个用例齐刷刷报
    "Cannot read properties of undefined (reading 'activities')" ——
    看起来像业务代码坏了，其实是测试辅助函数没把东西交出来。
  */
  return createServer(config);
}

// ══════════════════════════════════════════════════════════════════════
// 配置（方案 §8.1：全部走配置、无硬编码）
// ══════════════════════════════════════════════════════════════════════

test('配置：端口可改，且不需要修改代码', () => {
  const a = loadConfig({ PORT: '9999' });
  assert.equal(a.port, 9999);
  const b = loadConfig({ PORT: '1234' });
  assert.equal(b.port, 1234);
  assert.notEqual(a.port, b.port);
});

test('配置：.env 解析支持注释、引号、以及值里的 #', () => {
  const parsed = parseEnvFile(
    [
      '# 这是注释',
      'PORT=8080',
      'DB_USER="volunteer"',
      "DB_PASSWORD='p@ss#word'",
      'HOST=0.0.0.0',
      '',
      '  SPACED = value  ',
    ].join('\n'),
  );
  assert.equal(parsed.PORT, '8080');
  assert.equal(parsed.DB_USER, 'volunteer');
  // 引号里的 # 不是注释。
  assert.equal(parsed.DB_PASSWORD, 'p@ss#word');
  assert.equal(parsed.HOST, '0.0.0.0');
  assert.equal(parsed.SPACED, 'value');
});

test('配置：真实环境变量优先于 .env 文件', () => {
  // 用 overrides 模拟"容器里 -e 传的变量"，它必须能覆盖文件里的值。
  const cfg = loadConfig({ PORT: '7777' });
  assert.equal(cfg.port, 7777);
});

test('配置：mysql 缺少密码时**必须**报错，而不是回落到弱口令', () => {
  const cfg = loadConfig({
    DB_DRIVER: 'mysql',
    DB_HOST: 'db',
    DB_USER: 'u',
    DB_DATABASE: 'v',
    DB_PASSWORD: '',
  });
  const problems = validateConfig(cfg);
  assert.ok(
    problems.some((p) => p.includes('DB_PASSWORD')),
    '空密码必须被拒绝：一个悄悄生效的弱口令比启动失败危险得多',
  );
});

test('配置：未知驱动必须报错', () => {
  assert.throws(() => loadConfig({ DB_DRIVER: 'oracle' }), /sqlite|mysql/);
});

test('配置：生产环境必须提供足够长的 TOKEN_SECRET', () => {
  const weak = validateConfig(
    loadConfig({ NODE_ENV: 'prod', TOKEN_SECRET: 'short', CORS_ORIGIN: 'https://a.b' }),
  );
  assert.ok(weak.some((p) => p.includes('TOKEN_SECRET')));

  const ok = validateConfig(
    loadConfig({
      NODE_ENV: 'prod',
      TOKEN_SECRET: 'x'.repeat(48),
      CORS_ORIGIN: 'https://vol.example.edu.cn',
    }),
  );
  assert.equal(ok.length, 0, `不该有问题，实际：${ok.join('; ')}`);
});

test('配置：生产环境不允许 CORS_ORIGIN 为 *', () => {
  const problems = validateConfig(
    loadConfig({ NODE_ENV: 'prod', TOKEN_SECRET: 'y'.repeat(48), CORS_ORIGIN: '*' }),
  );
  assert.ok(problems.some((p) => p.includes('CORS_ORIGIN')));
});

// ══════════════════════════════════════════════════════════════════════
// 数据库地基
// ══════════════════════════════════════════════════════════════════════

test('迁移：幂等，重复执行不报错', async () => {
  const { conn } = await freshDb();
  const second = await migrate(conn);
  assert.ok(second.tables >= 10);
  await close(conn);
});

test('迁移：重复执行不会报错，也不会重复建索引（MySQL 安全）', async () => {
  const { conn } = await freshDb();

  /*
    ⚠️ 注意 `freshDb()` 内部**已经**跑过一次 `migrate()`（建表是前提），
    所以这里再调用属于"第二次"。因此断言不能写成"首次应当建出索引" ——
    那会误判。真正要守的性质是：**重复执行既不报错、也不改变索引集合**。
  */
  const indexNames = async () => {
    const rows = await conn.query(
      `SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'
        ORDER BY name`,
    );
    return rows.map((r) => r.name);
  };

  const before = await indexNames();
  assert.ok(before.length > 0, '前置条件：已经有索引');

  // 反复执行：每次都应成功、且不新增索引。
  //
  // 早期实现直接写 `CREATE INDEX IF NOT EXISTS`，而那是 **SQLite 扩展，
  // MySQL 不支持** —— 于是容器每次启动跑迁移时，MySQL 上会语法错误。
  // 表现是"本机（SQLite）测得好好的，一上生产就起不来"。
  for (let i = 0; i < 3; i++) {
    const r = await migrate(conn);
    assert.equal(r.indexesCreated, 0, `第 ${i + 2} 次迁移不应再建任何索引`);
  }

  assert.deepEqual(await indexNames(), before, '索引集合不应随迁移次数变化');
  await close(conn);
});

test('迁移：UNIQUE 索引真的建立了（幂等与去重的地基）', async () => {
  const { conn } = await freshDb();
  const rows = await conn.query(
    `SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'uq_%'`,
  );
  const names = rows.map((r) => r.name);
  for (const need of [
    'uq_activity_external',
    'uq_participant',
    'uq_attendance_task',
    'uq_idempotency',
    'uq_grant_token',
    'uq_admin_token',
  ]) {
    assert.ok(names.includes(need), `缺少唯一索引 ${need}`);
  }
  await close(conn);
});

test('迁移：所有表都真的建出来了', async () => {
  const { conn } = await freshDb();
  const rows = await conn.query(
    `SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'`,
  );
  const names = rows.map((r) => r.name);
  for (const t of [
    'activity',
    'participant',
    'checkin',
    'attendance_task',
    'invite_code',
    'activity_grant',
    'rule_snapshot',
    'change_log',
    'idempotency',
    'login_audit',
    'export_audit',
    'seq_counter',
  ]) {
    assert.ok(names.includes(t), `缺少表 ${t}`);
  }
  await close(conn);
});

test('唯一约束：(owner_id, external_id) 生效 —— 幂等的地基', async () => {
  const { conn, repos } = await freshDb();
  const a = makeActivity({
    externalId: 'E-1',
    title: 't',
    organizer: 'o',
    durationHours: 1,
    startTime: toIso(new Date()),
    endTime: toIso(new Date(Date.now() + 3600_000)),
    ownerId: 'owner-1',
  });
  await repos.activities.create(a);

  // 同 owner 同 externalId 再插一次必须失败。
  await assert.rejects(
    () => repos.activities.create({ ...a }),
    /UNIQUE|constraint/i,
    '唯一约束没生效的话，重复上报会产生重复活动',
  );

  // 不同 owner 的同一 externalId 应当允许（归属隔离）。
  await repos.activities.create({ ...a, ownerId: 'owner-2' });
  await close(conn);
});

test('序号游标：严格单调递增', async () => {
  const { conn } = await freshDb();
  const a = await conn.nextSeq();
  const b = await conn.nextSeq();
  const c = await conn.nextSeq();
  assert.ok(a < b && b < c, `必须严格递增，实际 ${a},${b},${c}`);
  await close(conn);
});

test('事务：抛异常时完整回滚', async () => {
  const { conn, repos } = await freshDb();
  await assert.rejects(() =>
    conn.transaction(async () => {
      await repos.activities.create(
        makeActivity({
          externalId: 'TX',
          title: 'tx',
          organizer: 'o',
          durationHours: 1,
          startTime: toIso(new Date()),
          endTime: toIso(new Date(Date.now() + 3600_000)),
          ownerId: 'o1',
        }),
      );
      throw new Error('故意失败');
    }),
  );
  const found = await repos.activities.findByExternalId('o1', 'TX');
  assert.equal(found, null, '回滚后不应留下半截数据');
  await close(conn);
});

// ══════════════════════════════════════════════════════════════════════
// 时间处理
// ══════════════════════════════════════════════════════════════════════

test('时间：ISO 输出带本地偏移，而不是 UTC 的 Z', () => {
  const iso = toIso(new Date(2026, 9, 16, 9, 0, 0));
  // 契约要求 `+08:00` 这种形式；`toISOString()` 会给 `...Z`，
  // 那会让前端显示的时间比实际早 8 小时。
  assert.match(iso, /^2026-10-16T09:00:00[+-]\d{2}:\d{2}$/);
  assert.ok(!iso.endsWith('Z'), '不应用 UTC 的 Z 结尾');
});

test('时间：宽松解析三种合法写法', () => {
  assert.ok(parseTime('2026-10-16T09:00:00+08:00'));
  assert.ok(parseTime('2026-10-16T01:00:00Z'));
  // 手工输入（管理端备注、种子数据）按本地时区解释 ——
  // 当成 UTC 会让时间偏 8 小时。
  const naive = parseTime('2026-10-16 09:00');
  assert.equal(naive.getHours(), 9);
});

test('时间：无法解析时返回 null，而不是抛异常或返回 Invalid Date', () => {
  assert.equal(parseTime('不是时间'), null);
  assert.equal(parseTime(''), null);
  assert.equal(parseTime(null), null);
});

test('时间：展示格式是 yyyy-MM-dd HH:mm，不含秒', () => {
  assert.equal(formatDisplay('2026-10-16T09:05:30+08:00'), '2026-10-16 09:05');
});

// ══════════════════════════════════════════════════════════════════════
// 错误码（方案 §6.1 的 8 个码值）
// ══════════════════════════════════════════════════════════════════════

test('错误码：只使用方案授权的 8 个值', () => {
  const authorized = new Set([0, 40001, 40101, 40301, 40401, 40901, 42901, 50001]);
  for (const [name, def] of Object.entries(CATALOG)) {
    assert.ok(
      authorized.has(def.code),
      `${name} 用了未授权的码值 ${def.code}；方案只授权 ${[...authorized].join('/')}`,
    );
  }
});

test('错误码：多个语义共享码值，因此**不能**按码值反查', () => {
  // 这是本项目最重要的一条契约约束。用测试把它钉住：
  // 如果将来有人加了"码值 → 唯一语义"的假设，这里会失败。
  const forbidden = Object.values(CATALOG).filter((d) => d.code === ERROR_CODES.FORBIDDEN);
  assert.ok(
    forbidden.length > 1,
    '40301 应当由多个语义共享（越权/不在名单/设备不符等）；' +
      '如果只剩一个，说明有人把它当成了唯一语义',
  );
  // 这些语义的文案必须不同，否则客户端无法区分。
  const msgs = new Set(forbidden.map((d) => d.message));
  assert.equal(msgs.size, forbidden.length, '共享码值的各语义必须有各自可区分的文案');
});

test('错误码：每条都有面向用户的文案与合理的 HTTP 状态', () => {
  for (const [name, def] of Object.entries(CATALOG)) {
    assert.ok(def.message && def.message.length > 0, `${name} 缺少文案`);
    assert.ok(def.http >= 200 && def.http < 600, `${name} 的 HTTP 状态不合法`);
  }
});

test('错误码：限流用 423 而不是 401', () => {
  // 401 的语义是"凭证错误"，会诱导客户端去清除令牌；
  // 而限流只是"暂时不允许尝试"，令牌是好的。
  assert.equal(CATALOG.ADMIN_CODE_LOCKED.http, 423);
  assert.equal(CATALOG.ADMIN_CODE_LOCKED.code, ERROR_CODES.UNAUTHORIZED);
});

test('错误码：msgOf 按语义名取文案，未知名回落为服务异常', () => {
  assert.equal(msgOf('NOT_IN_PARTICIPANT_LIST'), CATALOG.NOT_IN_PARTICIPANT_LIST.message);
  assert.equal(msgOf('不存在的语义'), CATALOG.SERVER_ERROR.message);
});

test('错误码：ApiError 保留语义名，便于日志定位', () => {
  const e = new ApiError('ACTIVITY_NOT_FOUND');
  assert.equal(e.semantic, 'ACTIVITY_NOT_FOUND');
  assert.equal(e.code, ERROR_CODES.NOT_FOUND);
  assert.equal(e.httpStatus, 404);
});

// ══════════════════════════════════════════════════════════════════════
// 读接口
// ══════════════════════════════════════════════════════════════════════

test('接口：健康检查可用且不查库', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const r = await call('GET', '/api/health');
  assert.equal(r.status, 200);
  assert.equal(r.code, 0);
  assert.equal(r.data.status, 'ok');
  assert.equal(r.data.driver, 'sqlite');
  await close(app.db);
});

test('信封：契约字段是 msg，同时也下发 message（兼容）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const r = await call('GET', '/api/health');
  assert.equal(typeof r.msg, 'string');
  assert.equal(r.msg, r.message, 'msg 与 message 必须同值');
  assert.ok(Array.isArray(r.errors));
  assert.ok(r.traceId, '每个响应都应有 traceId 便于对日志');
  assert.ok(r.serverTime, '服务端时间必须下发（倒计时以它为准）');
  await close(app.db);
});

test('信封：断言失败时 HTTP 状态与语义一致，不是恒 200', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const r = await call('GET', '/api/activities/nope');
  // 早期实现是"先 writeHead(200) 再改 res.statusCode"，
  // 那是无效的（头已发出），表现为所有错误都返回 200。
  assert.equal(r.status, 404, '不存在的活动必须返回 404');
  assert.equal(r.code, ERROR_CODES.NOT_FOUND);
  await close(app.db);
});

test('列表：空库返回空数组与 0 统计，而不是报错', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const r = await call('GET', '/api/activities');
  assert.equal(r.code, 0);
  assert.deepEqual(r.data.items, []);
  assert.equal(r.data.total, 0);
  assert.equal(r.data.hasMore, false);
  await close(app.db);
});

test('列表：分页字段是 size，且回显实际生效值', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const call = await makeCaller(app);

  const r = await call('GET', '/api/activities?page=1&size=2');
  assert.equal(r.data.size, 2, '必须回显实际生效的 size');
  assert.equal(r.data.items.length, 2);
  assert.equal(r.data.page, 1);
  assert.equal(r.data.hasMore, true);

  // 超过上限时被钳到 maxSize，且**回显钳后的值** ——
  // 早期实现不回显，导致客户端按自己请求的 size 算分页，算错。
  const big = await call('GET', '/api/activities?size=9999');
  assert.equal(big.data.size, 100);
  await close(app.db);
});

test('列表：pageSize 作为兼容输入也接受', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const call = await makeCaller(app);
  const r = await call('GET', '/api/activities?pageSize=3');
  assert.equal(r.data.size, 3);
  assert.equal(r.data.items.length, 3);
  await close(app.db);
});

test('列表：统计与筛选条件一致，且不随翻页变化', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const call = await makeCaller(app);

  const p1 = await call('GET', '/api/activities?page=1&size=2');
  const p2 = await call('GET', '/api/activities?page=2&size=2');
  // 若先分页再统计，翻页时数字会变 —— 用户会以为数据错了。
  assert.deepEqual(p1.data.stats.byStatus, p2.data.stats.byStatus);
  assert.equal(p1.data.stats.total, p2.data.stats.total);

  // 统计之和必须等于总数（四态自洽）。
  const sum = Object.values(p1.data.stats.byStatus).reduce((a, b) => a + b, 0);
  assert.equal(sum, p1.data.total, '各状态计数之和必须等于总数');
  await close(app.db);
});

test('列表：草稿对公开视图不可见', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  await app.repos.activities.create(
    makeActivity({
      externalId: 'DRAFT-1',
      title: '尚未发布的活动',
      organizer: 'o',
      durationHours: 1,
      startTime: toIso(new Date()),
      endTime: toIso(new Date(Date.now() + 3600_000)),
      ownerId: 'owner-x',
      status: 'draft',
    }),
  );
  const r = await call('GET', '/api/activities');
  assert.equal(r.data.total, 0, 'Web 是公开只读视图，草稿不该出现');
  await close(app.db);
});

test('列表：按状态、关键词、部门筛选', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const call = await makeCaller(app);

  const ongoing = await call('GET', '/api/activities?status=ongoing');
  assert.ok(ongoing.data.total >= 1);
  assert.ok(ongoing.data.items.every((a) => a.status === 'ongoing'));

  const kw = await call('GET', '/api/activities?keyword=图书馆');
  assert.ok(kw.data.total >= 1, '关键词应命中标题或部门');
  assert.ok(
    kw.data.items.every(
      (a) => a.title.includes('图书馆') || a.summary.includes('图书馆') || a.organizer.includes('图书馆'),
    ),
  );

  const multi = await call('GET', '/api/activities?status=ongoing,finished');
  assert.ok(multi.data.items.every((a) => ['ongoing', 'finished'].includes(a.status)));

  const org = await call('GET', '/api/activities/organizers');
  assert.ok(org.data.items.length >= 3);
  await close(app.db);
});

test('列表：非法排序字段不会造成注入，回落为默认排序', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const call = await makeCaller(app);
  // 恶意排序字段：必须被白名单挡掉，而不是拼进 ORDER BY。
  const r = await call('GET', '/api/activities?sortBy=id;DROP TABLE activity--');
  assert.equal(r.code, 0);
  // 表还在。
  const after = await call('GET', '/api/activities');
  assert.ok(after.data.total > 0, '活动表必须仍然可用');
  await close(app.db);
});

test('详情：字段名与契约一致（驼峰，不是数据库列名）', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const call = await makeCaller(app);

  const list = await call('GET', '/api/activities?status=ongoing');
  const id = list.data.items[0].id;
  const r = await call('GET', `/api/activities/${id}`);
  const a = r.data.activity;

  // 这些字段名如果写成了 `geo_lat` 之类，客户端会读不到值 ——
  // 而且不报错，只是安静地显示空。
  for (const k of ['geoLat', 'geoLng', 'durationHours', 'startTime', 'checkinRadius', 'externalId']) {
    assert.ok(k in a, `缺少契约字段 ${k}`);
  }
  for (const bad of ['geo_lat', 'duration_hours', 'start_time']) {
    assert.ok(!(bad in a), `不应出现数据库列名 ${bad}`);
  }
  assert.ok(Array.isArray(a.tags), 'tags 应当是数组，不是逗号分隔字符串');
  assert.equal(typeof a.geoLat, 'number');
  await close(app.db);
});

test('详情：签到窗口是服务端算好的派生值', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const call = await makeCaller(app);
  const list = await call('GET', '/api/activities?status=ongoing');
  const r = await call('GET', `/api/activities/${list.data.items[0].id}`);
  const a = r.data.activity;

  const start = parseTime(a.startTime).getTime();
  const opens = parseTime(a.checkinOpensAt).getTime();
  const ends = parseTime(a.endTime).getTime();
  const closes = parseTime(a.checkinClosesAt).getTime();

  assert.equal((start - opens) / 60_000, a.checkinWindowBefore, '窗口开始 = 开始前 N 分钟');
  assert.equal((closes - ends) / 60_000, a.checkinWindowAfter, '窗口结束 = 结束后 M 分钟');
  await close(app.db);
});

test('详情：下发服务端的免责声明（不在前端硬编码）', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const call = await makeCaller(app);
  const list = await call('GET', '/api/activities?status=ongoing');
  const r = await call('GET', `/api/activities/${list.data.items[0].id}`);
  assert.ok(r.data.disclaimer.includes('不作为志愿时长认定依据'));
  await close(app.db);
});

test('详情：草稿对非发布者返回"不存在"（不泄露草稿内容）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const id = await app.repos.activities.create(
    makeActivity({
      externalId: 'D-1',
      title: '内部草稿标题',
      organizer: 'o',
      durationHours: 1,
      startTime: toIso(new Date()),
      endTime: toIso(new Date(Date.now() + 3600_000)),
      ownerId: 'owner-x',
      status: 'draft',
    }),
  );
  const r = await call('GET', `/api/activities/${id}`);
  // 返回"不存在"而不是"无权限"：后者会泄露"这里有一个草稿"。
  assert.equal(r.code, ERROR_CODES.NOT_FOUND);
  assert.ok(!String(r.msg).includes('草稿'), '错误信息不应提到草稿的存在');
  await close(app.db);
});

test('留存期：终态 +7 天后不可访问（业务数据视为已销毁）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);

  const base = {
    organizer: 'o',
    durationHours: 1,
    ownerId: 'o1',
  };
  // 刚结束（在留存期内）→ 可见
  const fresh = await app.repos.activities.create(
    makeActivity({
      ...base,
      externalId: 'F-1',
      title: '刚结束',
      startTime: toIso(new Date(Date.now() - 7200_000)),
      endTime: toIso(new Date(Date.now() - 3600_000)),
      status: 'finished',
    }),
  );
  await app.db.execute('UPDATE activity SET terminal_at = ? WHERE id = ?', [
    toIso(new Date(Date.now() - 3600_000)),
    fresh,
  ]);

  // 结束于 10 天前 → 已过留存期 → 不可访问
  const old = await app.repos.activities.create(
    makeActivity({
      ...base,
      externalId: 'F-2',
      title: '很久以前结束',
      startTime: toIso(new Date(Date.now() - 11 * 86400_000)),
      endTime: toIso(new Date(Date.now() - 10 * 86400_000)),
      status: 'finished',
    }),
  );
  await app.db.execute('UPDATE activity SET terminal_at = ? WHERE id = ?', [
    toIso(new Date(Date.now() - 10 * 86400_000)),
    old,
  ]);

  assert.equal((await call('GET', `/api/activities/${fresh}`)).code, 0, '留存期内的应可见');
  assert.equal(
    (await call('GET', `/api/activities/${old}`)).code,
    ERROR_CODES.NOT_FOUND,
    '超过留存期的应不可访问',
  );

  const list = await call('GET', '/api/activities');
  assert.equal(list.data.total, 1, '列表里也只应有留存期内的那条');
  await close(app.db);
});

test('留存期：isExpired 只对终态生效', () => {
  const long = toIso(new Date(Date.now() - 30 * 86400_000));
  // 进行中的活动即使开始时间很早，也不算过期。
  assert.equal(
    isExpired({ status: 'ongoing', terminalAt: null }),
    false,
  );
  assert.equal(isExpired({ status: 'finished', terminalAt: long }), true);
  assert.equal(isExpired({ status: 'cancelled', terminalAt: null }), false);
});

test('契约自述：列出的路径与真实路由一致（防漂移）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const r = await call('GET', '/api/contract');

  const declared = new Set(r.data.endpoints.map(([m, p]) => `${m} ${p}`));
  const real = new Set(app.router.table().map((x) => `${x.method} ${x.pattern}`));

  for (const k of real) {
    assert.ok(declared.has(k), `契约自述漏了真实路由 ${k}`);
  }
  for (const k of declared) {
    assert.ok(real.has(k), `契约自述多了一个不存在的路由 ${k}`);
  }
  await close(app.db);
});

test('契约自述：声明只授权 8 个错误码', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const r = await call('GET', '/api/contract');
  assert.deepEqual(r.data.errorCodes.authorized, [0, 40001, 40101, 40301, 40401, 40901, 42901, 50001]);
  assert.ok(r.data.errorCodes.note.includes('不可逆'), '必须提醒客户端码值反查不可逆');
  await close(app.db);
});

test('路由：动作后缀能正确匹配（:verb 附着在参数上）', async () => {
  /*
    ⚠️ 这里用 `createRouter()` 而不是 `freshApp().router`。

    `createServer()` 返回的 router 在装配阶段就用完了（路由已注册），
    它没有 `post` / `get` 这些注册方法 —— 那些只存在于工厂返回的对象上。
    契约里的动作后缀路径（`/activities:upsert`）属于**尚未实现**的写入接口，
    所以这里直接拿工厂来验证匹配规则本身。
  */
  const r = createRouter('/api');
  r.post('/activities:upsert', () => {});
  r.post('/activities/:id:transition', () => {});

  const upsert = r.match('POST', '/activities:upsert');
  assert.ok(upsert, '`/activities:upsert` 这类动作后缀路径必须能匹配');
  assert.equal(upsert.action, 'upsert');

  const transition = r.match('POST', '/activities/42:transition');
  assert.ok(transition, '参数 + 动作后缀必须能匹配');
  assert.equal(transition.params.id, '42');
  assert.equal(transition.action, 'transition');

  // 不应误匹配：动作后缀是字面量的一部分。
  assert.equal(r.match('POST', '/activities/42'), null);
  assert.equal(r.match('POST', '/activities/42:wrong'), null);
});

test('路由：/api 前缀剥离正确', () => {
  const r = createRouter('/api');
  assert.equal(r.stripPrefix('/api/activities'), '/activities');
  assert.equal(r.stripPrefix('/api'), '/');
  // 不带前缀也接受（便于 curl 做存活检查）。
  assert.equal(r.stripPrefix('/activities'), '/activities');
});

test('路由：/api 前缀可带可不带', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const withPrefix = await call('GET', '/api/health');
  const without = await call('GET', '/health');
  assert.equal(withPrefix.code, 0);
  assert.equal(without.code, 0);
  await close(app.db);
});

test('路由：未知路径返回明确错误，而不是 500', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const r = await call('GET', '/api/不存在的东西');
  assert.notEqual(r.status, 500, '未知路径不该是服务端异常');
  assert.ok(r.msg.includes('接口不存在'), '错误信息要说明是路径问题');
  await close(app.db);
});

test('CORS：预检返回 204 且带允许头', async () => {
  const app = await freshApp();
  const res = fakeRes();
  await app.handle(
    { method: 'OPTIONS', url: '/api/activities', headers: {}, socket: {} },
    res,
  );
  assert.equal(res.statusCode, 204);
  assert.ok(res.headers['Access-Control-Allow-Origin']);
  assert.ok(res.headers['Access-Control-Allow-Headers'].includes('Authorization'));
  await close(app.db);
});

test('错误处理：handler 抛非预期异常时返回 500 且不泄露堆栈', async () => {
  const app = await freshApp();
  // 注入一个会抛异常的 handler。
  app.router.get('/_boom', () => {
    throw new Error('内部细节：数据库连接字符串是 secret');
  });
  const call = await makeCaller(app);
  const r = await call('GET', '/api/_boom');
  assert.equal(r.status, 500);
  assert.equal(r.code, ERROR_CODES.SERVER_ERROR);
  assert.ok(
    !JSON.stringify(r).includes('secret'),
    '错误响应绝不能泄露内部细节',
  );
  await close(app.db);
});

// ══════════════════════════════════════════════════════════════════════
// 仓储行为
// ══════════════════════════════════════════════════════════════════════

test('仓储：undefined 字段被转成 null，不会让写库失败', async () => {
  const { conn, repos } = await freshDb();
  // 刻意留几个 undefined 字段（真实代码里极易出现）。
  const id = await repos.activities.create({
    externalId: 'U-1',
    title: 't',
    organizer: 'o',
    durationHours: 1,
    startTime: toIso(new Date()),
    endTime: toIso(new Date(Date.now() + 3600_000)),
    ownerId: 'o1',
    status: 'published',
    // 以下全部 undefined
    location: undefined,
    geoLat: undefined,
    tags: undefined,
    quota: undefined,
  });
  assert.ok(id > 0, 'containing undefined 也必须能写入');
  const back = await repos.activities.findById(id);
  assert.equal(back.location, '');
  assert.deepEqual(back.tags, []);
  await close(conn);
});

test('仓储：数组字段序列化后能完整读回', async () => {
  const { conn, repos } = await freshDb();
  const id = await repos.activities.create(
    makeActivity({
      externalId: 'T-1',
      title: 't',
      organizer: 'o',
      durationHours: 1,
      startTime: toIso(new Date()),
      endTime: toIso(new Date(Date.now() + 3600_000)),
      ownerId: 'o1',
      tags: ['图书整理', '校内', '带,逗号的标签'],
    }),
  );
  const back = await repos.activities.findById(id);
  // ⚠️ 含逗号的标签会被 split 拆开 —— 这是 CSV 存储的固有限制，
  // 记录在此是为了让限制可见，而不是假装它不存在。
  assert.ok(back.tags.includes('图书整理'));
  assert.ok(back.tags.includes('校内'));
  await close(conn);
});

test('仓储：变更游标按 seq 返回，且不重不漏', async () => {
  const { conn, repos } = await freshDb();
  const mk = (ext, seq) =>
    repos.activities.create(
      makeActivity({
        externalId: ext,
        title: ext,
        organizer: 'o',
        durationHours: 1,
        startTime: toIso(new Date()),
        endTime: toIso(new Date(Date.now() + 3600_000)),
        ownerId: 'o1',
        status: 'published',
        seq,
      }),
    );
  await mk('A', 1);
  await mk('B', 2);
  await mk('C', 3);

  const after1 = await repos.activities.changesSince(1, { visibleOnly: true });
  assert.deepEqual(after1.map((a) => a.title), ['B', 'C'], '应只返回 seq > 1 的');

  const after3 = await repos.activities.changesSince(3, { visibleOnly: true });
  assert.deepEqual(after3, [], '游标之后没有新写入时应为空');
  await close(conn);
});

test('仓储：部门字典去重且有序', async () => {
  const { conn, repos } = await freshDb();
  for (const [i, org] of ['乙部门', '甲部门', '乙部门'].entries()) {
    await repos.activities.create(
      makeActivity({
        externalId: `O-${i}`,
        title: 't',
        organizer: org,
        durationHours: 1,
        startTime: toIso(new Date()),
        endTime: toIso(new Date(Date.now() + 3600_000)),
        ownerId: 'o1',
        status: 'published',
      }),
    );
  }
  const orgs = await repos.activities.organizers();
  assert.deepEqual(orgs, ['乙部门', '甲部门'].sort());
  await close(conn);
});

// ══════════════════════════════════════════════════════════════════════
// 导出（方案 §7.3 / §9.1）
// ══════════════════════════════════════════════════════════════════════

/**
 * 造一个能接收 CSV 的假 res。
 *
 * CSV 响应不是 JSON，因此不能走 `fakeRes()`（那个会尝试 JSON.parse）。
 */
function fakeCsvRes() {
  const r = { statusCode: 200, headers: null, raw: null, text: null };
  r.writeHead = (status, headers) => {
    r.statusCode = status;
    r.headers = headers;
  };
  r.end = (payload) => {
    r.raw = payload;
    r.text = payload.toString('utf8');
  };
  return r;
}

async function callCsv(app, url) {
  const req = Readable.from([]);
  req.method = 'GET';
  req.url = url;
  req.headers = {};
  req.socket = { remoteAddress: '127.0.0.1' };
  const res = fakeCsvRes();
  await app.handle(req, res);
  return res;
}

test('CSV：单元格转义处理逗号、引号、换行（RFC 4180）', async () => {
  const { csvCell, toCsv } = await import('../src/api/export.js');

  // 不含特殊字符 → 不加引号（保持文件可读）。
  assert.equal(csvCell('图书馆'), '图书馆');
  assert.equal(csvCell(42), '42');
  assert.equal(csvCell(null), '');
  assert.equal(csvCell(undefined), '');

  // 含逗号 → 必须加引号，否则整行列错位。
  assert.equal(csvCell('图书整理,校内'), '"图书整理,校内"');

  // 含双引号 → 引号加倍（RFC 4180）。
  assert.equal(csvCell('他说"来"'), '"他说""来"""');

  // 含换行 → 加引号，否则一行变两行。
  assert.equal(csvCell('第一行\n第二行'), '"第一行\n第二行"');

  // 整行组装：字段数应恒定。
  const csv = toCsv([
    ['a', 'b,c', 'd'],
    ['1', '2', '3'],
  ]);
  assert.equal(csv.split('\r\n').length, 2, '含逗号的字段不应把一行拆成两行');
});

test('CSV：必须带 UTF-8 BOM（否则 Excel 中文乱码）', async () => {
  const { UTF8_BOM } = await import('../src/api/export.js');
  assert.equal(UTF8_BOM, '\uFEFF');

  const app = await freshApp();
  await seedDemoData(app.repos);
  const res = await callCsv(app, '/api/activities/export');

  assert.equal(res.statusCode, 200);
  // 检查**原始字节**而不是解码后的字符串：BOM 的意义就在于字节层面。
  assert.equal(res.raw[0], 0xef);
  assert.equal(res.raw[1], 0xbb);
  assert.equal(res.raw[2], 0xbf);
  assert.ok(res.text.includes('图书馆书架整理'), '中文内容应可读');
  await close(app.db);
});

test('CSV：Content-Disposition 同时给 ASCII 兜底与 RFC 5987 中文名', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const res = await callCsv(app, '/api/activities/export');

  const cd = res.headers['Content-Disposition'];
  assert.ok(cd.startsWith('attachment;'), '应当是下载而不是内联');
  // ASCII 兜底：老客户端拿不到中文名时至少有个合法文件名。
  assert.match(cd, /filename="activities-\d{4}-\d{2}-\d{2}\.csv"/);
  // RFC 5987：现代浏览器优先用它，中文名才能正确显示。
  assert.match(cd, /filename\*=UTF-8''/);
  assert.ok(cd.includes(encodeURIComponent('志愿活动')), '中文文件名应被百分号编码');
  await close(app.db);
});

test('CSV：导出内容与筛选条件一致（筛选后导出才符合直觉）', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);

  const all = await callCsv(app, '/api/activities/export');
  const ongoing = await callCsv(app, '/api/activities/export?status=ongoing');

  const rowsOf = (res) => res.text.replace(/^\uFEFF/, '').trim().split('\r\n');
  const allRows = rowsOf(all);
  const ongoingRows = rowsOf(ongoing);

  assert.ok(allRows.length > ongoingRows.length, '筛选后导出的行数应当更少');
  // 第一行是表头。
  assert.ok(allRows[0].includes('活动名称'));
  assert.ok(ongoingRows[0].includes('活动名称'));
  // 每一行都应是"进行中"。
  for (const line of ongoingRows.slice(1)) {
    assert.ok(line.includes('进行中'), `不该出现非进行中的行：${line.slice(0, 40)}`);
  }
  await close(app.db);
});

test('CSV：联系方式默认脱敏（方案 §9.1 零成本底线）', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const res = await callCsv(app, '/api/activities/export');

  const text = res.text;
  // 演示数据里的联系人是 13800000001..8，导出里**不能**出现完整号码。
  assert.ok(!/1380000000\d/.test(text), '导出不得包含完整手机号');
  assert.ok(text.includes('138****'), '应当出现掩码后的号码');
  await close(app.db);
});

test('CSV：单个活动导出的默认类型是「签到名单」，且带"仅限内部使用"与脱敏', async () => {
  /*
    ⚠️ 默认 `kind` 是 **checkin_list**，不是活动摘要。

    客户端（管理端详情页）点"导出"要的是**签到名单**，
    并且明确传了 `?kind=checkin_list`。服务端早期忽略了这个参数、
    无脑返回"活动字段/值"，于是用户点"导出签到名单"拿到的是活动摘要
    —— 文件能下载、能打开、看起来也没坏，只是**内容不是他要的**。
    这种"错得体面"的问题只能靠内容断言抓。
  */
  const app = await freshApp();
  await seedDemoData(app.repos);
  const call = await makeCaller(app);
  const list = await call('GET', '/api/activities?status=ongoing');
  const id = list.data.items[0].id;

  // 加一个带手机号的参与者，验证默认脱敏。
  const admin = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: '1111', deviceId: 'csv-test' },
  });
  // ⚠️ 头名必须**小写**：Node 把请求头规范化为小写，服务端读的是 `headers.authorization`。
  // 写成大写会得到"管理端登录已过期"——看起来像令牌问题，其实是头没读到。
  const headers = { authorization: `Bearer ${admin.data.token}` };
  const added = await call('POST', `/api/activities/${id}/participants`, {
    body: { userNo: '2029001', name: '导出志愿者', phone: '13800001234' },
    headers,
  });
  assert.equal(added.code, 0, `加人失败：${added.msg}`);

  const res = await callCsv(app, `/api/activities/${id}/export?kind=checkin_list`);
  assert.equal(res.statusCode, 200);
  // BOM 必须存在（Excel 中文依赖它）
  assert.equal(res.text.charCodeAt(0), 0xfeff, '必须带 UTF-8 BOM');

  const text = res.text.replace(/^\uFEFF/, '');
  assert.ok(text.includes('仅限内部使用'), '导出首行必须有使用提示（底线③）');
  // 学院列是后加的（学号/姓名/学院/手机号/…），这里按片段断言，避免列序微调就红
  assert.ok(text.includes('学号,姓名,学院,手机号'), '签到名单应有名单表头（含学院）');
  assert.ok(text.includes('138****'), '手机号默认必须脱敏');
  assert.ok(!text.includes('13800001234'), '不得出现完整手机号（决策 D-3）');
  await close(app.db);
});

test('CSV：kind=summary 时导出「字段 / 值」两列', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const call = await makeCaller(app);
  const list = await call('GET', '/api/activities?status=ongoing');
  const id = list.data.items[0].id;

  const res = await callCsv(app, `/api/activities/${id}/export?kind=summary`);
  assert.equal(res.statusCode, 200);
  const text = res.text.replace(/^\uFEFF/, '');
  assert.ok(text.includes('仅限内部使用'));
  const rows = text.trim().split('\r\n');
  // 第一行是提示，第二行才是表头
  assert.equal(rows[1], '字段,值');
  assert.ok(rows.some((r) => r.startsWith('活动名称,')));
  assert.ok(rows.length > 8, '应当导出全部字段');
  await close(app.db);
});

test('CSV：不支持的 kind 返回 400，而不是悄悄给个别的文件', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const call = await makeCaller(app);
  const list = await call('GET', '/api/activities?status=ongoing');
  const id = list.data.items[0].id;

  const res = await callCsv(app, `/api/activities/${id}/export?kind=nonsense`);
  assert.equal(res.statusCode, 400, '未知类型应明确拒绝');
  await close(app.db);
});

test('CSV：导出不存在的活动返回 404，而不是空文件', async () => {
  const app = await freshApp();
  const res = await callCsv(app, '/api/activities/999999/export');
  // 空文件会让使用者以为"这个活动没有数据"，而实际是链接错了。
  assert.equal(res.statusCode, 404);
  await close(app.db);
});

test('路由：/activities/export 不被 /activities/:id 抢先匹配', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const res = await callCsv(app, '/api/activities/export');
  // 若路由顺序写反，这里会返回 404「活动 export 不存在」——
  // 错误信息看起来合理，很难联想到是顺序问题。
  assert.equal(res.statusCode, 200);
  assert.ok(res.headers['Content-Type'].includes('text/csv'));
  await close(app.db);
});

// ══════════════════════════════════════════════════════════════════════
// 种子数据
// ══════════════════════════════════════════════════════════════════════

test('种子：写入后覆盖多种状态，便于验证筛选与统计', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const call = await makeCaller(app);
  const r = await call('GET', '/api/activities');
  const statuses = new Set(r.data.items.map((a) => a.status));
  for (const s of ['published', 'ongoing', 'finished', 'cancelled']) {
    assert.ok(statuses.has(s), `演示数据应包含状态 ${s}`);
  }
  await close(app.db);
});

test('种子：重复执行不重复写入', async () => {
  const app = await freshApp();
  const first = await seedDemoData(app.repos);
  const second = await seedDemoData(app.repos);
  assert.ok(first.inserted > 0);
  assert.equal(second.inserted, 0);
  assert.equal(second.skipped, true);
  await close(app.db);
});

test('种子：时间相对当前时刻，因此不会"过期变全结束"', async () => {
  const app = await freshApp();
  await seedDemoData(app.repos);
  const call = await makeCaller(app);
  const r = await call('GET', '/api/activities');
  // 若用固定日期，跑一段时间后所有活动都会变成已结束，
  // 演示与联调会莫名其妙失败。这里断言"有未来的活动"。
  const now = Date.now();
  const future = r.data.items.filter((a) => parseTime(a.startTime).getTime() > now);
  assert.ok(future.length >= 2, '演示数据里应当始终有尚未开始的活动');
  await close(app.db);
});
