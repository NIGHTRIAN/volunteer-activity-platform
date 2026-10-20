/**
 * 签到 / 在岗抽查 / 看板 / 复核接口。
 *
 * ## 判定一律走 `scoring.js`
 *
 * 这个文件**只做**：取数据 → 调 `checkGate` / `scoreCheckin` → 落库 → 出参。
 * 任何"随手写一个阈值"都会让服务端与离线演示引擎、与 mock 三边漂移，
 * 而真机测试期间已经吃过"两边算得不一样"的亏。
 *
 * ## 移动端修过的三个语义，这里必须保留
 *
 * 1. **离线补传一律转待人工确认**（`offlineBackfill` 不因证据强而自动通过）。
 *    补传的时间与现场时间不同，无法排除事后补造。
 * 2. **在岗确认窗口两侧都要校验**：未到点不能提前点掉（真机踩过），
 *    超时也不能补。
 * 3. **签到成功/待确认都要生成抽查任务**（人在场是大概率），
 *    已驳回则不生成。
 */

import {
  ATTENDANCE_MODE,
  ATTENDANCE_TASK_STATUS,
  CHECKIN_STATUS,
  DEFAULTS,
  DISCLAIMER,
  TERMINAL_STATUSES,
} from '../contract.js';
import { ApiError } from '../http/envelope.js';
import { checkGate, scoreCheckin, fenceOf, distanceMeters } from '../scoring.js';
import { requireAdmin, requireVolunteer, assertActivityOwnership } from './auth.js';
import { toIso, parseTime, nowIso, addMinutesIso } from '../util/time.js';
import { parseJsonArray } from '../util/json.js';

// ─────────────────────────────────────────────────────────────────────────
// 证据归一
// ─────────────────────────────────────────────────────────────────────────

/** 把客户端上送的证据归一成 `scoring.js` 认识的形状。 */
export function normalizeSubmission(body = {}) {
  const loc = body.location ?? {};
  const net = body.network ?? {};
  const dev = body.device ?? {};

  const samples = Array.isArray(loc.samples) ? loc.samples : Array.isArray(body.samples) ? body.samples : [];
  const wifiList = Array.isArray(net.wifiBssids)
    ? net.wifiBssids
    : net.wifiBssid
      ? [net.wifiBssid]
      : Array.isArray(body.wifiBssids)
        ? body.wifiBssids
        : [];

  return {
    geoLat: loc.lat ?? body.geoLat ?? null,
    geoLng: loc.lng ?? body.geoLng ?? null,
    accuracy: loc.accuracy ?? body.accuracy ?? null,
    samples: samples.map((s) => ({
      lat: s.lat ?? s.geoLat ?? null,
      lng: s.lng ?? s.geoLng ?? null,
      accuracy: s.accuracy ?? null,
    })),
    wifiBssids: wifiList.map(String),
    sourceIp: net.sourceIp ?? net.localIp ?? body.sourceIp ?? body.localIp ?? null,
    deviceId: dev.deviceId ?? body.deviceId ?? null,
    appVersion: dev.appVersion ?? body.appVersion ?? null,
    mockLocationDetected: dev.mockLocationDetected === true || body.mockLocationDetected === true,
    clientTime: body.clientTime ?? null,
    recentInsideFence: body.recentInsideFence === true,
    offlineBackfill: body.offlineBackfill === true,
  };
}

/** Wi-Fi / 校园网是否命中活动白名单（未配置 → 不参与，返回 false）。 */
function networkMatches(activity, submission) {
  const wifiAllow = parseJsonArray(activity.wifiBssids ?? '[]');
  const ipAllow = parseJsonArray(activity.campusIpPrefixes ?? '[]');

  const submittedWifi = submission.wifiBssids.map((s) => String(s).toLowerCase());
  const wifiMatched =
    wifiAllow.length > 0 &&
    submittedWifi.length > 0 &&
    submittedWifi.some((s) => wifiAllow.map((a) => String(a).toLowerCase()).includes(s));

  const campusIpMatched =
    ipAllow.length > 0 &&
    typeof submission.sourceIp === 'string' &&
    ipAllow.some((prefix) => submission.sourceIp.startsWith(String(prefix)));

  return { wifiMatched, campusIpMatched };
}

// ─────────────────────────────────────────────────────────────────────────
// 签到
// ─────────────────────────────────────────────────────────────────────────

/** `POST /activities/{id}/checkins` —— 志愿者提交签到。 */
export async function submitCheckin(ctx) {
  const raw = await ctx.repos.activities.findById(ctx.params.id);
  if (!raw) {
    throw new ApiError('ACTIVITY_NOT_FOUND');
  }
  const activityId = String(raw.id);
  const auth = requireVolunteer(ctx, activityId);

  const participant = await ctx.repos.participants.findOne(activityId, auth.userNo);
  const existing = await ctx.db.queryOne(
    'SELECT * FROM checkin WHERE activity_id = ? AND user_no = ? ORDER BY id DESC LIMIT 1',
    [activityId, auth.userNo],
  );

  const submission = normalizeSubmission(ctx.body);
  const now = new Date();

  // 幂等：已签到就返回原记录，不重复计分（客户端也会重试）。
  if (existing) {
    return { checkin: checkinToWire(existing), alreadySubmitted: true };
  }

  const gate = checkGate({ activity: raw, participant, now });
  if (!gate.ok) {
    throw new ApiError(gate.code, gate.message);
  }

  const net = networkMatches(raw, submission);
  const verdict = scoreCheckin({
    activity: raw,
    submission,
    context: {
      wifiMatched: net.wifiMatched,
      campusIpMatched: net.campusIpMatched,
      recentInsideFence: submission.recentInsideFence,
      trajectoryAnomaly: null,
    },
  });

  /*
    离线补传**一律转待人工确认**（方案 §6.4）。

    理由：补传时"提交时间"与"现场时间"不一致，无法排除事后补造。
    即使证据看起来满分，也要人看一眼 —— 这是对"证据链"的尊重。
  */
  let status = verdict.status;
  let reason = verdict.reason;
  if (submission.offlineBackfill && status === CHECKIN_STATUS.SUCCESS) {
    status = CHECKIN_STATUS.PENDING_REVIEW;
    reason = '离线补传，已转人工确认（补传证据不能自动通过）';
  }

  const r = await ctx.db.execute(
    `INSERT INTO checkin
       (activity_id, user_no, name, method, status, reason,
        geo_lat, geo_lng, accuracy, score, score_breakdown, distance_meters,
        mock_location_detected, client_time, server_time,
        device_id, app_version, wifi_matched, campus_ip_matched, dwell_verified,
        offline_backfill)
     VALUES (?, ?, ?, 'geo', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)`,
    [
      activityId,
      auth.userNo,
      participant?.name ?? auth.name ?? null,
      status,
      reason,
      submission.geoLat,
      submission.geoLng,
      submission.accuracy,
      verdict.score,
      JSON.stringify(verdict.items),
      verdict.distanceMeters,
      verdict.mockLocationDetected ? 1 : 0,
      submission.clientTime,
      toIso(now),
      submission.deviceId ?? auth.deviceId ?? null,
      submission.appVersion ?? null,
      net.wifiMatched ? 1 : 0,
      net.campusIpMatched ? 1 : 0,
      submission.offlineBackfill ? 1 : 0,
    ],
  );

  // 签到受理（成功 / 待确认）都要生成在岗抽查：人在场是大概率。
  if (status !== CHECKIN_STATUS.REJECTED) {
    await ensureAttendanceTasks(ctx, raw, auth.userNo);
  }

  const saved = await ctx.db.queryOne('SELECT * FROM checkin WHERE id = ?', [r.lastInsertId]);
  return { checkin: checkinToWire(saved) };
}

/** `GET /activities/{id}/checkins` —— 管理端看签到记录。 */
export async function listCheckins(ctx) {
  const raw = await ctx.repos.activities.findById(ctx.params.id);
  const activity = await assertActivityOwnership(ctx, raw);
  const activityId = String(activity.id);

  const rows = await ctx.db.query(
    'SELECT * FROM checkin WHERE activity_id = ? ORDER BY id DESC',
    [activityId],
  );
  const items = rows.map(checkinToWire);
  return {
    items,
    total: items.length,
    counts: {
      success: items.filter((c) => c.status === CHECKIN_STATUS.SUCCESS).length,
      pendingReview: items.filter((c) => c.status === CHECKIN_STATUS.PENDING_REVIEW).length,
      rejected: items.filter((c) => c.status === CHECKIN_STATUS.REJECTED).length,
    },
  };
}

/** `GET /activities/{id}/checkins/mine` —— 本人签到记录。 */
export async function myCheckin(ctx) {
  const raw = await ctx.repos.activities.findById(ctx.params.id);
  if (!raw) {
    throw new ApiError('ACTIVITY_NOT_FOUND');
  }
  const activityId = String(raw.id);
  const auth = requireVolunteer(ctx, activityId);

  const rows = await ctx.db.query(
    'SELECT * FROM checkin WHERE activity_id = ? AND user_no = ? ORDER BY id DESC',
    [activityId, auth.userNo],
  );
  const items = rows.map(checkinToWire);
  /*
    返回 `{ items, latest }` 而不是裸记录：
    记录页要展示"最近一次 + 历史"，只有一条记录时也要能渲染。
    同时保留 `checkin` 键兼容早期调用方。
  */
  return {
    items,
    latest: items[0] ?? null,
    ...(items[0] ? { checkin: items[0] } : {}),
  };
}

/** `POST /checkins/{id}:review` —— 管理端复核。 */
export async function reviewCheckin(ctx) {
  const row = await ctx.db.queryOne('SELECT * FROM checkin WHERE id = ?', [ctx.params.checkinId]);
  if (!row) {
    throw new ApiError('ACTIVITY_NOT_FOUND', '签到记录不存在');
  }
  const raw = await ctx.repos.activities.findById(String(row.activity_id));
  await assertActivityOwnership(ctx, raw);

  const decision = String(ctx.body?.decision ?? '');
  if (!['approve', 'reject'].includes(decision)) {
    throw new ApiError('BAD_REQUEST', 'decision 只能是 approve 或 reject');
  }
  const next = decision === 'approve' ? CHECKIN_STATUS.SUCCESS : CHECKIN_STATUS.REJECTED;
  const note = typeof ctx.body?.note === 'string' ? ctx.body.note.trim() : '';

  /*
    ## 驳回必须写说明

    契约（方案 §4.3 / 验收 A12）：**驳回必须给出具体原因**，
    因为志愿者会看到这条说明。只驳回不解释，他完全不知道自己哪里做错了，
    而签到被驳回直接关系到志愿时长认定。

    客户端已本地拦了这一种（`checkin_review_page` 检查 `note.isEmpty`），
    服务端这里是**第二道**：绕过 App 直接调接口、或客户端将来改动，
    都不能出现"无理由驳回"。
  */
  if (decision === 'reject' && note.length < 2) {
    throw new ApiError('BAD_REQUEST', '驳回时必须填写备注（原因），志愿者会看到这条说明', [
      { field: 'note', message: '驳回时必须填写备注' },
    ]);
  }

  const now = toIso(new Date());
  await ctx.db.execute(
    `UPDATE checkin
        SET status = ?, reviewed_at = ?, reviewed_by = ?, review_note = ?
      WHERE id = ?`,
    [next, now, ctx.auth.ownerId, note, row.id],
  );

  const updated = await ctx.db.queryOne('SELECT * FROM checkin WHERE id = ?', [row.id]);
  return { checkin: checkinToWire(updated) };
}

// ─────────────────────────────────────────────────────────────────────────
// 在岗抽查
// ─────────────────────────────────────────────────────────────────────────

/**
 * 为某人生成在岗抽查任务（幂等）。
 *
 * 任务时刻：活动开始后 `attendanceFirstDelay` 分钟起，每隔
 * `attendanceInterval` 分钟一次，末次与结束至少留 `attendanceLastTaskMarginMinutes`。
 */
async function ensureAttendanceTasks(ctx, activity, userNo) {
  /*
    **手动抽查模式的活不自动生成任务**。

    自动模式按"开始后 N 分钟第一次、之后每 M 分钟"铺满整个活动；
    手动模式什么都不生成，等发布者在看板上点「手动抽查」才发一条。
    短活动里自动抽查会让人一直被打断，而发布者其实只想点一两次名。
  */
  if (activity.attendanceMode === ATTENDANCE_MODE.MANUAL) {
    return;
  }
  // 已经结束/取消的活动不该再补出任务（否则用户会收到"永远无法响应"的抽查）
  if (TERMINAL_STATUSES.includes(activity.status)) {
    return;
  }

  const activityId = String(activity.id);
  const start = parseTime(activity.startTime);
  const end = parseTime(activity.endTime);
  if (!start || !end) {
    return;
  }
  const firstDelay = Number(activity.attendanceFirstDelay ?? DEFAULTS.attendanceFirstDelayMinutes);
  const interval = Number(activity.attendanceInterval ?? DEFAULTS.attendanceIntervalMinutes);
  const window = Number(activity.attendanceResponseWindow ?? DEFAULTS.attendanceResponseWindowMinutes);
  const margin = DEFAULTS.attendanceLastTaskMarginMinutes;

  for (let seq = 1; ; seq += 1) {
    const scheduled = new Date(start.getTime() + (firstDelay + (seq - 1) * interval) * 60_000);
    if (scheduled.getTime() > end.getTime() - margin * 60_000) {
      break;
    }
    const exists = await ctx.db.queryOne(
      `SELECT id FROM attendance_task
        WHERE activity_id = ? AND user_no = ? AND seq = ?`,
      [activityId, userNo, seq],
    );
    if (exists) {
      continue;
    }
    await ctx.db.execute(
      `INSERT INTO attendance_task
         (activity_id, user_no, seq, scheduled_at, deadline_at, status)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [
        activityId,
        userNo,
        seq,
        toIso(scheduled),
        toIso(new Date(scheduled.getTime() + window * 60_000)),
        ATTENDANCE_TASK_STATUS.PENDING,
      ],
    );
  }
}

/** 把已过响应窗口仍未响应的任务标记为超时（幂等）。 */
async function settleOverdue(ctx, activityId, now = new Date()) {
  await ctx.db.execute(
    `UPDATE attendance_task
        SET status = ?, settled_at = ?
      WHERE activity_id = ? AND status = ? AND deadline_at <= ?`,
    [
      ATTENDANCE_TASK_STATUS.MISSED,
      toIso(now),
      activityId,
      ATTENDANCE_TASK_STATUS.PENDING,
      toIso(now),
    ],
  );
}

/** `GET /activities/{id}/attendance/tasks` —— 本人（或管理端看全部）在岗任务。 */
export async function listAttendanceTasks(ctx) {
  const raw = await ctx.repos.activities.findById(ctx.params.id);
  if (!raw) {
    throw new ApiError('ACTIVITY_NOT_FOUND');
  }
  const activityId = String(raw.id);
  await settleOverdue(ctx, activityId);

  // 志愿者只看自己的；管理端（且是 owner）看全部。
  const isOwner = ctx.auth?.kind === 'admin' && ctx.auth.ownerId === raw.ownerId;
  const isVolunteer = ctx.auth?.kind === 'volunteer' && ctx.auth.activityId === activityId;
  if (!isOwner && !isVolunteer) {
    throw new ApiError('UNAUTHORIZED');
  }

  const rows = isOwner
    ? await ctx.db.query(
        'SELECT * FROM attendance_task WHERE activity_id = ? ORDER BY seq, user_no',
        [activityId],
      )
    : await ctx.db.query(
        'SELECT * FROM attendance_task WHERE activity_id = ? AND user_no = ? ORDER BY seq',
        [activityId, ctx.auth.userNo],
      );

  return {
    activityId,
    activityTitle: raw.title,
    serverTime: nowIso(),
    items: rows.map(attendanceTaskToWire),
  };
}

/** `POST /attendances/{id}:confirm` —— 志愿者确认在岗。 */
export async function confirmAttendance(ctx) {
  const task = await ctx.db.queryOne('SELECT * FROM attendance_task WHERE id = ?', [
    ctx.params.taskId,
  ]);
  if (!task) {
    throw new ApiError('ATTENDANCE_TASK_NOT_FOUND');
  }
  const activityId = String(task.activity_id);
  const auth = requireVolunteer(ctx, activityId);

  if (task.user_no !== auth.userNo) {
    throw new ApiError('FORBIDDEN', '这不是你的在岗任务');
  }

  const raw = await ctx.repos.activities.findById(activityId);
  const now = new Date();
  await settleOverdue(ctx, activityId, now);

  // 幂等：已确认直接返回。
  if (task.status === ATTENDANCE_TASK_STATUS.DONE) {
    return { task: attendanceTaskToWire(task), alreadyDone: true };
  }
  if (task.status !== ATTENDANCE_TASK_STATUS.PENDING) {
    throw new ApiError('ATTENDANCE_TASK_CLOSED', '该在岗确认已超时，请联系发布者人工补录');
  }

  /*
    窗口**两侧**都要校验。

    真机测试发现过"可以提前把所有未来抽查一次性点掉"——
    只校验了 deadline，没校验 scheduled_at。那等于把在岗抽查废掉了。
  */
  const scheduled = parseTime(task.scheduled_at);
  const deadline = parseTime(task.deadline_at);
  if (scheduled && now.getTime() < scheduled.getTime()) {
    throw new ApiError(
      'ATTENDANCE_TASK_CLOSED',
      `该在岗确认尚未开始，请在 ${toIso(scheduled)} 之后确认`,
    );
  }
  if (deadline && now.getTime() > deadline.getTime()) {
    throw new ApiError('ATTENDANCE_TASK_CLOSED', '该在岗确认已超时，请联系发布者人工补录');
  }

  const submission = normalizeSubmission(ctx.body);
  if (submission.geoLat == null || submission.geoLng == null) {
    throw new ApiError('BAD_REQUEST', '未收到定位证据，无法完成在岗确认');
  }

  const fence = fenceOf(raw);
  const distance = distanceMeters(
    { lat: Number(submission.geoLat), lng: Number(submission.geoLng) },
    fence,
  );

  await ctx.db.execute(
    `UPDATE attendance_task
        SET status = ?, responded_at = ?, geo_lat = ?, geo_lng = ?, accuracy = ?,
            distance_meters = ?, settled_at = ?
      WHERE id = ?`,
    [
      ATTENDANCE_TASK_STATUS.DONE,
      toIso(now),
      submission.geoLat,
      submission.geoLng,
      submission.accuracy,
      distance,
      toIso(now),
      task.id,
    ],
  );

  const updated = await ctx.db.queryOne('SELECT * FROM attendance_task WHERE id = ?', [task.id]);
  return { task: attendanceTaskToWire(updated) };
}

/** `GET /activities/{id}/attendance` —— 考勤汇总。 */
export async function attendanceReport(ctx) {
  const raw = await ctx.repos.activities.findById(ctx.params.id);
  const activity = await assertActivityOwnership(ctx, raw);
  const activityId = String(activity.id);
  await settleOverdue(ctx, activityId);

  const people = await ctx.db.query(
    'SELECT * FROM participant WHERE activity_id = ? AND removed_at IS NULL ORDER BY id',
    [activityId],
  );
  const tasks = await ctx.db.query('SELECT * FROM attendance_task WHERE activity_id = ?', [
    activityId,
  ]);

  const rows = [];
  for (const p of people) {
    const mine = tasks.filter((t) => t.user_no === p.user_no);
    /*
      决策 D-6：抽查任务只为**已签到者**生成。

      所以"没有任务"意味着这人还没签到，不该出现在考勤明细里 ——
      否则他会以"0 次完成 / 完成率 0"出现在汇总里，看起来像缺勤，
      而实际只是还没开始。
    */
    if (mine.length === 0) {
      continue;
    }
    const done = mine.filter((t) => t.status === ATTENDANCE_TASK_STATUS.DONE).length;
    const missed = mine.filter((t) => t.status === ATTENDANCE_TASK_STATUS.MISSED).length;
    const excused = mine.filter((t) => t.status === ATTENDANCE_TASK_STATUS.EXCUSED).length;
    const total = done + missed;
    const summary =
      total === 0
        ? 'no_task'
        : (total - missed) / total >= DEFAULTS.attendancePartialMinRate
          ? 'ok'
          : 'partial';
    rows.push({
      userNo: p.user_no,
      name: p.name ?? '',
      attendanceSummary: summary,
      attendanceDone: done,
      attendanceMissed: missed,
      attendanceExcused: excused,
      attendanceRate: (total - missed) / total,
    });
  }

  return { rows, disclaimer: DISCLAIMER, serverTime: nowIso() };
}

/** `GET /activities/{id}/board` —— 现场看板。 */
export async function activityBoard(ctx) {
  const raw = await ctx.repos.activities.findById(ctx.params.id);
  const activity = await assertActivityOwnership(ctx, raw);
  const activityId = String(activity.id);
  await settleOverdue(ctx, activityId);

  const people = await ctx.db.query(
    'SELECT * FROM participant WHERE activity_id = ? AND removed_at IS NULL ORDER BY id',
    [activityId],
  );
  const checkins = await ctx.db.query('SELECT * FROM checkin WHERE activity_id = ?', [activityId]);
  const tasks = await ctx.db.query('SELECT * FROM attendance_task WHERE activity_id = ?', [
    activityId,
  ]);

  const statusOf = (userNo) => {
    const c = checkins.filter((x) => x.user_no === userNo).pop();
    return c ? c.status : 'none';
  };

  const participants = people.map((p) => ({
    userNo: p.user_no,
    name: p.name ?? '',
    // 学院：与名单接口保持一致。看板原来漏了这个字段，
    // 于是"同一个人在名单页有学院、在看板页没有"—— 现场核对时很别扭。
    ...(p.college ? { college: p.college } : {}),
    signupStatus: p.signup_status === 'registered' ? 'signed' : p.signup_status,
    checkinStatus: statusOf(p.user_no),
    ...(p.phone ? { phone: maskPhoneOf(p.phone) } : {}),
    attendanceDone: tasks.filter(
      (t) => t.user_no === p.user_no && t.status === ATTENDANCE_TASK_STATUS.DONE,
    ).length,
    attendanceMissed: tasks.filter(
      (t) => t.user_no === p.user_no && t.status === ATTENDANCE_TASK_STATUS.MISSED,
    ).length,
    attendanceExcused: tasks.filter(
      (t) => t.user_no === p.user_no && t.status === ATTENDANCE_TASK_STATUS.EXCUSED,
    ).length,
  }));

  const countStatus = (s) => participants.filter((p) => p.checkinStatus === s).length;

  return {
    activityId,
    checkedIn: countStatus(CHECKIN_STATUS.SUCCESS),
    pendingReview: countStatus(CHECKIN_STATUS.PENDING_REVIEW),
    notCheckedIn: countStatus('none'),
    removed: 0,
    attendancePending: tasks.filter((t) => t.status === ATTENDANCE_TASK_STATUS.PENDING).length,
    attendanceDone: tasks.filter((t) => t.status === ATTENDANCE_TASK_STATUS.DONE).length,
    attendanceMissed: tasks.filter((t) => t.status === ATTENDANCE_TASK_STATUS.MISSED).length,
    attendanceExcused: tasks.filter((t) => t.status === ATTENDANCE_TASK_STATUS.EXCUSED).length,
    servingNow: countStatus(CHECKIN_STATUS.SUCCESS),
    serverTime: nowIso(),
    participants,
    disclaimer: DISCLAIMER,
    activityTitle: activity.title,
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 出参映射
// ─────────────────────────────────────────────────────────────────────────

function maskPhoneOf(phone) {
  if (typeof phone !== 'string' || phone.length !== 11) {
    return null;
  }
  return `${phone.slice(0, 3)}****${phone.slice(7)}`;
}

function checkinToWire(row) {
  if (!row) {
    return null;
  }
  return {
    id: String(row.id),
    activityId: String(row.activity_id),
    userNo: row.user_no,
    name: row.name ?? '',
    method: row.method === 'gps' ? 'geo' : row.method,
    status: row.status,
    reason: row.reason ?? null,
    ...(row.geo_lat != null ? { geoLat: Number(row.geo_lat) } : {}),
    ...(row.geo_lng != null ? { geoLng: Number(row.geo_lng) } : {}),
    ...(row.accuracy != null ? { accuracy: Number(row.accuracy) } : {}),
    ...(row.score != null ? { score: Number(row.score) } : {}),
    scoreBreakdown: parseJsonArray(row.score_breakdown) ?? [],
    ...(row.distance_meters != null ? { distanceMeters: Number(row.distance_meters) } : {}),
    mockLocationDetected: Boolean(row.mock_location_detected),
    wifiMatched: Boolean(row.wifi_matched),
    campusIpMatched: Boolean(row.campus_ip_matched),
    offlineBackfill: Boolean(row.offline_backfill),
    ...(row.client_time ? { clientTime: row.client_time } : {}),
    serverTime: row.server_time,
    ...(row.reviewed_at ? { reviewedAt: row.reviewed_at } : {}),
    ...(row.review_note ? { reviewNote: row.review_note } : {}),
    /*
      **谁复核的**必须下发（契约：复核要留痕）。

      少了这一个字段，页面就无法回答"这条是谁通过的"——
      而复核是会把一次签到变成有效志愿时长的动作，没有留痕等于无法追责。
      端到端用例直接断言了 `reviewedBy isNotNull`。
    */
    ...(row.reviewed_by ? { reviewedBy: row.reviewed_by } : {}),
  };
}

function attendanceTaskToWire(row) {
  if (!row) {
    return null;
  }
  return {
    id: String(row.id),
    activityId: String(row.activity_id),
    userNo: row.user_no,
    seq: Number(row.seq),
    scheduledAt: row.scheduled_at,
    deadlineAt: row.deadline_at,
    status: row.status,
    ...(row.notified_at ? { notifiedAt: row.notified_at } : {}),
    ...(row.responded_at ? { respondedAt: row.responded_at } : {}),
    ...(row.geo_lat != null ? { geoLat: Number(row.geo_lat) } : {}),
    ...(row.geo_lng != null ? { geoLng: Number(row.geo_lng) } : {}),
    ...(row.accuracy != null ? { accuracy: Number(row.accuracy) } : {}),
    // 豁免信息：活动取消/结束时未响应的抽查会被置为 excused，
    // 用户端要能说清为什么这次不用确认了。
    ...(row.excused_at ? { excusedAt: row.excused_at } : {}),
    ...(row.excused_reason ? { excusedReason: row.excused_reason } : {}),
    manualFill: Boolean(row.manual_fill),
    ...(row.filled_by ? { filledBy: row.filled_by } : {}),
  };
}

export { checkinToWire, attendanceTaskToWire, addMinutesIso };
