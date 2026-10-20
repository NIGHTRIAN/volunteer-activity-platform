/**
 * 管理端写入接口测试：活动上报 / 状态流转 / 名单 / 邀请码。
 *
 * ## 最后那条"全链路"用例是重点
 *
 * 它把「登录 → 建活动 → 加人 → 发码 → 志愿者绑定」
 * 串成一条真实路径。这条路径一旦断，手机端就永远停在绑定页，
 * 而**每一段单独看都是好的** —— 只有串起来跑才知道通不通。
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';

import { loadConfig } from '../src/config.js';
import { close } from '../src/db/index.js';
import { createServer } from '../src/server.js';
import { nowIso, addMinutesIso } from '../src/util/time.js';

// ─────────────────────────────────────────────────────────────────────────
// 辅助
// ─────────────────────────────────────────────────────────────────────────

async function freshApp(env = {}) {
  const config = loadConfig({
    DB_DRIVER: 'sqlite',
    DB_SQLITE_FILE: ':memory:',
    NODE_ENV: 'test',
    ACCESS_LOG: 'false',
    ...env,
  });
  return createServer(config);
}

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

/** 登录并返回带 Authorization 头的对象。 */
async function adminAuth(app, call, deviceId = 'admin-dev') {
  const r = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId },
  });
  assert.equal(r.code, 0, `登录失败：${r.msg}`);
  return { authorization: `Bearer ${r.data.token}` };
}

/** 一个合法的活动上报体。 */
function activityBody(overrides = {}) {
  return {
    externalId: 'EXT-M1',
    title: '写接口测试活动',
    organizer: '校团委',
    durationHours: 2,
    startTime: addMinutesIso(nowIso(), -10),
    endTime: addMinutesIso(nowIso(), 110),
    location: '南湖校区图书馆',
    geoLat: 34.2175,
    geoLng: 117.1425,
    checkinRadius: 300,
    summary: '测试',
    status: 'published',
    ...overrides,
  };
}

/** 建一个活动，返回 { id, body }。 */
async function createActivity(call, headers, overrides = {}) {
  const body = activityBody(overrides);
  const r = await call('POST', '/api/activities:upsert', {
    body: { batch: [body] },
    headers,
  });
  assert.equal(r.code, 0, `创建失败：${r.msg} ${JSON.stringify(r.data?.rejected ?? [])}`);
  const id = r.data.created[0];
  assert.ok(id, '应返回新活动 id');
  return { id, body };
}

// ─────────────────────────────────────────────────────────────────────────
// 活动上报
// ─────────────────────────────────────────────────────────────────────────

test('上报：创建活动，返回 id 且在列表里可见', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);

  const { id } = await createActivity(call, headers);

  const list = await call('GET', '/api/activities', { headers });
  assert.equal(list.code, 0);
  assert.equal(list.data.items.length, 1);
  assert.equal(list.data.items[0].id, id);
  assert.equal(list.data.items[0].title, '写接口测试活动');
  assert.equal(list.data.items[0].ownerId, app.config.auth.ownerId);
  await close(app.db);
});

test('上报：未登录返回 40101（写入接口一律要身份）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);

  const r = await call('POST', '/api/activities:upsert', {
    body: { batch: [activityBody()] },
  });
  assert.equal(r.status, 401);
  assert.equal(r.code, 40101);
  await close(app.db);
});

test('上报：同一 externalId 再发是**更新**而不是新建（幂等）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);

  const first = await call('POST', '/api/activities:upsert', {
    body: { batch: [activityBody({ title: '标题 A' })] },
    headers,
  });
  const second = await call('POST', '/api/activities:upsert', {
    body: { batch: [activityBody({ title: '标题 B' })] },
    headers,
  });

  assert.equal(first.data.created.length, 1);
  assert.equal(second.data.updated.length, 1, '同 externalId 应走更新');
  assert.equal(second.data.created.length, 0);

  const list = await call('GET', '/api/activities', { headers });
  assert.equal(list.data.items.length, 1, '不能产生两条记录');
  assert.equal(list.data.items[0].title, '标题 B');
  await close(app.db);
});

test('上报：缺少坐标被拒（没有坐标的活动志愿者永远签不上）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);

  const r = await call('POST', '/api/activities:upsert', {
    body: { batch: [activityBody({ geoLat: undefined, geoLng: undefined })] },
    headers,
  });
  assert.equal(r.code, 0, '批量为部分成功语义，整体仍 200');
  assert.equal(r.data.accepted, 0);
  assert.equal(r.data.rejected.length, 1);
  assert.match(JSON.stringify(r.data.rejected[0].errors), /坐标必填|位置/);
  await close(app.db);
});

test('上报：批量里一行错不影响其他行（部分成功）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);

  const r = await call('POST', '/api/activities:upsert', {
    body: {
      batch: [
        activityBody({ externalId: 'OK-1', title: '好的一行' }),
        activityBody({ externalId: '', title: '缺外部编号' }),
        activityBody({ externalId: 'OK-2', title: '另一行好的' }),
      ],
    },
    headers,
  });
  assert.equal(r.data.accepted, 2);
  assert.equal(r.data.rejected.length, 1);
  assert.equal(r.data.rejected[0].index, 1);
  await close(app.db);
});

test('上报：结束时间早于开始时间被拒', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);

  const r = await call('POST', '/api/activities:upsert', {
    body: {
      batch: [
        activityBody({
          startTime: addMinutesIso(nowIso(), 100),
          endTime: addMinutesIso(nowIso(), 10),
        }),
      ],
    },
    headers,
  });
  assert.equal(r.data.accepted, 0);
  assert.match(JSON.stringify(r.data.rejected[0].errors), /晚于开始时间/);
  await close(app.db);
});

test('上报：已发布活动的关键规则被冻结（否则可事后改半径）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);

  await createActivity(call, headers);

  // 只改半径 → 必须被拒
  const frozen = await call('POST', '/api/activities:upsert', {
    body: { batch: [activityBody({ checkinRadius: 900 })] },
    headers,
  });
  assert.equal(frozen.data.accepted, 0);
  assert.match(JSON.stringify(frozen.data.rejected[0].errors), /checkinRadius|冻结/);

  // 只改说明性字段 → 允许
  const okChange = await call('POST', '/api/activities:upsert', {
    body: { batch: [activityBody({ summary: '换了简介' })] },
    headers,
  });
  assert.equal(okChange.data.accepted, 1, '说明性字段应可改');
  await close(app.db);
});

test('上报：网络白名单可写，且"没传"不等于"清空"', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);

  // 草稿状态便于反复改（已发布会冻结关键字段，但白名单不属于冻结项）
  const created = await call('POST', '/api/activities:upsert', {
    body: {
      batch: [
        activityBody({
          wifiBssids: ['aa:bb:cc:dd:ee:ff'],
          campusIpPrefixes: ['10.3.'],
        }),
      ],
    },
    headers,
  });
  const id = created.data.created[0];

  /*
    详情接口**同时**给扁平字段与 `{activity, disclaimer}`。

    * 手机端把 `data` 直接当 `Activity.fromJson` 的输入（要扁平）；
    * 网页端读 `data.activity`（要包裹）。

    少任一种就有一端显示空白，而且**不会报错**：
    `Activity.fromJson` 对缺字段一律给默认值，表现为
    「未知状态 / 1970-01-01」。真机上就是这么发现这个契约不一致的。
  */
  const detail = await call('GET', `/api/activities/${id}`, { headers });
  assert.equal(detail.data.id, id, '扁平形状：手机端直接解析 data 需要它');
  assert.ok(detail.data.status, '扁平形状需要 status（否则 App 显示"未知状态"）');
  assert.deepEqual(detail.data.activity.wifiBssids, ['aa:bb:cc:dd:ee:ff']);
  assert.deepEqual(detail.data.activity.campusIpPrefixes, ['10.3.']);

  // 不带这两个字段再上报 → 应**保留**原配置
  await call('POST', '/api/activities:upsert', {
    body: { batch: [activityBody({ summary: '只改简介' })] },
    headers,
  });
  const after = await call('GET', `/api/activities/${id}`, { headers });
  assert.deepEqual(after.data.activity.wifiBssids, ['aa:bb:cc:dd:ee:ff'], '没传就不能清空');
  assert.deepEqual(after.data.activity.campusIpPrefixes, ['10.3.']);

  // 显式传空数组 → 清空
  await call('POST', '/api/activities:upsert', {
    body: { batch: [activityBody({ wifiBssids: [], campusIpPrefixes: [] })] },
    headers,
  });
  const cleared = await call('GET', `/api/activities/${id}`, { headers });
  assert.deepEqual(cleared.data.activity.wifiBssids, []);
  await close(app.db);
});

// ─────────────────────────────────────────────────────────────────────────
// 状态流转
// ─────────────────────────────────────────────────────────────────────────

test('流转：草稿 → 已发布 → 进行中 → 已结束，逐级合法', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);

  const { id } = await createActivity(call, headers, { status: 'draft' });

  const steps = ['published', 'ongoing', 'finished'];
  for (const to of steps) {
    const r = await call('POST', `/api/activities/${id}:transition`, {
      body: { to },
      headers,
    });
    assert.equal(r.code, 0, `流转到 ${to} 失败：${r.msg}`);
    assert.equal(r.data.to, to);
  }

  const detail = await call('GET', `/api/activities/${id}`, { headers });
  assert.equal(detail.data.activity.status, 'finished');
  assert.ok(detail.data.activity.terminalAt, '终态应写 terminalAt（留存期从它算起）');
  await close(app.db);
});

test('流转：跳过中间状态被拒（草稿不能直接结束）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);

  const { id } = await createActivity(call, headers, { status: 'draft' });
  const r = await call('POST', `/api/activities/${id}:transition`, {
    body: { to: 'finished' },
    headers,
  });
  assert.equal(r.status, 409);
  assert.equal(r.code, 40901);
  assert.equal(r.data, null);
  await close(app.db);
});

test('流转：取消必须给至少 5 个字的原因', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);

  const { id } = await createActivity(call, headers);

  const noReason = await call('POST', `/api/activities/${id}:transition`, {
    body: { to: 'cancelled' },
    headers,
  });
  assert.match(noReason.msg, /取消原因/);

  const short = await call('POST', `/api/activities/${id}:transition`, {
    body: { to: 'cancelled', cancelReason: '雨' },
    headers,
  });
  assert.match(short.msg, /取消原因/);

  const ok = await call('POST', `/api/activities/${id}:transition`, {
    body: { to: 'cancelled', cancelReason: '连续降雨，场地无法使用' },
    headers,
  });
  assert.equal(ok.code, 0);
  assert.equal(ok.data.to, 'cancelled');
  await close(app.db);
});

test('流转：发布时写入规则快照（争议时有据可依）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);

  const { id } = await createActivity(call, headers, { status: 'draft' });
  await call('POST', `/api/activities/${id}:transition`, {
    body: { to: 'published' },
    headers,
  });

  const snap = await app.db.queryOne('SELECT * FROM rule_snapshot WHERE activity_id = ?', [id]);
  assert.ok(snap, '发布后必须有规则快照');
  const payload = JSON.parse(snap.payload);
  assert.ok(payload.checkinRadius > 0);
  await close(app.db);
});

// ─────────────────────────────────────────────────────────────────────────
// 名单
// ─────────────────────────────────────────────────────────────────────────

test('名单：加人 → 列表可见，手机号只下发掩码', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);
  const { id } = await createActivity(call, headers);

  const add = await call('POST', `/api/activities/${id}/participants`, {
    body: { userNo: '2021001', name: '张伟', phone: '13800000001' },
    headers,
  });
  assert.equal(add.code, 0);
  assert.equal(add.data.item.userNo, '2021001');

  const list = await call('GET', `/api/activities/${id}/participants`, { headers });
  assert.equal(list.data.total, 1);
  assert.equal(list.data.items[0].name, '张伟');
  assert.equal(list.data.items[0].phone, '138****0001', '列表不能下发完整手机号');
  assert.equal(list.data.counts.notCheckedIn, 1);
  await close(app.db);
});

test('名单：同一学号重复加返回 409 冲突（不是静默重复）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);
  const { id } = await createActivity(call, headers);

  await call('POST', `/api/activities/${id}/participants`, {
    body: { userNo: '2021001', name: '张伟' },
    headers,
  });
  const dup = await call('POST', `/api/activities/${id}/participants`, {
    body: { userNo: '2021001', name: '张伟' },
    headers,
  });
  assert.equal(dup.status, 409);
  assert.equal(dup.code, 40901);
  assert.match(dup.msg, /已存在/);
  await close(app.db);
});

test('名单：移出是软删，且同时作废该人的活动授权', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);
  const { id } = await createActivity(call, headers);

  await call('POST', `/api/activities/${id}/participants`, {
    body: { userNo: '2021001', name: '张伟' },
    headers,
  });
  // 发码并绑定，制造一个有效授权
  const codes = await call('POST', `/api/activities/${id}/invite-codes`, {
    body: {},
    headers,
  });
  const code = codes.data.items[0].inviteCode;
  const bind = await call('POST', '/api/auth/bind', {
    body: { activityId: id, userNo: '2021001', inviteCode: code, deviceId: 'vol-1' },
  });
  assert.equal(bind.code, 0, `绑定失败：${bind.msg}`);
  assert.ok(await app.repos.grants.findByToken(bind.data.token));

  const del = await call('DELETE', `/api/activities/${id}/participants/2021001`, { headers });
  assert.equal(del.code, 0);

  const list = await call('GET', `/api/activities/${id}/participants`, { headers });
  /*
    软删除：记录**仍在名单里**，只是状态变成"已移出"。

    这才是软删的意义 —— 硬删会让"这个人到底来没来过"永远无法回答，
    而发布者也需要看到"他曾在名单里、什么时候被移出的"。
    界面据此把这一行渲染成灰显的"已移出"。
  */
  assert.equal(list.data.total, 1, '软删记录应保留在名单里');
  assert.equal(list.data.items[0].signupStatus, 'cancelled', '状态应为已移出');
  assert.ok(list.data.items[0].removedAt, '要留下移出时间（对账留痕）');

  const grant = await app.repos.grants.findByToken(bind.data.token);
  assert.equal(grant, null, '移出后该人的令牌必须立即失效');

  // 记录仍在库里（软删），便于回答"这个人到底来过没有"
  const row = await app.db.queryOne(
    'SELECT removed_at, signup_status FROM participant WHERE activity_id = ? AND user_no = ?',
    [id, '2021001'],
  );
  assert.ok(row.removed_at);
  assert.equal(row.signup_status, 'cancelled');
  await close(app.db);
});

test('名单：批量导入逐行给结果，部分成功', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);
  const { id } = await createActivity(call, headers);

  const r = await call('POST', `/api/activities/${id}/participants:import`, {
    body: {
      rows: [
        ['2021001', '张伟', '13800000001'],
        ['', '缺学号'],
        ['2021003', '王强', ''],
      ],
    },
    headers,
  });
  assert.equal(r.code, 0);
  assert.equal(r.data.total, 3);
  assert.equal(r.data.accepted, 2);
  assert.equal(r.data.rejected, 1);

  const list = await call('GET', `/api/activities/${id}/participants`, { headers });
  assert.equal(list.data.total, 2);
  await close(app.db);
});

// ─────────────────────────────────────────────────────────────────────────
// 邀请码
// ─────────────────────────────────────────────────────────────────────────

test('发码：重复调用复用未使用的码（现场刚念完就变码会乱套）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);
  const { id } = await createActivity(call, headers);
  await call('POST', `/api/activities/${id}/participants`, {
    body: { userNo: '2021001', name: '张伟' },
    headers,
  });

  const first = await call('POST', `/api/activities/${id}/invite-codes`, { body: {}, headers });
  const second = await call('POST', `/api/activities/${id}/invite-codes`, { body: {}, headers });
  assert.equal(first.data.items[0].inviteCode, second.data.items[0].inviteCode);
  await close(app.db);
});

test('发码：码被用掉后再发是新码，且旧码不再展示', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);
  const { id } = await createActivity(call, headers);
  await call('POST', `/api/activities/${id}/participants`, {
    body: { userNo: '2021001', name: '张伟' },
    headers,
  });

  const first = await call('POST', `/api/activities/${id}/invite-codes`, { body: {}, headers });
  const oldCode = first.data.items[0].inviteCode;
  await call('POST', '/api/auth/bind', {
    body: { activityId: id, userNo: '2021001', inviteCode: oldCode, deviceId: 'vol-1' },
  });

  const second = await call('POST', `/api/activities/${id}/invite-codes`, { body: {}, headers });
  assert.notEqual(second.data.items[0].inviteCode, oldCode, '用掉后应换新码');
  await close(app.db);
});

// ─────────────────────────────────────────────────────────────────────────
// 越权
// ─────────────────────────────────────────────────────────────────────────

/*
  归属越权统一返回 **403 无权操作该活动**。

  曾经写成 404（"不泄露活动是否存在"），但那会让发布者看到"活动不存在"
  → 以为自己的活动丢了。列表接口已做归属隔离，管理员本来也看不到别人的活动，
  所以泄露风险很小、而误导的代价很大。
*/
test('越权：别人的活动一律 403（无权操作该活动）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);
  const { id } = await createActivity(call, headers);

  // 直接把 owner 改掉，模拟"另一个发布者的活动"
  await app.db.execute('UPDATE activity SET owner_id = ? WHERE id = ?', ['owner-other', id]);

  const list = await call('GET', `/api/activities/${id}/participants`, { headers });
  assert.equal(list.status, 403);
  assert.equal(list.code, 40301);

  const del = await call('DELETE', `/api/activities/${id}/participants/2021001`, { headers });
  assert.equal(del.status, 403);

  const trans = await call('POST', `/api/activities/${id}:transition`, {
    body: { to: 'ongoing' },
    headers,
  });
  assert.equal(trans.status, 403, '越权流转必须被挡住');
  await close(app.db);
});

// ─────────────────────────────────────────────────────────────────────────
// 全链路
// ─────────────────────────────────────────────────────────────────────────

test('全链路：登录 → 建活动 → 加人 → 发码 → 志愿者绑定成功', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);

  // ① 管理端登录
  const headers = await adminAuth(app, call, 'admin-e2e');

  // ② 建活动（带场地网络白名单 —— 否则自动通过不可达）
  const { id } = await createActivity(call, headers, {
    externalId: 'E2E-1',
    title: '全链路活动',
    wifiBssids: ['aa:bb:cc:dd:ee:ff'],
    campusIpPrefixes: ['10.3.'],
  });

  // ③ 加名单
  const add = await call('POST', `/api/activities/${id}/participants`, {
    body: { userNo: '2021001', name: '张伟', phone: '13800000001' },
    headers,
  });
  assert.equal(add.code, 0);

  // ④ 发邀请码
  const codes = await call('POST', `/api/activities/${id}/invite-codes`, { body: {}, headers });
  assert.equal(codes.code, 0);
  assert.equal(codes.data.items.length, 1);
  const { inviteCode } = codes.data.items[0];
  assert.ok(inviteCode);

  // ⑤ 志愿者绑定（换一个"设备"，模拟用户端）
  const bind = await call('POST', '/api/auth/bind', {
    body: {
      activityId: id,
      userNo: '2021001',
      inviteCode,
      deviceId: 'vol-device-e2e',
      phoneSuffix: '0001',
    },
  });
  assert.equal(bind.code, 0, `绑定失败：${bind.msg}`);
  assert.ok(bind.data.token);
  assert.equal(bind.data.userNo, '2021001');
  assert.equal(bind.data.name, '张伟');

  // ⑥ 管理者随即能看到这个人的"待绑定/已绑定"状态变化
  const list = await call('GET', `/api/activities/${id}/participants`, { headers });
  assert.equal(list.data.items[0].inviteCodeIssued, true, '绑定后名单应标注已发码已使用');

  await close(app.db);
});

// ══════════════════════════════════════════════════════════════════════════
// 导出：必须带上场地网络白名单（O-17 收尾）
// ══════════════════════════════════════════════════════════════════════════

/** CSV 响应不是 JSON，不能走 `fakeRes()`（那个会 JSON.parse）。 */
function fakeCsvRes() {
  const r = { statusCode: 200, headers: null, text: null };
  r.writeHead = (status, headers) => {
    r.statusCode = status;
    r.headers = headers;
  };
  r.end = (payload) => {
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

test('导出：活动列表 CSV 包含场地网络白名单两列', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);

  await createActivity(call, headers, {
    externalId: 'EXP-1',
    title: '导出白名单测试',
    wifiBssids: ['aa:bb:cc:dd:ee:ff', '11:22:33:44:55:66'],
    campusIpPrefixes: ['10.3.', '202.119.'],
  });

  /*
    为什么这两列必须进导出：
    判定的两个加分项（Wi-Fi +20 / 校园网 +10）只在活动**配置了白名单**时才生效。
    事后审计"某次签到为什么被自动通过"时，如果导出里没有这两列，
    就没法回答"当时到底配了什么、配得对不对"。
  */
  const res = await callCsv(app, '/api/activities/export');
  assert.equal(res.statusCode, 200);
  assert.match(String(res.headers['Content-Type'] ?? ''), /text\/csv/);

  assert.match(res.text, /场地 Wi-Fi\(BSSID\)/, '表头应有 Wi-Fi 列');
  assert.match(res.text, /校园网网段/, '表头应有校园网列');
  assert.match(res.text, /aa:bb:cc:dd:ee:ff/, '值应包含 BSSID');
  assert.match(res.text, /202\.119\./, '值应包含校园网网段');

  await close(app.db);
});
// ─────────────────────────────────────────────────────────────────────────
// 名单：学院字段 / 学号长度 / 手机号选填
// ─────────────────────────────────────────────────────────────────────────

/**
 * 这组测试来自一个真实报障：**管理端手动输入时读取的行是错的**。
 *
 * 根因在客户端解析（空格没被当分隔符），但暴露出的三个前提必须由服务端保证：
 *   * 学号长度不固定（不能卡"4 位起"）
 *   * 姓名长度不固定
 *   * 手机号选填
 *   * 学院是可选列
 */
test('名单：学院可选、手机号可选、学号长度不固定', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);
  const { id } = await createActivity(call, headers);

  const report = await call('POST', `/api/activities/${id}/participants:import`, {
    headers,
    body: {
      rows: [
        // 学号(2 位) / 姓名 / 手机号 / 学院
        ['A1', '张三', '13800000001', '计算机学院'],
        // 有学院但没手机号（手机号选填）
        ['2026102', '李娜', '', '外国语学院'],
        // 只有学号和姓名
        ['2026103', '王强'],
        // 长学号 + 长姓名 + 长学院
        ['202110010101', '欧阳上官', '13900000002', '信息与控制工程学院'],
      ],
    },
  });

  assert.equal(report.code, 0, `导入失败：${report.msg}`);
  assert.equal(report.data.total, 4);
  assert.equal(report.data.accepted, 4, `应有 4 行被接受：${JSON.stringify(report.data.rows)}`);
  assert.equal(report.data.rejected, 0);

  const list = await call('GET', `/api/activities/${id}/participants`, { headers });
  const byNo = new Map(list.data.items.map((p) => [p.userNo, p]));

  assert.equal(byNo.get('A1').college, '计算机学院', '学院要落库并回传');
  assert.equal(byNo.get('2026102').college, '外国语学院');
  assert.equal(byNo.get('2026102').phone, undefined, '没填手机号就不该有 phone 字段');
  assert.equal(byNo.get('2026103').college, undefined, '没填学院就不该有 college 字段');
  assert.equal(byNo.get('202110010101').name, '欧阳上官', '姓名长度不固定');

  await close(app.db);
});

test('名单：单条加人也能带学院', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);
  const { id } = await createActivity(call, headers);

  const added = await call('POST', `/api/activities/${id}/participants`, {
    headers,
    body: { userNo: 'B7', name: '赵六', college: '体育学院' },
  });
  assert.equal(added.code, 0, added.msg);
  assert.equal(added.data.item.college, '体育学院');
  assert.equal(added.data.item.userNo, 'B7', '2 位学号应被接受');

  await close(app.db);
});

test('名单：学号仍然拒绝明显非法的值（不能因为放宽就什么都收）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const headers = await adminAuth(app, call);
  const { id } = await createActivity(call, headers);

  for (const bad of ['bad!!', '带空格 的', 'a'.repeat(33)]) {
    const r = await call('POST', `/api/activities/${id}/participants`, {
      headers,
      body: { userNo: bad, name: '非法' },
    });
    assert.equal(r.code, 40001, `「${bad}」应被拒绝`);
  }

  await close(app.db);
});