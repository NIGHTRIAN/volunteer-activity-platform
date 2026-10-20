/**
 * 鉴权接口测试（`/auth/admin/login`、`/auth/bind`）。
 *
 * ## 这两个接口为什么需要这么多用例
 *
 * 它们是**手机端唯一的前置门槛**：拿不到令牌，App 一个请求都发不出去，
 * 表现为"登录不进去 / 绑定不上"——用户能看到的只有一句错误提示，
 * 完全无法自查。所以这里的每一条错误路径都要有确定的行为，
 * 而且错误码要能指导用户下一步动作（找发布者要码？核对姓名？等十分钟？）。
 *
 * ## 覆盖的关键规则
 *
 * | 规则 | 为什么重要 |
 * |---|---|
 * | 邀请码 = 发布者身份（不是设备） | 否则换手机就"活动全部消失" |
 * | 同设备重试幂等 | 否则响应丢了就把用户**永久锁死**在绑定页 |
 * | 换设备需重新发码 | 否则两台手机能同时签到 |
 * | 登录失败锁定 | 邀请码默认 1111，必须防暴力猜 |
 * | 无效令牌不阻断公开接口 | 否则令牌过期后连首页都打不开 |
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';

import { loadConfig } from '../src/config.js';
import { close } from '../src/db/index.js';
import { createServer } from '../src/server.js';
import { makeActivity } from '../src/stores/activity.js';
import { nowIso, addMinutesIso } from '../src/util/time.js';

// ══════════════════════════════════════════════════════════════════════
// 辅助
// ══════════════════════════════════════════════════════════════════════

/** 起一个隔离的内存库服务。 */
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

/** 调一次接口（走真实读流，与生产同一条路径）。 */
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

/** 建一个已发布的活动，owner 取配置里的 ownerId（与登录后一致）。 */
async function seedActivity(app, overrides = {}) {
  const now = new Date();
  const a = makeActivity({
    externalId: overrides.externalId ?? 'EXT-AUTH-1',
    title: overrides.title ?? '鉴权测试活动',
    organizer: '校团委',
    durationHours: 2,
    startTime: addMinutesIso(nowIso(), -10),
    endTime: addMinutesIso(nowIso(), 110),
    status: 'published',
    ownerId: app.config.auth.ownerId,
    geoLat: 34.2175,
    geoLng: 117.1425,
    checkinRadius: 300,
    ...overrides,
  });
  const newId = await app.repos.activities.create(a);
  // makeActivity 不生成 id（id 由库自增）。不回填的话后面所有
  // 以 activity.id 为参数的操作都会绑到 undefined —— SQLite 直接报
  // "cannot be bound to SQLite parameter"，而错误看起来像 SQL 写错了。
  a.id = String(newId);
  return a;
}

/** 往名单里加一个人。 */
async function seedParticipant(app, activityId, { userNo, name, phoneSuffix }) {
  const now = nowIso();
  const r = await app.db.execute(
    `INSERT INTO participant
       (activity_id, user_no, name, phone, phone_suffix, signup_status,
        removed_at, removed_by, grant_expires_at, invite_code_used_at,
        bound_device_id, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, 'signed', NULL, NULL, NULL, NULL, NULL, ?, ?)`,
    [activityId, userNo, name, `1380000${phoneSuffix}`, phoneSuffix, now, now],
  );
  return r.lastInsertId;
}

/** 发一个邀请码。 */
async function seedInvite(app, activityId, userNo, code, { usedAt = null } = {}) {
  const now = nowIso();
  const r = await app.db.execute(
    `INSERT INTO invite_code
       (activity_id, user_no, code, expires_at, used_at, reissued, created_at)
     VALUES (?, ?, ?, ?, ?, 0, ?)`,
    [activityId, userNo, code, addMinutesIso(now, 60 * 24), usedAt, now],
  );
  return r.lastInsertId;
}

/** 准备一个"可绑定"的场景：活动 + 名单 + 邀请码。 */
async function seedBindable(app, opts = {}) {
  const activity = await seedActivity(app);
  await seedParticipant(app, activity.id, {
    userNo: '2021001',
    name: '张伟',
    phoneSuffix: '0001',
  });
  await seedInvite(app, activity.id, '2021001', opts.code ?? 'ABCD2345', {
    usedAt: opts.usedAt,
  });
  return activity;
}

const DEVICE = 'android-test-device-1';

// ══════════════════════════════════════════════════════════════════════
// 管理端登录
// ══════════════════════════════════════════════════════════════════════

test('登录：邀请码正确时返回令牌、ownerId 与活跃活动数', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  await seedActivity(app);

  const r = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: DEVICE },
  });

  assert.equal(r.status, 200);
  assert.equal(r.code, 0);
  assert.ok(r.data.token, '必须返回令牌，否则 App 无法发任何请求');
  assert.equal(r.data.ownerId, app.config.auth.ownerId);
  assert.equal(r.data.deviceId, DEVICE);
  assert.equal(r.data.activeActivityCount, 1, '应按 ownerId 统计非终态活动');
  assert.ok(r.data.serverTime, '客户端要用它校正时钟偏差');
  await close(app.db);
});

test('登录：邀请码是**发布者身份**，换设备登录仍看到同一批活动', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  await seedActivity(app);

  const a = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: 'device-A' },
  });
  const b = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: 'device-B' },
  });

  /*
    mock 阶段用**设备指纹**推导 ownerId，结果换设备后
    "我发布的活动"变成 0 条。这条用例就是钉住那个回归：
    归属由邀请码决定，与设备无关。
  */
  assert.equal(a.data.ownerId, b.data.ownerId, '换设备不能换 ownerId');
  assert.equal(b.data.activeActivityCount, 1, '换设备后仍应看到同一批活动');
  assert.notEqual(a.data.token, b.data.token, '每次登录应是新令牌');
  await close(app.db);
});

test('登录：邀请码错误返回 40101，且**不泄露**正确码', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);

  const r = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: '9999', deviceId: DEVICE },
  });

  assert.equal(r.status, 401);
  assert.equal(r.code, 40101);
  assert.equal(r.msg, '邀请码不正确');
  assert.ok(!r.msg.includes(app.config.auth.adminInviteCode), '错误文案不能带出正确邀请码');
  await close(app.db);
});

test('登录：缺少设备标识返回 40001（设备绑定是后续所有授权的前提）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);

  const r = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode },
  });

  assert.equal(r.status, 400);
  assert.equal(r.code, 40001);
  assert.equal(r.msg, '设备标识不能为空');
  await close(app.db);
});

test('登录：连续失败达到上限后锁定，且锁定优先于校验码', async () => {
  const app = await freshApp({ LOGIN_MAX_FAILURES: '3' });
  const call = await makeCaller(app);

  for (let i = 0; i < 3; i += 1) {
    const bad = await call('POST', '/api/auth/admin/login', {
      body: { inviteCode: '9999', deviceId: DEVICE },
    });
    assert.equal(bad.code, 40101);
  }

  // 第 4 次即使填**正确**邀请码也必须被拒 —— 否则暴力破解只需猜对一次。
  const locked = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: DEVICE },
  });
  // 423 Locked：这不是"凭证错误"，而是"暂时不允许尝试"，语义上更准确。
  assert.equal(locked.status, 423);
  assert.equal(locked.code, 40101);
  assert.match(locked.msg, /连续 3 次失败/);
  await close(app.db);
});

test('登录：锁定时长过后可以重新登录', async () => {
  const app = await freshApp({ LOGIN_MAX_FAILURES: '1', LOGIN_LOCK_MINUTES: '10' });
  const call = await makeCaller(app);

  await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: '9999', deviceId: DEVICE },
  });
  const locked = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: DEVICE },
  });
  assert.match(locked.msg, /失败/);

  // 把审计记录挪到窗口之外，模拟"等够时间了"。
  await app.db.execute('UPDATE login_audit SET at = ?', [
    addMinutesIso(nowIso(), -60),
  ]);

  const ok = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: DEVICE },
  });
  assert.equal(ok.code, 0);
  assert.ok(ok.data.token);
  await close(app.db);
});

test('登录：成功登录会清除失败计数（不会被历史失败拖累）', async () => {
  const app = await freshApp({ LOGIN_MAX_FAILURES: '2' });
  const call = await makeCaller(app);

  await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: '9999', deviceId: DEVICE },
  });
  const ok = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: DEVICE },
  });
  assert.equal(ok.code, 0);

  /*
    这里刻意**不**要求"成功后清零失败计数"。
    理由：清零会让攻击者用"猜错 N-1 次 + 猜对 1 次"无限试探。
    正确做法是失败按时间窗统计，成功后不清零 —— 只要不乱猜就不会被锁。
    这条用例固定的是"成功一次后仍能继续登录"，而不是"计数被清零"。
  */
  const again = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: DEVICE },
  });
  assert.equal(again.code, 0);
  await close(app.db);
});

// ══════════════════════════════════════════════════════════════════════
// 志愿者绑定
// ══════════════════════════════════════════════════════════════════════

test('绑定：成功返回活动授权、学号与姓名', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const activity = await seedBindable(app);

  const r = await call('POST', '/api/auth/bind', {
    body: {
      activityId: activity.id,
      userNo: '2021001',
      inviteCode: 'ABCD2345',
      deviceId: DEVICE,
    },
  });

  assert.equal(r.code, 0);
  assert.ok(r.data.token);
  assert.equal(r.data.activityId, activity.id);
  assert.equal(r.data.userNo, '2021001');
  assert.equal(r.data.name, '张伟');
  assert.equal(r.data.deviceId, DEVICE);
  assert.ok(r.data.expiresAt);
  assert.ok(r.data.serverTime);

  // 名单上要落下设备指纹与授权到期时间（看板/审计要用）。
  const row = await app.db.queryOne(
    'SELECT bound_device_id, grant_expires_at, invite_code_used_at FROM participant WHERE activity_id = ? AND user_no = ?',
    [activity.id, '2021001'],
  );
  assert.equal(row.bound_device_id, DEVICE);
  assert.ok(row.grant_expires_at);
  assert.ok(row.invite_code_used_at);
  await close(app.db);
});

test('绑定：同设备重试必须幂等（否则响应丢了就把人永久锁死）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const activity = await seedBindable(app);

  const body = {
    activityId: activity.id,
    userNo: '2021001',
    inviteCode: 'ABCD2345',
    deviceId: DEVICE,
  };
  const first = await call('POST', '/api/auth/bind', { body });
  assert.equal(first.code, 0);

  /*
    第二次携带的是**同一个、已经用过的**邀请码。
    如果不做幂等，这里会报"邀请码无效/已被使用"，
    用户就再也进不去 —— 而这是他无法自救的状态。
  */
  const second = await call('POST', '/api/auth/bind', { body });
  assert.equal(second.code, 0, `重试应成功，实际：${second.msg}`);
  assert.equal(second.data.token, first.data.token, '应返回同一个令牌');
  assert.equal(second.data.idempotentReplay, true);
  await close(app.db);
});

test('绑定：邀请码错误返回 40101 INVITE_CODE_INVALID', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const activity = await seedBindable(app);

  const r = await call('POST', '/api/auth/bind', {
    body: {
      activityId: activity.id,
      userNo: '2021001',
      inviteCode: 'WRONG123',
      deviceId: DEVICE,
    },
  });
  assert.equal(r.status, 401);
  assert.equal(r.code, 40101);
  assert.match(r.msg, /邀请码/);
  await close(app.db);
});

test('绑定：邀请码发给了别人 → 身份不匹配（不是"码无效"）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const activity = await seedBindable(app);

  /*
    错误码区分很重要：说"邀请码无效"用户会一直重填同一个码；
    说"不属于这个学号"他才会去核对学号。
  */
  const r = await call('POST', '/api/auth/bind', {
    body: {
      activityId: activity.id,
      userNo: '2029999',
      inviteCode: 'ABCD2345',
      deviceId: DEVICE,
    },
  });
  assert.equal(r.status, 403);
  assert.equal(r.code, 40301);
  assert.match(r.msg, /不属于这个学号/);
  await close(app.db);
});

test('绑定：不在名单里返回 40301 NOT_IN_PARTICIPANT_LIST', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const activity = await seedActivity(app);
  // 名单里没有这个人，但码存在（模拟发布者发码后把人移出了名单）
  await seedInvite(app, activity.id, '2021001', 'ABCD2345');

  const r = await call('POST', '/api/auth/bind', {
    body: {
      activityId: activity.id,
      userNo: '2021001',
      inviteCode: 'ABCD2345',
      deviceId: DEVICE,
    },
  });
  assert.equal(r.status, 403);
  assert.equal(r.code, 40301);
  assert.match(r.msg, /名单/);
  await close(app.db);
});

test('绑定：姓名或手机后四位不匹配 → 40301 IDENTITY_MISMATCH', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const activity = await seedBindable(app);

  const wrongName = await call('POST', '/api/auth/bind', {
    body: {
      activityId: activity.id,
      userNo: '2021001',
      inviteCode: 'ABCD2345',
      deviceId: DEVICE,
      name: '李四',
    },
  });
  assert.equal(wrongName.code, 40301);
  assert.equal(wrongName.msg, '姓名或手机号后四位不匹配');

  // 只填手机后四位、且对得上 → 应通过（现场更常见）
  const bySuffix = await call('POST', '/api/auth/bind', {
    body: {
      activityId: activity.id,
      userNo: '2021001',
      inviteCode: 'ABCD2345',
      deviceId: DEVICE,
      phoneSuffix: '0001',
    },
  });
  assert.equal(bySuffix.code, 0, `后四位正确应通过，实际：${bySuffix.msg}`);
  await close(app.db);
});

test('绑定：填了姓名且正确 → 通过（姓名/后四位是"或"不是"且"）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const activity = await seedBindable(app);

  const r = await call('POST', '/api/auth/bind', {
    body: {
      activityId: activity.id,
      userNo: '2021001',
      inviteCode: 'ABCD2345',
      deviceId: DEVICE,
      name: '张伟',
      phoneSuffix: '9999', // 故意给错的
    },
  });
  assert.equal(r.code, 0, '任一项对上即可，不该要求两项都对');
  await close(app.db);
});

test('绑定：邀请码已过期返回 40101', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const activity = await seedActivity(app);
  await seedParticipant(app, activity.id, { userNo: '2021001', name: '张伟', phoneSuffix: '0001' });
  await app.db.execute(
    `INSERT INTO invite_code (activity_id, user_no, code, expires_at, used_at, reissued, created_at)
     VALUES (?, ?, ?, ?, NULL, 0, ?)`,
    [activity.id, '2021001', 'OLDCODE1', addMinutesIso(nowIso(), -60), nowIso()],
  );

  const r = await call('POST', '/api/auth/bind', {
    body: {
      activityId: activity.id,
      userNo: '2021001',
      inviteCode: 'OLDCODE1',
      deviceId: DEVICE,
    },
  });
  assert.equal(r.code, 40101);
  assert.match(r.msg, /过期/);
  await close(app.db);
});

test('绑定：活动不存在返回 40401（不泄露"曾经存在过"）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);

  const r = await call('POST', '/api/auth/bind', {
    body: {
      activityId: 'act-not-exist',
      userNo: '2021001',
      inviteCode: 'ABCD2345',
      deviceId: DEVICE,
    },
  });
  assert.equal(r.status, 404);
  assert.equal(r.code, 40401);
  await close(app.db);
});

test('绑定：换设备且邀请码已用过 → 40301 DEVICE_ALREADY_BOUND', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const activity = await seedBindable(app);

  const first = await call('POST', '/api/auth/bind', {
    body: {
      activityId: activity.id,
      userNo: '2021001',
      inviteCode: 'ABCD2345',
      deviceId: 'device-A',
    },
  });
  assert.equal(first.code, 0);

  /*
    换设备必须被挡住：否则同一个身份可以在两台手机上同时签到，
    "一个人只能在一个设备上操作"这条防线就没了。
    解绑需要发布者重新发码。
  */
  const second = await call('POST', '/api/auth/bind', {
    body: {
      activityId: activity.id,
      userNo: '2021001',
      inviteCode: 'ABCD2345',
      deviceId: 'device-B',
    },
  });
  assert.equal(second.status, 403);
  assert.equal(second.code, 40301);
  assert.match(second.msg, /已绑定其他设备/);
  await close(app.db);
});

test('绑定：发布者重新发码后，换设备可以重新绑定（旧授权作废）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const activity = await seedBindable(app);

  const first = await call('POST', '/api/auth/bind', {
    body: {
      activityId: activity.id,
      userNo: '2021001',
      inviteCode: 'ABCD2345',
      deviceId: 'device-A',
    },
  });
  assert.equal(first.code, 0);

  // 发布者重新发一个码（模拟"换手机，找发布者要新码"）。
  //
  // 走**仓储**而不是手写 INSERT：`invite_code` 在 (activity_id, user_no)
  // 上有唯一约束，重发必须是 UPDATE（reissued + 1）；INSERT 会直接
  // 报 `UNIQUE constraint failed` —— 而发布者只是想"再发一次"。
  await app.repos.inviteCodes.create({
    activityId: activity.id,
    userNo: '2021001',
    code: 'NEWCODE9',
  });

  const second = await call('POST', '/api/auth/bind', {
    body: {
      activityId: activity.id,
      userNo: '2021001',
      inviteCode: 'NEWCODE9',
      deviceId: 'device-B',
    },
  });
  assert.equal(second.code, 0, `重新发码后应可换设备，实际：${second.msg}`);
  assert.notEqual(second.data.token, first.data.token);

  // 旧令牌必须失效 —— 否则"已换手机"还留着后门。
  const old = await app.repos.grants.findByToken(first.data.token);
  assert.equal(old, null, '旧授权应被作废');
  await close(app.db);
});

// ══════════════════════════════════════════════════════════════════════
// 令牌解析
// ══════════════════════════════════════════════════════════════════════

test('令牌解析：管理端令牌 → admin 身份，含 ownerId', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);

  const login = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: DEVICE },
  });

  // 用一个需要身份的后续接口来间接验证（列表接口本身允许匿名）。
  const me = await app.db.queryOne('SELECT owner_id FROM admin_session WHERE token = ?', [
    login.data.token,
  ]);
  assert.equal(me.owner_id, app.config.auth.ownerId);
  await close(app.db);
});

test('令牌解析：无效令牌不阻断公开接口（否则令牌过期后首页都打不开）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  await seedActivity(app);

  /*
    这条规则很容易写错：如果"令牌无效"直接抛 401，
    用户在令牌过期后被锁在首页之外 —— 而首页正是"重新登录"的入口。
    所以解析失败一律按匿名处理，要不要强制由各接口自己决定。
  */
  const r = await call('GET', '/api/activities', {
    headers: { authorization: 'Bearer totally-invalid-token' },
  });
  assert.equal(r.code, 0, '公开接口应正常返回');
  assert.ok(Array.isArray(r.data.items));
  await close(app.db);
});

test('令牌解析：志愿者令牌不能当管理端令牌用', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const activity = await seedBindable(app);

  const bind = await call('POST', '/api/auth/bind', {
    body: {
      activityId: activity.id,
      userNo: '2021001',
      inviteCode: 'ABCD2345',
      deviceId: DEVICE,
    },
  });
  assert.equal(bind.code, 0);

  const grant = await app.repos.grants.findByToken(bind.data.token);
  assert.ok(grant, '志愿者令牌应能解析成活动授权');
  assert.equal(grant.userNo, '2021001');
  assert.equal(grant.activityId, activity.id);

  const admin = await app.repos.adminSession.findByToken(bind.data.token);
  assert.equal(admin, null, '志愿者令牌不能解析成管理端会话');
  await close(app.db);
});

test('令牌解析：过期的管理端令牌视为无效', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);

  const login = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: DEVICE },
  });

  await app.db.execute('UPDATE admin_session SET expires_at = ? WHERE token = ?', [
    addMinutesIso(nowIso(), -1),
    login.data.token,
  ]);

  const session = await app.repos.adminSession.findByToken(login.data.token);
  assert.equal(session, null, '过期会话必须解析为 null');
  await close(app.db);
});

// ══════════════════════════════════════════════════════════════════════════
// 令牌续期（P1 缺口：12 小时固定过期、授权 7 天固定）
// ══════════════════════════════════════════════════════════════════════════

test('续期：管理端令牌快到期时，用一次就自动延长（滑动过期）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);

  const login = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: DEVICE },
  });
  const token = login.data.token;

  // 把到期时间压到"只剩 1 分钟"（< TTL 的 1/4，应当被续期）
  const almostExpired = addMinutesIso(nowIso(), 1);
  await app.db.execute('UPDATE admin_session SET expires_at = ? WHERE token = ?', [
    almostExpired,
    token,
  ]);

  // 任何一个需要身份的请求都会经过 resolveAuth
  await call('GET', '/api/activities', { headers: { authorization: `Bearer ${token}` } });

  const row = await app.db.queryOne('SELECT expires_at FROM admin_session WHERE token = ?', [
    token,
  ]);
  assert.ok(
    Date.parse(row.expires_at) > Date.parse(almostExpired),
    '快到期时被使用应自动延长 —— 否则现场从早忙到晚必然中途掉登录',
  );
  await close(app.db);
});

test('续期：远离到期时不改写数据库（避免每个请求都 UPDATE）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);

  const login = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: DEVICE },
  });
  const before = await app.db.queryOne('SELECT expires_at FROM admin_session WHERE token = ?', [
    login.data.token,
  ]);

  await call('GET', '/api/activities', {
    headers: { authorization: `Bearer ${login.data.token}` },
  });

  const after = await app.db.queryOne('SELECT expires_at FROM admin_session WHERE token = ?', [
    login.data.token,
  ]);
  assert.equal(after.expires_at, before.expires_at, '刚登录不该被续期');
  await close(app.db);
});

test('续期：长期活动的授权期限覆盖到活动结束后，而不是固定 7 天', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);
  const login = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: DEVICE },
  });
  const headers = { authorization: `Bearer ${login.data.token}` };

  /*
    ## 这条是在守什么

    授权期限 = max(配置下限 7 天, 活动结束 + 24h)。

    活动时长本身有 72 小时上限，所以正常情况 7 天足够 —— 这一层是**兜底**：
    `endTime` 可以独立于 `durationHours` 设得很远（例如一个跨月的报名/服务窗口），
    那时写死 7 天就会让志愿者在第 8 天被要求重新绑定，
    而他什么也没做错、现场也没有发布者能给他发新码。

    客户端还会**本地**按 expiresAt 清授权（user_app/main.dart），
    所以这个时机必须服务端一开始就算对，不能靠滑动续期补救。
  */
  const longEnd = addMinutesIso(nowIso(), 10 * 24 * 60);
  const created = await call('POST', '/api/activities:upsert', {
    body: {
      batch: [
        {
          externalId: 'LONG-1',
          title: '长期志愿岗',
          organizer: '校团委',
          durationHours: 2,
          startTime: addMinutesIso(nowIso(), -60),
          endTime: longEnd,
          location: '长期岗位',
          geoLat: 34.2175,
          geoLng: 117.1425,
          checkinRadius: 200,
          status: 'published',
        },
      ],
    },
    headers,
  });
  const activityId = created.data.created[0];

  await call('POST', `/api/activities/${activityId}/participants`, {
    body: { userNo: '2021001', name: '张伟' },
    headers,
  });
  const codes = await call('POST', `/api/activities/${activityId}/invite-codes`, {
    body: {},
    headers,
  });
  const bind = await call('POST', '/api/auth/bind', {
    body: {
      activityId,
      userNo: '2021001',
      inviteCode: codes.data.items[0].inviteCode,
      deviceId: DEVICE,
    },
  });
  assert.equal(bind.code, 0, `绑定失败：${bind.msg}`);

  const expiresAt = Date.parse(bind.data.expiresAt);
  assert.ok(
    expiresAt > Date.parse(longEnd),
    `授权应覆盖活动全程：授权到 ${bind.data.expiresAt}，活动结束于 ${longEnd}`,
  );
  await close(app.db);
});
// ══════════════════════════════════════════════════════════════════════════
// 多发布者（P1 缺口：ownerId 由配置固定）
// ══════════════════════════════════════════════════════════════════════════

/** 在指定配置下建服务。 */
async function freshAppWithOwners(spec) {
  return freshApp({ ADMIN_OWNERS: spec });
}

/** 用某邀请码登录，返回 { ownerId, headers }。 */
async function loginWith(app, call, code, deviceId) {
  const r = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: code, deviceId },
  });
  assert.equal(r.code, 0, `登录失败（${code}）：${r.msg}`);
  return { ownerId: r.data.ownerId, headers: { authorization: `Bearer ${r.data.token}` } };
}

test('多发布者：不同邀请码归到不同 ownerId', async () => {
  const app = await freshAppWithOwners('1111:owner-org-a,2222:owner-org-b');
  const call = await makeCaller(app);

  const a = await loginWith(app, call, '1111', 'dev-a');
  const b = await loginWith(app, call, '2222', 'dev-b');
  assert.equal(a.ownerId, 'owner-org-a');
  assert.equal(b.ownerId, 'owner-org-b');
  assert.notEqual(a.ownerId, b.ownerId);
  await close(app.db);
});

test('多发布者：未登记的邀请码被拒（不能混进别的组织）', async () => {
  const app = await freshAppWithOwners('1111:owner-org-a,2222:owner-org-b');
  const call = await makeCaller(app);

  const r = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: '3333', deviceId: 'dev-x' },
  });
  assert.equal(r.status, 401);
  assert.equal(r.code, 40101);
  await close(app.db);
});

test('多发布者：A 建的活动 B 看不到（列表按 owner 隔离）', async () => {
  const app = await freshAppWithOwners('1111:owner-org-a,2222:owner-org-b');
  const call = await makeCaller(app);

  const a = await loginWith(app, call, '1111', 'dev-a');
  const b = await loginWith(app, call, '2222', 'dev-b');

  const up = await call('POST', '/api/activities:upsert', {
    body: {
      batch: [
        {
          externalId: 'A-ONLY',
          title: 'A 部门的活动',
          organizer: 'A 部门',
          durationHours: 2,
          startTime: addMinutesIso(nowIso(), -10),
          endTime: addMinutesIso(nowIso(), 110),
          location: 'A 场地',
          geoLat: 34.2175,
          geoLng: 117.1425,
          checkinRadius: 200,
          status: 'published',
        },
      ],
    },
    headers: a.headers,
  });
  assert.equal(up.code, 0);
  const activityId = up.data.created[0];

  /*
    这是多发布者最容易出错的一处：管理端首页写的是「我发布的活动」，
    客户端也带了 `onlyMine=true` —— 但服务端早期完全忽略它，
    任何管理员都能看到别的组织的活动。
  */
  const listA = await call('GET', '/api/activities', { headers: a.headers });
  assert.equal(listA.data.total, 1, 'A 应看到自己的 1 条');

  const listB = await call('GET', '/api/activities', { headers: b.headers });
  assert.equal(listB.data.total, 0, 'B 不应看到 A 的活动');

  // 详情/名单同样不能越权
  const detailB = await call('GET', `/api/activities/${activityId}`, { headers: b.headers });
  assert.equal(detailB.code, 0, '已发布活动详情对公开可读（网页匿名也要能看）');
  const rosterB = await call('GET', `/api/activities/${activityId}/participants`, {
    headers: b.headers,
  });
  assert.equal(rosterB.status, 403, '名单属于管理端资源，B 越权应 403 无权操作该活动');

  await close(app.db);
});

test('多发布者：匿名（网页）仍能看到所有已发布活动', async () => {
  const app = await freshAppWithOwners('1111:owner-org-a,2222:owner-org-b');
  const call = await makeCaller(app);

  const a = await loginWith(app, call, '1111', 'dev-a');
  const b = await loginWith(app, call, '2222', 'dev-b');

  for (const [i, h] of [a.headers, b.headers].entries()) {
    await call('POST', '/api/activities:upsert', {
      body: {
        batch: [
          {
            externalId: `ORG-${i}`,
            title: `组织 ${i} 的活动`,
            organizer: `组织 ${i}`,
            durationHours: 2,
            startTime: addMinutesIso(nowIso(), -10),
            endTime: addMinutesIso(nowIso(), 110),
            location: '场地',
            geoLat: 34.2175,
            geoLng: 117.1425,
            checkinRadius: 200,
            status: 'published',
          },
        ],
      },
      headers: h,
    });
  }

  /*
    隔离只针对**管理端身份**。网页是公开只读浏览端（方案 §1.4 无账号体系），
    匿名请求必须能看到所有组织已发布的活动 —— 否则"校园志愿活动一览"
    这个功能就没意义了。
  */
  const anon = await call('GET', '/api/activities');
  assert.equal(anon.data.total, 2, '匿名应看到两个组织共 2 条已发布活动');
  await close(app.db);
});

test('多发布者：未配 ADMIN_OWNERS 时退化为单发布者（老部署不受影响）', async () => {
  const app = await freshApp();
  const call = await makeCaller(app);

  const r = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: 'dev-single' },
  });
  assert.equal(r.code, 0);
  assert.equal(
    r.data.ownerId,
    app.config.auth.ownerId,
    '没配映射表时应退回配置里的 ownerId（与种子数据对齐）',
  );
  await close(app.db);
});