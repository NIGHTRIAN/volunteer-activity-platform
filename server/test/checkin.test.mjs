/**
 * 签到判定与在岗抽查测试。
 *
 * ## 为什么判定要单独测（而不只是走接口）
 *
 * `scoring.js` 是从 mock_server 移植过来的，而 mock 的判定在真机测试期间
 * 反复修正过三次（模拟定位误杀、精度门槛、围栏宽容带）。移植时任何一处
 * 数字抄错，表现都是"同样的情况，结论变了"，而接口层测试很难覆盖所有组合。
 *
 * 所以这里**直接测纯函数**，再用接口端到端确认它被正确接上。
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';

import { loadConfig } from '../src/config.js';
import { close } from '../src/db/index.js';
import { createServer } from '../src/server.js';
import { scoreCheckin, detectMockLocation, checkGate } from '../src/scoring.js';
import { DEFAULTS, CHECKIN_STATUS } from '../src/contract.js';
import { nowIso, addMinutesIso } from '../src/util/time.js';

// ─────────────────────────────────────────────────────────────────────────
// 辅助
// ─────────────────────────────────────────────────────────────────────────

const ACTIVITY = {
  externalId: 'CHK-1',
  title: '判定测试活动',
  geoLat: 34.2175,
  geoLng: 117.1425,
  checkinRadius: 200,
  startTime: addMinutesIso(nowIso(), -5),
  endTime: addMinutesIso(nowIso(), 90),
  checkinWindowBefore: 30,
  checkinWindowAfter: 60,
  attendanceFirstDelay: 15,
  attendanceInterval: 30,
  attendanceResponseWindow: 5,
  wifiBssids: '["aa:bb:cc:dd:ee:ff"]',
  campusIpPrefixes: '["10.3."]',
};

/** 一个在围栏中心、精度良好的提交。 */
function goodSubmission(overrides = {}) {
  return {
    geoLat: 34.2175,
    geoLng: 117.1425,
    accuracy: 20,
    samples: [
      { lat: 34.217501, lng: 117.142501, accuracy: 20 },
      { lat: 34.217502, lng: 117.142502, accuracy: 22 },
      { lat: 34.217503, lng: 117.142503, accuracy: 21 },
    ],
    wifiBssids: [],
    sourceIp: null,
    mockLocationDetected: false,
    ...overrides,
  };
}

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

/**
 * 造一个"已绑定"的完整场景，返回志愿者调用器与关键 id。
 *
 * 走的是真实接口（登录→建活动→加人→发码→绑定），
 * 而不是直接塞库 —— 这样测试才覆盖真实接线。
 */
async function boundScenario(app, opts = {}) {
  const call = await makeCaller(app);
  const admin = await call('POST', '/api/auth/admin/login', {
    body: { inviteCode: app.config.auth.adminInviteCode, deviceId: 'admin-t' },
  });
  const ah = { authorization: `Bearer ${admin.data.token}` };

  const created = await call('POST', '/api/activities:upsert', {
    body: {
      batch: [
        {
          externalId: 'CHK-E2E',
          title: '签到端到端活动',
          organizer: '校团委',
          durationHours: 2,
          startTime: addMinutesIso(nowIso(), -5),
          endTime: addMinutesIso(nowIso(), 90),
          location: '南湖校区图书馆',
          geoLat: 34.2175,
          geoLng: 117.1425,
          checkinRadius: 200,
          status: 'published',
          campusIpPrefixes: opts.campusIpPrefixes ?? ['10.3.'],
          ...(opts.attendanceMode ? { attendanceMode: opts.attendanceMode } : {}),
        },
      ],
    },
    headers: ah,
  });
  assert.equal(created.code, 0, `建活动失败：${created.msg}`);
  const activityId = created.data.created[0];

  await call('POST', `/api/activities/${activityId}/participants`, {
    body: { userNo: '2021001', name: '张伟', phone: '13800000001' },
    headers: ah,
  });
  const codes = await call('POST', `/api/activities/${activityId}/invite-codes`, {
    body: {},
    headers: ah,
  });
  const bind = await call('POST', '/api/auth/bind', {
    body: {
      activityId,
      userNo: '2021001',
      inviteCode: codes.data.items[0].inviteCode,
      deviceId: 'vol-t',
    },
  });
  assert.equal(bind.code, 0, `绑定失败：${bind.msg}`);

  return {
    call,
    adminHeaders: ah,
    activityId,
    volunteerHeaders: { authorization: `Bearer ${bind.data.token}` },
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 纯函数：评分
// ─────────────────────────────────────────────────────────────────────────

test('评分：围栏内 40 + 采样一致 10 = 50 → 待人工确认', () => {
  const r = scoreCheckin({ activity: ACTIVITY, submission: goodSubmission() });
  assert.equal(r.score, 50);
  assert.equal(r.status, CHECKIN_STATUS.PENDING_REVIEW);
  assert.match(r.reason, /50/);
});

test('评分：再加校园网命中 10 → 60 自动通过（O-17 的价值）', () => {
  const r = scoreCheckin({
    activity: ACTIVITY,
    submission: goodSubmission(),
    context: { campusIpMatched: true },
  });
  assert.equal(r.score, 60);
  assert.equal(
    r.status,
    CHECKIN_STATUS.SUCCESS,
    '配了白名单且命中才可能自动通过 —— 这是 O-17 的意义',
  );
});

test('评分：Wi-Fi 命中 20 分，单独就足以越过门槛', () => {
  const r = scoreCheckin({
    activity: ACTIVITY,
    submission: goodSubmission(),
    context: { wifiMatched: true },
  });
  assert.equal(r.score, 70);
  assert.equal(r.status, CHECKIN_STATUS.SUCCESS);
});

test('评分：精度 >100m 不计分（而不是直接驳回）', () => {
  const r = scoreCheckin({
    activity: ACTIVITY,
    submission: goodSubmission({ accuracy: 350 }),
  });
  // 只有采样一致 10 分，落在 30 以下 → 驳回；但**不是**因为精度被判伪造
  assert.equal(r.score, 10);
  assert.match(r.items.map((i) => i.reason).join('|'), /超过 100m 门槛/);
});

test('评分：围栏外 1.5 倍半径之内给 0 分', () => {
  // 200m 半径，往北约 250m
  const r = scoreCheckin({
    activity: ACTIVITY,
    submission: goodSubmission({ geoLat: 34.2197, geoLng: 117.1425, samples: [] }),
  });
  assert.equal(r.score, 0);
  assert.match(r.items.map((i) => i.reason).join('|'), /紧邻围栏外/);
});

test('评分：围栏外超过 1.5 倍半径 → 驳回并说明原因', () => {
  // 往北约 600m
  const r = scoreCheckin({
    activity: ACTIVITY,
    submission: goodSubmission({ geoLat: 34.2229, geoLng: 117.1425, samples: [] }),
  });
  assert.equal(r.status, CHECKIN_STATUS.REJECTED);
  assert.match(r.reason, /证据不足/);
  assert.match(r.items.map((i) => i.reason).join('|'), /超出活动签到范围/);
});

test('评分：无坐标转人工而不是驳回（设备故障不该让人失去申诉）', () => {
  const r = scoreCheckin({
    activity: ACTIVITY,
    submission: { geoLat: null, geoLng: null, accuracy: null, samples: [] },
  });
  assert.equal(r.status, CHECKIN_STATUS.PENDING_REVIEW);
  assert.match(r.reason, /未收到有效定位坐标/);
});

test('评分：模拟定位一票否决 —— 即使分数很高也转人工', () => {
  const r = scoreCheckin({
    activity: ACTIVITY,
    submission: goodSubmission({ mockLocationDetected: true }),
    context: { wifiMatched: true, campusIpMatched: true },
  });
  assert.ok(r.score < 60, '扣分项已把总分拉下来');
  assert.equal(r.status, CHECKIN_STATUS.PENDING_REVIEW, '但必须转人工（一票否决）');
  assert.match(JSON.stringify(r.items), /模拟位置|模拟定位/, '评分明细要能解释为什么被拦');
  assert.match(r.reason, /模拟定位/);
});

// ─────────────────────────────────────────────────────────────────────────
// 纯函数：模拟定位判定（真机修正过的口径）
// ─────────────────────────────────────────────────────────────────────────

test('模拟定位：坐标与精度都完全一致且精度 ≤5m 才判伪造', () => {
  const samples = [
    { lat: 34.1, lng: 117.1, accuracy: 3 },
    { lat: 34.1, lng: 117.1, accuracy: 3 },
  ];
  assert.equal(detectMockLocation({ samples }).detected, true);
});

test('模拟定位：静止用户采样一致但精度正常 → **不能**判伪造', () => {
  /*
    真机测试修正过：早期只要"多次采样完全一致"就判伪造，
    误杀了在室内静止的真实用户（GPS 抖动小本来正常）。
  */
  const samples = [
    { lat: 34.1, lng: 117.1, accuracy: 30 },
    { lat: 34.1, lng: 117.1, accuracy: 30 },
  ];
  assert.equal(detectMockLocation({ samples }).detected, false);
});

test('模拟定位：采样不一致 → 不判伪造', () => {
  const samples = [
    { lat: 34.1, lng: 117.1, accuracy: 3 },
    { lat: 34.1001, lng: 117.1001, accuracy: 3 },
  ];
  assert.equal(detectMockLocation({ samples }).detected, false);
});

test('模拟定位：客户端明确标记 → 直接判伪造', () => {
  assert.equal(detectMockLocation({ clientFlagged: true, samples: [] }).detected, true);
});

// ─────────────────────────────────────────────────────────────────────────
// 纯函数：门槛
// ─────────────────────────────────────────────────────────────────────────

test('门槛：签到窗口外被拒（开始前 30 分钟到结束后 60 分钟）', () => {
  const early = checkGate({
    activity: ACTIVITY,
    participant: { removedAt: null },
    now: new Date(Date.parse(ACTIVITY.startTime) - 60 * 60_000),
  });
  assert.equal(early.ok, false);
  assert.equal(early.code, 'OUTSIDE_CHECKIN_WINDOW');

  const inside = checkGate({
    activity: ACTIVITY,
    participant: { removedAt: null },
    now: new Date(),
  });
  assert.equal(inside.ok, true);
});

test('门槛：已签到 / 不在名单被拒', () => {
  assert.equal(
    checkGate({ activity: ACTIVITY, participant: {}, now: new Date(), existingCheckin: { id: 1 } }).code,
    'ALREADY_CHECKED_IN',
  );
  assert.equal(
    checkGate({ activity: ACTIVITY, participant: null, now: new Date() }).code,
    'NOT_IN_PARTICIPANT_LIST',
  );
});

// ─────────────────────────────────────────────────────────────────────────
// 接口：端到端
// ─────────────────────────────────────────────────────────────────────────

test('接口：签到 → 待确认 → 管理端复核通过 → 看板已签到 1', async () => {
  const app = await freshApp();
  const s = await boundScenario(app);

  const body = {
    location: {
      lat: 34.2175,
      lng: 117.1425,
      accuracy: 20,
      samples: [
        { geoLat: 34.21751, geoLng: 117.14251, accuracy: 20 },
        { geoLat: 34.21752, geoLng: 117.14252, accuracy: 21 },
      ],
    },
    network: { sourceIp: '192.168.1.9' }, // 校外网络 → 不命中白名单
    device: { deviceId: 'vol-t', mockLocationDetected: false },
    clientTime: nowIso(),
  };
  const ck = await s.call('POST', `/api/activities/${s.activityId}/checkins`, {
    body,
    headers: s.volunteerHeaders,
  });
  assert.equal(ck.code, 0, `签到失败：${ck.msg}`);
  assert.equal(ck.data.checkin.score, 50);
  assert.equal(ck.data.checkin.status, 'pending_review');

  const review = await s.call(
    'POST',
    `/api/checkins/${ck.data.checkin.id}/review`,
    { body: { decision: 'approve', note: '现场核对无误' }, headers: s.adminHeaders },
  );
  assert.equal(review.code, 0, `复核失败：${review.msg}`);
  assert.equal(review.data.checkin.status, 'success');

  const board = await s.call('GET', `/api/activities/${s.activityId}/board`, {
    headers: s.adminHeaders,
  });
  assert.equal(board.code, 0);
  assert.equal(board.data.checkedIn, 1);
  assert.equal(board.data.pendingReview, 0);
  await close(app.db);
});

test('接口：命中校园网 → 60 分自动通过（不需要人工复核）', async () => {
  const app = await freshApp();
  const s = await boundScenario(app);

  const ck = await s.call('POST', `/api/activities/${s.activityId}/checkins`, {
    body: {
      location: {
        lat: 34.2175,
        lng: 117.1425,
        accuracy: 20,
        samples: [
          { geoLat: 34.21751, geoLng: 117.14251, accuracy: 20 },
          { geoLat: 34.21752, geoLng: 117.14252, accuracy: 21 },
        ],
      },
      network: { sourceIp: '10.3.229.13' }, // 命中 10.3. 白名单
      device: { deviceId: 'vol-t' },
      clientTime: nowIso(),
    },
    headers: s.volunteerHeaders,
  });
  assert.equal(ck.code, 0, `签到失败：${ck.msg}`);
  assert.equal(ck.data.checkin.score, 60);
  assert.equal(ck.data.checkin.status, 'success');
  assert.equal(ck.data.checkin.campusIpMatched, true);
  await close(app.db);
});

test('接口：离线补传即使满分也转人工', async () => {
  const app = await freshApp();
  const s = await boundScenario(app);

  const ck = await s.call('POST', `/api/activities/${s.activityId}/checkins`, {
    body: {
      location: {
        lat: 34.2175,
        lng: 117.1425,
        accuracy: 10,
        samples: [
          { geoLat: 34.21751, geoLng: 117.14251, accuracy: 10 },
          { geoLat: 34.21752, geoLng: 117.14252, accuracy: 11 },
        ],
      },
      network: { sourceIp: '10.3.1.1', wifiBssids: [] },
      device: { deviceId: 'vol-t' },
      offlineBackfill: true,
      clientTime: nowIso(),
    },
    headers: s.volunteerHeaders,
  });
  assert.equal(ck.code, 0, `签到失败：${ck.msg}`);
  assert.ok(ck.data.checkin.score >= 60);
  assert.equal(ck.data.checkin.status, 'pending_review', '补传不能自动通过');
  assert.match(ck.data.checkin.reason, /离线补传/);
  await close(app.db);
});

test('接口：重复签到幂等，不产生第二条记录', async () => {
  const app = await freshApp();
  const s = await boundScenario(app);

  const body = {
    location: { lat: 34.2175, lng: 117.1425, accuracy: 20, samples: [] },
    device: { deviceId: 'vol-t' },
    clientTime: nowIso(),
  };
  const first = await s.call('POST', `/api/activities/${s.activityId}/checkins`, {
    body,
    headers: s.volunteerHeaders,
  });
  const second = await s.call('POST', `/api/activities/${s.activityId}/checkins`, {
    body,
    headers: s.volunteerHeaders,
  });
  assert.equal(second.code, 0);
  assert.equal(second.data.alreadySubmitted, true);
  assert.equal(second.data.checkin.id, first.data.checkin.id);

  const rows = await app.db.query('SELECT id FROM checkin WHERE activity_id = ?', [s.activityId]);
  assert.equal(rows.length, 1);
  await close(app.db);
});

test('接口：签到受理后生成在岗抽查，未到点不能确认', async () => {
  const app = await freshApp();
  const s = await boundScenario(app);

  await s.call('POST', `/api/activities/${s.activityId}/checkins`, {
    body: {
      location: { lat: 34.2175, lng: 117.1425, accuracy: 20, samples: [] },
      device: { deviceId: 'vol-t' },
      clientTime: nowIso(),
    },
    headers: s.volunteerHeaders,
  });

  const tasks = await s.call('GET', `/api/activities/${s.activityId}/attendance/tasks`, {
    headers: s.volunteerHeaders,
  });
  assert.equal(tasks.code, 0, `取在岗任务失败：${tasks.msg}`);
  assert.ok(tasks.data.items.length > 0, '签到受理后必须生成抽查任务');

  const first = tasks.data.items[0];
  const scheduled = Date.parse(first.scheduledAt);
  assert.ok(scheduled > Date.now(), '活动刚开始，第一次抽查应在未来');

  const confirm = await s.call('POST', `/api/attendances/${first.id}:confirm`, {
    body: { location: { lat: 34.2175, lng: 117.1425, accuracy: 20 } },
    headers: s.volunteerHeaders,
  });
  assert.equal(confirm.code, 40901);
  assert.match(confirm.msg, /尚未开始/, '未到点不能提前点掉（真机踩过的漏洞）');
  await close(app.db);
});

test('接口：别人的在岗任务不能确认', async () => {
  const app = await freshApp();
  const s = await boundScenario(app);

  await s.call('POST', `/api/activities/${s.activityId}/checkins`, {
    body: {
      location: { lat: 34.2175, lng: 117.1425, accuracy: 20, samples: [] },
      device: { deviceId: 'vol-t' },
      clientTime: nowIso(),
    },
    headers: s.volunteerHeaders,
  });
  const tasks = await s.call('GET', `/api/activities/${s.activityId}/attendance/tasks`, {
    headers: s.volunteerHeaders,
  });
  const taskId = tasks.data.items[0].id;

  // 造第二个志愿者（另一个人），去确认张伟的任务
  await s.call('POST', `/api/activities/${s.activityId}/participants`, {
    body: { userNo: '2021002', name: '李娜' },
    headers: s.adminHeaders,
  });
  const codes = await s.call('POST', `/api/activities/${s.activityId}/invite-codes`, {
    body: {},
    headers: s.adminHeaders,
  });
  const liCode = codes.data.items.find((i) => i.userNo === '2021002').inviteCode;
  const bind2 = await s.call('POST', '/api/auth/bind', {
    body: {
      activityId: s.activityId,
      userNo: '2021002',
      inviteCode: liCode,
      deviceId: 'vol-2',
    },
  });
  assert.equal(bind2.code, 0, `第二个志愿者绑定失败：${bind2.msg}`);

  const confirm = await s.call('POST', `/api/attendances/${taskId}:confirm`, {
    body: { location: { lat: 34.2175, lng: 117.1425, accuracy: 20 } },
    headers: { authorization: `Bearer ${bind2.data.token}` },
  });
  assert.equal(confirm.status, 403, '不能确认别人的在岗任务');
  await close(app.db);
});

test('接口：志愿者不能看别人的签到记录（管理端接口）', async () => {
  const app = await freshApp();
  const s = await boundScenario(app);

  const r = await s.call('GET', `/api/activities/${s.activityId}/checkins`, {
    headers: s.volunteerHeaders,
  });
  // 志愿者令牌不是一个有效的**管理端**令牌，所以是 40101/401；
  assert.equal(r.status, 401, '签到记录列表是管理端接口，志愿者令牌不能通过');
  await close(app.db);
});

// ─────────────────────────────────────────────────────────────────────────
// 在岗抽查：自动 / 手动 / 终态豁免
// ─────────────────────────────────────────────────────────────────────────

/**
 * 这三组测试对应两类真机反馈：
 *
 *  1. **活动取消后用户端还在显示抽查、还在催确认** —— 因为"待响应"的任务
 *     从来没有任何代码把它置为 `excused`，过了截止时间还会被结算成缺席。
 *  2. **抽查只有自动一种** —— 短活动里自动发 3–4 次太吵，发布者只想点个名。
 */

test('自动抽查：签到后按间隔生成任务', async () => {
  const app = await freshApp();
  const s = await boundScenario(app);

  const ck = await s.call('POST', `/api/activities/${s.activityId}/checkins`, {
    body: goodSubmission(),
    headers: s.volunteerHeaders,
  });
  assert.equal(ck.code, 0, ck.msg);

  const tasks = await s.call('GET', `/api/activities/${s.activityId}/attendance/tasks`, {
    headers: s.volunteerHeaders,
  });
  assert.ok(
    tasks.data.items.length > 0,
    `自动模式应生成抽查任务：${JSON.stringify(tasks.data)}`,
  );

  await close(app.db);
});

test('手动抽查：签到后不自动生成任务，发布者点一下才发', async () => {
  const app = await freshApp();
  const s = await boundScenario(app, { attendanceMode: 'manual' });

  const ck = await s.call('POST', `/api/activities/${s.activityId}/checkins`, {
    body: goodSubmission(),
    headers: s.volunteerHeaders,
  });
  assert.equal(ck.code, 0, ck.msg);

  const before = await s.call('GET', `/api/activities/${s.activityId}/attendance/tasks`, {
    headers: s.volunteerHeaders,
  });
  assert.equal(
    before.data.items.length,
    0,
    '手动模式下不应该自动生成任何抽查',
  );

  // 发布者手动发起一次
  const created = await s.call('POST', `/api/activities/${s.activityId}/attendance/manual`, {
    body: {},
    headers: s.adminHeaders,
  });
  assert.equal(created.code, 0, created.msg);
  assert.equal(created.data.total, 1, '应为已签到的 1 个人生成抽查');
  assert.equal(created.data.created[0].userNo, '2021001');

  const after = await s.call('GET', `/api/activities/${s.activityId}/attendance/tasks`, {
    headers: s.volunteerHeaders,
  });
  assert.equal(after.data.items.length, 1);
  assert.equal(after.data.items[0].status, 'pending');

  // 再点一次：不能给同一个人叠出两条待响应
  const again = await s.call('POST', `/api/activities/${s.activityId}/attendance/manual`, {
    body: {},
    headers: s.adminHeaders,
  });
  assert.equal(again.data.total, 0);
  assert.equal(again.data.skipped.length, 1);

  await close(app.db);
});

test('手动抽查：进度已签到时默认不抽查任何人（不制造无意义的待响应）', async () => {
  const app = await freshApp();
  const s = await boundScenario(app, { attendanceMode: 'manual' });

  // 还没有人签到
  const r = await s.call('POST', `/api/activities/${s.activityId}/attendance/manual`, {
    body: {},
    headers: s.adminHeaders,
  });
  assert.equal(r.code, 0);
  assert.equal(r.data.total, 0);

  await close(app.db);
});

test('取消活动：待响应的抽查一律置为「已豁免」，不再是待确认/缺席', async () => {
  const app = await freshApp();
  const s = await boundScenario(app);

  const ck = await s.call('POST', `/api/activities/${s.activityId}/checkins`, {
    body: goodSubmission(),
    headers: s.volunteerHeaders,
  });
  assert.equal(ck.code, 0, ck.msg);

  const before = await s.call('GET', `/api/activities/${s.activityId}/attendance/tasks`, {
    headers: s.volunteerHeaders,
  });
  assert.ok(before.data.items.length > 0);
  assert.ok(
    before.data.items.every((t) => t.status === 'pending'),
    '此时应全部待响应',
  );

  const cancelled = await s.call('POST', `/api/activities/${s.activityId}:transition`, {
    body: { to: 'cancelled', reason: '当日持续降雨，场地湿滑，协商取消' },
    headers: s.adminHeaders,
  });
  assert.equal(cancelled.code, 0, cancelled.msg);

  const after = await s.call('GET', `/api/activities/${s.activityId}/attendance/tasks`, {
    headers: s.volunteerHeaders,
  });
  assert.ok(after.data.items.length > 0);
  for (const t of after.data.items) {
    assert.equal(
      t.status,
      'excused',
      `活动取消后抽查应已豁免，实际是 ${t.status}`,
    );
    assert.ok(t.excusedAt, '应记录豁免时间');
  }

  await close(app.db);
});

test('结束活动：还没响应的抽查也豁免（活动都结束了，再记缺席不公平）', async () => {
  const app = await freshApp();
  const s = await boundScenario(app);

  await s.call('POST', `/api/activities/${s.activityId}/checkins`, {
    body: goodSubmission(),
    headers: s.volunteerHeaders,
  });
  // published → ongoing → finished（状态机不允许 published 直接到 finished）
  const toOngoing = await s.call('POST', `/api/activities/${s.activityId}:transition`, {
    body: { from: 'published', to: 'ongoing' },
    headers: s.adminHeaders,
  });
  assert.equal(toOngoing.code, 0, toOngoing.msg);
  const toFinished = await s.call('POST', `/api/activities/${s.activityId}:transition`, {
    body: { from: 'ongoing', to: 'finished' },
    headers: s.adminHeaders,
  });
  assert.equal(toFinished.code, 0, toFinished.msg);

  const after = await s.call('GET', `/api/activities/${s.activityId}/attendance/tasks`, {
    headers: s.volunteerHeaders,
  });
  for (const t of after.data.items) {
    assert.equal(t.status, 'excused', `结束后未响应应豁免，实际 ${t.status}`);
  }

  await close(app.db);
});