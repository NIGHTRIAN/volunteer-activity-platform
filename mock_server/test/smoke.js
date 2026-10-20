/**
 * Mock 服务端冒烟测试。
 *
 * 直接调用 handler 层（不启 HTTP 端口），因此跑得快、无端口冲突，
 * 适合作为每次改动的回归。覆盖《移动端应用开发方案》§12 验收用例中
 * **服务端可验证**的部分。
 *
 * 运行：node test/smoke.js
 *
 * 设计原则：**每个用例自带夹具并自行清理**。
 * 早期版本让用例共用种子里那个「进行中」的活动，结果一个用例失败就会
 * 把状态留给下一个，产生一串看不出真实原因的错误。现在凡是要改数据的
 * 用例都调 `makeFixture()` 造一个独立活动，跑完 `cleanup()`。
 */

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

// 用独立的临时数据目录，避免污染开发者的调试数据。
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'vol-mock-test-'));
process.env.MOCK_DATA_DIR = TMP;

const { store, iso, addMinutes, findParticipant, nextSeq } = await import('../src/store.js');
const { seedIfEmpty } = await import('../src/seed.js');
const api = await import('../src/api.js');
const { codeForSeed } = await import('../src/seed_codes.js');
const { scoreCheckin, distanceMeters } = await import('../src/scoring.js');
const { ERR, CATALOG, CHECKIN_STATUS, CHECKIN_METHOD, TASK_STATUS, DEFAULTS } = await import(
  '../src/constants.js'
);
const { regenerateAttendanceTasks, planSlots } = await import('../src/attendance_engine.js');

store.load();
seedIfEmpty();

let passed = 0;
let failed = 0;
const failures = [];

function test(name, fn) {
  try {
    fn();
    passed += 1;
    console.log(`  ✓ ${name}`);
  } catch (err) {
    failed += 1;
    // 打印完整信息：只印 message 会让 "Cannot read properties of undefined"
    // 这类错误失去定位价值。
    const detail = [err.message, err.stack ? `        ${err.stack.split('\n')[1]?.trim()}` : '']
      .filter(Boolean)
      .join('\n');
    failures.push({ name, message: detail });
    console.log(`  ✗ ${name}\n      ${detail}`);
  }
}

function section(title) {
  console.log(`\n${title}`);
}

/** 构造 handler 上下文。 */
function ctx(
  {
    params = {},
    query = {},
    body = {},
    headers = {},
    auth = null,
    ip = '127.0.0.1',
    res = null,
  } = {},
) {
  return {
    req: {},
    // 默认给一个不落地的桩；文件下载类用例需要自己传 res 来捕获输出。
    res: res ?? { writeHead() {}, end() {} },
    params,
    query,
    body,
    headers,
    auth,
    ip,
    traceId: 'test',
  };
}

const OWNER = 'owner-demo-0001';
const DEMO_DEVICE = 'demo-admin-device';

/** 种子里的进行中活动，用于只读断言。 */
const ongoing = store.db.activities.find((a) => a.status === 'ongoing');
const finished = store.db.activities.find((a) => a.status === 'finished');
const base = { lat: ongoing.geoLat, lng: ongoing.geoLng };

const M_PER_DEG_LAT = 111320;

/** 在围栏中心的某个方位偏移若干米。 */
function offsetMeters(lat, lng, dn, de) {
  return {
    lat: lat + dn / M_PER_DEG_LAT,
    lng: lng + de / (M_PER_DEG_LAT * Math.cos((lat * Math.PI) / 180)),
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 夹具
// ─────────────────────────────────────────────────────────────────────────

let fixtureSeq = 0;

/**
 * 造一个「当前时刻正处于签到窗口内」的独立活动。
 *
 * 关键点：抽查任务的计划时刻**也落在合法响应窗口内**，这样「点一下就完成」
 * 的场景可以直接测，不需要每条用例都手工改 deadline。
 */
function makeFixture({
  participants = ['u001', 'u002', 'u003'],
  phones = [],
  status = 'ongoing',
  // 3 小时、30 分钟前开始：此刻处于签到窗口内，且按默认抽查参数会生成
  // T+15/T+45/T+75/T+105 四个时段，其中 seq=2（T+45）的计划时刻
  // 正好落在「现在」附近，可以在岗场景直接响应。
  durationMinutes = 180,
  startOffsetMinutes = -30,
  activeTaskSeq = 2,
  // 是否把夹具里的人先"签到"掉。
  //
  // 决策 D-6（网页方案 §4.5）改为**只为已签到者生成抽查任务**后，
  // 需要验证在岗行为的用例必须让先签到；而验证「未签到」的用例
  // （看板四态、拒绝/驳回等）必须保持未签到。因此做成可选项。
  checkedIn = false,
  ...overrides
} = {}) {
  fixtureSeq += 1;
  const id = `act-fx-${fixtureSeq}`;
  const start = addMinutes(new Date(), startOffsetMinutes);
  const end = addMinutes(start, durationMinutes);

  const activity = {
    id,
    title: `夹具活动 ${fixtureSeq}`,
    organizer: '测试部门',
    durationHours: durationMinutes / 60,
    startTime: iso(start),
    endTime: iso(end),
    signupDeadline: iso(addMinutes(start, -60)),
    location: '测试场地',
    geoLat: base.lat,
    geoLng: base.lng,
    checkinRadius: 200,
    checkinWindowBefore: 15,
    checkinWindowAfter: 15,
    attendanceFirstDelay: 15,
    attendanceInterval: 30,
    attendanceResponseWindow: 5,
    quota: null,
    enrolled: participants.length,
    // 方案 §4.1：`externalId` 是必填的幂等键。夹具用活动 id 派生，保证唯一。
    externalId: `FX-${id}`,
    // 场地类型影响默认半径（室外 300 / 室内 150），夹具显式给 outdoor 以求稳定。
    locationType: 'outdoor',
    // 网络辅证白名单（评分表 +20 / +10 的判定依据）。
    //
    // 必须由发布者在活动里配置，而不是"客户端上报了就给分" ——
    // 否则任何人填一个 BSSID 都能拿 20 分，辅证就失去意义。
    wifiBssids: ['a4:2b:8c:11:22:33'],
    campusIpPrefixes: ['202.119.', '10.20.'],
    // 增量同步序号（网页方案 §6.4.9）。
    // 真实路径由 `normalizeActivity` 调用 `nextSeq()` 赋值；
    // 夹具是手工构造对象，必须自己补上，否则增量接口看不到它
    //（过滤条件是 `seq > cursor`，缺 seq 会被当成 0 而永久跳过）。
    seq: nextSeq(),
    status,
    tags: [],
    summary: '夹具活动',
    description: '',
    contact: null,
    ownerId: OWNER,
    version: 1,
    ruleSnapshot: {
      frozenAt: iso(start),
      startTime: iso(start),
      endTime: iso(end),
      durationHours: durationMinutes / 60,
      checkinRadius: 200,
      checkinWindowBefore: 15,
      checkinWindowAfter: 15,
      attendanceFirstDelay: 15,
      attendanceInterval: 30,
      attendanceResponseWindow: 5,
      revision: 1,
      reason: null,
      changedBy: OWNER,
    },
    createdAt: iso(addMinutes(start, -120)),
    updatedAt: iso(new Date()),
    terminalAt: null,
    publishedAt: iso(addMinutes(start, -120)),
    cancelReason: null,
    finishedAt: null,
    ...overrides,
  };

  store.db.activities.push(activity);

  for (const userNo of participants) {
    // 手机号可显式指定（顺序与 participants 对齐），否则留空。
    // 留空时 phoneSuffix 也必须是 null —— 否则「入库时没有手机号可比对」
    // 这个真实场景就测不到了。
    const phone = phones[participants.indexOf(userNo)] ?? null;
    store.db.participants.push({
      activityId: id,
      userNo,
      name: `用户${userNo}`,
      phone,
      phoneSuffix: phone ? phone.slice(-4) : null,
      signupStatus: 'signed',
      addedAt: activity.createdAt,
      addedBy: OWNER,
      removedAt: null,
      removedBy: null,
      boundDeviceId: null,
      inviteCodeUsedAt: null,
      grantExpiresAt: null,
    });
  }

  // ── 先造签到，再生成抽查任务 ──────────────────────────────────────
  //
  // 决策 D-6（采用网页方案 §4.5）：**只为「已签到且在名单中」的人生成抽查任务**。
  // 因此需要验证在岗行为的夹具必须先把人"签到"上（`checkedIn: true`），
  // 否则抽查任务数为 0。
  //
  // 这与真实时序一致：志愿者先签到入场，之后才开始被防脱岗抽查。
  if (checkedIn && (status === 'ongoing' || status === 'finished')) {
    for (const userNo of participants) {
      store.db.checkins.push({
        id: `chk-fx-${fixtureSeq}-${userNo}`,
        activityId: id,
        userNo,
        name: `用户${userNo}`,
        method: 'gps',
        status: 'success',
        reason: '夹具：定位证据充分，自动通过',
        geoLat: base.lat + 0.00005,
        geoLng: base.lng + 0.00004,
        accuracy: 12,
        score: 75,
        scoreBreakdown: [{ reason: '围栏内且距中心 8m（≤50m）', points: 40 }],
        distanceMeters: 8,
        mockLocationDetected: false,
        clientTime: iso(addMinutes(start, 2)),
        serverTime: iso(addMinutes(start, 2)),
        samples: [],
        deviceId: null,
        offlineBackfill: false,
        reviewedAt: null,
        reviewedBy: null,
        reviewNote: null,
      });
      const p = findParticipant(id, userNo);
      if (p) {
        p.checkinStatus = 'checked_in';
      }
    }
  }

  if (status === 'ongoing' || status === 'finished') {
    regenerateAttendanceTasks(activity);
  }

  // 把某个 seq 的任务挪到「现在正处于响应窗口内」，供在岗场景使用。
  if (activeTaskSeq != null) {
    for (const p of participants) {
      const t = store.db.attendanceTasks.find(
        (x) => x.activityId === id && x.userNo === p && Number(x.seq) === activeTaskSeq,
      );
      if (t) {
        t.scheduledAt = iso(addMinutes(new Date(), -1));
        t.deadlineAt = iso(addMinutes(new Date(), 4));
      }
    }
  }

  return activity;
}

/** 清掉一个夹具活动的全部痕迹。 */
function cleanup(activityId) {
  const collections = [
    'activities',
    'participants',
    'attendanceTasks',
    'checkins',
    'inviteCodes',
    'grants',
    'ruleChanges',
    'exports',
  ];
  for (const key of collections) {
    store.db[key] = store.db[key].filter(
      (x) => x.activityId !== activityId && x.id !== activityId,
    );
  }
  // 幂等缓存按 endpoint 前缀清理
  for (const [k, v] of Object.entries(store.db.idempotency)) {
    if (v.endpoint && v.endpoint.includes(activityId)) {
      delete store.db.idempotency[k];
    }
  }
}

/** 生成一份完整的 GPS 签到载荷。 */
function gpsPayload(overrides = {}) {
  const at = { lat: base.lat + 0.00005, lng: base.lng + 0.00004 };
  const now = new Date();
  return {
    method: 'gps',
    geoLat: at.lat,
    geoLng: at.lng,
    accuracy: 12,
    clientTime: iso(now),
    mockLocationDetected: false,
    recentInsideFence: true,
    deviceId: 'demo-vol-1',
    appVersion: '0.1.0-test',
    samples: [
      { geoLat: at.lat, geoLng: at.lng, accuracy: 12, capturedAt: iso(now) },
      { geoLat: at.lat + 0.000004, geoLng: at.lng + 0.000003, accuracy: 14, capturedAt: iso(now) },
      { geoLat: at.lat + 0.000008, geoLng: at.lng + 0.000006, accuracy: 11, capturedAt: iso(now) },
    ],
    ...overrides,
  };
}

function volunteerAuth(userNo, activityId) {
  return { kind: 'volunteer', userNo, activityId, token: `test-${userNo}`, deviceId: null };
}

function adminAuth() {
  return { kind: 'admin', ownerId: OWNER, deviceId: DEMO_DEVICE, token: 'test-admin' };
}

/**
 * 捕获「直接下载」类接口写入的 CSV。
 *
 * 导出契约是**一次 GET 拿文件**（网页方案 §6.4.8），handler 会自己调
 * `res.writeHead` / `res.end` 并返回 `undefined`，因此不能像普通接口那样
 * 拿返回值断言。这个辅助函数用一个假 res 把响应截下来。
 *
 * 返回的 `content` 已剥掉 UTF-8 BOM，便于直接做文本断言；
 * 需要验证 BOM 本身时用 `body`（原始 Buffer）。
 */
function captureCsv(handler, context) {
  let captured = null;
  const fakeRes = {
    writeHead(status, headers) {
      captured = { status, headers: headers ?? {} };
    },
    end(payload) {
      const buf = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload ?? ''), 'utf8');
      captured.body = buf;
      // 去掉 BOM 后的正文
      const text = buf.toString('utf8');
      captured.content = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
    },
  };

  const returned = handler({ ...context, res: fakeRes });

  if (returned !== undefined) {
    // handler 没走下载分支，而是返回了业务错误 —— 直接把错误暴露出来，
    // 否则断言会以 "captured 是 null" 这种看不出原因的方式失败。
    const message = returned.__error?.message ?? JSON.stringify(returned);
    throw new Error(`导出未产生文件，handler 返回：${message}`);
  }
  if (captured === null) {
    throw new Error('导出未写入任何响应');
  }
  return captured;
}

// ═════════════════════════════════════════════════════════════════════════
section('§6.1 风险评分（纯函数，判定权在服务端）');
// ═════════════════════════════════════════════════════════════════════════

const scoreFixture = makeFixture();

test('围栏内 ≤50m + 停留验证 + 采样一致 → success', () => {
  const r = scoreCheckin({
    activity: scoreFixture,
    submission: gpsPayload(),
    context: { recentInsideFence: true, sameDeviceOtherUsers: 0 },
  });
  // 40 + 15 + 10 = 65 ≥ 60
  assert.equal(r.score, 65, `期望 65，实际 ${r.score}`);
  assert.equal(r.status, CHECKIN_STATUS.SUCCESS);
});

test('围栏内但无任何辅证 → 40 分，转待人工确认', () => {
  const r = scoreCheckin({
    activity: scoreFixture,
    submission: gpsPayload({ recentInsideFence: false, samples: [] }),
    context: {},
  });
  assert.equal(r.score, 40);
  assert.equal(r.status, CHECKIN_STATUS.PENDING_REVIEW);
});

test('模拟定位 −60 强制转人工，即使围栏内也不自动通过', () => {
  const r = scoreCheckin({
    activity: scoreFixture,
    submission: gpsPayload({ mockLocationDetected: true }),
    context: { recentInsideFence: true },
  });
  assert.equal(r.status, CHECKIN_STATUS.PENDING_REVIEW);
  assert.match(r.reason, /模拟定位/);
  assert.equal(r.score, 5); // 40 + 15 + 10 − 60
});

test('服务端能识别「客户端谎报未模拟定位」但证据自相矛盾的情况', () => {
  const at = { lat: base.lat, lng: base.lng };
  const same = iso(new Date());
  const r = scoreCheckin({
    activity: scoreFixture,
    // 三次采样坐标与精度完全一致：真实 GPS 不会如此完美
    submission: gpsPayload({
      mockLocationDetected: false,
      samples: [
        { geoLat: at.lat, geoLng: at.lng, accuracy: 5, capturedAt: same },
        { geoLat: at.lat, geoLng: at.lng, accuracy: 5, capturedAt: same },
        { geoLat: at.lat, geoLng: at.lng, accuracy: 5, capturedAt: same },
      ],
    }),
    context: { recentInsideFence: true },
  });
  assert.equal(r.status, CHECKIN_STATUS.PENDING_REVIEW);
  assert.match(r.reason, /模拟定位/);
});

/*
  真机测试发现的误判（回归用例）。

  ## 现象

  志愿者站在签到点上**不动**，App 采 3 次样，服务端判为模拟定位：
  得分 40(围栏) + 10(采样一致) − 60(模拟) = **−10**，强制转人工。

  ## 原因

  Android 融合定位在设备静止时直接返回**缓存值**，三次采样逐位相同
  （真机实测 34.218196 / 117.137571 / ±30m 三份完全一样）。
  而原判据只看"完全一致"，于是把真人当成了作弊。

  后果：方案 §6.1 的"自动通过"路径实际永远走不到；
  而且与同一张评分表里的"采样一致 +10"自相矛盾。

  ## 现在的口径

  "完全一致"必须叠加"精度异常理想（≤5 m）"才判模拟定位。
  静态真机融合定位的典型精度是 20–50 m，作弊工具才写 0–5 m。
*/
test('真机站着不动：多次采样逐位相同但精度正常（±30m）→ 不得判为模拟定位', () => {
  const at = { lat: base.lat, lng: base.lng };
  const same = iso(new Date());
  const r = scoreCheckin({
    activity: scoreFixture,
    submission: gpsPayload({
      mockLocationDetected: false,
      samples: [
        { geoLat: at.lat, geoLng: at.lng, accuracy: 30, capturedAt: same },
        { geoLat: at.lat, geoLng: at.lng, accuracy: 30, capturedAt: same },
        { geoLat: at.lat, geoLng: at.lng, accuracy: 30, capturedAt: same },
      ],
    }),
    context: { recentInsideFence: true },
  });
  // 40(围栏内≤50m) + 15(近期在围栏内) + 10(采样一致) = 65 → 自动通过
  assert.equal(r.score, 65);
  assert.equal(
    r.status,
    CHECKIN_STATUS.SUCCESS,
    '真人站着不动必须能自动通过，否则「自动通过」这条路径在真机上不可达',
  );
  assert.doesNotMatch(r.reason, /模拟定位/);
});

test('伪造指纹仍被抓住：逐位相同 + 精度 3m（真机达不到）→ 模拟定位', () => {
  const at = { lat: base.lat, lng: base.lng };
  const same = iso(new Date());
  const r = scoreCheckin({
    activity: scoreFixture,
    submission: gpsPayload({
      mockLocationDetected: false,
      samples: [
        { geoLat: at.lat, geoLng: at.lng, accuracy: 3, capturedAt: same },
        { geoLat: at.lat, geoLng: at.lng, accuracy: 3, capturedAt: same },
        { geoLat: at.lat, geoLng: at.lng, accuracy: 3, capturedAt: same },
      ],
    }),
    context: { recentInsideFence: true },
  });
  assert.equal(r.status, CHECKIN_STATUS.PENDING_REVIEW);
  assert.match(r.reason, /模拟定位/);
  // 具体原因在评分明细里（管理端「待确认」列表就是靠它解释为什么）。
  assert.ok(
    r.items.some((it) => /精度异常理想/.test(it.reason)),
    '评分明细应指出"精度异常理想"，否则发布者无从判断为什么被判作弊',
  );
});

test('验收 A12：距场地 1.5 倍半径外 → rejected 且原因明确指出距离与半径', () => {
  const far = offsetMeters(base.lat, base.lng, scoreFixture.checkinRadius * 1.6, 0);
  const r = scoreCheckin({
    activity: scoreFixture,
    submission: gpsPayload({ geoLat: far.lat, geoLng: far.lng, samples: [] }),
    context: {},
  });
  assert.equal(r.status, CHECKIN_STATUS.REJECTED);
  assert.ok(r.score < 30, `期望 <30，实际 ${r.score}`);
  assert.match(r.reason, /不在签到范围内/);
  assert.match(r.reason, /签到半径 200 米/);
  assert.match(r.reason, /距场地约 320 米/, `实际：${r.reason}`);
});

test('验收 A14：明显在城外的坐标（约 500m 东北偏）被识别为坐标系未转换', () => {
  const shifted = offsetMeters(base.lat, base.lng, 350, 350);
  const r = scoreCheckin({
    activity: scoreFixture,
    submission: gpsPayload({ geoLat: shifted.lat, geoLng: shifted.lng, samples: [] }),
    context: {},
  });
  assert.equal(r.status, CHECKIN_STATUS.REJECTED);
  assert.equal(r.coordinateVerdict, 'suspected_unconverted_gcj02');
  // 坐标系提示是**附加信息**，不替代「不在范围内」这个主因——否则真实跑错
  // 场地的志愿者会被误导去查坐标系。
  assert.match(r.reason, /不在签到范围内/);
  assert.match(r.reason, /坐标系/);
});

test('精度 >100m 时该证据不计分（不直接判死，但拿不到围栏分）', () => {
  const r = scoreCheckin({
    activity: scoreFixture,
    submission: gpsPayload({ accuracy: 150, samples: [], recentInsideFence: false }),
    context: {},
  });
  assert.equal(r.score, 0);
  assert.equal(r.status, CHECKIN_STATUS.REJECTED);
});

test('同设备多账号 −30，能把「围栏内」拖到待人工确认', () => {
  const r = scoreCheckin({
    activity: scoreFixture,
    submission: gpsPayload(),
    context: { recentInsideFence: true, sameDeviceOtherUsers: 1 },
  });
  assert.equal(r.score, 35); // 40 + 15 + 10 − 30
  assert.equal(r.status, CHECKIN_STATUS.PENDING_REVIEW);
});

test('无有效坐标 → 转人工而不是驳回（不得出现死路）', () => {
  const r = scoreCheckin({
    activity: scoreFixture,
    submission: { geoLat: 0, geoLng: 0, accuracy: 0, samples: [] },
    context: {},
  });
  assert.equal(r.status, CHECKIN_STATUS.PENDING_REVIEW);
});

test('距离计算与 Haversine 量级一致（1 公里级）', () => {
  const p = offsetMeters(base.lat, base.lng, 1000, 0);
  const d = distanceMeters(base, p);
  assert.ok(Math.abs(d - 1000) < 5, `期望约 1000m，实际 ${d.toFixed(1)}m`);
});

cleanup(scoreFixture.id);

// ═════════════════════════════════════════════════════════════════════════
section('§6.2 在岗抽查：计划生成（验收 A20）');
// ═════════════════════════════════════════════════════════════════════════

test('验收 A20：2 小时活动默认生成 3 次抽查（T+15 / T+45 / T+75）', () => {
  const activity = {
    startTime: iso(addMinutes(new Date(), -30)),
    endTime: iso(addMinutes(new Date(), 90)),
    attendanceFirstDelay: 15,
    attendanceInterval: 30,
    attendanceResponseWindow: 5,
  };
  const slots = planSlots(activity);
  assert.equal(slots.length, 3, `期望 3 次，实际 ${slots.length}`);
  const start = new Date(activity.startTime);
  assert.deepEqual(
    slots.map((s) => Math.round((s - start) / 60_000)),
    [15, 45, 75],
  );
});

test('末次抽查为活动收尾留出 30 分钟（取 15 会让 2 小时活动变成 4 次）', () => {
  const activity = {
    startTime: iso(addMinutes(new Date(), -30)),
    endTime: iso(addMinutes(new Date(), 90)),
    attendanceFirstDelay: 15,
    attendanceInterval: 30,
  };
  const slots = planSlots(activity);
  const lastAllowed = addMinutes(new Date(activity.endTime), -30);
  assert.ok(
    slots[slots.length - 1] <= lastAllowed,
    '末次抽查应不晚于 endTime − 30min',
  );
  const minBeforeEnd = (new Date(activity.endTime) - slots[slots.length - 1]) / 60_000;
  assert.equal(minBeforeEnd, 45, `末次距结束 ${minBeforeEnd} 分钟`);
});

test('异常参数（间隔为 0）不会死循环', () => {
  const activity = {
    startTime: iso(addMinutes(new Date(), -30)),
    endTime: iso(addMinutes(new Date(), 90)),
    attendanceFirstDelay: 15,
    attendanceInterval: 0,
  };
  const slots = planSlots(activity);
  assert.ok(slots.length > 0 && slots.length < 100, `槽位数异常：${slots.length}`);
});

test('验收（§14.1-3）：重复生成任务幂等，不产生重复', () => {
  const fx = makeFixture({ participants: ['0001', '0002', '0003', '0004', '0005'], checkedIn: true });

  // 夹具创建时已经生成过一轮（5 人 × 3h 的 5 个时段 = 25 个）。
  const initial = store.db.attendanceTasks.filter((t) => t.activityId === fx.id).length;
  assert.equal(initial, 25, `夹具应已生成 25 个任务，实际 ${initial}`);

  // 再调三次：都应新增 0 个
  assert.equal(regenerateAttendanceTasks(fx), 0, '重复调用不应新增');
  assert.equal(regenerateAttendanceTasks(fx), 0, '重复调用不应新增');
  assert.equal(regenerateAttendanceTasks(fx), 0, '重复调用不应新增');
  assert.equal(store.db.attendanceTasks.filter((t) => t.activityId === fx.id).length, 25);

  // 幂等键三元组 (activityId, userNo, seq) 必须唯一
  const keys = store.db.attendanceTasks
    .filter((t) => t.activityId === fx.id)
    .map((t) => `${t.userNo}#${t.seq}`);
  assert.equal(new Set(keys).size, keys.length, '存在重复的 (userNo, seq)');

  cleanup(fx.id);
});

test('活动时间改长后仅补生成新增时段，已结案任务不被改写', () => {
  const fx = makeFixture({ participants: ['0011'], checkedIn: true });
  const first = store.db.attendanceTasks.find(
    (t) => t.activityId === fx.id && t.userNo === '0011' && Number(t.seq) === 1,
  );
  first.status = TASK_STATUS.DONE;
  first.respondedAt = iso(new Date());
  const respondedAt = first.respondedAt;

  const before = store.db.attendanceTasks.filter((t) => t.activityId === fx.id).length;
  regenerateAttendanceTasks({ ...fx, endTime: iso(addMinutes(new Date(fx.endTime), 60)) });
  const after = store.db.attendanceTasks.filter((t) => t.activityId === fx.id);

  assert.ok(after.length > before, '应补生成新增时段');
  const firstAfter = after.find((t) => t.userNo === '0011' && Number(t.seq) === 1);
  assert.equal(firstAfter.status, TASK_STATUS.DONE, '已结案的任务不应被改写');
  assert.equal(firstAfter.respondedAt, respondedAt, '历史判定不变');

  cleanup(fx.id);
});

// ═════════════════════════════════════════════════════════════════════════
section('§4.1 管理端登录（验收 A1 / A2 / A3 / A22）');
// ═════════════════════════════════════════════════════════════════════════

test('验收 A1/A2：用默认邀请码 1111 登录成功，并记录登录审计', () => {
  const auditBefore = store.db.loginAudits.length;
  const res = api.adminLogin(ctx({ body: { inviteCode: '1111', deviceId: DEMO_DEVICE } }));
  assert.ok(res.token, '应签发令牌');
  assert.equal(res.deviceId, DEMO_DEVICE);
  assert.ok(store.db.loginAudits.length > auditBefore, '应写入登录审计');
  assert.equal(store.db.loginAudits[0].success, true);
});

// ── 验收 A22：管理端 App 的**默认邀请码是 1111** ──────────────────────
//
// 这条要求同时是"安全底线的让步"，值得把话说明白：
//
// README §3.3 底线①写的是「管理端不使用固定默认邀请码」，
// 而方案 §2/§14.1 与验收 A1/A2 **都把固定默认码 1111 当作既定设计**
// 并写进了验收标准。两者直接冲突，我按方案实现（见 docs/open-issues-app.md O-1）。
//
// 因此"固定 1111"这件事必须有两道配套的补偿措施，否则它就是一个
// 公开的默认口令：
//   1. 设备指纹绑定（登录必须带 deviceId）—— 压小被谁拿到的影响面；
//   2. 连续 5 次失败锁 10 分钟 —— 挡住暴力尝试。
// 下面两条测试分别钉住"默认值就是 1111"与"可被服务端覆盖"，
// 最后一条钉住"覆盖生效时默认值必须失效"。

test('验收 A22：默认邀请码是 1111', () => {
  assert.equal(
    DEFAULTS.DEFAULT_ADMIN_INVITE_CODE,
    '1111',
    '方案 §2/§14.1 与验收 A1/A2 都把默认码定为 1111',
  );
  // 未设环境变量时，实际生效的就是这个默认值。
  const saved = process.env.ADMIN_INVITE_CODE;
  try {
    delete process.env.ADMIN_INVITE_CODE;
    assert.equal(api.adminInviteCode(), '1111', '未配置环境变量时应回落到 1111');
  } finally {
    if (saved !== undefined) {
      process.env.ADMIN_INVITE_CODE = saved;
    }
  }
});

test('验收 A22：默认邀请码可被服务端配置覆盖（ADMIN_INVITE_CODE）', () => {
  const saved = process.env.ADMIN_INVITE_CODE;
  try {
    process.env.ADMIN_INVITE_CODE = '8888';
    assert.equal(api.adminInviteCode(), '8888', '环境变量应覆盖默认值');

    // 覆盖生效后：新码可用，**旧默认码必须失效**。
    // 若 1111 仍能登录，说明覆盖只是"多了一个码"，
    // 那台机器实际上还留着一个公开口令。
    const ok = api.adminLogin(
      ctx({ body: { inviteCode: '8888', deviceId: 'a22-override-device' }, ip: '10.9.9.1' }),
    );
    assert.ok(ok.token, '覆盖后的新码应能登录');

    const stale = api.adminLogin(
      ctx({ body: { inviteCode: '1111', deviceId: 'a22-stale-device' }, ip: '10.9.9.2' }),
    );
    assert.equal(
      stale.__error.code,
      ERR.ADMIN_CODE_INVALID,
      '被覆盖后，旧的默认码 1111 不得再能登录',
    );
  } finally {
    if (saved !== undefined) {
      process.env.ADMIN_INVITE_CODE = saved;
    } else {
      delete process.env.ADMIN_INVITE_CODE;
    }
  }
});

test('验收 A22：默认码是固定值，因此必须靠设备指纹与锁定策略兜底', () => {
  // 这条不是"再测一遍功能"，而是把**为什么 1111 可以接受**这件事
  // 变成可执行的断言 —— 否则将来有人拿掉设备指纹校验或锁定策略时，
  // 「固定默认码」就会从"可接受的让步"变成"公开的默认口令"。

  // 1) 无设备标识 → 拒绝（压小暴露面）
  const noDevice = api.adminLogin(ctx({ body: { inviteCode: '1111' } }));
  assert.equal(noDevice.__error.code, ERR.BAD_REQUEST, '登录必须携带设备标识');

  // 2) 连续失败 → 锁定（挡住暴力尝试）
  //
  // ⚠️ 计数口径：前 5 次都返回「邀请码错误」，**第 6 次**才返回「已锁定」。
  // 这不是笔误 —— 服务端在累计到阈值的那一次仍按"错误"回复并提示
  // 剩余次数，下一次才真正拒绝。因此循环 5 次之后，第 6 次才应看到锁定。
  const ip = '10.9.9.88';
  for (let i = 0; i < 5; i++) {
    api.adminLogin(ctx({ body: { inviteCode: '9999', deviceId: 'lock-probe' }, ip }));
  }
  const locked = api.adminLogin(
    ctx({ body: { inviteCode: '9999', deviceId: 'lock-probe' }, ip }),
  );
  // 文案是「错误次数过多，请在 10 分钟后重试」——刻意**不**用"锁定"二字：
  // 对管理员来说"账号被锁定"听起来像是永久封禁，而实际只是 10 分钟冷却。
  assert.match(
    locked.__error.message,
    /错误次数过多|分钟后重试/,
    `连续失败后应拒绝并给出冷却时间，实际：${JSON.stringify(locked.__error)}`,
  );
  // HTTP 423（Locked）比 401 更准确：这不是"凭证错误"，
  // 而是"暂时不允许尝试"。
  assert.equal(locked.__error.httpStatus, 423, '限流应返回 423 而不是 401');
});

test('验收 A2（暴露面）：无设备标识的登录被拒绝', () => {
  const res = api.adminLogin(ctx({ body: { inviteCode: '1111' } }));
  assert.equal(res.__error.code, ERR.BAD_REQUEST);
});

test('验收 A3：连续 5 次错误邀请码 → 锁定 10 分钟', () => {
  const ip = '10.0.0.99';
  for (let i = 0; i < 4; i++) {
    const r = api.adminLogin(ctx({ body: { inviteCode: '0000', deviceId: 'x' }, ip }));
    assert.equal(r.__error.code, ERR.ADMIN_CODE_INVALID, `第 ${i + 1} 次应为邀请码错误`);
  }
  const fifth = api.adminLogin(ctx({ body: { inviteCode: '0000', deviceId: 'x' }, ip }));
  assert.equal(fifth.__error.code, ERR.ADMIN_CODE_INVALID);

  // 第 6 次应已被锁定
  const locked = api.adminLogin(ctx({ body: { inviteCode: '0000', deviceId: 'x' }, ip }));
  assert.equal(locked.__error.code, ERR.ADMIN_CODE_LOCKED, `实际 ${locked.__error.code}`);

  // 即使码正确也应被拦截
  const blocked = api.adminLogin(ctx({ body: { inviteCode: '1111', deviceId: 'x' }, ip }));
  assert.equal(blocked.__error.code, ERR.ADMIN_CODE_LOCKED);

  delete store.db.loginFailures[ip];
});

test('审计不含完整手机号或学号（README §3.3 底线②）', () => {
  for (const a of store.db.loginAudits) {
    const s = JSON.stringify(a);
    assert.ok(!/1[3-9]\d{9}/.test(s), `审计中出现疑似完整手机号：${s}`);
    assert.ok(!/\d{7,}/.test(s), `审计中出现疑似完整学号：${s}`);
  }
});

test('§13-A1 收紧路径：环境变量可覆盖默认邀请码', () => {
  process.env.ADMIN_INVITE_CODE = '8888';
  try {
    // 默认码失效
    const old = api.adminLogin(ctx({ body: { inviteCode: '1111', deviceId: 'd-override' } }));
    assert.equal(old.__error.code, ERR.ADMIN_CODE_INVALID);
    // 新码生效
    const ok = api.adminLogin(ctx({ body: { inviteCode: '8888', deviceId: 'd-override' } }));
    assert.ok(ok.token, '环境变量配置的邀请码应可用');
  } finally {
    delete process.env.ADMIN_INVITE_CODE;
  }
  store.db.admins = store.db.admins.filter((a) => a.deviceId !== 'd-override');
});

// ═════════════════════════════════════════════════════════════════════════
section('§2 归属隔离（验收 A4）');
// ═════════════════════════════════════════════════════════════════════════

test('验收 A4：管理端 A 操作 B 的活动 → 40301，且数据不变', () => {
  const fx = makeFixture();
  const beforeVersion = fx.version;
  const beforeStatus = fx.status;

  const res = api.updateActivity(
    ctx({
      params: { id: fx.id },
      body: { summary: '越权篡改' },
      auth: { kind: 'admin', ownerId: 'owner-someone-else', deviceId: 'other' },
    }),
  );
  assert.equal(res.__error.code, ERR.FORBIDDEN, `实际 ${JSON.stringify(res.__error)}`);
  assert.equal(fx.version, beforeVersion, '版本不应变化');
  assert.equal(fx.status, beforeStatus, '状态不应变化');
  assert.notEqual(fx.summary, '越权篡改', '数据不应被修改');

  // 取消、结束、名单改动同样应被拦截
  for (const call of [
    () => api.cancelActivity(ctx({ params: { id: fx.id }, body: { reason: '越权取消尝试' }, auth: { kind: 'admin', ownerId: 'other' } })),
    () => api.finishActivity(ctx({ params: { id: fx.id }, auth: { kind: 'admin', ownerId: 'other' } })),
    () => api.removeParticipant(ctx({ params: { id: fx.id, userNo: 'u001' }, auth: { kind: 'admin', ownerId: 'other' } })),
  ]) {
    assert.equal(call().__error.code, ERR.FORBIDDEN);
  }

  cleanup(fx.id);
});

test('不存在的活动 → 30001（不泄露是否存在）', () => {
  const res = api.getActivity(ctx({ params: { id: 'act-does-not-exist' }, auth: adminAuth() }));
  assert.equal(res.__error.code, ERR.ACTIVITY_NOT_FOUND);
});

// ═════════════════════════════════════════════════════════════════════════
section('§4.2 / §4.5 发布与受限编辑（验收 A5 / A6）');
// ═════════════════════════════════════════════════════════════════════════

const draftNew = {
  externalId: 'ACT-TEST-0001',
  title: '测试活动',
  organizer: '测试部门',
  durationHours: 2,
  startTime: iso(addMinutes(new Date(), 24 * 60)),
  endTime: iso(addMinutes(new Date(), 26 * 60)),
  location: '测试地点',
  geoLat: base.lat,
  geoLng: base.lng,
  checkinRadius: 200,
  summary: '测试用活动简介',
};

let createdActivityId = null;

test('验收 A5：上报活动创建成功并冻结规则快照', () => {
  const res = api.upsertActivities(ctx({ body: draftNew, auth: adminAuth() }));

  // `:upsert` 的契约响应形状：accepted / created / updated / rejected（网页 §6.4.1）。
  // 注意**没有** `activity` 字段 —— 逐条上报返回的是 id 列表，不是完整对象，
  // 否则批量 100 条时会返回一个巨大的响应体。要详情请再调 GET 详情。
  assert.equal(res.accepted, 1, JSON.stringify(res));
  assert.equal(res.created.length, 1);
  assert.equal(res.updated.length, 0);
  assert.deepEqual(res.rejected, []);

  createdActivityId = res.created[0];

  // 详情里的状态与快照
  const detail = api.getActivity(ctx({ params: { id: createdActivityId }, auth: adminAuth() }));
  assert.equal(detail.status, 'published');
  assert.ok(detail.ruleSnapshot, '发布应生成规则快照');
  assert.equal(detail.ruleSnapshot.revision, 1);
  assert.equal(detail.externalId, draftNew.externalId, 'externalId 应被保存（幂等键）');
});

test('验收 A5 补充：同一 externalId 重复上报 → 更新而不是新建（幂等）', () => {
  const before = store.db.activities.length;
  const res = api.upsertActivities(
    ctx({ body: { ...draftNew, title: '改过的名称' }, auth: adminAuth() }),
  );
  assert.equal(res.updated.length, 1, '应识别为更新');
  assert.equal(res.created.length, 0);
  assert.equal(res.updated[0], createdActivityId, '应更新同一个活动');
  assert.equal(store.db.activities.length, before, '不应新增活动');

  const detail = api.getActivity(ctx({ params: { id: createdActivityId }, auth: adminAuth() }));
  assert.equal(detail.title, '改过的名称');
  // 重传不得把已发布状态打回草稿（方案 §5.4）
  assert.equal(detail.status, 'published', '重传不得覆盖服务端已流转的状态');
});

test('录入校验：签到半径小于 10 或大于 1000 被拒绝（方案 §4.1）', () => {
  for (const radius of [0, 9, 1001, 1500]) {
    const res = api.upsertActivities(
      ctx({ body: { ...draftNew, externalId: `ACT-R${radius}`, checkinRadius: radius }, auth: adminAuth() }),
    );
    // 逐条上报的语义：部分失败仍返回 200，失败原因在 rejected[] 里。
    assert.deepEqual(res.created, [], `半径 ${radius} 不应被创建`);
    assert.equal(res.rejected.length, 1, `半径 ${radius} 应被拒绝`);
    assert.ok(
      res.rejected[0].errors.some((e) => e.field === 'checkinRadius'),
      `半径 ${radius} 应报 checkinRadius 错误：${JSON.stringify(res.rejected[0].errors)}`,
    );
  }
});

test('录入校验：endTime ≤ startTime 进入 rejected[] 并给出字段原因', () => {
  const res = api.upsertActivities(
    ctx({ body: { ...draftNew, externalId: 'ACT-BADTIME', endTime: draftNew.startTime }, auth: adminAuth() }),
  );
  assert.equal(res.rejected.length, 1);
  assert.ok(res.rejected[0].errors.some((e) => e.field === 'endTime'));
  // 逐条结果必须带上定位信息，客户端才能把出错的条目标红
  assert.equal(res.rejected[0].externalId, 'ACT-BADTIME');
  assert.equal(res.rejected[0].index, 0);
});

test('录入校验：报名截止晚于开始时间被拒绝', () => {
  const res = api.upsertActivities(
    ctx({
      body: { ...draftNew, externalId: 'ACT-BADDEADLINE', signupDeadline: draftNew.endTime },
      auth: adminAuth(),
    }),
  );
  assert.equal(res.rejected.length, 1);
  assert.ok(res.rejected[0].errors.some((e) => e.field === 'signupDeadline'));
});

test('录入校验：必填缺失逐字段报告（含 externalId）', () => {
  const res = api.upsertActivities(
    ctx({ body: { ...draftNew, externalId: '', title: '' }, auth: adminAuth() }),
  );
  assert.equal(res.rejected.length, 1);
  assert.ok(res.rejected[0].errors.some((e) => e.field === 'externalId'), 'externalId 是必填幂等键');
  assert.ok(res.rejected[0].errors.some((e) => e.field === 'title'));
});

test('录入校验：长度超限被拒绝（方案 §4.1 保证列表同构呈现）', () => {
  const res = api.upsertActivities(
    ctx({
      body: {
        ...draftNew,
        externalId: 'ACT-LONG',
        title: '标'.repeat(61),
        organizer: '部'.repeat(51),
        summary: '简'.repeat(121),
      },
      auth: adminAuth(),
    }),
  );
  assert.equal(res.rejected.length, 1);
  const fields = res.rejected[0].errors.map((e) => e.field);
  assert.ok(fields.includes('title'), `title 应超限：${fields}`);
  assert.ok(fields.includes('organizer'), `organizer 应超限：${fields}`);
  assert.ok(fields.includes('summary'), `summary 应超限：${fields}`);
});

test('录入校验：时长步长必须是 0.5 小时', () => {
  const bad = api.upsertActivities(
    ctx({ body: { ...draftNew, externalId: 'ACT-STEP', durationHours: 2.3 }, auth: adminAuth() }),
  );
  assert.equal(bad.rejected.length, 1);
  assert.ok(bad.rejected[0].errors.some((e) => e.field === 'durationHours'));

  const ok = api.upsertActivities(
    ctx({ body: { ...draftNew, externalId: 'ACT-STEP-OK', durationHours: 2.5 }, auth: adminAuth() }),
  );
  assert.equal(ok.created.length, 1, '2.5 应被接受');
  cleanup(ok.created[0]);
});

test('录入校验：抽查参数导致 0 次抽查 → rejected', () => {
  const res = api.upsertActivities(
    ctx({
      body: {
        ...draftNew,
        externalId: 'ACT-NOPATROL',
        endTime: iso(addMinutes(new Date(draftNew.startTime), 30)),
        attendanceFirstDelay: 60,
      },
      auth: adminAuth(),
    }),
  );
  assert.equal(res.rejected.length, 1);
  assert.ok(res.rejected[0].errors.some((e) => e.field === 'attendanceFirstDelay'));
});

test('批量上报：合法行入库、非法行逐条报告，且仍返回 200（部分失败）', () => {
  const before = store.db.activities.length;
  const res = api.upsertActivities(
    ctx({
      body: {
        source: 'admin-app',
        batch: [
          { ...draftNew, externalId: 'BATCH-OK-1', title: '批量活动一' },
          { ...draftNew, externalId: '', title: '缺幂等键' },
          { ...draftNew, externalId: 'BATCH-OK-2', title: '批量活动二' },
          { ...draftNew, externalId: 'BATCH-BAD', endTime: draftNew.startTime },
        ],
      },
      auth: adminAuth(),
    }),
  );
  assert.equal(res.accepted, 2, JSON.stringify(res));
  assert.equal(res.created.length, 2);
  assert.equal(res.rejected.length, 2);
  assert.equal(store.db.activities.length, before + 2);
  assert.match(res.note, /2 条被拒绝/, '应提示需要修正后重传');

  for (const id of res.created) {
    cleanup(id);
  }
});

test('批量上报：空 batch 被拒绝', () => {
  const res = api.upsertActivities(ctx({ body: { batch: [] }, auth: adminAuth() }));
  assert.equal(res.__error.code, ERR.BAD_REQUEST);
});

test('验收 A6：改关键字段不填原因 → 拒绝并说明', () => {
  const res = api.updateActivity(
    ctx({
      params: { id: createdActivityId },
      body: { endTime: iso(addMinutes(new Date(), 27 * 60)) },
      auth: adminAuth(),
    }),
  );
  assert.equal(res.__error.code, ERR.ACTIVITY_RULE_FROZEN);
  assert.ok(res.__error.errors.some((e) => e.field === 'changeReason'));
});

test('验收 A6：填了原因 → 记录前后值、生成新快照、历史判定不变', () => {
  const act = store.db.activities.find((a) => a.id === createdActivityId);
  const oldEnd = act.endTime;
  const newEnd = iso(addMinutes(new Date(oldEnd), 60));
  const oldRevision = act.ruleSnapshot.revision;

  const res = api.updateActivity(
    ctx({
      params: { id: createdActivityId },
      body: { endTime: newEnd, changeReason: '场地使用时间延长一小时' },
      auth: adminAuth(),
    }),
  );
  assert.ok(res.activity, JSON.stringify(res));
  assert.equal(res.ruleChangeRecorded, true);
  assert.equal(res.revision, oldRevision + 1);
  assert.deepEqual(res.frozenFieldsChanged, ['endTime']);

  const changes = api.activityChanges(ctx({ params: { id: createdActivityId }, auth: adminAuth() }));
  assert.equal(changes.items.length, 1);
  assert.equal(changes.items[0].field, 'endTime');
  assert.equal(changes.items[0].before, oldEnd);
  assert.equal(changes.items[0].after, newEnd);
  assert.match(changes.items[0].reason, /场地使用时间延长/);
  assert.equal(changes.items[0].notifiedCount, 0, '无绑定用户时应通知 0 人');
});

test('非关键字段可自由修改，不触发原因校验', () => {
  const res = api.updateActivity(
    ctx({ params: { id: createdActivityId }, body: { summary: '改过的简介' }, auth: adminAuth() }),
  );
  assert.ok(res.activity, JSON.stringify(res));
  assert.equal(res.activity.summary, '改过的简介');
});

test('乐观锁：version 不匹配 → 10003', () => {
  const res = api.updateActivity(
    ctx({ params: { id: createdActivityId }, body: { summary: 'x', version: 999 }, auth: adminAuth() }),
  );
  assert.equal(res.__error.code, ERR.VERSION_CONFLICT);
});

// ═════════════════════════════════════════════════════════════════════════
section('§4.4 取消活动（验收 A7）');
// ═════════════════════════════════════════════════════════════════════════

test('取消原因少于 5 字 → 拒绝', () => {
  const fx = makeFixture();
  const res = api.cancelActivity(
    ctx({ params: { id: fx.id }, body: { reason: '下雨' }, auth: adminAuth() }),
  );
  assert.equal(res.__error.code, ERR.BAD_REQUEST);
  assert.ok(res.__error.errors.some((e) => e.field === 'reason'));
  cleanup(fx.id);
});

test('验收 A7：取消活动 → 未发生任务置 excused，已发生的保留', () => {
  const fx = makeFixture({ participants: ['0021'], checkedIn: true });
  const tasks = store.db.attendanceTasks.filter((t) => t.activityId === fx.id);
  assert.ok(tasks.length >= 2, '夹具应生成至少 2 个任务');
  // 把第一个标记为已发生，第二个保持未发生
  tasks[0].status = TASK_STATUS.DONE;
  tasks[0].respondedAt = iso(new Date());
  const doneId = tasks[0].id;
  const pendingIds = tasks.slice(1).map((t) => t.id);

  const res = api.cancelActivity(
    ctx({
      params: { id: fx.id },
      body: { reason: '当日持续降雨，场地湿滑，协商取消' },
      auth: adminAuth(),
    }),
  );
  assert.ok(res.activity, JSON.stringify(res));
  assert.equal(res.excusedTasks, pendingIds.length);
  assert.equal(res.irreversible, true);
  assert.equal(res.activity.status, 'cancelled');

  assert.equal(
    store.db.attendanceTasks.find((t) => t.id === doneId).status,
    TASK_STATUS.DONE,
    '已发生的任务应保持原状，不冤枉已到场的人',
  );
  for (const id of pendingIds) {
    assert.equal(store.db.attendanceTasks.find((t) => t.id === id).status, TASK_STATUS.EXCUSED);
  }

  cleanup(fx.id);
});

test('取消不可逆：重复取消被拒绝', () => {
  const fx = makeFixture({ status: 'cancelled', cancelReason: '已取消' });
  const res = api.cancelActivity(
    ctx({ params: { id: fx.id }, body: { reason: '再次取消尝试应当失败' }, auth: adminAuth() }),
  );
  assert.equal(res.__error.code, ERR.ACTIVITY_STATE_INVALID);
  cleanup(fx.id);
});

test('宣布结束后签到与抽查关闭，并给出数据销毁时刻', () => {
  const fx = makeFixture();
  const res = api.finishActivity(ctx({ params: { id: fx.id }, auth: adminAuth() }));
  assert.ok(res.activity, JSON.stringify(res));
  assert.equal(res.activity.status, 'finished');
  assert.match(res.reminder, /7 天内完成导出/);
  assert.ok(res.dataDestroyAt);

  // 结束后签到应被拒
  const chk = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload(),
      auth: volunteerAuth('u001', fx.id),
      headers: { 'idempotency-key': `k-fin-${fx.id}` },
    }),
  );
  assert.equal(chk.__error.code, ERR.ACTIVITY_STATE_INVALID);

  cleanup(fx.id);
});

// ═════════════════════════════════════════════════════════════════════════
section('§4.6 / §4.7 名单与邀请码（验收 A8 / A9 / A10）');
// ═════════════════════════════════════════════════════════════════════════

test('验收 A8：批量导入含重复与格式错误 → 合法行入库，错误行逐条报告', () => {
  // 夹具里放 1001（姓名「用户1001」、库里无手机号后四位）。
  const fx = makeFixture({ participants: ['1001'] });
  // 表头 1 行 + 数据 6 行。行号按含表头的源文件计。
  const a8text = [
    '学号\t姓名\t手机号', // 第 1 行：表头，跳过
    '1002\t孙悦\t13800001006', // 第 2 行：正常
    'imp\t钱进\t13800001007', // 第 3 行：学号格式错误
    '1001\t用户1001', // 第 4 行：姓名一致且无新信息 → 活动内重复
    '1003\t', // 第 5 行：缺姓名
    '1004\t周舟\t1380000', // 第 6 行：手机号格式错误
    '1005\t吴迪\t13800001009', // 第 7 行：正常
  ].join('\n');

  const res = api.importParticipants(
    ctx({ params: { id: fx.id }, body: { text: a8text }, auth: adminAuth() }),
  );

  assert.equal(res.total, 6, `应解析 6 个数据行（表头不计），实际 ${res.total}`);
  assert.equal(
    res.rows.length,
    res.total,
    '每一行都必须有报告结果，不能静默丢弃',
  );
  assert.equal(res.accepted, 2, `期望接收 2 行（1002/1005），实际 ${res.accepted}`);
  assert.equal(res.rejected, 4, `期望拒绝 4 行，实际 ${res.rejected}`);

  // 行号必须对应源文件（含表头），否则用户回 Excel 定位会错位
  assert.equal(res.rows[0].row, 2, '第一行数据应对应源文件第 2 行');

  const byRow = new Map(res.rows.map((r) => [r.row, r]));
  assert.equal(byRow.get(2).accepted, true, '第 2 行应被接收');
  assert.equal(byRow.get(2).userNo, '1002');
  assert.match(byRow.get(3).reason, /学号格式/, `第 3 行：${byRow.get(3).reason}`);
  assert.match(byRow.get(4).reason, /已存在该学号/, `第 4 行：${byRow.get(4).reason}`);
  assert.match(byRow.get(5).reason, /缺少姓名/, `第 5 行：${byRow.get(5).reason}`);
  assert.match(byRow.get(6).reason, /手机号/, `第 6 行：${byRow.get(6).reason}`);
  assert.equal(byRow.get(7).accepted, true, '第 7 行应被接收');

  // 合法行必须真的入库，错误行不得入库
  assert.ok(findParticipant(fx.id, '1002'), '1002 应入库');
  assert.ok(findParticipant(fx.id, '1005'), '1005 应入库');
  assert.equal(findParticipant(fx.id, 'imp'), null, '格式错误的行不应入库');
  // 重复行不得改动既有记录
  const p1001 = findParticipant(fx.id, '1001');
  assert.equal(p1001.name, '用户1001');
  assert.equal(p1001.phoneSuffix, null, '重复行不应把粘贴的手机号写进库里');

  cleanup(fx.id);
});

test('导入时姓名与既有记录不符 → 标为「待确认」而不是丢弃（§14.1-2）', () => {
  // 库里已有手机号后四位，但这次粘贴的姓名与后四位都对不上 → 必须标待确认。
  const fx = makeFixture({ participants: ['1101'], phones: ['13800001234'] });
  const p = findParticipant(fx.id, '1101');
  assert.equal(p.phoneSuffix, '1234', '夹具应带手机号后四位，否则测不到二次校验');

  const res = api.importParticipants(
    ctx({
      params: { id: fx.id },
      body: { rows: [['1101', '完全不同的名字', '13900009999']] },
      auth: adminAuth(),
    }),
  );
  assert.equal(res.pendingConfirm, 1, `期望 1 行待确认，实际 ${res.pendingConfirm}`);
  const row = res.rows.find((r) => r.userNo === '1101');
  assert.equal(row.accepted, true, '待确认的行仍然入库，只是标记出来');
  assert.equal(row.status, 'pending_confirm');
  assert.match(row.reason, /不一致/);
  // 记录必须保留，交由发布者判断
  assert.ok(findParticipant(fx.id, '1101'), '不应丢弃该行');

  cleanup(fx.id);
});

test('导入时姓名与手机号后四位都能对上且无新信息 → 报活动内重复，不改动既有记录', () => {
  const fx = makeFixture({ participants: ['1102'], phones: ['13800005678'] });
  const before = findParticipant(fx.id, '1102');

  const res = api.importParticipants(
    ctx({
      params: { id: fx.id },
      body: { rows: [['1102', '用户1102', '13800005678']] },
      auth: adminAuth(),
    }),
  );
  // 重导一遍同一份 Excel：这行不带来任何新信息，必须报重复，
  // 而不是悄悄让它"成功"，否则发布者会以为自己导入成功了两次。
  assert.equal(res.accepted, 0);
  assert.equal(res.rejected, 1);
  assert.equal(res.pendingConfirm, 0);
  assert.match(res.rows[0].reason, /已存在该学号/);

  const after = findParticipant(fx.id, '1102');
  assert.equal(after.name, before.name);
  assert.equal(after.phoneSuffix, before.phoneSuffix);

  cleanup(fx.id);
});

test('导入补上库里缺失的手机号后四位 → 接受并更新（有新增信息，不算重复）', () => {
  const fx = makeFixture({ participants: ['1103'] }); // 库里没有手机号
  const res = api.importParticipants(
    ctx({
      params: { id: fx.id },
      body: { rows: [['1103', '用户1103', '13800009999']] },
      auth: adminAuth(),
    }),
  );
  assert.equal(res.accepted, 1, `实际 ${JSON.stringify(res.rows)}`);
  assert.equal(res.rows[0].status, 'signed');
  assert.equal(findParticipant(fx.id, '1103').phoneSuffix, '9999', '后四位应被补齐');
  cleanup(fx.id);
});

test('导入的手机号后四位与库里冲突 → 标待确认，不覆盖既有值', () => {
  const fx = makeFixture({ participants: ['1104'], phones: ['13800001111'] });
  const res = api.importParticipants(
    ctx({
      params: { id: fx.id },
      body: { rows: [['1104', '用户1104', '13800002222']] },
      auth: adminAuth(),
    }),
  );
  assert.equal(res.pendingConfirm, 1, `实际 ${JSON.stringify(res.rows)}`);
  assert.equal(res.rows[0].status, 'pending_confirm');
  assert.equal(
    findParticipant(fx.id, '1104').phoneSuffix,
    '1111',
    '冲突时不得用粘贴值覆盖库里的既有值',
  );
  cleanup(fx.id);
});

test('导入支持纯文本与空行、行尾空白混乱', () => {
  const fx = makeFixture({ participants: [] });
  const res = api.importParticipants(
    ctx({
      params: { id: fx.id },
      body: {
        // 混合分隔符（空格+逗号 / 分号 / Tab）、空行、行尾多余空白
        text: '  w001 ,  张三  ,13800001111\n\nw002;李四;13800002222\n   \nw003\t王五\t\n',
      },
      auth: adminAuth(),
    }),
  );
  assert.equal(res.accepted, 3, `期望 3 行，实际 ${res.accepted}：${JSON.stringify(res.rows)}`);
  assert.ok(
    res.rows.some((r) => r.userNo === 'w001' && r.name === '张三'),
    '空格+逗号分隔应被正确解析',
  );
  assert.ok(res.rows.some((r) => r.userNo === 'w002' && r.name === '李四'), '分号分隔应被解析');
  assert.ok(res.rows.some((r) => r.userNo === 'w003' && r.name === '王五'), 'Tab 分隔应被解析');
  cleanup(fx.id);
});

test('移出名单是软删除：历史记录保留，标注已移出', () => {
  const fx = makeFixture({ participants: ['0031'] });
  const res = api.removeParticipant(
    ctx({ params: { id: fx.id, userNo: '0031' }, auth: adminAuth() }),
  );
  assert.ok(res.item, JSON.stringify(res));
  assert.equal(res.item.signupStatus, 'cancelled');
  assert.ok(res.item.removedAt, '应记录移出时间');
  assert.equal(res.historicalRecordsKept, true);
  assert.ok(findParticipant(fx.id, '0031'), '记录不应被物理删除');
  cleanup(fx.id);
});

test('移出名单后该人的未发生抽查被豁免', () => {
  const fx = makeFixture({ participants: ['0032'], checkedIn: true });
  const res = api.removeParticipant(
    ctx({ params: { id: fx.id, userNo: '0032' }, auth: adminAuth() }),
  );
  assert.ok(res.excusedTasks > 0, '应豁免未发生的抽查');
  const tasks = store.db.attendanceTasks.filter((t) => t.activityId === fx.id && t.userNo === '0032');
  assert.ok(tasks.every((t) => t.status === TASK_STATUS.EXCUSED));
  cleanup(fx.id);
});

test('验收 A9：学号 + 一次性邀请码绑定成功并签发设备令牌', () => {
  const fx = makeFixture({ participants: ['0101'] });
  const issued = api.issueInviteCodes(
    ctx({ params: { id: fx.id }, body: {}, auth: adminAuth() }),
  );
  const code = issued.items[0].inviteCode;
  assert.ok(code, '应返回明文邀请码');

  const res = api.volunteerBind(
    ctx({
      body: {
        activityId: fx.id,
        userNo: '0101',
        inviteCode: code,
        name: '用户0101',
        deviceId: 'device-A',
      },
    }),
  );
  assert.ok(res.token, JSON.stringify(res));
  assert.equal(res.userNo, '0101');

  // 授权到期 = 活动结束 + 留存期
  const expected = addMinutes(new Date(fx.endTime), 7 * 24 * 60);
  assert.ok(
    Math.abs(new Date(res.expiresAt) - expected) < 60_000,
    `授权到期时间不符：${res.expiresAt}`,
  );

  cleanup(fx.id);
});

test('一次性邀请码用过即失效', () => {
  const fx = makeFixture({ participants: ['0102'] });
  const issued = api.issueInviteCodes(ctx({ params: { id: fx.id }, body: {}, auth: adminAuth() }));
  const code = issued.items[0].inviteCode;

  api.volunteerBind(
    ctx({ body: { activityId: fx.id, userNo: '0102', inviteCode: code, deviceId: 'device-B' } }),
  );
  const again = api.volunteerBind(
    ctx({ body: { activityId: fx.id, userNo: '0102', inviteCode: code, deviceId: 'device-C' } }),
  );
  assert.equal(again.__error.code, ERR.INVITE_CODE_INVALID);
  cleanup(fx.id);
});

/*
  同一设备重试绑定必须幂等（真机回归）。

  ## 现象

  真机上首次绑定因网络抖动**超时**，客户端显示「网络超时」。
  但服务端其实**已经绑定成功**（邀请码消费、grant 签发、名单绑定全部落库）。
  用户重试 → 「该邀请码已被使用」→ **永久锁死**，只能找发布者重新发码。

  一次网络抖动就能把用户锁在门外，而服务端明明已经准备好了授权。

  ## 现在的口径

  邀请码已被使用时，先看是不是**同一设备 + 同一学号**在用：

  * 是 → 幂等返回既有 grant（`idempotentReplay: true`）；
  * 否 → 仍然拒绝，一次性语义不变（见上一条测试）。

  安全上等价：deviceId 本身就是绑定凭据，能复现它说明还是那台机器。
*/
test('同一设备重试绑定 → 幂等返回原授权，而不是「邀请码已被使用」', () => {
  const fx = makeFixture({ participants: ['0105'] });
  const issued = api.issueInviteCodes(ctx({ params: { id: fx.id }, body: {}, auth: adminAuth() }));
  const code = issued.items.find((i) => i.userNo === '0105').inviteCode;

  // 首次绑定（服务端成功，但假设响应在网络上丢了）
  const first = api.volunteerBind(
    ctx({ body: { activityId: fx.id, userNo: '0105', inviteCode: code, deviceId: 'device-phone' } }),
  );
  assert.ok(first.token, `首次绑定应签发令牌，实际：${JSON.stringify(first).slice(0, 200)}`);

  // 用户重试：同设备、同学号、同码
  const retry = api.volunteerBind(
    ctx({ body: { activityId: fx.id, userNo: '0105', inviteCode: code, deviceId: 'device-phone' } }),
  );

  assert.ok(
    !retry.__error,
    `同一设备重试必须能拿回授权，否则用户被永久锁死。实际：${JSON.stringify(retry).slice(0, 250)}`,
  );
  assert.equal(retry.token, first.token, '应返回同一个令牌（幂等，而不是签发新的）');
  assert.equal(retry.idempotentReplay, true, '应标记为幂等重放，便于排障');

  cleanup(fx.id);
});

test('邀请码与学号必须配对（一对一私发）', () => {
  const fx = makeFixture({ participants: ['0103', '0104'] });
  const issued = api.issueInviteCodes(ctx({ params: { id: fx.id }, body: {}, auth: adminAuth() }));
  const codeForV003 = issued.items.find((i) => i.userNo === '0103').inviteCode;

  const res = api.volunteerBind(
    ctx({
      body: { activityId: fx.id, userNo: '0104', inviteCode: codeForV003, deviceId: 'device-C' },
    }),
  );
  assert.equal(res.__error.code, ERR.INVITE_CODE_INVALID);
  assert.match(res.__error.message, /不属于此学号/);
  cleanup(fx.id);
});

test('验收 A10：非名单用户绑定 → 明确提示且不泄露名单', () => {
  const fx = makeFixture({ participants: ['0105'] });
  // 有合法邀请码但不在名单
  store.db.inviteCodes.push({
    activityId: fx.id,
    userNo: 'outsider',
    name: '外人',
    code: 'OUTSIDER1',
    issuedAt: iso(new Date()),
    expiresAt: iso(addMinutes(new Date(), 60)),
    usedAt: null,
  });

  const res = api.volunteerBind(
    ctx({
      body: {
        activityId: fx.id,
        userNo: 'outsider',
        inviteCode: 'OUTSIDER1',
        deviceId: 'device-D',
      },
    }),
  );
  assert.equal(res.__error.code, ERR.NOT_IN_PARTICIPANT_LIST);
  assert.equal(res.__error.message, '你不在本次活动名单中');

  // 无效邀请码的提示不能暴露"这个学号在不在名单里"
  const noCode = api.volunteerBind(
    ctx({
      body: { activityId: fx.id, userNo: '0105', inviteCode: 'BADCODE1', deviceId: 'device-D' },
    }),
  );
  assert.equal(noCode.__error.code, ERR.INVITE_CODE_INVALID);

  cleanup(fx.id);
});

test('二次校验：姓名与手机号后四位都不匹配 → 20006，且不消耗邀请码', () => {
  const fx = makeFixture({ participants: ['0106'] });
  const p = findParticipant(fx.id, '0106');
  p.phoneSuffix = '1003';
  const issued = api.issueInviteCodes(ctx({ params: { id: fx.id }, body: {}, auth: adminAuth() }));
  const code = issued.items[0].inviteCode;

  const res = api.volunteerBind(
    ctx({
      body: {
        activityId: fx.id,
        userNo: '0106',
        inviteCode: code,
        name: '冒名顶替',
        phoneSuffix: '0000',
        deviceId: 'device-E',
      },
    }),
  );
  assert.equal(res.__error.code, ERR.IDENTITY_MISMATCH);

  // 二次校验失败不应消耗邀请码，否则志愿者会被彻底卡住
  const invite = store.db.inviteCodes.find(
    (c) => c.activityId === fx.id && c.userNo === '0106',
  );
  assert.equal(invite.usedAt, null, '校验失败不应消耗邀请码');

  cleanup(fx.id);
});

test('二次校验：姓名匹配即可通过（手机号后四位非必填）', () => {
  const fx = makeFixture({ participants: ['0107'] });
  const issued = api.issueInviteCodes(ctx({ params: { id: fx.id }, body: {}, auth: adminAuth() }));
  const res = api.volunteerBind(
    ctx({
      body: {
        activityId: fx.id,
        userNo: '0107',
        inviteCode: issued.items[0].inviteCode,
        name: '用户0107',
        deviceId: 'device-E2',
      },
    }),
  );
  assert.ok(res.token, JSON.stringify(res));
  cleanup(fx.id);
});

test('邀请码接口返回明文仅在签发时；查询接口只返回掩码', () => {
  const fx = makeFixture({ participants: ['0108'] });
  const issued = api.issueInviteCodes(ctx({ params: { id: fx.id }, body: {}, auth: adminAuth() }));
  assert.ok(issued.items[0].inviteCode, '签发时应返回明文');
  assert.equal(issued.displayOnce, true);
  assert.match(issued.warning, /一对一私发/);

  const listed = api.listInviteCodes(ctx({ params: { id: fx.id }, auth: adminAuth() }));
  for (const it of listed.items) {
    assert.ok(!('inviteCode' in it), '查询接口不应返回明文');
    assert.match(it.masked, /\*\*\*\*/);
  }
  cleanup(fx.id);
});

test('已绑定的人重新签发邀请码会被跳过', () => {
  const fx = makeFixture({ participants: ['0109'] });
  const issued = api.issueInviteCodes(ctx({ params: { id: fx.id }, body: {}, auth: adminAuth() }));
  api.volunteerBind(
    ctx({
      body: {
        activityId: fx.id,
        userNo: '0109',
        inviteCode: issued.items[0].inviteCode,
        deviceId: 'device-F',
      },
    }),
  );
  const again = api.issueInviteCodes(ctx({ params: { id: fx.id }, body: {}, auth: adminAuth() }));
  assert.equal(again.items.length, 0, '已绑定的人不应再签发');
  assert.equal(again.skipped.length, 1);
  assert.match(again.skipped[0].reason, /已绑定/);
  cleanup(fx.id);
});

// ═════════════════════════════════════════════════════════════════════════
section('§5.3 / §6.1 / §6.4 签到提交（验收 A11 / A13 / A15 / A23）');
// ═════════════════════════════════════════════════════════════════════════

test('验收 A11：围栏内 ≤50m → success，评分 ≥60', () => {
  const fx = makeFixture({ participants: ['0201'] });
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload(),
      auth: volunteerAuth('0201', fx.id),
      headers: { 'idempotency-key': `k-a11-${fx.id}` },
    }),
  );
  assert.ok(res.checkin, JSON.stringify(res));
  assert.equal(res.checkin.status, CHECKIN_STATUS.SUCCESS);
  assert.ok(res.checkin.score >= 60, `评分应 ≥60，实际 ${res.checkin.score}`);
  assert.ok(res.scoreBreakdown.length > 0, '应返回评分构成供管理端复核展示');
  cleanup(fx.id);
});

test('验收 A13：开启模拟定位后签到 → 强制 pending_review，不自动通过', () => {
  const fx = makeFixture({ participants: ['0202'] });
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload({ mockLocationDetected: true }),
      auth: volunteerAuth('0202', fx.id),
      headers: { 'idempotency-key': `k-a13-${fx.id}` },
    }),
  );
  assert.ok(res.checkin, JSON.stringify(res));
  assert.equal(res.checkin.status, CHECKIN_STATUS.PENDING_REVIEW);
  assert.equal(res.checkin.mockLocationDetected, true);
  assert.match(res.checkin.reason, /模拟定位/);
  cleanup(fx.id);
});

test('验收 A23：同一幂等键重复提交不产生重复记录', () => {
  const fx = makeFixture({ participants: ['0203'] });
  const payload = gpsPayload();
  const key = `k-a23-${fx.id}`;

  const first = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: payload,
      auth: volunteerAuth('0203', fx.id),
      headers: { 'idempotency-key': key },
    }),
  );
  const countAfterFirst = store.db.checkins.filter((c) => c.activityId === fx.id).length;

  const second = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: payload,
      auth: volunteerAuth('0203', fx.id),
      headers: { 'idempotency-key': key },
    }),
  );
  const countAfterSecond = store.db.checkins.filter((c) => c.activityId === fx.id).length;

  assert.equal(countAfterSecond, countAfterFirst, '不应产生重复记录');
  assert.equal(second.idempotentReplay, true, '应命中幂等缓存');
  assert.equal(second.checkin.id, first.checkin.id);

  // 同键不同内容 → 10002
  const conflict = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload({ accuracy: 33 }),
      auth: volunteerAuth('0203', fx.id),
      headers: { 'idempotency-key': key },
    }),
  );
  assert.equal(conflict.__error.code, ERR.IDEMPOTENCY_CONFLICT);

  cleanup(fx.id);
});

test('同一活动同一用户只有一条有效签到（重复点击幂等返回）', () => {
  const fx = makeFixture({ participants: ['0204'] });
  const first = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload(),
      auth: volunteerAuth('0204', fx.id),
      headers: { 'idempotency-key': `k-dup1-${fx.id}` },
    }),
  );
  const second = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload(),
      auth: volunteerAuth('0204', fx.id),
      headers: { 'idempotency-key': `k-dup2-${fx.id}` },
    }),
  );
  assert.equal(second.alreadyCheckedIn, true);
  assert.equal(second.checkin.id, first.checkin.id);
  assert.equal(store.db.checkins.filter((c) => c.activityId === fx.id).length, 1);
  cleanup(fx.id);
});

test('验收 A15：离线补传一律 pending_review，不因证据强而自动通过', () => {
  const fx = makeFixture({ participants: ['0205'] });
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload({ offlineBackfill: true }),
      auth: volunteerAuth('0205', fx.id),
      headers: { 'idempotency-key': `k-a15-${fx.id}` },
    }),
  );
  assert.ok(res.checkin, JSON.stringify(res));
  assert.equal(res.checkin.status, CHECKIN_STATUS.PENDING_REVIEW);
  assert.match(res.checkin.reason, /离线补传/);
  assert.equal(res.checkin.offlineBackfill, true);
  cleanup(fx.id);
});

test('§6.4：服务端同时保存 clientTime 与 serverTime', () => {
  const fx = makeFixture({ participants: ['0206'] });
  api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload({ clientTime: iso(addMinutes(new Date(), -3)) }),
      auth: volunteerAuth('0206', fx.id),
      headers: { 'idempotency-key': `k-times-${fx.id}` },
    }),
  );
  const rec = store.db.checkins.find((c) => c.activityId === fx.id);
  assert.ok(rec.clientTime, '应保存客户端时间');
  assert.ok(rec.serverTime, '应保存服务端时间');
  assert.notEqual(rec.clientTime, rec.serverTime, '两者应各自保留，不互相覆盖');
  cleanup(fx.id);
});

test('不在签到时段内（活动未开始）被拒绝并给出开放时间', () => {
  const fx = makeFixture({ participants: ['0207'], startOffsetMinutes: 240, durationMinutes: 120 });
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload(),
      auth: volunteerAuth('0207', fx.id),
      headers: { 'idempotency-key': `k-early-${fx.id}` },
    }),
  );
  assert.equal(res.__error.code, ERR.OUTSIDE_CHECKIN_WINDOW);
  assert.match(res.__error.message, /签到将于/);
  cleanup(fx.id);
});

test('非名单用户签到被拒绝（验收 A10 的签到侧）', () => {
  const fx = makeFixture({ participants: ['0208'] });
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload(),
      auth: volunteerAuth('not-in-list', fx.id),
      headers: { 'idempotency-key': `k-outsider-${fx.id}` },
    }),
  );
  assert.equal(res.__error.code, ERR.NOT_IN_PARTICIPANT_LIST);
  cleanup(fx.id);
});

test('志愿者不能给别人的活动签到（跨活动授权隔离）', () => {
  const fx = makeFixture({ participants: ['0209'] });
  const other = makeFixture({ participants: ['0209'] });
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload(),
      auth: volunteerAuth('0209', other.id),
      headers: { 'idempotency-key': `k-cross-${fx.id}` },
    }),
  );
  assert.equal(res.__error.code, ERR.GRANT_EXPIRED);
  cleanup(fx.id);
  cleanup(other.id);
});

// ═════════════════════════════════════════════════════════════════════════
section('§4.8 人工复核与看板');
// ═════════════════════════════════════════════════════════════════════════

test('驳回必须填备注', () => {
  const fx = makeFixture({ participants: ['0301'] });
  api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload({ mockLocationDetected: true }),
      auth: volunteerAuth('0301', fx.id),
      headers: { 'idempotency-key': `k-rv-${fx.id}` },
    }),
  );
  const pending = store.db.checkins.find((c) => c.activityId === fx.id);
  assert.equal(pending.status, CHECKIN_STATUS.PENDING_REVIEW);

  const res = api.reviewCheckin(
    ctx({ params: { checkinId: pending.id }, body: { decision: 'reject' }, auth: adminAuth() }),
  );
  assert.equal(res.__error.code, ERR.BAD_REQUEST);
  assert.ok(res.__error.errors.some((e) => e.field === 'note'));
  cleanup(fx.id);
});

test('复核通过后计入已签到；复核驳回后不计入', () => {
  const fx = makeFixture({ participants: ['0302', '0303'] });
  for (const u of ['0302', '0303']) {
    api.submitCheckin(
      ctx({
        params: { id: fx.id },
        body: gpsPayload({ mockLocationDetected: true }),
        auth: volunteerAuth(u, fx.id),
        headers: { 'idempotency-key': `k-rv-${u}-${fx.id}` },
      }),
    );
  }
  const checkins = store.db.checkins.filter((c) => c.activityId === fx.id);

  const approve = api.reviewCheckin(
    ctx({
      params: { checkinId: checkins[0].id },
      body: { decision: 'approve', note: '现场已核对，确实在场' },
      auth: adminAuth(),
    }),
  );
  assert.equal(approve.checkin.status, CHECKIN_STATUS.SUCCESS);
  assert.equal(approve.checkin.reviewedBy, OWNER);
  assert.match(approve.checkin.reviewNote, /现场已核对/);

  const reject = api.reviewCheckin(
    ctx({
      params: { checkinId: checkins[1].id },
      body: { decision: 'reject', note: '定位显示在校外' },
      auth: adminAuth(),
    }),
  );
  assert.equal(reject.checkin.status, CHECKIN_STATUS.REJECTED);

  // 已复核的记录不能再次复核
  const again = api.reviewCheckin(
    ctx({ params: { checkinId: checkins[1].id }, body: { decision: 'approve' }, auth: adminAuth() }),
  );
  assert.equal(again.__error.code, ERR.ACTIVITY_STATE_INVALID);

  cleanup(fx.id);
});

test('看板四态计数与名单总和一致', () => {
  const fx = makeFixture({ participants: ['0401', '0402', '0403', '0404'] });
  // bd1 正常签到；bd2 待复核；bd3 未签到；bd4 移出
  api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload(),
      auth: volunteerAuth('0401', fx.id),
      headers: { 'idempotency-key': `k-bd1-${fx.id}` },
    }),
  );
  api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload({ mockLocationDetected: true }),
      auth: volunteerAuth('0402', fx.id),
      headers: { 'idempotency-key': `k-bd2-${fx.id}` },
    }),
  );
  api.removeParticipant(ctx({ params: { id: fx.id, userNo: '0404' }, auth: adminAuth() }));

  const board = api.activityBoard(ctx({ params: { id: fx.id }, auth: adminAuth() }));
  assert.equal(board.checkedIn, 1);
  assert.equal(board.pendingReview, 1);
  assert.equal(board.notCheckedIn, 1);
  assert.equal(board.removed, 1);
  const active = board.checkedIn + board.pendingReview + board.notCheckedIn;
  assert.equal(active, 3, '三态之和应等于有效名单人数');

  // 一键筛出未签到者
  const notChecked = api.listParticipants(
    ctx({ params: { id: fx.id }, query: { filter: 'not_checked_in' }, auth: adminAuth() }),
  );
  assert.equal(notChecked.total, 1);
  assert.equal(notChecked.items[0].userNo, '0403');

  cleanup(fx.id);
});

test('看板带免责声明（考勤只作参考，不自动扣减）', () => {
  const fx = makeFixture();
  const board = api.activityBoard(ctx({ params: { id: fx.id }, auth: adminAuth() }));
  assert.match(board.disclaimer, /仅作现场管理参考/);
  assert.match(board.disclaimer, /不自动产生任何扣减/);
  cleanup(fx.id);
});

test('现场点名补录：记录操作人，标注 method=manual', () => {
  const fx = makeFixture({ participants: ['0501'] });
  const res = api.manualCheckin(
    ctx({
      params: { id: fx.id },
      body: { userNo: '0501', note: '现场点名确认到场' },
      auth: adminAuth(),
    }),
  );
  assert.ok(res.checkin, JSON.stringify(res));
  assert.equal(res.checkin.method, 'manual');
  assert.equal(res.checkin.status, CHECKIN_STATUS.SUCCESS);
  assert.match(res.checkin.reason, /现场点名确认到场/);
  cleanup(fx.id);
});

// ═════════════════════════════════════════════════════════════════════════
section('§5.4 / §6.2 在岗确认（验收 A17 / A18 / A19）');
// ═════════════════════════════════════════════════════════════════════════

test('验收 A17：点开通知 → 自动定位上报 → task=done，零输入', () => {
  const fx = makeFixture({ participants: ['0041'], activeTaskSeq: 2, checkedIn: true });
  const task = store.db.attendanceTasks.find(
    (t) => t.activityId === fx.id && t.userNo === '0041' && Number(t.seq) === 2,
  );

  const payload = { geoLat: base.lat + 0.00005, geoLng: base.lng + 0.00005, accuracy: 15 };
  const key = `k-a17-${fx.id}`;

  const res = api.respondAttendance(
    ctx({
      params: { id: fx.id, taskId: task.id },
      body: payload,
      auth: volunteerAuth('0041', fx.id),
      headers: { 'idempotency-key': key },
    }),
  );
  assert.ok(res.task, JSON.stringify(res));
  assert.equal(res.task.status, TASK_STATUS.DONE);
  assert.ok(res.task.respondedAt);
  // 通知时刻必须被记录：用于区分「人不在」与「通知没到」
  assert.ok(res.task.notifiedAt, '应记录通知时刻');
  // 零输入：请求体里只有自动采集的定位，没有任何需要用户填写的字段
  assert.deepEqual(Object.keys(payload).sort(), ['accuracy', 'geoLat', 'geoLng']);

  // 幂等重放：**必须用同一份证据体**，否则是"同键不同内容"，应报 10002。
  const replay = api.respondAttendance(
    ctx({
      params: { id: fx.id, taskId: task.id },
      body: payload,
      auth: volunteerAuth('0041', fx.id),
      headers: { 'idempotency-key': key },
    }),
  );
  assert.equal(replay.idempotentReplay, true, '同键同内容应命中幂等缓存');
  assert.equal(replay.task.status, TASK_STATUS.DONE);

  // 换一个幂等键重复响应：已完成的重复点击应幂等返回，而不是报错
  const again = api.respondAttendance(
    ctx({
      params: { id: fx.id, taskId: task.id },
      body: payload,
      auth: volunteerAuth('0041', fx.id),
      headers: { 'idempotency-key': `k-a17b-${fx.id}` },
    }),
  );
  assert.equal(again.alreadyDone, true, '重复点击不应报错');

  cleanup(fx.id);
});

test('验收 A19：只点按「我在」而无定位证据 → 不通过', () => {
  const fx = makeFixture({ participants: ['0042'], activeTaskSeq: 2, checkedIn: true });
  const task = store.db.attendanceTasks.find(
    (t) => t.activityId === fx.id && t.userNo === '0042' && Number(t.seq) === 2,
  );

  const res = api.respondAttendance(
    ctx({
      params: { id: fx.id, taskId: task.id },
      body: {},
      auth: volunteerAuth('0042', fx.id),
      headers: { 'idempotency-key': `k-a19-${fx.id}` },
    }),
  );
  assert.equal(res.__error.code, ERR.BAD_REQUEST);
  assert.match(res.__error.message, /定位证据/);

  const after = store.db.attendanceTasks.find((t) => t.id === task.id);
  assert.notEqual(after.status, TASK_STATUS.DONE, '不得算作完成');
  cleanup(fx.id);
});

/*
  在岗确认的报文形状（真机回归）。

  ## 现象

  真机上点「我在现场」永远失败：
  「未收到定位证据，无法完成在岗确认。请确认已开启定位权限后重试。」

  而定位权限是开着的、定位也采到了。

  ## 原因

  客户端按契约发**嵌套**结构：

      { method: 'geo',
        location: { lat, lng, accuracy },
        device: { mockLocationDetected },
        samples: [...] }

  而 `respondAttendance` 读的是**扁平**的 `ctx.body.geoLat` / `ctx.body.accuracy`，
  恒为 undefined → 永远判成"没有定位证据"。

  签到接口早就有 `normalizeCheckinPayload` 处理嵌套，确认接口却各写一套。
  现在两个接口共用同一套归一化。

  ## 为什么必须锁住

  "接口读错字段"不会语法报错、不会 500，只会静默地把
  有效证据判成缺失 —— 单测如果只按扁平形状构造请求体，
  就永远和真实客户端对不上。
*/
test('在岗确认：接受契约的嵌套 location 报文（而不是只认扁平 geoLat）', () => {
  const fx = makeFixture({ participants: ['0045'], activeTaskSeq: 2, checkedIn: true });
  const task = store.db.attendanceTasks.find(
    (t) => t.activityId === fx.id && t.userNo === '0045' && Number(t.seq) === 2,
  );

  const res = api.respondAttendance(
    ctx({
      // ⚠️ 这里刻意只传 taskId：真实路由也不会给活动 id（见参数名漂移守卫）。
      params: { taskId: task.id },
      // 完全按客户端真实报文形状构造。
      body: {
        method: 'geo',
        location: { lat: base.lat, lng: base.lng, accuracy: 20 },
        device: { mockLocationDetected: false },
        samples: [
          { lat: base.lat, lng: base.lng, accuracy: 20, capturedAt: iso(new Date()) },
        ],
      },
      auth: volunteerAuth('0045', fx.id),
      headers: { 'idempotency-key': `k-att-nested-${fx.id}` },
    }),
  );

  assert.equal(
    res.task?.status,
    TASK_STATUS.DONE,
    `嵌套报文应被正确解析；实际返回：${JSON.stringify(res).slice(0, 200)}`,
  );
  assert.equal(res.task.geoLat, base.lat);

  const after = store.db.attendanceTasks.find((t) => t.id === task.id);
  assert.equal(after.status, TASK_STATUS.DONE);
  cleanup(fx.id);
});

/*
  防脱岗抽查不能被"预先点掉"（真机回归）。

  ## 现象

  抽查任务在志愿者签到时就把后续所有时段（T+15 / T+45 / T+75）预创建好了。
  真机上点「我在现场」时，服务端只拦了"已过期"，**没拦"还没到点"** ——
  于是志愿者可以把所有未来的抽查一次性全部确认掉，
  然后人离开场地也不会被查出脱岗。防脱岗抽查完全失效。

  真机复现：活动 13:25 开始，第 3 次抽查计划 14:40，
  14:03 点一下就变成 `done`。

  ## 现在的口径

  只在 [scheduledAt, deadlineAt] 内允许确认。
  deadline 那侧由 settleOverdueTasks 负责，scheduledAt 这侧必须显式校验。
*/
test('在岗确认：未到计划时刻不得提前确认（防脱岗抽查不能被预先点掉）', () => {
  // activeTaskSeq 传 null：不要把这个夹具的任务挪到"当前窗口"，
  // 这样 seq=3 保持在真实的未来时刻。
  const fx = makeFixture({ participants: ['0046'], activeTaskSeq: null, checkedIn: true });
  const future = store.db.attendanceTasks.find(
    (t) => t.activityId === fx.id && t.userNo === '0046' && Number(t.seq) === 3,
  );
  assert.ok(future, 'fixture 必须生成 seq=3 的任务');
  assert.ok(
    new Date(future.scheduledAt).getTime() > Date.now(),
    '夹具前提：seq=3 的计划时刻应在未来',
  );

  const res = api.respondAttendance(
    ctx({
      params: { taskId: future.id },
      body: { location: { lat: base.lat, lng: base.lng, accuracy: 20 } },
      auth: volunteerAuth('0046', fx.id),
      headers: { 'idempotency-key': `k-early-${fx.id}` },
    }),
  );

  assert.ok(res.__error, '提前确认必须被拒，否则防脱岗抽查形同虚设');
  assert.match(res.__error.message, /尚未开始/);

  const after = store.db.attendanceTasks.find((t) => t.id === future.id);
  assert.equal(after.status, TASK_STATUS.PENDING, '被拒的任务不得变成已完成');
  cleanup(fx.id);
});

test('精度不足时转人工而不是算完成', () => {
  const fx = makeFixture({ participants: ['0043'], activeTaskSeq: 2, checkedIn: true });
  const task = store.db.attendanceTasks.find(
    (t) => t.activityId === fx.id && t.userNo === '0043' && Number(t.seq) === 2,
  );

  const res = api.respondAttendance(
    ctx({
      params: { id: fx.id, taskId: task.id },
      body: { geoLat: base.lat, geoLng: base.lng, accuracy: 250 },
      auth: volunteerAuth('0043', fx.id),
      headers: { 'idempotency-key': `k-a19b-${fx.id}` },
    }),
  );
  assert.ok(res.needsManualReview, JSON.stringify(res));

  const after = store.db.attendanceTasks.find((t) => t.id === task.id);
  assert.notEqual(after.status, TASK_STATUS.DONE, '精度不足不得自动算完成');
  assert.equal(after.needsManualReview, true);
  assert.match(after.reviewNote, /精度/);
  cleanup(fx.id);
});

test('模拟定位在岗响应同样强制转人工', () => {
  const fx = makeFixture({ participants: ['0044'], activeTaskSeq: 2, checkedIn: true });
  const task = store.db.attendanceTasks.find(
    (t) => t.activityId === fx.id && t.userNo === '0044' && Number(t.seq) === 2,
  );
  const res = api.respondAttendance(
    ctx({
      params: { id: fx.id, taskId: task.id },
      body: {
        geoLat: base.lat,
        geoLng: base.lng,
        accuracy: 10,
        mockLocationDetected: true,
      },
      auth: volunteerAuth('0044', fx.id),
      headers: { 'idempotency-key': `k-at4-${fx.id}` },
    }),
  );
  assert.ok(res.needsManualReview);
  assert.match(res.message, /模拟定位/);
  cleanup(fx.id);
});

test('响应窗口外的任务不能响应', () => {
  const fx = makeFixture({ participants: ['0045'], activeTaskSeq: 2, checkedIn: true });
  const task = store.db.attendanceTasks.find(
    (t) => t.activityId === fx.id && t.userNo === '0045' && Number(t.seq) === 2,
  );
  task.deadlineAt = iso(addMinutes(new Date(), -10));

  const res = api.respondAttendance(
    ctx({
      params: { id: fx.id, taskId: task.id },
      body: { geoLat: base.lat, geoLng: base.lng, accuracy: 10 },
      auth: volunteerAuth('0045', fx.id),
      headers: { 'idempotency-key': `k-overdue-${fx.id}` },
    }),
  );
  assert.equal(res.__error.code, ERR.ATTENDANCE_TASK_CLOSED);
  // 惰性结算应已把它置为 missed
  assert.equal(
    store.db.attendanceTasks.find((t) => t.id === task.id).status,
    TASK_STATUS.MISSED,
  );
  cleanup(fx.id);
});

test('验收 A18：超时未响应 → missed，保留通知记录，可从看板人工补录', () => {
  const fx = makeFixture({ participants: ['0046'], checkedIn: true });
  const task = store.db.attendanceTasks.find(
    (t) => t.activityId === fx.id && t.userNo === '0046' && Number(t.seq) === 2,
  );
  // 已过宽限期，且有通知记录
  task.deadlineAt = iso(addMinutes(new Date(), -5));
  task.notifiedAt = iso(addMinutes(new Date(), -6));

  const board = api.activityBoard(ctx({ params: { id: fx.id }, auth: adminAuth() }));
  const after = store.db.attendanceTasks.find((t) => t.id === task.id);
  assert.equal(after.status, TASK_STATUS.MISSED, '过宽限期应置 missed');
  assert.ok(after.notifiedAt, '通知记录必须保留，以区分人不在与通知没到');
  assert.ok(board.attendanceMissed > 0);

  // 人工补录兜底
  const fill = api.manualAttendance(
    ctx({
      params: { id: fx.id },
      body: { userNo: '0046', seq: 2, note: '现场点名确认在岗' },
      auth: adminAuth(),
    }),
  );
  assert.ok(fill.task, JSON.stringify(fill));
  assert.equal(fill.task.status, TASK_STATUS.DONE);
  assert.equal(fill.task.manualFill, true);
  assert.equal(fill.task.filledBy, OWNER);
  assert.equal(fill.previousStatus, TASK_STATUS.MISSED, '应记录补录前的状态以便追溯');

  cleanup(fx.id);
});

test('志愿者只能响应自己的任务', () => {
  const fx = makeFixture({ participants: ['0047', '0048'], activeTaskSeq: 2, checkedIn: true });
  const othersTask = store.db.attendanceTasks.find(
    (t) => t.activityId === fx.id && t.userNo === '0048' && Number(t.seq) === 2,
  );
  const res = api.respondAttendance(
    ctx({
      params: { id: fx.id, taskId: othersTask.id },
      body: { geoLat: base.lat, geoLng: base.lng, accuracy: 10 },
      auth: volunteerAuth('0047', fx.id),
      headers: { 'idempotency-key': `k-notmine-${fx.id}` },
    }),
  );
  assert.equal(res.__error.code, ERR.FORBIDDEN);
  cleanup(fx.id);
});

test('前台轮询接口：志愿者只看到自己的任务，且带服务端时间', () => {
  const fx = makeFixture({ participants: ['0049', '0050'], checkedIn: true });
  const res = api.listAttendanceTasks(
    ctx({ params: { id: fx.id }, auth: volunteerAuth('0049', fx.id) }),
  );
  assert.ok(res.items.length > 0);
  assert.ok(res.items.every((t) => t.userNo === '0049'), '不应看到他人任务');
  assert.ok(res.serverTime, '必须带服务端时间供客户端校正倒计时');
  cleanup(fx.id);
});

test('催办记录明确说明「不启用推送」（不假装能送达）', () => {
  const fx = makeFixture({ participants: ['0051'], checkedIn: true });
  const task = store.db.attendanceTasks.find((t) => t.activityId === fx.id);
  const res = api.remindAttendance(
    ctx({ params: { id: fx.id, taskId: task.id }, auth: adminAuth() }),
  );
  assert.equal(res.deliveryChannel, 'onsite_verbal');
  assert.match(res.message, /不启用推送/);
  assert.equal(res.remindCount, 1);
  cleanup(fx.id);
});

// ═════════════════════════════════════════════════════════════════════════
section('降级手段：不启用动态签到码（决策 D-2）');
// ═════════════════════════════════════════════════════════════════════════
//
// 方案 §6.3 设计了动态签到码。本项目决定不实现，因此这里验证的是
// **拒定位权限时仍有可行路径**，而不是码本身。

test('不再提供动态码端点（能力已移除）', () => {
  assert.equal(api.issueCheckinCode, undefined);
  assert.equal(api.currentCheckinCode, undefined);
});

test('提交 method=code 被明确拒绝，而不是静默按 GPS 处理', () => {
  const fx = makeFixture({ participants: ['0601'] });
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: { method: 'code', checkinCode: '123456', userNo: '0601' },
      auth: volunteerAuth('0601', fx.id),
      headers: { 'idempotency-key': `k-code-${fx.id}` },
    }),
  );
  // 静默按 GPS 处理会产生一条"位置证据为空"的记录，反而更难排查。
  assert.equal(res.__error.code, ERR.BAD_REQUEST);
  assert.match(res.__error.message, /不启用签到码|仅支持定位签到/);
  assert.ok(res.__error.errors.some((e) => e.field === 'method'));
  cleanup(fx.id);
});

test('验收 A16：拒定位权限的降级路径 —— 发布者现场核实', () => {
  const fx = makeFixture({ participants: ['0602'] });

  // 志愿者签不了（没有任何定位证据）→ 转人工，而不是驳回（不得出现死路）
  const denied = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: { method: 'gps', userNo: '0602' },
      auth: volunteerAuth('0602', fx.id),
      headers: { 'idempotency-key': `k-denied-${fx.id}` },
    }),
  );
  assert.ok(denied.checkin, JSON.stringify(denied));
  assert.equal(denied.checkin.status, CHECKIN_STATUS.PENDING_REVIEW);

  // 发布者在管理端现场核实 → 升级为已签到
  const filled = api.manualCheckin(
    ctx({
      params: { id: fx.id },
      body: { userNo: '0602', note: '志愿者定位权限被拒，已现场核实本人在场' },
      auth: adminAuth(),
    }),
  );
  assert.ok(filled.checkin, JSON.stringify(filled));
  assert.equal(filled.checkin.status, CHECKIN_STATUS.SUCCESS);
  assert.equal(filled.upgradedFromPendingReview, true);
  assert.match(filled.checkin.reason, /现场核实/);

  // 关键：不能新增第二条记录，而是把原来那条升级。
  // 同一活动同一用户只能有一条有效签到（方案 §6.1）。
  const recs = store.db.checkins.filter((c) => c.activityId === fx.id && c.userNo === '0602');
  assert.equal(recs.length, 1, '现场核实应升级原记录，而不是插一条新的');

  // method 保留**原始采集方式**，人工介入单独用 verifiedByOwner 标记，
  // 这样审计里仍能看出"最初是定位报上来的、后来被人工核实"。
  //
  // 值用契约词表 `geo`（`gps` 是早期写法，解析层仍兼容，但写入侧已统一）。
  // 关键是它**没有**被改写成 `manual` —— 那会抹掉"最早是靠定位报的"这条信息。
  assert.equal(recs[0].method, CHECKIN_METHOD.GEO, 'method 应保留原始采集方式，不被改写为 manual');
  assert.notEqual(recs[0].method, CHECKIN_METHOD.MANUAL, '人工核实不得覆盖原始采集方式');
  assert.equal(recs[0].verifiedByOwner, true, '人工介入应有独立标记');
  assert.equal(recs[0].reviewedBy, OWNER, '必须记录操作人，可在审计中追溯');
  assert.ok(recs[0].reviewedAt);

  cleanup(fx.id);
});

test('验收 A16：已自动通过的记录再做现场核实是幂等的，不重复也不改写证据', () => {
  const fx = makeFixture({ participants: ['0603'] });
  // 正常定位签到，自动通过
  const first = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload(),
      auth: volunteerAuth('0603', fx.id),
      headers: { 'idempotency-key': `k-ok-${fx.id}` },
    }),
  );
  assert.equal(first.checkin.status, CHECKIN_STATUS.SUCCESS);
  const scoreBefore = first.checkin.score;

  // 发布者又点了一次现场核实
  const filled = api.manualCheckin(
    ctx({ params: { id: fx.id }, body: { userNo: '0603', note: '重复操作' }, auth: adminAuth() }),
  );
  assert.equal(filled.alreadyCheckedIn, true);
  assert.equal(
    filled.checkin.score,
    scoreBefore,
    '已通过的记录不应被人工操作改写评分证据',
  );
  assert.equal(
    store.db.checkins.filter((c) => c.activityId === fx.id).length,
    1,
    '不应产生第二条记录',
  );
  cleanup(fx.id);
});

// ═════════════════════════════════════════════════════════════════════════
section('导出：统一入口直接下载（网页方案 §6.4.8）');
// ═════════════════════════════════════════════════════════════════════════
//
// 契约把导出定义为**一次 GET 拿文件**，不是「建任务 → 轮询 → 下载」。
// 因此测试围绕 `captureCsv` 展开：它替掉 res，把服务端写入的响应捕获下来。

test('管理端导出签到名单：含「仅限内部使用」提示，手机号已脱敏', () => {
  const cap = captureCsv(
    api.exportActivity,
    ctx({
      params: { id: finished.id },
      query: { kind: 'checkin_list' },
      auth: adminAuth(),
    }),
  );

  assert.equal(cap.status, 200);
  assert.match(cap.content, /仅限内部使用/);
  assert.match(cap.content, /138\*\*\*\*/, '手机号应脱敏');
  assert.ok(!/138\d{8}/.test(cap.content), '不应出现完整手机号');
  assert.match(cap.content, /不作为志愿时长认定依据/, '必须带免责说明');
  assert.equal(cap.headers['X-Export-Notice'] !== undefined, true, '应带上使用提示头');
});

test('考勤明细导出包含抽查状态与免责说明', () => {
  const cap = captureCsv(
    api.exportActivity,
    ctx({
      params: { id: finished.id },
      query: { kind: 'attendance_detail' },
      auth: adminAuth(),
    }),
  );
  assert.match(cap.content, /抽查序号/);
  assert.match(cap.content, /是否人工补录/);
  assert.match(cap.content, /考勤汇总/);
  assert.ok(Number(cap.headers['X-Export-Rowcount']) > 0, '应有行数');
});

test('导出响应头：UTF-8 BOM + 中文文件名（否则 Excel 乱码 / 文件名截断）', () => {
  const cap = captureCsv(
    api.exportActivity,
    ctx({ params: { id: finished.id }, query: { kind: 'summary' }, auth: adminAuth() }),
  );
  assert.equal(cap.status, 200);
  assert.match(cap.headers['Content-Type'], /text\/csv/);
  assert.match(cap.headers['Content-Disposition'], /attachment/);
  // 中文文件名必须走 filename*=UTF-8''，裸 filename= 会乱码
  assert.match(
    cap.headers['Content-Disposition'],
    /filename\*=UTF-8''/,
    '中文文件名要用 RFC 5987 形式',
  );
  // UTF-8 BOM
  assert.deepEqual([...cap.body.slice(0, 3)], [0xef, 0xbb, 0xbf]);
});

test('验收（网页 §6.4.8）：用户端仅可导出已结束活动', () => {
  // 未结束 → 拒绝
  const ongoingFx = makeFixture({ participants: ['0701'] });
  const bad = api.exportActivity(
    ctx({
      params: { id: ongoingFx.id },
      query: { kind: 'my_records' },
      auth: { kind: 'volunteer', userNo: '0701', activityId: ongoingFx.id, token: 't' },
    }),
  );
  assert.equal(bad.__error.code, ERR.ACTIVITY_STATE_INVALID);
  cleanup(ongoingFx.id);

  // 已结束 → 只能拿到自己的记录
  const finFx = makeFixture({ participants: ['0702', '0703'], status: 'finished', checkedIn: true });
  const grant = {
    token: 'vol-ex2',
    activityId: finFx.id,
    userNo: '0702',
    name: '用户0702',
    deviceId: 'device-fin',
    expiresAt: iso(addMinutes(new Date(), 60)),
  };
  store.db.grants.push(grant);

  const cap = captureCsv(
    api.exportActivity,
    ctx({
      params: { id: finFx.id },
      query: { kind: 'my_records' },
      auth: { kind: 'volunteer', userNo: '0702', activityId: finFx.id, token: grant.token },
    }),
  );
  assert.match(cap.content, /0702/, '应含本人学号');
  assert.ok(!/0703/.test(cap.content), '不应含他人学号');
  assert.match(cap.content, /免责说明/);

  // 即使请求别的 kind，志愿者也只能拿到自己的记录
  const cap2 = captureCsv(
    api.exportActivity,
    ctx({
      params: { id: finFx.id },
      query: { kind: 'checkin_list' },
      auth: { kind: 'volunteer', userNo: '0702', activityId: finFx.id, token: grant.token },
    }),
  );
  assert.ok(!/0703/.test(cap2.content), 'kind 不应让志愿者越权拿到全量名单');

  cleanup(finFx.id);
});

// ═════════════════════════════════════════════════════════════════════════
section('导出脱敏策略（决策 D-3）');
// ═════════════════════════════════════════════════════════════════════════

test('默认导出脱敏：手机号一律掩码', () => {
  const fx = makeFixture({ participants: ['1301'], phones: ['13800001234'], status: 'finished' });
  const cap = captureCsv(
    api.exportActivity,
    ctx({ params: { id: fx.id }, query: { kind: 'participants' }, auth: adminAuth() }),
  );
  assert.match(cap.content, /138\*\*\*\*1234/);
  assert.ok(!/13800001234/.test(cap.content), '不得出现完整手机号');
  assert.match(cap.content, /仅限内部使用/);
  assert.ok(
    !/本文件含完整联系方式/.test(cap.content),
    '默认脱敏时不应出现"含完整联系方式"的警告（会误导）',
  );
  cleanup(fx.id);
});

test('显式 includeFullContact=true 时输出完整号码，且文件头醒目提示', () => {
  const fx = makeFixture({ participants: ['1302'], phones: ['13800005678'], status: 'finished' });
  const cap = captureCsv(
    api.exportActivity,
    ctx({
      params: { id: fx.id },
      query: { kind: 'participants', includeFullContact: 'true' },
      auth: adminAuth(),
    }),
  );
  assert.match(cap.content, /13800005678/, '显式请求时应输出完整号码');
  assert.match(cap.content, /本文件含完整联系方式/, '文件头必须标注');
  assert.match(cap.content, /请勿外传/, '必须带转发警告');
  cleanup(fx.id);
});

test('导出完整联系方式会写入审计（谁、何时、多少行）', () => {
  const before = (store.db.exportAudits ?? []).length;
  const fx = makeFixture({ participants: ['1303'], phones: ['13800001111'], status: 'finished' });
  captureCsv(
    api.exportActivity,
    ctx({
      params: { id: fx.id },
      query: { kind: 'participants', includeFullContact: 'true' },
      auth: adminAuth(),
    }),
  );

  const audits = store.db.exportAudits ?? [];
  assert.equal(audits.length, before + 1, '敏感导出必须留痕');
  const entry = audits[0];
  assert.equal(entry.activityId, fx.id);
  assert.equal(entry.requestedBy, OWNER);
  assert.equal(entry.includesFullContact, true);
  assert.ok(entry.at, '应记录时间');
  assert.ok(entry.rowCount >= 1, '应记录行数');

  // 通过接口也能查
  const listed = api.exportAudits(ctx({ query: {}, auth: adminAuth() }));
  assert.ok(listed.items.some((e) => e.activityId === fx.id));
  cleanup(fx.id);
});

test('默认脱敏导出**不**进敏感审计（避免淹没正常操作）', () => {
  const before = (store.db.exportAudits ?? []).length;
  const fx = makeFixture({ participants: ['1304'], status: 'finished' });
  captureCsv(
    api.exportActivity,
    ctx({ params: { id: fx.id }, query: { kind: 'summary' }, auth: adminAuth() }),
  );
  assert.equal(
    (store.db.exportAudits ?? []).length,
    before,
    '脱敏导出是常规操作，不该进敏感审计',
  );
  cleanup(fx.id);
});

test('志愿者不能请求导出完整联系方式（越权 40301）', () => {
  const fx = makeFixture({ participants: ['1305'], status: 'finished' });
  const grant = {
    token: 'vol-1305',
    activityId: fx.id,
    userNo: '1305',
    name: '用户1305',
    deviceId: 'd',
    expiresAt: iso(addMinutes(new Date(), 60)),
  };
  store.db.grants.push(grant);

  const res = api.exportActivity(
    ctx({
      params: { id: fx.id },
      query: { kind: 'my_records', includeFullContact: 'true' },
      auth: { kind: 'volunteer', userNo: '1305', activityId: fx.id, token: grant.token },
    }),
  );
  assert.equal(res.__error.code, ERR.FORBIDDEN);
  assert.match(res.__error.message, /仅活动发布者/);
  cleanup(fx.id);
});

test('不支持的导出类型被拒绝并列出可选值', () => {
  const fx = makeFixture({ participants: ['1306'], status: 'finished' });
  const res = api.exportActivity(
    ctx({ params: { id: fx.id }, query: { kind: '不存在的类型' }, auth: adminAuth() }),
  );
  assert.equal(res.__error.code, ERR.BAD_REQUEST);
  assert.ok(res.__error.errors.some((e) => e.field === 'kind'));
  assert.match(res.__error.errors[0].message, /checkin_list/);
  cleanup(fx.id);
});

test('批量导出活动汇总（网页 §6.4.8 第二个入口）', () => {
  const cap = captureCsv(
    api.exportActivities,
    ctx({ query: { status: 'finished', format: 'csv' }, auth: adminAuth() }),
  );
  assert.equal(cap.status, 200);
  assert.match(cap.content, /活动名称/);
  assert.match(cap.content, /已签到/);
  assert.match(cap.content, /仅限内部使用/);
});

test('批量导出按状态过滤生效', () => {
  const cap = captureCsv(
    api.exportActivities,
    ctx({ query: { status: 'cancelled' }, auth: adminAuth() }),
  );
  // 种子里只有一个已取消活动
  assert.match(cap.content, /cancelled/);
  assert.ok(!/finished/.test(cap.content.split('\n').slice(5).join('\n')), '未选的状态不应出现');
});

test('批量导出仅管理端可用', () => {
  const res = api.exportActivities(ctx({ query: {}, auth: null }));
  assert.equal(res.__error.code, ERR.ROLE_NOT_ALLOWED);
});

// ═════════════════════════════════════════════════════════════════════════
section('§6.2 / §14.1 在岗汇总与留存');
// ═════════════════════════════════════════════════════════════════════════

test('考勤汇总：按完成率 0.7 阈值区分 partial 与 insufficient（决策 D-7）', () => {
  const summary = api.attendanceSummaryReport(
    ctx({ params: { id: finished.id }, auth: adminAuth() }),
  );
  assert.match(summary.disclaimer, /仅作现场管理参考/);

  // 种子数据：2023001 全勤；2023002 3 次里超时 1 次（完成率 0.5）
  const full = summary.rows.find((r) => r.userNo === '2023001');
  assert.equal(full.attendanceSummary, 'full', JSON.stringify(full));
  assert.equal(full.attendanceMissed, 0);
  assert.equal(full.attendanceRate, 1);

  // 完成率 0.5 < 0.7 → insufficient（网页方案 §6.4.7 的阈值）。
  // 移动端方案 §4.8 的旧判据（「有 missed 且 done>0」）会把它记成 partial ——
  // 这正是决策 D-7 要修掉的："3 次里完成 1 次" 与 "10 次里完成 8 次" 不该同列。
  const low = summary.rows.find((r) => r.userNo === '2023002');
  assert.equal(low.attendanceSummary, 'insufficient', JSON.stringify(low));
  assert.equal(low.attendanceRate, 0.5);
});

test('考勤汇总：完成率 0.6（<0.7）→ insufficient', () => {
  const fx = makeFixture({ participants: ['2101'], checkedIn: true });
  const tasks = store.db.attendanceTasks
    .filter((t) => t.activityId === fx.id && t.userNo === '2101')
    .sort((a, b) => Number(a.seq) - Number(b.seq));
  assert.equal(tasks.length, 5, `夹具应生成 5 次抽查，实际 ${tasks.length}`);

  // 5 次里完成 3 次 → 0.6 < 0.7 → insufficient
  tasks.slice(0, 3).forEach((t) => {
    t.status = 'done';
    t.respondedAt = iso(new Date());
  });
  tasks.slice(3).forEach((t) => {
    t.status = 'missed';
    t.settledAt = iso(new Date());
  });

  const summary = api.attendanceSummaryReport(ctx({ params: { id: fx.id }, auth: adminAuth() }));
  const row = summary.rows.find((r) => r.userNo === '2101');
  assert.equal(row.attendanceRate, 0.6);
  assert.equal(row.attendanceSummary, 'insufficient', JSON.stringify(row));
  cleanup(fx.id);
});

test('考勤汇总：完成率 0.8（≥0.7）→ partial', () => {
  const fx = makeFixture({ participants: ['2103'], checkedIn: true });
  const tasks = store.db.attendanceTasks
    .filter((t) => t.activityId === fx.id && t.userNo === '2103')
    .sort((a, b) => Number(a.seq) - Number(b.seq));

  // 5 次里完成 4 次 → 0.8 ≥ 0.7 → partial
  tasks.slice(0, 4).forEach((t) => {
    t.status = 'done';
    t.respondedAt = iso(new Date());
  });
  tasks.slice(4).forEach((t) => {
    t.status = 'missed';
    t.settledAt = iso(new Date());
  });

  const summary = api.attendanceSummaryReport(ctx({ params: { id: fx.id }, auth: adminAuth() }));
  const row = summary.rows.find((r) => r.userNo === '2103');
  assert.equal(row.attendanceRate, 0.8);
  assert.equal(row.attendanceSummary, 'partial', JSON.stringify(row));
  cleanup(fx.id);
});

test('未签到者不生成抽查任务，因此不出现在在岗明细里（决策 D-6）', () => {
  const fx = makeFixture({ participants: ['2102'], checkedIn: false });
  const tasks = store.db.attendanceTasks.filter((t) => t.activityId === fx.id);
  assert.equal(
    tasks.length,
    0,
    '只为已签到者生成抽查任务 —— 没到场的人不该被记一串 missed，那只会污染分母',
  );
  const summary = api.attendanceSummaryReport(ctx({ params: { id: fx.id }, auth: adminAuth() }));
  assert.equal(summary.rows.length, 0);
  cleanup(fx.id);
});

test('全部抽查被豁免时记为「证据不足」而不是「缺席」（不冤枉人）', () => {
  const fx = makeFixture({ participants: ['0801'], status: 'finished', checkedIn: true });
  // 夹具已造了成功签到；把全部抽查置为 excused（模拟活动临时取消抽查时段）
  for (const t of store.db.attendanceTasks.filter((t) => t.activityId === fx.id)) {
    t.status = TASK_STATUS.EXCUSED;
  }
  const summary = api.attendanceSummaryReport(ctx({ params: { id: fx.id }, auth: adminAuth() }));
  const row = summary.rows.find((r) => r.userNo === '0801');
  assert.equal(row.attendanceSummary, 'insufficient', JSON.stringify(row));
  assert.equal(row.attendanceRate, null, '无已定案任务时完成率应为 null');
  cleanup(fx.id);
});

test('验收 A21：活动终态 +7 天后不可访问（业务数据视为已销毁）', () => {
  const expired = {
    ...finished,
    id: 'act-expired-test',
    status: 'finished',
    terminalAt: iso(addMinutes(new Date(), -8 * 24 * 60)),
  };
  store.db.activities.push(expired);

  const res = api.getActivity(ctx({ params: { id: 'act-expired-test' }, auth: adminAuth() }));
  assert.equal(res.__error.code, ERR.ACTIVITY_NOT_FOUND, '过期活动应视为不存在');

  const list = api.listActivities(ctx({ query: { onlyMine: 'true' }, auth: adminAuth() }));
  assert.ok(!list.items.some((a) => a.id === 'act-expired-test'), '过期活动不应出现在列表中');

  store.db.activities = store.db.activities.filter((a) => a.id !== 'act-expired-test');
});

test('留存期内的已结束活动仍可访问，并给出销毁时刻', () => {
  const res = api.getActivity(ctx({ params: { id: finished.id }, auth: adminAuth() }));
  assert.ok(res.id, JSON.stringify(res));
  const board = api.activityBoard(ctx({ params: { id: finished.id }, auth: adminAuth() }));
  assert.ok(board.dataDestroyAt, '应给出数据销毁时刻');
  const expected = addMinutes(new Date(finished.terminalAt), 7 * 24 * 60);
  assert.ok(Math.abs(new Date(board.dataDestroyAt) - expected) < 60_000);
});

// ═════════════════════════════════════════════════════════════════════════
section('§5.1 列表筛选与分页');
// ═════════════════════════════════════════════════════════════════════════

test('用户端看不到草稿活动', () => {
  const res = api.listActivities(ctx({ query: {} }));
  assert.ok(!res.items.some((a) => a.status === 'draft'), '草稿不应对外可见');
});

test('管理端默认只看自己名下的活动', () => {
  const res = api.listActivities(ctx({ query: { onlyMine: 'true' }, auth: adminAuth() }));
  assert.ok(res.items.length > 0);
  assert.ok(res.items.every((a) => a.ownerId === OWNER || a.ownerId === undefined));
});

test('关键词筛选命中标题与简介', () => {
  const res = api.listActivities(ctx({ query: { keyword: '图书馆' } }));
  assert.ok(res.items.length >= 1);
  assert.ok(res.items.some((a) => a.title.includes('图书馆')));
});

test('状态多选筛选', () => {
  const res = api.listActivities(ctx({ query: { status: 'finished,cancelled' } }));
  assert.ok(res.items.every((a) => ['finished', 'cancelled'].includes(a.status)));
});

test('时间范围筛选', () => {
  const res = api.listActivities(
    ctx({ query: { startFrom: iso(addMinutes(new Date(), -60 * 24 * 10)) } }),
  );
  for (const a of res.items) {
    assert.ok(new Date(a.startTime) >= addMinutes(new Date(), -60 * 24 * 10));
  }
});

test('分页与 hasMore 正确', () => {
  const page1 = api.listActivities(ctx({ query: { page: '1', pageSize: '2' } }));
  assert.equal(page1.items.length, 2);
  assert.equal(page1.page, 1);
  assert.equal(page1.hasMore, page1.total > 2);
});

test('统计基于筛选后全量，不随翻页跳动', () => {
  const page1 = api.listActivities(ctx({ query: { page: '1', pageSize: '1' } }));
  const page2 = api.listActivities(ctx({ query: { page: '2', pageSize: '1' } }));
  assert.equal(page1.stats.total, page2.stats.total, '统计不应随翻页变化');
  assert.equal(page1.stats.total, page1.total);
});

test('默认按 startTime 倒序（§5.1）', () => {
  const res = api.listActivities(ctx({ query: { pageSize: '50' } }));
  for (let i = 1; i < res.items.length; i++) {
    assert.ok(
      new Date(res.items[i - 1].startTime) >= new Date(res.items[i].startTime),
      '应按 startTime 倒序',
    );
  }
});

test('列表与详情中的联系方式已脱敏', () => {
  const res = api.listActivities(ctx({ query: { pageSize: '50' } }));
  for (const a of res.items) {
    if (!a.contact) {
      continue;
    }
    assert.ok(!/1[3-9]\d{9}/.test(a.contact), `联系方式未脱敏：${a.contact}`);
  }
});

test('志愿者视角的详情不下发 ownerId，并带「我的」状态', () => {
  const fx = makeFixture({ participants: ['0901'] });
  const grant = {
    token: 'vol-mv1',
    activityId: fx.id,
    userNo: '0901',
    name: '用户0901',
    deviceId: 'd',
    expiresAt: iso(addMinutes(new Date(), 60)),
  };
  store.db.grants.push(grant);
  const res = api.getActivity(
    ctx({
      params: { id: fx.id },
      auth: { kind: 'volunteer', userNo: '0901', activityId: fx.id, token: grant.token },
    }),
  );
  assert.equal(res.ownerId, undefined, '不应下发 ownerId');
  assert.equal(res.mySignupStatus, 'signed');
  assert.ok('pendingAttendanceCount' in res);
  cleanup(fx.id);
});

// ═════════════════════════════════════════════════════════════════════════
section('§5.2 / §2 授权与令牌生命周期');
// ═════════════════════════════════════════════════════════════════════════

test('过期授权访问被拒绝（未认证 40101）', () => {
  store.db.grants.push({
    token: 'vol-expired',
    activityId: finished.id,
    userNo: '2023001',
    name: '吴磊',
    deviceId: 'd',
    expiresAt: iso(addMinutes(new Date(), -1)),
  });
  const err = api.authenticate(
    ctx({ headers: { authorization: 'Bearer vol-expired' } }),
    'volunteer',
  );
  assert.equal(err.__error.code, ERR.GRANT_EXPIRED);
});

test('设备指纹不匹配被拒绝（越权 40301）', () => {
  store.db.grants.push({
    token: 'vol-dev',
    activityId: finished.id,
    userNo: '2023001',
    name: '吴磊',
    deviceId: 'device-original',
    expiresAt: iso(addMinutes(new Date(), 60)),
  });
  const err = api.authenticate(
    ctx({ headers: { authorization: 'Bearer vol-dev', 'x-device-id': 'device-other' } }),
    'volunteer',
  );
  assert.equal(err.__error.code, ERR.DEVICE_MISMATCH);
});

test('无效令牌 → 未认证（40101）', () => {
  const err = api.authenticate(ctx({ headers: { authorization: 'Bearer nonsense' } }), 'admin');
  assert.equal(err.__error.code, ERR.UNAUTHORIZED);
});

test('缺少 Authorization → 未认证（40101）', () => {
  const err = api.authenticate(ctx({ headers: {} }), 'admin');
  assert.equal(err.__error.code, ERR.UNAUTHORIZED);
});

test('角色越界：志愿者令牌访问管理端接口被拒绝', () => {
  store.db.grants.push({
    token: 'vol-role',
    activityId: finished.id,
    userNo: '2023001',
    name: '吴磊',
    deviceId: 'd',
    expiresAt: iso(addMinutes(new Date(), 60)),
  });
  const err = api.authenticate(ctx({ headers: { authorization: 'Bearer vol-role' } }), 'admin');
  assert.equal(err.__error.code, ERR.FORBIDDEN);
});

test('管理端令牌在名下活动全部终态 24 小时后失效', () => {
  // 造一个名下只有终态活动的管理员
  store.db.admins.push({
    ownerId: 'owner-idle',
    deviceId: 'device-idle',
    token: 'adm-idle',
    createdAt: iso(addMinutes(new Date(), -100 * 60)),
    loginCount: 1,
  });
  store.db.activities.push({
    ...finished,
    id: 'act-idle-test',
    ownerId: 'owner-idle',
    status: 'finished',
    terminalAt: iso(addMinutes(new Date(), -25 * 60)),
  });

  const err = api.authenticate(ctx({ headers: { authorization: 'Bearer adm-idle' } }), 'admin');
  assert.equal(err.__error.code, ERR.ADMIN_TOKEN_EXPIRED);

  // 24 小时内仍有效
  store.db.activities.find((a) => a.id === 'act-idle-test').terminalAt = iso(
    addMinutes(new Date(), -1),
  );
  const ok = api.authenticate(ctx({ headers: { authorization: 'Bearer adm-idle' } }), 'admin');
  assert.equal(ok, null, '名下活动刚结束不久，令牌应仍有效');

  store.db.activities = store.db.activities.filter((a) => a.id !== 'act-idle-test');
  store.db.admins = store.db.admins.filter((a) => a.deviceId !== 'device-idle');
});

// ═════════════════════════════════════════════════════════════════════════
section('状态流转：POST /activities/{id}:transition（网页 §6.4.2）');
// ═════════════════════════════════════════════════════════════════════════

test('transition：published → ongoing 成功，并按 D-6 生成抽查任务（此刻为 0 条）', () => {
  // 用 checkedIn: false 的夹具：还没人签到，因此抽查任务应为 0 条。
  const fx = makeFixture({ participants: ['3001'], status: 'published', checkedIn: false });
  const res = api.transitionActivity(
    ctx({
      params: { id: fx.id },
      body: { from: 'published', to: 'ongoing', reason: '到场即开始' },
      auth: adminAuth(),
    }),
  );
  assert.ok(res.activity, JSON.stringify(res));
  assert.equal(res.activity.status, 'ongoing');
  assert.equal(res.transitionedFrom, 'published');
  assert.equal(res.transitionedTo, 'ongoing');
  assert.equal(
    res.attendanceTasksCreated,
    0,
    '决策 D-6：没人签到就不生成抽查任务',
  );
  cleanup(fx.id);
});

test('transition：from 与当前状态不符 → 版本冲突（乐观锁）', () => {
  const fx = makeFixture({ participants: ['3002'], status: 'published' });
  const res = api.transitionActivity(
    ctx({
      params: { id: fx.id },
      body: { from: 'draft', to: 'ongoing' }, // 客户端以为还是草稿
      auth: adminAuth(),
    }),
  );
  assert.equal(res.__error.code, ERR.VERSION_CONFLICT);
  assert.match(res.__error.message, /刷新后重试/);
  cleanup(fx.id);
});

test('transition：非法转移 → 状态冲突，且终态不可再流转', () => {
  const fx = makeFixture({ participants: ['3003'], status: 'published' });

  // published 不能直接跳到 finished
  const bad = api.transitionActivity(
    ctx({ params: { id: fx.id }, body: { to: 'finished' }, auth: adminAuth() }),
  );
  assert.equal(bad.__error.code, ERR.ACTIVITY_STATE_INVALID);

  // 走到终态
  api.transitionActivity(ctx({ params: { id: fx.id }, body: { to: 'ongoing' }, auth: adminAuth() }));
  api.transitionActivity(ctx({ params: { id: fx.id }, body: { to: 'finished' }, auth: adminAuth() }));

  const after = api.transitionActivity(
    ctx({ params: { id: fx.id }, body: { to: 'ongoing' }, auth: adminAuth() }),
  );
  assert.equal(after.__error.code, ERR.ACTIVITY_STATE_INVALID);
  assert.match(after.__error.message, /终态/);
  cleanup(fx.id);
});

test('transition：→ cancelled 走取消规则（原因 <5 字被拒）', () => {
  const fx = makeFixture({ participants: ['3004'], status: 'published' });
  const res = api.transitionActivity(
    ctx({ params: { id: fx.id }, body: { to: 'cancelled', reason: '下雨' }, auth: adminAuth() }),
  );
  assert.equal(res.__error.code, ERR.BAD_REQUEST);
  assert.ok(res.__error.errors.some((e) => e.field === 'reason'));
  cleanup(fx.id);
});

test('transition：→ cancelled 带合规原因时豁免未发生的抽查', () => {
  const fx = makeFixture({ participants: ['3005'], checkedIn: true });
  const res = api.transitionActivity(
    ctx({
      params: { id: fx.id },
      body: { to: 'cancelled', reason: '当日持续降雨，场地湿滑，协商取消' },
      auth: adminAuth(),
    }),
  );
  assert.ok(res.activity, JSON.stringify(res));
  assert.equal(res.activity.status, 'cancelled');
  assert.ok(res.excusedTasks > 0, '未发生的抽查应被豁免');
  cleanup(fx.id);
});

test('transition：draft → published 生成规则快照', () => {
  const fx = makeFixture({ participants: ['3006'], status: 'draft' });
  fx.ruleSnapshot = null;
  const res = api.transitionActivity(
    ctx({ params: { id: fx.id }, body: { to: 'published' }, auth: adminAuth() }),
  );
  assert.ok(res.activity, JSON.stringify(res));
  assert.equal(res.activity.status, 'published');
  assert.ok(res.activity.ruleSnapshot, '发布即冻结规则快照（方案 §5.2）');
  cleanup(fx.id);
});

test('transition：缺少 to 参数 → 参数错误', () => {
  const fx = makeFixture({ participants: ['3007'], status: 'published' });
  const res = api.transitionActivity(
    ctx({ params: { id: fx.id }, body: {}, auth: adminAuth() }),
  );
  assert.equal(res.__error.code, ERR.BAD_REQUEST);
  assert.ok(res.__error.errors.some((e) => e.field === 'to'));
  cleanup(fx.id);
});

// ═════════════════════════════════════════════════════════════════════════
section('增量同步：GET /changes?since=（网页 §6.4.9）');
// ═════════════════════════════════════════════════════════════════════════

test('changes：首次不带 since → 返回全量快照并标明 fullSnapshot', () => {
  const res = api.changes(ctx({ query: {}, auth: adminAuth() }));
  assert.equal(res.fullSnapshot, true);
  assert.ok(res.items.length > 0);
  assert.ok(res.nextCursor, '必须给出游标供下次增量');
  assert.equal(res.windowDays, 7, '幂等窗口为 7 天');
  assert.ok(res.serverTime);
});

test('changes：变更条目只带列表页字段，不带详情', () => {
  const res = api.changes(ctx({ query: {}, auth: adminAuth() }));
  const item = res.items[0];
  assert.ok(item.id && item.op === 'upsert');
  assert.ok('title' in item && 'status' in item && 'startTime' in item);
  assert.ok(
    !('description' in item) && !('contact' in item),
    '增量接口会被高频调用，不该塞详情字段',
  );
});

test('changes：连续两次增量收敛（序号游标不会重复、不会漏）', () => {
  const first = api.changes(ctx({ query: {}, auth: adminAuth() }));

  // 用序号做游标后，第二次必须**精确为空** —— 这正是改用单调序号的原因：
  // 时间戳游标在"同毫秒多条写入"时要么漏、要么反复下发。
  const second = api.changes(ctx({ query: { since: first.nextCursor }, auth: adminAuth() }));
  assert.equal(second.fullSnapshot, false, '给了有效游标就不该再返回全量');
  assert.deepEqual(second.items, [], '没有新写入时应精确为空');

  // 再来一次，游标必须保持不变（不能原地乱跳）
  const third = api.changes(ctx({ query: { since: second.nextCursor }, auth: adminAuth() }));
  assert.deepEqual(third.items, []);
  assert.equal(third.nextCursor, second.nextCursor, '无变更时游标不应变化');
});

test('changes：同毫秒内的多次写入不会漏（时间戳游标的固有问题）', () => {
  // 连续创建两个活动：它们的 `updatedAt` 很可能落在同一毫秒。
  // 用时间戳做游标时这是最难处理的场景，用序号则天然安全。
  const a1 = makeFixture({ participants: [], status: 'published' });
  const a2 = makeFixture({ participants: [], status: 'published' });

  const snap = api.changes(ctx({ query: {}, auth: adminAuth() }));
  const ids = snap.items.map((i) => i.id);
  assert.ok(ids.includes(a1.id) && ids.includes(a2.id), '两个都应出现在快照里');

  const inc = api.changes(ctx({ query: { since: snap.nextCursor }, auth: adminAuth() }));
  assert.deepEqual(inc.items, [], '快照之后没有新写入');

  // 再改其中一个：必须只下发它
  a1.updatedAt = iso(new Date());
  a1.seq = 999999;
  const inc2 = api.changes(ctx({ query: { since: snap.nextCursor }, auth: adminAuth() }));
  assert.equal(inc2.items.length, 1, `应只下发被改的那一条，实际 ${inc2.items.length}`);
  assert.equal(inc2.items[0].id, a1.id);

  cleanup(a1.id);
  cleanup(a2.id);
});

test('changes：分页游标必须推进（不会漏也不会卡住）', () => {
  let cursor = null;
  const seen = new Set();
  let rounds = 0;

  while (rounds < 10) {
    rounds += 1;
    const res = api.changes(
      ctx({ query: cursor ? { since: cursor } : { limit: '2' }, auth: adminAuth() }),
    );
    for (const it of res.items) {
      seen.add(it.id);
    }
    // 全量快照分页时游标才会变；这里主要验证不会卡在同一游标上。
    if (cursor && res.nextCursor === cursor) {
      break;
    }
    cursor = res.nextCursor;
    if (res.items.length === 0) {
      break;
    }
  }

  assert.ok(seen.size > 0, '应至少同步到一条');
  assert.ok(rounds < 10, '循环必须收敛');
});

test('changes：活动被更新后会出现在增量结果里', () => {
  const first = api.changes(ctx({ query: {}, auth: adminAuth() }));
  const fx = makeFixture({ participants: ['3101'], status: 'published' });

  const second = api.changes(
    ctx({ query: { since: first.nextCursor }, auth: adminAuth() }),
  );
  if (!second.items.some((i) => i.id === fx.id)) {
    const act = store.db.activities.find((a) => a.id === fx.id);
    console.log(`      [诊断] cursor=${first.nextCursor} since=${first.nextCursor?.slice(1)}`);
    console.log(`      [诊断] fx.updatedAt=${act?.updatedAt} → ${new Date(act?.updatedAt).getTime()}`);
    console.log(`      [诊断] fx.createdAt=${act?.createdAt} → ${new Date(act?.createdAt).getTime()}`);
    console.log(`      [诊断] now=${Date.now()}`);
    console.log(`      [诊断] second.items=${second.items.length} fullSnapshot=${second.fullSnapshot}`);
  }
  assert.ok(
    second.items.some((i) => i.id === fx.id),
    '新建的活动应出现在增量结果中',
  );
  cleanup(fx.id);
});

test('changes：游标早于 7 天窗口 → 重新全量对齐（降级为时间窗拉取）', () => {
  const stale = iso(addMinutes(new Date(), -8 * 24 * 60));
  const res = api.changes(ctx({ query: { since: stale }, auth: adminAuth() }));
  assert.equal(res.fullSnapshot, true);
  assert.match(res.reason, /重新对齐/);
});

test('changes：也接受 ISO 时间（降级方案），不只是游标', () => {
  const time = iso(addMinutes(new Date(), -60));
  const res = api.changes(ctx({ query: { since: time }, auth: adminAuth() }));
  assert.equal(res.fullSnapshot, false, '1 小时前在窗口内，应走增量');
});

test('changes：草稿不对外开放（管理端看自己的，未登录看不到）', () => {
  const anon = api.changes(ctx({ query: {} }));
  assert.ok(
    !anon.items.some((i) => i.status === 'draft'),
    '草稿不应出现在未授权视图里',
  );
});

test('changes：limit 受上限约束，避免一次拉爆客户端', () => {
  const res = api.changes(ctx({ query: { limit: '99999' }, auth: adminAuth() }));
  assert.ok(res.limit <= 500, `limit 应被压低，实际 ${res.limit}`);
});

// ═════════════════════════════════════════════════════════════════════════
section('签到报文：嵌套结构（网页 §6.4.5）');
// ═════════════════════════════════════════════════════════════════════════

/** 契约规定的嵌套报文。 */
function nestedPayload(overrides = {}) {
  const at = { lat: base.lat + 0.00005, lng: base.lng + 0.00004 };
  const now = new Date();
  return {
    method: 'geo',
    location: {
      lat: at.lat,
      lng: at.lng,
      accuracy: 12,
      provider: 'gps',
      samples: 3,
      sampledAt: iso(now),
    },
    network: { wifiBssids: ['a4:2b:8c:11:22:33'], sourceIp: '202.119.1.1' },
    device: { deviceId: 'dev-nested', mockLocationDetected: false },
    clientTime: iso(now),
    ...overrides,
  };
}

test('嵌套报文可完成签到，且坐标为 location.lat/lng', () => {
  const fx = makeFixture({ participants: ['3201'] });
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: nestedPayload(),
      auth: volunteerAuth('3201', fx.id),
      headers: { 'idempotency-key': `k-nested-${fx.id}` },
    }),
  );
  assert.ok(res.checkin, JSON.stringify(res));
  assert.equal(res.checkin.status, CHECKIN_STATUS.SUCCESS);
  assert.ok(res.checkin.geoLat > 0, '坐标应被正确解析');
  assert.ok(res.checkin.score >= 60);
  cleanup(fx.id);
});

test('嵌套报文：network.wifiBssids 命中白名单计入辅证（+20）', () => {
  const fx = makeFixture({ participants: ['3202'] });
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: nestedPayload(),
      auth: volunteerAuth('3202', fx.id),
      headers: { 'idempotency-key': `k-wifi-${fx.id}` },
    }),
  );
  const items = res.scoreBreakdown ?? [];
  assert.ok(
    items.some((i) => /Wi-Fi/.test(i.reason) && i.points === 20),
    `命中白名单应给 +20：${JSON.stringify(items)}`,
  );
  // 校园网 IP 也应命中（夹具配了 202.119. 前缀）
  assert.ok(
    items.some((i) => /校园网/.test(i.reason) && i.points === 10),
    `校园网 IP 命中应给 +10：${JSON.stringify(items)}`,
  );
  // 40 + 20 + 10 = 70 ≥ 60
  assert.equal(res.checkin.status, CHECKIN_STATUS.SUCCESS);
  cleanup(fx.id);
});

test('网络辅证不在白名单内时不给分（防"随便填个 BSSID 就拿 20 分"）', () => {
  const fx = makeFixture({ participants: ['3207'] });
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: nestedPayload({
        network: { wifiBssids: ['ff:ff:ff:ff:ff:ff'], sourceIp: '8.8.8.8' },
      }),
      auth: volunteerAuth('3207', fx.id),
      headers: { 'idempotency-key': `k-wifi-miss-${fx.id}` },
    }),
  );
  const items = res.scoreBreakdown ?? [];
  assert.ok(
    !items.some((i) => /Wi-Fi|校园网/.test(i.reason) && i.points > 0),
    `未命中白名单不该给辅证分：${JSON.stringify(items)}`,
  );
  cleanup(fx.id);
});

test('嵌套报文：device.mockLocationDetected 命中即强制转人工（验收 A13）', () => {
  const fx = makeFixture({ participants: ['3203'] });
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: nestedPayload({ device: { deviceId: 'd', mockLocationDetected: true } }),
      auth: volunteerAuth('3203', fx.id),
      headers: { 'idempotency-key': `k-mock-${fx.id}` },
    }),
  );
  assert.equal(res.checkin.status, CHECKIN_STATUS.PENDING_REVIEW);
  assert.match(res.checkin.reason, /模拟定位/);
  cleanup(fx.id);
});

test('嵌套报文：location.samples 为数组时按逐次采样处理（反作弊更强）', () => {
  const fx = makeFixture({ participants: ['3204'] });
  const at = { lat: base.lat + 0.00005, lng: base.lng + 0.00004 };
  const now = new Date();
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: nestedPayload({
        location: {
          lat: at.lat,
          lng: at.lng,
          accuracy: 12,
          provider: 'gps',
          // 数组形态：本平台扩展，用于交叉验证模拟定位
          samples: [
            { geoLat: at.lat, geoLng: at.lng, accuracy: 12, capturedAt: iso(now) },
            { geoLat: at.lat + 0.000004, geoLng: at.lng + 0.000003, accuracy: 14, capturedAt: iso(now) },
          ],
        },
      }),
      auth: volunteerAuth('3204', fx.id),
      headers: { 'idempotency-key': `k-samples-${fx.id}` },
    }),
  );
  assert.ok(res.checkin, JSON.stringify(res));
  const items = res.scoreBreakdown ?? [];
  assert.ok(
    items.some((i) => /采样/.test(i.reason)),
    `传了采样数组就应给出"采样一致"判定：${JSON.stringify(items)}`,
  );
  cleanup(fx.id);
});

test('嵌套报文：只给 samples 数量时不猜"采样一致"（不默认给分）', () => {
  const fx = makeFixture({ participants: ['3205'] });
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: nestedPayload(), // samples: 3（数量，无数组）
      auth: volunteerAuth('3205', fx.id),
      headers: { 'idempotency-key': `k-count-${fx.id}` },
    }),
  );
  const items = res.scoreBreakdown ?? [];
  assert.ok(
    !items.some((i) => i.points === 10 && /采样一致/.test(i.reason)),
    '只有数量没有内容，无法判定一致性，不该给这 10 分',
  );
  cleanup(fx.id);
});

test('扁平报文仍然兼容（早期客户端已在用）', () => {
  const fx = makeFixture({ participants: ['3206'] });
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload(), // 扁平结构
      auth: volunteerAuth('3206', fx.id),
      headers: { 'idempotency-key': `k-flat-${fx.id}` },
    }),
  );
  assert.ok(res.checkin, JSON.stringify(res));
  assert.equal(res.checkin.status, CHECKIN_STATUS.SUCCESS);
  cleanup(fx.id);
});

// ═════════════════════════════════════════════════════════════════════════
section('决策 D-6 配套：签到后立即生成抽查任务');
// ═════════════════════════════════════════════════════════════════════════

test('签到成功即生成本人的抽查任务，后续按时段补齐', () => {
  const fx = makeFixture({ participants: ['3301'], checkedIn: false });
  assert.equal(
    store.db.attendanceTasks.filter((t) => t.activityId === fx.id).length,
    0,
    '签到前不该有抽查任务',
  );

  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload(),
      auth: volunteerAuth('3301', fx.id),
      headers: { 'idempotency-key': `k-hook-${fx.id}` },
    }),
  );
  assert.equal(res.checkin.status, CHECKIN_STATUS.SUCCESS);
  assert.ok(res.attendanceTasksCreated > 0, '签到响应应告知创建了抽查任务');

  const tasks = store.db.attendanceTasks.filter((t) => t.activityId === fx.id);
  assert.equal(tasks.length, 5, `3 小时活动应建 5 个时段，实际 ${tasks.length}`);
  assert.ok(tasks.every((t) => t.userNo === '3301'), '只给签到的人建任务');

  // 幂等：再签一次（换幂等键）不应重复建任务
  api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload(),
      auth: volunteerAuth('3301', fx.id),
      headers: { 'idempotency-key': `k-hook2-${fx.id}` },
    }),
  );
  assert.equal(
    store.db.attendanceTasks.filter((t) => t.activityId === fx.id).length,
    5,
    '重复签到不得产生重复任务（幂等键 activityId+userNo+seq）',
  );
  cleanup(fx.id);
});

test('待人工确认的签到也会生成抽查任务（人在场是大概率）', () => {
  const fx = makeFixture({ participants: ['3302'], checkedIn: false });
  api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload({ mockLocationDetected: true }),
      auth: volunteerAuth('3302', fx.id),
      headers: { 'idempotency-key': `k-pending-${fx.id}` },
    }),
  );
  assert.ok(
    store.db.attendanceTasks.filter((t) => t.activityId === fx.id).length > 0,
    '若只给 success 建任务，人工复核一慢这人就完全不被防脱岗覆盖',
  );
  cleanup(fx.id);
});

test('被驳回的签到不生成抽查任务（人没到场，谈不上脱岗）', () => {
  const fx = makeFixture({ participants: ['3303'], checkedIn: false });
  const far = { lat: base.lat + 0.02, lng: base.lng + 0.02 };
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload({ geoLat: far.lat, geoLng: far.lng, samples: [], recentInsideFence: false }),
      auth: volunteerAuth('3303', fx.id),
      headers: { 'idempotency-key': `k-reject-${fx.id}` },
    }),
  );
  assert.equal(res.checkin.status, CHECKIN_STATUS.REJECTED);
  assert.equal(
    store.db.attendanceTasks.filter((t) => t.activityId === fx.id).length,
    0,
    '被驳回的人不该被防脱岗抽查',
  );
  cleanup(fx.id);
});

// ═════════════════════════════════════════════════════════════════════════
section('契约完整性');
// ═════════════════════════════════════════════════════════════════════════

test('契约自述列出全部端点与判定阈值', () => {
  const c = api.contractSelfDescription();
  assert.equal(c.apiVersion, 'v1');
  assert.ok(c.endpoints.length > 30, `端点数量偏少：${c.endpoints.length}`);
  assert.equal(c.scoring.successThreshold, 60);
  assert.equal(c.scoring.pendingReviewThreshold, 30);
  assert.equal(c.scoring.mockLocationForcesManualReview, true);
  assert.equal(c.scoring.maxUsableAccuracyMeters, 100);
  assert.equal(c.attendance.pushEnabled, false, '必须明确不启用推送');
  assert.equal(c.attendance.responseWindowMinutes, 5);
  assert.equal(c.attendance.missGraceMinutes, 2);
  assert.equal(c.retention.days, 7);
});

test('契约自述的信封与分页口径是网页方案 §6.1 的（msg / size）', () => {
  const c = api.contractSelfDescription();
  // 信封字段必须是 msg
  assert.match(c.envelope.success, /\bmsg\b/);
  assert.ok(!/\bmessage,/.test(c.envelope.success), '不得把 message 当契约字段');
  // 幂等键头是 X-Idempotency-Key
  assert.ok(
    c.headers.request.includes('X-Idempotency-Key'),
    `请求头缺 X-Idempotency-Key：${c.headers.request}`,
  );
  // 分页用 size
  assert.ok(
    c.pagination.request.some((s) => /size/.test(s)),
    '分页请求参数必须写 size',
  );
  assert.ok(c.pagination.response.includes('size'), '分页响应必须含 size');
  // 授权的 8 个码值
  assert.deepEqual(c.errorCodes.authorized, [0, 40001, 40101, 40301, 40401, 40901, 42901, 50001]);
});

/*
  ## 归属隔离：管理员只能看到自己名下的活动

  真机测试抓到的越权：`GET /activities` 的路由**没有 auth 选项**，
  于是 `authenticate` 从不执行、`ctx.auth` 一直是空对象 `{}`，
  `listActivities` 里 `ctx.auth.kind === 'admin'` 恒为 false，
  走的是"非管理员"分支（只排除草稿）—— **所有发布者的活动互相可见**。

  实测：owner-mvcchx26m0glavl3 的管理员拿到了 6 条属于
  owner-demo-0001 的活动，自己的 0 条。而界面写的是「我发布的」活动。

  修复：给该路由加 `optional` 鉴权 ——
  网页端匿名浏览公开列表仍然可用，带令牌的管理端则按 owner 过滤。
*/
test('活动列表：管理员只能看到自己名下的活动（归属隔离）', () => {
  const fx = makeFixture({ participants: ['0901'] });

  // 另一个发布者的管理员
  const other = api.listActivities(
    ctx({ query: {}, auth: { kind: 'admin', ownerId: 'owner-someone-else', deviceId: 'device-x', token: 't-x' } }),
  );
  const otherIds = (other.items ?? []).map((a) => a.id);
  assert.ok(
    !otherIds.includes(fx.id),
    '不同 owner 的管理员不得看到别人的活动（否则跨发布者数据泄露）',
  );

  // 自己的管理员应当看得到
  const mine = api.listActivities(ctx({ query: {}, auth: adminAuth() }));
  const mineIds = (mine.items ?? []).map((a) => a.id);
  assert.ok(mineIds.includes(fx.id), '自己的活动必须可见');

  cleanup(fx.id);
});

test('活动列表：匿名请求仍可浏览公开活动（网页端不能被迫登录）', () => {
  const fx = makeFixture({ participants: ['0902'], status: 'published' });
  // 匿名：ctx.auth 为空对象，走"非管理员"分支，只排除草稿
  const anon = api.listActivities(ctx({ query: {}, auth: {} }));
  const ids = (anon.items ?? []).map((a) => a.id);
  assert.ok(ids.includes(fx.id), '匿名应能看到已发布活动');
  cleanup(fx.id);
});

test('GET /activities 与 GET /changes 必须声明 optional 鉴权（否则归属过滤退化）', async () => {
  const { routeTable } = await import('../src/router.js');
  for (const pattern of ['/activities', '/changes']) {
    const r = routeTable().find((x) => x.method === 'GET' && x.pattern === pattern);
    assert.ok(r, `${pattern} 路由必须存在`);
    assert.equal(
      r.auth,
      'optional',
      `${pattern} 必须用 optional 鉴权：完全不给 auth 会让 ctx.auth 恒为空对象，`
        + '依赖 ctx.auth.kind 的可见性/归属过滤会静默失效',
    );
  }
});

test('契约自述与真实路由**不会漂移**', async () => {
  // ⚠️ 这条测试的存在理由：契约自述曾经严重过期——
  // 里面写着 `message`、写着 `POST /activities`、`/participants/import`，
  // 而实际路由早已改成 `msg`、`:upsert`、`:import`。
  //
  // 自述是给人看的"活的契约"，但它**没有任何机制保证与路由一致**，
  // 于是每次改路由都会悄悄留一处谎言。这个测试把两者绑起来。
  const { routeTable } = await import('../src/router.js');
  const actual = new Set(
    routeTable().map((r) => `${r.method} ${r.pattern}`),
  );

  const documented = api.contractSelfDescription().endpoints;
  const missing = documented
    .map(([m, p]) => `${m} ${p}`)
    // 这两个是维护用端点，不属于业务契约
    .filter((k) => !k.endsWith('/dev/reset'))
    .filter((k) => !actual.has(k));

  assert.deepEqual(
    missing,
    [],
    `契约自述里这些端点在实际路由中不存在（文档漂移）：\n  ${missing.join('\n  ')}`,
  );

  // 反向：实际路由里有没有完全没被记录的？
  const documentedSet = new Set(documented.map(([m, p]) => `${m} ${p}`));
  const undocumented = [...actual].filter(
    (k) =>
      !documentedSet.has(k) &&
      !k.endsWith('/dev/reset') &&
      !k.endsWith('/dev/time-travel-example'),
  );
  assert.deepEqual(
    undocumented,
    [],
    `这些路由存在但契约自述没写（新端点漏登记）：\n  ${undocumented.join('\n  ')}`,
  );
});

/*
  ## 参数名漂移的静态守卫

  ⚠️ 这条测试是真机测试逼出来的。

  `POST /attendances/{taskId}:confirm` 的路由模式声明的是 **`taskId`**，
  而 `respondAttendance` 里读的是 `ctx.params.id` —— 恒为 undefined，
  于是 `findVisibleActivity(undefined)` 返回 null，
  接口**100% 返回 404「活动不存在或已过留存期」**，整条在岗确认链路不可用。

  为什么原有的单测全绿：测试是**直接调用 handler** 并手工构造
  `params: { id, taskId }` —— 两个参数都塞进去，掩盖了真实路由只给 `taskId`。
  "直接调 handler"的测试在参数名层面永远不可靠。

  所以这里不调 handler，而是**读源码**：把路由模式里声明的参数名
  与处理函数实际读取的 `ctx.params.X` 对比，不一致就失败。

  这类检查能一次性覆盖所有路由，比逐个补集成测试划算得多。
*/
test('每个处理函数读取的 ctx.params.* 必须在路由模式里声明（防参数名漂移）', async () => {
  const { routeTable } = await import('../src/router.js');

  const problems = [];
  for (const r of routeTable()) {
    // 模式里的参数名：`:id` / `:taskId:confirm` 中的 `id` / `taskId`
    // （动作后缀也是 `:xxx` 形式，一并收集不影响判断——只会让集合更大）
    const declared = new Set(
      (r.pattern.match(/:([A-Za-z_$][\w$]*)/g) ?? []).map((s) => s.slice(1)),
    );
    const source = String(r.handler);
    const used = new Set();
    for (const m of source.matchAll(/ctx\.params\.([A-Za-z_$][\w$]*)/g)) {
      used.add(m[1]);
    }
    for (const name of used) {
      if (!declared.has(name)) {
        problems.push(
          `${r.method} ${r.pattern} 的处理函数读取 ctx.params.${name}，`
          + `但路由模式未声明该参数（声明的是：${[...declared].join(', ') || '无'}）`,
        );
      }
    }
  }

  assert.deepEqual(
    problems,
    [],
    `参数名漂移会让接口恒返回"不存在"，而且直接调 handler 的测试发现不了：\n  ${problems.join('\n  ')}`,
  );
});

test('在岗确认：以 taskId 为主键解析活动，不再依赖不存在的 ctx.params.id', async () => {
  // 回归：曾经 `ctx.params.id` 是 undefined，导致接口恒 404。
  const { routeTable } = await import('../src/router.js');
  const route = routeTable().find((r) => r.pattern === '/attendances/:taskId:confirm');
  assert.ok(route, '在岗确认路由必须存在');
  const source = String(route.handler);
  assert.doesNotMatch(
    source,
    /ctx\.params\.id\b/,
    '在岗确认路径不含活动 id，不得读取 ctx.params.id',
  );
  assert.match(
    source,
    /ctx\.params\.taskId/,
    '在岗确认必须按 taskId 找任务，再由 task.activityId 推活动',
  );
});

test('名单行的 checkinStatus 与 checkin.status 用**同一套词表**', () => {
  // ⚠️ 这条测试的存在理由（实测踩到过）：
  //
  // 早期 `presentParticipant` 把状态翻译成 `checked_in` / `not_checked_in`，
  // 而 `checkin.status` 用的是 `success` / `pending_review`。
  // 两套词表并存，客户端只认其中一套，于是**看板上所有已签到的参与者
  // 都显示成"未知状态"** —— 而这正是发布者现场最需要看的一列。
  //
  // 现在统一取 `checkin.status` 原值（无记录时为 `none`），
  // 这条断言把"不许再引入翻译层"钉住。
  const fx = makeFixture({ participants: ['2101', '2102'], checkedIn: true });

  // 2101 已签到（success）；把 2102 改成待确认。
  const c2 = store.db.checkins.find((c) => c.activityId === fx.id && c.userNo === '2102');
  c2.status = CHECKIN_STATUS.PENDING_REVIEW;

  const board = api.activityBoard(
    ctx({ params: { id: fx.id }, query: { includeParticipants: 'true' }, auth: adminAuth() }),
  );

  const byNo = new Map(board.participants.map((p) => [p.userNo, p]));
  assert.equal(byNo.get('2101').checkinStatus, CHECKIN_STATUS.SUCCESS);
  assert.equal(byNo.get('2102').checkinStatus, CHECKIN_STATUS.PENDING_REVIEW);

  // 允许的取值必须**恰好**是种检查词表 + `none`，不能有别的写法。
  const allowed = new Set([
    CHECKIN_STATUS.SUCCESS,
    CHECKIN_STATUS.PENDING_REVIEW,
    'none',
  ]);
  for (const p of board.participants) {
    assert.ok(
      allowed.has(p.checkinStatus),
      `checkinStatus=${p.checkinStatus} 不在授权词表内（${[...allowed].join(' / ')}）`,
    );
    // 明确排除早期那套写法。
    assert.ok(
      p.checkinStatus !== 'checked_in' && p.checkinStatus !== 'not_checked_in',
      '不得再使用 checked_in / not_checked_in 这套旧词表',
    );
  }

  cleanup(fx.id);
});

test('无签到记录时 checkinStatus 为 none（而不是 not_checked_in）', () => {
  const fx = makeFixture({ participants: ['2201'], checkedIn: false });
  const board = api.activityBoard(
    ctx({ params: { id: fx.id }, query: { includeParticipants: 'true' }, auth: adminAuth() }),
  );
  assert.equal(board.participants[0].checkinStatus, 'none');
  // 四态计数之和必须等于有效名单人数（看板可信的前提）。
  assert.equal(
    board.checkedIn + board.pendingReview + board.notCheckedIn,
    1,
    '四态之和应等于有效名单人数',
  );
  cleanup(fx.id);
});

test('写入侧的 method 一律是契约值 geo（读取侧仍兼容 gps）', () => {
  const fx = makeFixture({ participants: ['2301'] });
  const res = api.submitCheckin(
    ctx({
      params: { id: fx.id },
      body: gpsPayload(),
      auth: volunteerAuth('2301', fx.id),
      headers: { 'idempotency-key': `k-method-${fx.id}` },
    }),
  );
  assert.ok(res.checkin, JSON.stringify(res));
  // 写入统一用 geo；早期写成 gps 的那批数据由客户端解析层兼容。
  assert.equal(res.checkin.method, CHECKIN_METHOD.GEO);
  assert.ok(
    res.checkin.method !== 'gps',
    '写入侧不应再产生 gps，否则线上会长期并存两套词表',
  );
  cleanup(fx.id);
});

test('错误码只使用网页方案 §6.1 授权的 8 个值', () => {  // 方案原文：0 成功、40001 参数错误、40101 未认证、40301 越权、
  // 40401 不存在、40901 状态冲突、42901 限流、50001 服务异常。
  const allowed = new Set([0, 40001, 40101, 40301, 40401, 40901, 42901, 50001]);
  for (const [name, code] of Object.entries(ERR)) {
    assert.ok(
      allowed.has(code),
      `错误码 ${name} = ${code} 不在方案授权的 8 个值内`,
    );
  }

  // 抽样核对语义映射
  assert.equal(ERR.OK, 0);
  assert.equal(ERR.FORBIDDEN, 40301, '方案原文明确给出');
  assert.equal(ERR.UNAUTHORIZED, 40101);
  assert.equal(ERR.NOT_IN_PARTICIPANT_LIST, 40301, '「不在名单」也归 40301');
  assert.equal(ERR.VERSION_CONFLICT, 40901);
  assert.equal(ERR.SERVER_ERROR, 50001);
  assert.equal(ERR.BAD_REQUEST, 40001);
});

test('每个细分错误都有文案与 HTTP 状态，且 HTTP 状态符合语义', () => {
  for (const [name, def] of Object.entries(CATALOG)) {
    assert.ok(def.message, `${name} 缺少文案`);
    assert.ok(def.http, `${name} 缺少 HTTP 状态`);
    assert.ok(typeof def.code === 'number', `${name} 的 code 不是数字`);
  }
  // HTTP 状态必须被逐细分保留，不能因为线码合并而互相覆盖
  assert.equal(CATALOG.BAD_REQUEST.http, 400);
  assert.equal(CATALOG.NOT_IN_PARTICIPANT_LIST.http, 403, '不在名单应是 403 而不是 400');
  assert.equal(CATALOG.VERSION_CONFLICT.http, 409);
  assert.equal(CATALOG.ACTIVITY_NOT_FOUND.http, 404);
  assert.equal(CATALOG.TOO_MANY_REQUESTS.http, 429);
  assert.equal(CATALOG.ADMIN_CODE_LOCKED.http, 423);
});

test('健康检查可用', () => {
  const h = api.health();
  assert.equal(h.status, 'ok');
  assert.ok(h.dataFile);
});

// ═════════════════════════════════════════════════════════════════════════
// P2 清理：部门字典 / dev 接口守卫
// ═════════════════════════════════════════════════════════════════════════

test('部门字典：返回去重排序的 organizer 列表', () => {
  /*
    没有这个接口时，网页只能从"当前页的活动"里凑部门 ——
    翻到第 2 页选项就变了，用户会以为筛选坏了。
    真服务端早有这个接口，mock 缺它会导致同一份前端
    连 mock 与连真实服务端行为不一致，很难排查。
  */
  assert.equal(typeof api.listOrganizers, 'function', '必须导出 listOrganizers');

  const r = api.listOrganizers({ auth: {}, query: {} });
  assert.ok(Array.isArray(r.items), 'items 必须是数组');
  assert.equal(r.total, r.items.length);
  assert.equal(new Set(r.items).size, r.items.length, '不能有重复部门');
  const sorted = [...r.items].sort((a, b) => a.localeCompare(b, 'zh'));
  assert.deepEqual(r.items, sorted, '部门应已排序（下拉直接渲染）');
});

test('/dev 接口默认关闭：未设 MOCK_ALLOW_DEV 时返回"接口不存在"', () => {
  /*
    mock 常被反代到手机上做真机联调，端口确实暴露在局域网。
    此时 `/dev/reset` 就成了"谁都能调、一调清空全部演示数据"的后门，
    而且调用者不需要任何身份。

    默认关闭，必须显式 `MOCK_ALLOW_DEV=1` 才开；
    `NODE_ENV=production` 时即使设了也不开（那只能是误操作）。
  */
  const prev = process.env.MOCK_ALLOW_DEV;
  delete process.env.MOCK_ALLOW_DEV;
  try {
    const r = api.devReset({ body: { confirm: 'RESET' } });
    assert.ok(r && r.__error, '应返回错误信封而不是执行重置');
    assert.match(r.__error.message, /接口不存在/, '不能暴露"这其实是权限问题"');
  } finally {
    if (prev !== undefined) {
      process.env.MOCK_ALLOW_DEV = prev;
    }
  }
});

test('/dev 接口：显式开启后才可用，且仍需 confirm 参数', () => {
  const prev = process.env.MOCK_ALLOW_DEV;
  process.env.MOCK_ALLOW_DEV = '1';
  try {
    const noConfirm = api.devReset({ body: {} });
    assert.equal(noConfirm.__error.code, 40001, '没有 confirm 应被拒');
    assert.match(noConfirm.__error.message, /RESET/);
  } finally {
    if (prev === undefined) {
      delete process.env.MOCK_ALLOW_DEV;
    } else {
      process.env.MOCK_ALLOW_DEV = prev;
    }
  }
});

// ═════════════════════════════════════════════════════════════════════════
// 汇总
// ═════════════════════════════════════════════════════════════════════════

console.log(`\n${'─'.repeat(60)}`);
console.log(`通过 ${passed} 项，失败 ${failed} 项`);
if (failed > 0) {
  console.log('\n失败明细：');
  for (const f of failures) {
    console.log(`  ✗ ${f.name}\n      ${f.message}`);
  }
}
console.log(`数据目录（已隔离）：${TMP}`);
console.log(`${'─'.repeat(60)}\n`);

process.exit(failed > 0 ? 1 : 0);
