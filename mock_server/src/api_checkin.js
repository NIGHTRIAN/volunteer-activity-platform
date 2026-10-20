/**
 * 签到、在岗响应、降级动态码、考勤汇总与导出。
 *
 * 覆盖：
 *   * GPS 签到：服务端判定（§6.1）、幂等（§9/验收 A23）、离线补传（§6.4/验收 A15）、
 *     模拟定位强制转人工（验收 A13）、坐标偏移识别（验收 A14）
 *   * 人工复核与现场点名补录（§4.8）—— **这是拒定位权限时唯一的降级路径**，
 *     因为本平台不启用动态签到码（决策见 docs/decisions.md D-2）
 *   * 在岗抽查响应：**点一下即完成，零输入**（§5.4/验收 A17、A18、A19）
 *   * 导出（§4.9、§5.6，统一走服务端）
 */

import {
  CHECKIN_ALLOWED_STATUSES,
  CHECKIN_METHOD,
  CHECKIN_STATUS,
  DEFAULTS,
  ERR,
  SIGNUP_STATUS,
  SUMMARY,
  TASK_STATUS,
  TERMINAL_STATUSES,
  msgOf,
} from './constants.js';
import { fail, requireOwnedActivity } from './api_auth.js';
import {
  addMinutes,
  findParticipant,
  findVisibleActivity,
  isRetentionExpired,
  iso,
  newId,
  parseTime,
  store,
} from './store.js';
import {
  buildAttendanceSummary,
  countTasks,
  regenerateAttendanceTasks,
  settleOverdueTasks,
} from './attendance_engine.js';
import { checkGate, distanceMeters, fenceOf, scoreCheckin } from './scoring.js';
import { maskPhone, presentCheckin, presentTask } from './presenters.js';
import crypto from 'node:crypto';

// ─────────────────────────────────────────────────────────────────────────
// 幂等（方案 §9、验收 A23）
// ─────────────────────────────────────────────────────────────────────────

/**
 * 幂等键处理。
 *
 * 幂等键由**客户端**生成并在重试时复用同一个键（方案 §9）。服务端据此保证：
 *   * 同键同内容 → 直接返回上次的响应，**不产生重复记录**；
 *   * 同键不同内容 → 报 `10002`，提示客户端换新键（这是客户端 bug 的信号）。
 */
function withIdempotency(ctx, endpoint, produce) {
  const key = ctx.headers['idempotency-key'] ?? ctx.body?.idempotencyKey;
  if (!key) {
    return produce();
  }
  const bodyHash = crypto
    .createHash('sha256')
    .update(JSON.stringify(ctx.body ?? {}))
    .digest('hex');

  const record = store.db.idempotency[key];
  if (record) {
    if (record.endpoint !== endpoint || record.bodyHash !== bodyHash) {
      return fail(
        ERR.IDEMPOTENCY_CONFLICT,
        '该幂等键已用于内容不同的请求，请更换幂等键后重试',
      );
    }
    // 命中：原样返回缓存响应，附带标记便于联调时确认幂等生效。
    return { ...record.response, idempotentReplay: true };
  }

  const response = produce();
  if (response && typeof response === 'object' && !('__error' in response)) {
    store.db.idempotency[key] = {
      endpoint,
      bodyHash,
      response,
      at: iso(new Date()),
    };
  }
  return response;
}

// ─────────────────────────────────────────────────────────────────────────
// 签到（§5.3、§6.1、§6.4）
// ─────────────────────────────────────────────────────────────────────────

/**
 * 采集服务端侧上下文，用于评分。
 *
 * 这些是客户端**无法伪造或不便自行计算**的量：
 *   * `recentInsideFence`：需要服务端的定位历史；Mock 用同一设备/用户的
 *     在先签到记录近似（真实实现应有一个短期的定位上报缓存）；
 *   * `sameDeviceOtherUsers`：同设备在本活动内的其他账号数（同设备多账号风险）；
 *   * `trajectoryAnomaly`：与本人上一次记录的位置推算出的速度是否合理。
 */
function buildScoreContext({ activity, userNo, deviceId, submission, now }) {
  const ctxOut = { recentInsideFence: false, sameDeviceOtherUsers: 0, trajectoryAnomaly: null };
  const fence = fenceOf(activity);

  if (submission.recentInsideFence === true) {
    ctxOut.recentInsideFence = true;
  }

  // ── 网络辅证（评分表 +20 / +10）───────────────────────────────────
  //
  // ⚠️ 这一段的必要性：`scoreCheckin` 的 Wi-Fi / 校园网加分只读
  // `context.wifiMatched` / `context.campusIpMatched`，**不读请求体**。
  // 早期版本忘了在这里填这两个标志，结果是"客户端老老实实上报了 BSSID，
  // 服务端却一分不给"——评分表写了加分项，实际永远拿不到。
  //
  // 判定依据：
  //   * Wi-Fi：提交的 BSSID 与活动配置的 `wifiBssids` 有交集即算命中；
  //   * 校园网：本机 IP 落在活动配置的 `campusIpPrefixes` 前缀内即算命中。
  // 活动没配这两项时**不加分也不扣分**（无法证明，就不参与判定）。
  ctxOut.wifiMatched = false;
  const allowWifi = Array.isArray(activity.wifiBssids) ? activity.wifiBssids : [];
  if (allowWifi.length > 0) {
    const submitted = Array.isArray(submission.wifiBssids)
      ? submission.wifiBssids
      : submission.wifiBssid
        ? [submission.wifiBssid]
        : [];
    const normalized = new Set(allowWifi.map((b) => String(b).toLowerCase()));
    ctxOut.wifiMatched = submitted.some((b) => normalized.has(String(b).toLowerCase()));
  }

  ctxOut.campusIpMatched = false;
  const allowIp = Array.isArray(activity.campusIpPrefixes) ? activity.campusIpPrefixes : [];
  if (allowIp.length > 0 && submission.localIp) {
    const ip = String(submission.localIp);
    ctxOut.campusIpMatched = allowIp.some((prefix) => ip.startsWith(String(prefix)));
  }

  if (deviceId) {
    const others = new Set(
      store.db.checkins
        .filter(
          (c) =>
            c.activityId === activity.id &&
            c.deviceId === deviceId &&
            c.userNo !== userNo &&
            (c.status === CHECKIN_STATUS.SUCCESS || c.status === CHECKIN_STATUS.PENDING_REVIEW),
        )
        .map((c) => c.userNo),
    );
    ctxOut.sameDeviceOtherUsers = others.size;
  }

  // 轨迹异常：与本人上一次记录比较，速度是否超出合理范围。
  const prior = store.db.checkins
    .filter((c) => c.activityId === activity.id && c.userNo === userNo && c.geoLat != null)
    .sort((a, b) => parseTime(b.serverTime) - parseTime(a.serverTime))[0];
  if (prior && submission.geoLat != null) {
    const dtS = (now - parseTime(prior.serverTime)) / 1000;
    const dist = distanceMeters(
      { lat: Number(prior.geoLat), lng: Number(prior.geoLng) },
      { lat: Number(submission.geoLat), lng: Number(submission.geoLng) },
    );
    if (dtS > 0) {
      const speed = dist / dtS;
      // >30 m/s（108 km/h）在步行活动场景下不合理。
      if (speed > 30) {
        ctxOut.trajectoryAnomaly = `与上次上报位置推算速度异常（${speed.toFixed(1)} m/s）`;
      }
    }
    // 上一次就在围栏内，可作为停留线索。
    if (
      distanceMeters({ lat: Number(prior.geoLat), lng: Number(prior.geoLng) }, fence.center) <=
      fence.radius
    ) {
      ctxOut.recentInsideFence = true;
    }
  }

  return ctxOut;
}

/**
 * 把上报报文规整为内部扁平结构。
 *
 * ## 契约来源：网页方案 §6.4.5（嵌套报文）
 *
 * ```jsonc
 * { "method":"geo",
 *   "location":{ "lat":…, "lng":…, "accuracy":18.5,
 *                "provider":"gps", "samples":3, "sampledAt":"…" },
 *   "network":{ "wifiBssids":["a4:2b:8c:11:22:33"], "sourceIp":"202.119.x.x" },
 *   "device":{ "deviceId":"…", "mockLocationDetected":false },
 *   "clientTime":"…" }
 * ```
 *
 * **同时兼容扁平报文**（`geoLat`/`geoLng`/`accuracy`/`wifiBssid`...）。
 * 理由：早期客户端已经按扁平结构实现，硬切会让联调期的两版客户端
 * 一个都跑不通；两种都收的成本很低（只是几个 `??`）。
 * 但**下发给服务端判定的内部结构统一为扁平**，评分逻辑只有一份。
 *
 * ⚠️ 一个刻意的取舍：契约里的 `location.samples` 是**数量**（int），
 * 而我用**逐次采样数组**做模拟定位交叉验证（也是 +10「多次采样一致」的依据）。
 * 因此：
 *   * 两种都接受 —— `samples` 为数组时取数组，为数字时只记数量；
 *   * 只在数量而无数组时，"采样一致"这一项无法判定，按**不加分**处理
 *     （不猜、不默认给分）。
 *
 * 这一条已列在 `docs/contract-alignment-web-plan.md` §3.2 待澄清。
 */
function normalizeCheckinPayload(body = {}) {
  const loc = body.location ?? {};
  const net = body.network ?? {};
  const dev = body.device ?? {};

  // 采样：数组（我方扩展，反作弊更强）或数量（契约字段）。
  const rawSamples = loc.samples ?? body.samples;
  const samples = Array.isArray(rawSamples) ? rawSamples : [];
  const sampleCount = Array.isArray(rawSamples)
    ? rawSamples.length
    : Number.isFinite(Number(rawSamples))
      ? Number(rawSamples)
      : samples.length;

  // Wi-Fi：契约是复数数组，取第一个作为命中判定输入（评分表只判"是否命中"）。
  const bssids = Array.isArray(net.wifiBssids)
    ? net.wifiBssids
    : net.wifiBssid
      ? [net.wifiBssid]
      : [];

  return {
    // 坐标：契约的 location.lat/lng 优先，兼容扁平 geoLat/geoLng。
    geoLat: loc.lat ?? loc.geoLat ?? body.geoLat ?? null,
    geoLng: loc.lng ?? loc.geoLng ?? body.geoLng ?? null,
    accuracy: loc.accuracy ?? body.accuracy ?? null,
    altitude: loc.altitude ?? body.altitude ?? null,
    speed: loc.speed ?? body.speed ?? null,
    provider: loc.provider ?? body.provider ?? null,
    /** 采样数组（可能为空）。 */
    samples,
    /** 采样数量（无论报文给的是数组还是数字）。 */
    sampleCount,
    /** 主 Wi-Fi BSSID。 */
    wifiBssid: bssids.length > 0 ? String(bssids[0]) : null,
    /** 全部 Wi-Fi BSSID，便于服务端做多 AP 辅证。 */
    wifiBssids: bssids.map(String),
    localIp: net.sourceIp ?? net.localIp ?? body.localIp ?? null,
    deviceId: dev.deviceId ?? body.deviceId ?? null,
    appVersion: dev.appVersion ?? body.appVersion ?? null,
    mockLocationDetected:
      dev.mockLocationDetected === true || body.mockLocationDetected === true,
    clientTime: body.clientTime ?? null,
    method: String(body.method ?? CHECKIN_METHOD.GEO),
    offlineBackfill: body.offlineBackfill === true,
    recentInsideFence: body.recentInsideFence === true,
    userNo: body.userNo ?? null,
  };
}

/**
 * 提交签到（网页方案 §6.4.5）。
 *
 * 判定顺序（方案 §6.4.5 明文）：
 *   ① 活动状态与签到窗口 → ② 是否重复（按活动唯一）
 *   → ③ 客观证据评分 → ④ 降级方式校验（本平台不启用动态码，见决策 D-2）
 *
 * ⚠️ 客户端在这个响应到达前**只能显示「提交中」**（验收 A15）。
 */
export function submitCheckin(ctx) {
  const activityId = ctx.params.id;
  const activity = findVisibleActivity(activityId);
  if (!activity) {
    return fail('ACTIVITY_NOT_FOUND');
  }

  // 志愿者只能给自己签到（活动级授权，网页方案 §6.3）。
  if (ctx.auth.kind === 'volunteer' && ctx.auth.activityId !== activityId) {
    return fail('GRANT_EXPIRED', '你未获得该活动的访问授权');
  }

  return withIdempotency(ctx, `checkin:${activityId}`, () => {
    const now = new Date();
    const payload = normalizeCheckinPayload(ctx.body ?? {});
    const userNo = payload.userNo ?? ctx.auth.userNo;
    const isBackfill = payload.offlineBackfill;
    const participant = findParticipant(activityId, userNo);
    const method = payload.method;

    // ── 门槛校验（判定顺序①②）──────────────────────────────────────
    const gateError = checkGate({ activity, userNo, participant, now, isBackfill });
    if (gateError) {
      if (gateError.code === ERR.NOT_IN_PARTICIPANT_LIST && !participant) {
        // 验收 A10：非名单用户签到的提示必须明确。
        return fail('NOT_IN_PARTICIPANT_LIST');
      }
      return fail(gateError.code, gateError.message);
    }

    // ── 重复签到（判定顺序②）───────────────────────────────────────
    const existing = store.db.checkins.find(
      (c) =>
        c.activityId === activityId &&
        c.userNo === userNo &&
        (c.status === CHECKIN_STATUS.SUCCESS || c.status === CHECKIN_STATUS.PENDING_REVIEW),
    );
    if (existing) {
      // 幂等地返回已有记录，而不是报错——志愿者重复点击是常见操作。
      return {
        checkin: presentCheckin(existing),
        alreadyCheckedIn: true,
        message: msgOf('ALREADY_CHECKED_IN'),
      };
    }

    // ── 不支持的签到方式 ───────────────────────────────────────────
    //
    // 本平台**不启用动态签到码**（决策见 docs/decisions.md D-2），因此只接受
    // 契约规定的 `geo`（网页方案 §6.4.5）。`manual` 是**管理端**的动作，
    // 走 `/activities/:id/checkins/manual`，志愿者端不得自行声明。
    //
    // 明确拒绝而不是"看不懂就当定位处理"：如果客户端还在发旧版的
    // `gps` / `code`，静默按定位处理会得到一个位置证据可能为空的记录，
    // 反而更难排查。`gps` 作为历史写法仍然接受（早期客户端已在用）。
    const acceptedGeo = [CHECKIN_METHOD.GEO, CHECKIN_METHOD.GPS];
    if (!acceptedGeo.includes(method)) {
      return fail(
        'BAD_REQUEST',
        `不支持的签到方式：${method}。本平台不启用签到码，请使用定位签到；` +
          '如无法获取定位，请找发布者现场核实。',
        [{ field: 'method', message: `仅支持定位签到（${CHECKIN_METHOD.GEO}）` }],
      );
    }

    // ── 主判据：GPS 评分（判定顺序③）───────────────────────────────
    const context = buildScoreContext({
      activity,
      userNo,
      deviceId: ctx.headers['x-device-id'] ?? payload.deviceId,
      submission: payload,
      now,
    });

    const scored = scoreCheckin({ activity, submission: payload, context });

    // 离线补传：**一律转待人工确认**（移动端方案 §6.4）。
    //
    // 不管证据多强、甚至独立看已经达到自动通过标准，只要是在签到时段之外
    // 补传的，就不能自动通过——否则「先不去，事后编造一个坐标补传」会成为
    // 一条比正常签到更省事的路径。
    let status = scored.status;
    let reason = scored.reason;
    if (isBackfill && status !== CHECKIN_STATUS.REJECTED) {
      status = CHECKIN_STATUS.PENDING_REVIEW;
      reason = scored.status === CHECKIN_STATUS.SUCCESS
        ? '离线补传：已过签到时段，转人工确认'
        : `离线补传：已过签到时段，转人工确认（${scored.reason}）`;
    }

    const record = buildCheckinRecord({
      activity,
      userNo,
      method: CHECKIN_METHOD.GEO,
      status,
      reason,
      score: scored.score,
      items: scored.items,
      submission: payload,
      now,
      distance: scored.distance,
      deviceId: ctx.headers['x-device-id'] ?? payload.deviceId,
      offlineBackfill: isBackfill,
      coordinateVerdict: scored.coordinateVerdict,
    });
    store.db.checkins.push(record);

    if (status === CHECKIN_STATUS.SUCCESS || status === CHECKIN_STATUS.PENDING_REVIEW) {
      markParticipantCheckedIn(participant, now, status);
    }

    // ── 签到成功后生成在岗抽查任务（决策 D-6）───────────────────────
    //
    // ⚠️ 这一步是 D-6 的**必要配套**，不是可选的优化。
    // 因为抽查任务只为"已签到者"生成，所以生成时机必须晚于签到本身。
    // 放在这里而不是"服务端定时扫描"，是为了让任务在签到那一刻就位 ——
    // 否则志愿者签完到、关掉 App 再打开，中间那段时间不会被抽查覆盖。
    //
    // 幂等由 `(activityId, userNo, seq)` 保证，重复调用安全。
    let attendanceTasksCreated = 0;
    if (status === CHECKIN_STATUS.SUCCESS || status === CHECKIN_STATUS.PENDING_REVIEW) {
      attendanceTasksCreated = regenerateAttendanceTasks(activity, {
        preserveExisting: true,
      });
    }

    store.save();

    return {
      checkin: presentCheckin(record),
      // 把评分构成返回给客户端，管理端复核时可展示「为什么是这个分」。
      scoreBreakdown: scored.items,
      ...(attendanceTasksCreated > 0 ? { attendanceTasksCreated } : {}),
    };
  });
}

function buildCheckinRecord({
  activity,
  userNo,
  method,
  status,
  reason,
  score,
  items,
  submission,
  now,
  distance = null,
  deviceId = null,
  offlineBackfill = false,
  coordinateVerdict = null,
}) {
  const p = findParticipant(activity.id, userNo);
  return {
    id: newId('chk-'),
    activityId: activity.id,
    userNo,
    name: p?.name ?? '',
    method,
    status,
    reason,
    geoLat: submission.geoLat != null ? Number(submission.geoLat) : null,
    geoLng: submission.geoLng != null ? Number(submission.geoLng) : null,
    accuracy: submission.accuracy != null ? Number(submission.accuracy) : null,
    score: score ?? null,
    scoreBreakdown: items ?? [],
    distanceMeters: distance == null ? null : Math.round(distance),
    mockLocationDetected: submission.mockLocationDetected === true,
    clientTime: submission.clientTime ? iso(parseTime(submission.clientTime)) : null,
    serverTime: iso(now),
    samples: Array.isArray(submission.samples) ? submission.samples : [],
    wifiBssid: submission.wifiBssid ?? null,
    localIp: submission.localIp ?? null,
    recentInsideFence: submission.recentInsideFence === true,
    deviceId,
    appVersion: submission.appVersion ?? null,
    offlineBackfill,
    coordinateVerdict,
    reviewedAt: null,
    reviewedBy: null,
    reviewNote: null,
  };
}

function markParticipantCheckedIn(participant, now, status) {
  if (!participant) {
    return;
  }
  participant.checkinStatus =
    status === CHECKIN_STATUS.SUCCESS ? 'checked_in' : 'pending_review';
  participant.lastCheckinAt = iso(now);
}

/** 管理端：签到列表（看板与待复核筛选，方案 §4.8）。 */
export function listCheckins(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  const { status, filter } = ctx.query;
  let items = store.db.checkins.filter((c) => c.activityId === ctx.params.id);

  if (status) {
    const wanted = String(status).split(',').map((s) => s.trim());
    items = items.filter((c) => wanted.includes(c.status));
  }
  if (filter === 'pending_review') {
    items = items.filter((c) => c.status === CHECKIN_STATUS.PENDING_REVIEW);
  } else if (filter === 'mock') {
    items = items.filter((c) => c.mockLocationDetected);
  } else if (filter === 'backfill') {
    items = items.filter((c) => c.offlineBackfill);
  }

  items = [...items].sort((a, b) => parseTime(b.serverTime) - parseTime(a.serverTime));

  return {
    items: items.map(presentCheckin),
    total: items.length,
    counts: {
      success: store.db.checkins.filter(
        (c) => c.activityId === ctx.params.id && c.status === CHECKIN_STATUS.SUCCESS,
      ).length,
      pendingReview: store.db.checkins.filter(
        (c) => c.activityId === ctx.params.id && c.status === CHECKIN_STATUS.PENDING_REVIEW,
      ).length,
      rejected: store.db.checkins.filter(
        (c) => c.activityId === ctx.params.id && c.status === CHECKIN_STATUS.REJECTED,
      ).length,
    },
  };
}

/** 用户端：本人签到。 */
export function myCheckin(ctx) {
  const activityId = ctx.params.id;
  const activity = findVisibleActivity(activityId);
  if (!activity) {
    return fail('ACTIVITY_NOT_FOUND');
  }
  const items = store.db.checkins
    .filter((c) => c.activityId === activityId && c.userNo === ctx.auth.userNo)
    .sort((a, b) => parseTime(b.serverTime) - parseTime(a.serverTime));
  return {
    items: items.map(presentCheckin),
    latest: items.length > 0 ? presentCheckin(items[0]) : null,
    // 「我的记录」仅在有效授权期内可查（方案 §5.5）。
    grantExpiresAt:
      store.db.grants.find((g) => g.token === ctx.auth.token)?.expiresAt ?? null,
  };
}

/** 人工复核（§4.8，验收 A13 的收口环节）。 */
export function reviewCheckin(ctx) {
  const checkin = store.db.checkins.find((c) => c.id === ctx.params.checkinId);
  if (!checkin) {
    return fail('ACTIVITY_NOT_FOUND', '签到记录不存在');
  }
  const owned = requireOwnedActivity(ctx, checkin.activityId);
  if (owned.__error) {
    return owned;
  }

  const decision = String(ctx.body?.decision ?? '');
  const note = String(ctx.body?.note ?? '').trim();

  if (decision !== 'approve' && decision !== 'reject') {
    return fail('BAD_REQUEST', 'decision 必须为 approve 或 reject', [
      { field: 'decision', message: '请选择通过或驳回' },
    ]);
  }
  // 驳回必须填备注：否则志愿者不知道自己哪里没做对。
  if (decision === 'reject' && note.length === 0) {
    return fail('BAD_REQUEST', '驳回必须填写备注', [
      { field: 'note', message: '请填写驳回备注，志愿者会看到这条说明' },
    ]);
  }
  if (checkin.status !== CHECKIN_STATUS.PENDING_REVIEW) {
    return fail(
      ERR.ACTIVITY_STATE_INVALID,
      `该记录当前状态为 ${checkin.status}，仅「待人工确认」的记录可以复核`,
    );
  }

  const now = new Date();
  checkin.status = decision === 'approve' ? CHECKIN_STATUS.SUCCESS : CHECKIN_STATUS.REJECTED;
  checkin.reviewedAt = iso(now);
  checkin.reviewedBy = ctx.auth.ownerId;
  checkin.reviewNote = note || null;
  checkin.reason =
    decision === 'approve'
      ? `人工复核通过${note ? `：${note}` : ''}`
      : `人工复核驳回${note ? `：${note}` : ''}`;

  const p = findParticipant(checkin.activityId, checkin.userNo);
  if (p) {
    p.checkinStatus =
      decision === 'approve' ? 'checked_in' : 'not_checked_in';
  }

  store.save();
  return { checkin: presentCheckin(checkin) };
}

/**
 * 现场点名人工补录（§4.8）。
 *
 * 这是 GPS 判据失效时的兜底手段之一（方案 §7「不得出现死路」）。
 * 补录记录 `method: manual`，且**必须记录操作人**，留痕可查。
 */
export function manualCheckin(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  const activity = owned;
  const { userNo, note } = ctx.body ?? {};
  if (!userNo) {
    return fail('BAD_REQUEST', '请指定要补录的学号', [
      { field: 'userNo', message: '请指定要补录的学号' },
    ]);
  }
  const p = findParticipant(activity.id, String(userNo));
  if (!p || p.signupStatus === SIGNUP_STATUS.CANCELLED || p.removedAt) {
    return fail('NOT_IN_PARTICIPANT_LIST', '该学号不在有效名单中');
  }

  const existing = store.db.checkins.find(
    (c) =>
      c.activityId === activity.id &&
      c.userNo === p.userNo &&
      (c.status === CHECKIN_STATUS.SUCCESS || c.status === CHECKIN_STATUS.PENDING_REVIEW),
  );

  const now = new Date();

  // ── 已有记录：分两种情况处理，不能一律"已签到，直接返回" ──────────
  //
  // 这个分支是**拒定位权限时唯一的降级路径**（本平台不启用动态码，
  // 决策 D-2），所以它必须真的能把人从"待人工确认"救出来。
  //
  //   * `success` → 确实已经签上了，幂等返回，不重复记一条；
  //   * `pending_review` → 发布者现场看着人在场，这就是**复核**。
  //     此时升级为 success，并保留原始证据与评分，注明是人工核实，
  //     而不是新插一条记录（那会产生同一人的两条签到）。
  if (existing) {
    if (existing.status === CHECKIN_STATUS.SUCCESS) {
      return { checkin: presentCheckin(existing), alreadyCheckedIn: true };
    }

    existing.status = CHECKIN_STATUS.SUCCESS;
    existing.reviewedAt = iso(now);
    existing.reviewedBy = ctx.auth.ownerId;
    existing.reviewNote = note || '发布者现场核实';
    existing.reason = `现场核实通过（原判定：${existing.reason ?? '证据不足'}）${
      note ? `：${note}` : ''
    }`;
    existing.manualBy = ctx.auth.ownerId;
    // 不覆盖 method：保留原始采集方式（例如 gps），这样审计里仍能看出
    // "这条记录最初是靠定位报上来的、后来被人工核实"。**单独用
    // verifiedByOwner 标记人工介入**，避免把两种信息混在一个字段里。
    existing.verifiedByOwner = true;

    markParticipantCheckedIn(p, now, CHECKIN_STATUS.SUCCESS);
    store.save();

    return {
      checkin: presentCheckin(existing),
      upgradedFromPendingReview: true,
      note: '已将「待人工确认」升级为已签到，操作人已记录，可在审计中追溯',
    };
  }

  const record = buildCheckinRecord({
    activity,
    userNo: p.userNo,
    method: CHECKIN_METHOD.MANUAL,
    status: CHECKIN_STATUS.SUCCESS,
    reason: `现场点名人工补录${note ? `：${note}` : ''}`,
    score: null,
    items: [{ reason: '管理端现场补录', points: 0 }],
    submission: {},
    now,
  });
  record.manualBy = ctx.auth.ownerId;
  store.db.checkins.push(record);
  markParticipantCheckedIn(p, now, CHECKIN_STATUS.SUCCESS);
  store.save();

  return {
    checkin: presentCheckin(record),
    note: '人工补录已记录操作人，可在审计中追溯',
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 在岗抽查（§5.4、§6.2）
// ─────────────────────────────────────────────────────────────────────────

/**
 * 在岗任务列表 —— **App 前台轮询的入口**（方案 §5.4、§6.2）。
 *
 * 不启用推送，因此这个接口承担了「把待确认任务送到志愿者眼前」的全部职责。
 *
 * 管理端调用时返回全部人的任务（供看板与催办）；
 * 志愿者调用时只返回自己的任务。
 */
export function listAttendanceTasks(ctx) {
  const activity = findVisibleActivity(ctx.params.id);
  if (!activity) {
    return fail('ACTIVITY_NOT_FOUND');
  }

  settleOverdueTasks(activity);

  const { status } = ctx.query;
  let items;
  if (ctx.auth.kind === 'volunteer') {
    items = store.db.attendanceTasks.filter(
      (t) => t.activityId === activity.id && t.userNo === ctx.auth.userNo,
    );
  } else {
    const owned = requireOwnedActivity(ctx, activity.id);
    if (owned.__error) {
      return owned;
    }
    items = store.db.attendanceTasks.filter((t) => t.activityId === activity.id);
  }

  if (status) {
    const wanted = String(status).split(',').map((s) => s.trim());
    items = items.filter((t) => wanted.includes(t.status));
  }

  items = [...items].sort((a, b) => Number(a.seq) - Number(b.seq));

  store.save();
  return {
    activityId: activity.id,
    activityTitle: activity.title,
    // 服务端时间：客户端据此校正倒计时（方案 §9 设备时间不准）。
    serverTime: iso(new Date()),
    items: items.map(presentTask),
    counts: countTasks(activity.id),
  };
}

/**
 * 响应在岗抽查 —— 志愿者的**唯一动作是点一下**（验收 A17）。
 *
 * 零输入、零扫码：客户端随后自动采集一次高精度定位并上报，
 * 服务端置 `done`。
 *
 * ⚠️ 验收 A19：**仅点按「我在」而无现场证据不得通过**。因此这里要求
 * 必须携带有效定位证据，否则转为待人工确认（而不是默默算完成）。
 */
/**
 * 归一化在岗确认的报文。
 *
 * ⚠️ 真机测试抓到的 bug：这里原先直接读 `ctx.body.geoLat` / `ctx.body.accuracy`
 * （扁平字段），而客户端按契约发的是**嵌套**结构：
 *
 * ```json
 * { "method": "geo",
 *   "location": { "lat": 34.218, "lng": 117.137, "accuracy": 30 },
 *   "device": { "mockLocationDetected": false },
 *   "samples": [ { "lat": ..., "lng": ..., "accuracy": ..., "capturedAt": ... } ] }
 * ```
 *
 * 结果 `ctx.body.geoLat` 恒为 undefined，接口永远回
 * 「未收到定位证据，无法完成在岗确认」——**在岗确认根本做不成**。
 *
 * 签到接口早就有 `normalizeCheckinPayload` 处理嵌套，确认接口没跟上，
 * 于是"同一套定位证据、两个接口、两种报文形状"。
 * 现在复用同一个归一化函数，避免再次分叉。
 */
function normalizeAttendancePayload(body = {}) {
  const p = normalizeCheckinPayload(body);
  return {
    lat: p.geoLat,
    lng: p.geoLng,
    accuracy: p.accuracy,
    samples: p.samples,
    mockLocationDetected: p.mockLocationDetected,
  };
}

export function respondAttendance(ctx) {
  /*
    ⚠️ 路径是全局资源 `/attendances/:taskId:confirm`，**不含活动 id**。

    真机测试抓到的 bug：这里原先写的是 `findVisibleActivity(ctx.params.id)`，
    而路由填进 `ctx.params` 的只有 `taskId` —— `ctx.params.id` 恒为 undefined，
    于是**在岗确认接口 100% 返回 404「活动不存在或已过留存期」**，
    整条在岗确认链路在真机上完全不可用。

    为什么单测没抓到：测试是直接调 handler 的，
    并且手工构造了 `params: { id, taskId }` —— 两个参数都塞进去，
    所以 `ctx.params.id` 在测试里是好的。**参数名契约一旦和路由脱节，
    直接调 handler 的测试就永远发现不了。**

    正确做法：以 taskId 为主键找任务，再由 `task.activityId` 推出活动。
    这也符合"任务本身就是资源"的语义。
  */
  const referenced = store.db.attendanceTasks.find((t) => t.id === ctx.params.taskId);
  if (!referenced) {
    return fail('ATTENDANCE_TASK_NOT_FOUND');
  }
  const activity = findVisibleActivity(referenced.activityId);
  if (!activity) {
    return fail('ACTIVITY_NOT_FOUND');
  }
  if (ctx.auth.kind === 'volunteer' && ctx.auth.activityId !== activity.id) {
    return fail('GRANT_EXPIRED', '你未获得该活动的访问授权');
  }

  return withIdempotency(ctx, `attendance:${ctx.params.taskId}`, () => {
    const now = new Date();
    settleOverdueTasks(activity);

    const task = store.db.attendanceTasks.find((t) => t.id === ctx.params.taskId);
    if (!task || task.activityId !== activity.id) {
      return fail('ATTENDANCE_TASK_CLOSED', '在岗任务不存在');
    }
    if (ctx.auth.kind === 'volunteer' && task.userNo !== ctx.auth.userNo) {
      return fail('FORBIDDEN', '这不是你的在岗任务');
    }
    if (task.status !== TASK_STATUS.PENDING) {
      // 幂等：已完成的重复响应直接返回现状，而不是报错。
      if (task.status === TASK_STATUS.DONE) {
        return { task: presentTask(task), alreadyDone: true };
      }
      return fail(
        ERR.ATTENDANCE_TASK_CLOSED,
        task.status === TASK_STATUS.MISSED
          ? '该在岗确认已超时，请联系发布者人工补录'
          : '该在岗确认已结束',
      );
    }
    if (TERMINAL_STATUSES.includes(activity.status)) {
      return fail('ATTENDANCE_TASK_CLOSED', '活动已结束，在岗确认已关闭');
    }

    /*
      ⚠️ 响应窗口**是否已经开始**必须校验 —— 真机测试抓到过这个漏洞。

      抽查任务在签到时就全部预创建好了（T+15 / T+45 / T+75）。
      原先这里只靠 `settleOverdueTasks` 把过期的标成 missed，
      却**没有拦住"还没到点就确认"**。

      后果很严重：志愿者签到完，可以把所有未来的抽查一次性全部点掉，
      "防脱岗"抽查就完全失效了 —— 人走了也能预先交差。

      真机复现：活动 13:25 开始，第 3 次抽查计划 14:40，
      14:03 点「我在现场」直接 `done`。

      正确口径：只有在 [scheduledAt, deadlineAt] 窗口内才允许确认。
      deadline 那侧由 settleOverdueTasks 处理，这里补上 scheduledAt 这侧。
    */
    const scheduledAt = parseTime(task.scheduledAt);
    // ⚠️ `parseTime` 返回的是 **Date 对象**，不是毫秒数。
    //
    // 这里踩过一次：写成 `Number.isFinite(parseTime(...))` 恒为 false，
    // 守卫被静默跳过 —— 看起来有校验，实际一次都没生效。
    // （代码库里 `parseTime(a) - parseTime(b)` 能工作是因为 `-` 会强制转数字，
    //   但 `Number.isFinite` 不会。）
    const scheduledMs = scheduledAt ? scheduledAt.getTime() : Number.NaN;
    if (Number.isFinite(scheduledMs) && now.getTime() < scheduledMs) {
      // 用 HH:mm 而不是完整 ISO：这句话是给现场志愿者看的，
      // 他只需要知道"几点之后能点"。
      const hhmm = String(task.scheduledAt).slice(11, 16);
      return fail(
        ERR.ATTENDANCE_TASK_CLOSED,
        `该在岗确认尚未开始，请在 ${hhmm} 之后再确认`,
      );
    }

    // 记录「已通知」时刻，用于区分「人不在」与「通知没到」（方案 §13-A5）。
    task.notifiedAt = task.notifiedAt ?? iso(now);

    // 报文归一化：兼容契约的嵌套 `location` 与早期扁平 `geoLat`。
    const payload = normalizeAttendancePayload(ctx.body ?? {});
    const lat = payload.lat;
    const lng = payload.lng;
    const accuracy = Number(payload.accuracy);
    const hasFix =
      Number.isFinite(Number(lat)) &&
      Number.isFinite(Number(lng)) &&
      !(Number(lat) === 0 && Number(lng) === 0);

    // 验收 A19：没有现场证据不通过。
    if (!hasFix) {
      return fail(
        ERR.BAD_REQUEST,
        '未收到定位证据，无法完成在岗确认。请确认已开启定位权限后重试。',
        [{ field: 'geoLat', message: '缺少定位证据' }],
      );
    }
    if (!Number.isFinite(accuracy) || accuracy <= 0 || accuracy > DEFAULTS.MAX_USABLE_ACCURACY_M) {
      // 精度不达标：不直接判失败（可能是室内），但也不能算完成。
      // 置为待人工确认，由发布者现场核对——这是"不出现死路"的体现（方案 §7）。
      task.status = TASK_STATUS.PENDING;
      task.needsManualReview = true;
      task.reviewNote = `定位精度 ${Number.isFinite(accuracy) ? Math.round(accuracy) : '未知'} 米，超过 100 米门槛`;
      task.geoLat = Number(lat);
      task.geoLng = Number(lng);
      task.accuracy = Number.isFinite(accuracy) ? accuracy : null;
      task.respondedAt = iso(now);
      store.save();
      return {
        task: presentTask(task),
        needsManualReview: true,
        message: '定位精度不足，已提交给发布者人工确认',
      };
    }

    const fence = fenceOf(activity);
    const dist = distanceMeters({ lat: Number(lat), lng: Number(lng) }, fence.center);

    // 模拟定位命中：强制转人工，不自动算完成（与签到同一口径）。
    // 读归一化后的值，兼容嵌套 `device.mockLocationDetected` 与扁平字段。
    if (payload.mockLocationDetected === true) {
      task.status = TASK_STATUS.PENDING;
      task.needsManualReview = true;
      task.reviewNote = '检测到模拟定位，需人工确认';
      task.geoLat = Number(lat);
      task.geoLng = Number(lng);
      task.accuracy = accuracy;
      task.respondedAt = iso(now);
      store.save();
      return {
        task: presentTask(task),
        needsManualReview: true,
        message: '检测到模拟定位，已转人工确认',
      };
    }

    // 在岗抽查的判定口径比签到宽松：这是**防脱岗**抽查，不是入场判定。
    // 只要人在围栏外沿的合理范围内即视为在岗；否则需人工确认。
    const tolerance = Math.max(fence.radius * 2, 500);
    if (dist > tolerance) {
      task.status = TASK_STATUS.PENDING;
      task.needsManualReview = true;
      task.reviewNote = `距场地约 ${Math.round(dist)} 米，超出在岗容许范围`;
      task.geoLat = Number(lat);
      task.geoLng = Number(lng);
      task.accuracy = accuracy;
      task.respondedAt = iso(now);
      store.save();
      return {
        task: presentTask(task),
        needsManualReview: true,
        message: `距场地约 ${Math.round(dist)} 米，已提交给发布者人工确认`,
      };
    }

    task.status = TASK_STATUS.DONE;
    task.geoLat = Number(lat);
    task.geoLng = Number(lng);
    task.accuracy = accuracy;
    task.respondedAt = iso(now);
    task.distanceMeters = Math.round(dist);
    store.save();

    return {
      task: presentTask(task),
      distanceMeters: Math.round(dist),
      message: '在岗确认已完成',
    };
  });
}

/** 管理端催办（§4.8）。不启用推送，因此这是**记录一次催办动作**。 */
export function remindAttendance(ctx) {
  /*
    与 respondAttendance 同一个坑：路由 `/attendances/:taskId:remind`
    只给 `taskId`，没有活动 id。这里同样改成"先按 taskId 找任务，
    再用 task.activityId 校验归属"。
  */
  const task = store.db.attendanceTasks.find((t) => t.id === ctx.params.taskId);
  if (!task) {
    return fail('ATTENDANCE_TASK_NOT_FOUND');
  }
  const owned = requireOwnedActivity(ctx, task.activityId);
  if (owned.__error) {
    return owned;
  }
  const now = new Date();
  task.remindedAt = iso(now);
  task.remindCount = (task.remindCount ?? 0) + 1;
  store.save();
  return {
    task: presentTask(task),
    remindCount: task.remindCount,
    // ⚠️ 诚实说明：不启用推送，所以服务端无法真正「送达」提醒。
    // 这条记录用于现场口头催办时的台账，也用于事后区分。
    deliveryChannel: 'onsite_verbal',
    message: '已记录催办。本平台不启用推送，请现场口头提醒志愿者打开 App。',
  };
}

/** 在岗人工补录（§4.8 兜底）。 */
export function manualAttendance(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  const activity = owned;
  const { userNo, seq, note } = ctx.body ?? {};
  if (!userNo) {
    return fail('BAD_REQUEST', '请指定要补录的学号', [
      { field: 'userNo', message: '请指定要补录的学号' },
    ]);
  }
  const p = findParticipant(activity.id, String(userNo));
  if (!p) {
    return fail('NOT_IN_PARTICIPANT_LIST', '该学号不在名单中');
  }

  let task;
  if (seq != null) {
    task = store.db.attendanceTasks.find(
      (t) => t.activityId === activity.id && t.userNo === p.userNo && Number(t.seq) === Number(seq),
    );
  } else {
    // 未指定序号：补录最近一个未结案的任务。
    task = store.db.attendanceTasks
      .filter((t) => t.activityId === activity.id && t.userNo === p.userNo && t.status !== TASK_STATUS.DONE)
      .sort((a, b) => parseTime(a.scheduledAt) - parseTime(b.scheduledAt))[0];
  }

  if (!task) {
    return fail('ATTENDANCE_TASK_CLOSED', '没有可补录的在岗任务（可能已完成或尚未生成）');
  }

  const now = new Date();
  const wasStatus = task.status;
  task.status = TASK_STATUS.DONE;
  task.manualFill = true;
  task.filledBy = ctx.auth.ownerId;
  task.respondedAt = iso(now);
  task.reviewNote = note ? `人工补录：${note}` : '人工补录';
  task.previousStatus = wasStatus;
  store.save();

  return {
    task: presentTask(task),
    previousStatus: wasStatus,
    note: '人工补录已记录操作人，可在审计中追溯',
  };
}

/** 考勤汇总（§4.8）。 */
export function attendanceSummaryReport(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  settleOverdueTasks(owned);
  store.save();
  return buildAttendanceSummary(owned);
}

// ─────────────────────────────────────────────────────────────────────────
// 降级手段：不启用动态签到码（决策见 docs/decisions.md D-2）
// ─────────────────────────────────────────────────────────────────────────
//
// 方案 §6.3 设计了动态签到码（签到码 5 分钟、在岗码 60 秒轮换、预取续播）。
// 本项目决定**不实现**，已移除 `issueCheckinCode` / `currentCheckinCode` 与
// `/activities/:id/checkin-code` 端点。
//
// 拒定位权限时的降级路径（方案 §7「不得出现死路」）现在只剩两条，都在管理端：
//   1. **现场核实**：发布者看人到了，在管理端看板调用
//      `POST /activities/:id/checkins/manual`，记录 `method = manual`，
//      并带 `note` 说明是现场核实；
//   2. **人工补录**：同一端点，用于设备故障、事后补录等情形。
//
// 两者都必须记录操作人（`manualBy`），可在审计中追溯。

// ─────────────────────────────────────────────────────────────────────────
// 导出（网页方案 §6.4.8）
//
// 契约是**统一入口、直接下载**：
//   GET /api/v1/activities/{id}/export?format=csv
//   GET /api/v1/export/activities?dateFrom=&dateTo=&status=finished&format=csv
//
// 「服务端生成（UTF-8 BOM），三端共用；含个人信息时附"仅限内部使用"提示；
//   用户端仅可导出已结束活动。」
//
// 早期我实现成「POST 建任务 → 轮询 → 下载」，那是错的方向：
// 方案明确要的是**一次 GET 拿到文件**。任务式导出对客户端更麻烦
//（要处理轮询、过期、重试），而这里的数据量（每活动 ≤500 行，方案 §4.8）
// 根本不需要异步。
// ─────────────────────────────────────────────────────────────────────────

/**
 * 导出单个活动。
 *
 * 查询参数：
 *   * `format` —— `csv`（默认）。目前只有 csv，保留参数是为了将来加 xlsx。
 *   * `kind` —— `checkin_list`（默认）/ `attendance_detail` / `summary` /
 *     `participants` / `my_records`（志愿者自动落到这个）。
 *   * `includeFullContact` —— `true` 时输出完整手机号（**仅管理端**，且留审计）。
 *
 * 权限（方案 §6.4.8）：
 *   * 管理端：只能导出**自己名下**的活动（`ownerId` 隔离）；
 *   * 用户端：只能导出**已结束**活动的**本人**记录。
 */
export function exportActivity(ctx) {
  const activity = findVisibleActivity(ctx.params.id);
  if (!activity) {
    return fail('ACTIVITY_NOT_FOUND');
  }

  const requestedKind = String(ctx.query.kind ?? ctx.query.type ?? 'checkin_list');
  const includeFullContact = ctx.query.includeFullContact === 'true';

  const prepared = prepareExport(ctx, activity, { requestedKind, includeFullContact });
  if (prepared.__error) {
    return prepared;
  }

  return sendCsv(ctx, prepared);
}

/**
 * 批量导出活动汇总（方案 §6.4.8 的第二个入口）。
 *
 * ```
 * GET /api/v1/export/activities?dateFrom=&dateTo=&status=finished&format=csv
 * ```
 *
 * 面向"按时间段导出汇总"的场景（管理端收尾对账、Web 统计页导出）。
 */
export function exportActivities(ctx) {
  if (ctx.auth?.kind !== 'admin') {
    return fail('ROLE_NOT_ALLOWED', '该导出仅管理端可用');
  }
  const dateFrom = parseTime(ctx.query.dateFrom);
  const dateTo = parseTime(ctx.query.dateTo);
  const statusFilter = ctx.query.status
    ? String(ctx.query.status)
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean)
    : null;

  const now = new Date();
  const rows = store.db.activities.filter((a) => {
    if (a.ownerId !== ctx.auth.ownerId) return false;
    if (isRetentionExpired(a, now)) return false;
    if (statusFilter && !statusFilter.includes(a.status)) return false;
    const start = parseTime(a.startTime);
    if (dateFrom && start && start < dateFrom) return false;
    if (dateTo && start && start > dateTo) return false;
    return true;
  });

  const lines = [csvRow(['# 志愿活动信息平台导出 · 仅限内部使用'])];
  lines.push(csvRow([`# 生成时间 ${iso(new Date())}`]));
  if (dateFrom || dateTo) {
    lines.push(
      csvRow([
        `# 时间范围 ${dateFrom ? iso(dateFrom) : '不限'} ~ ${dateTo ? iso(dateTo) : '不限'}`,
      ]),
    );
  }
  lines.push('');
  lines.push(
    csvRow([
      '外部唯一号',
      '活动名称',
      '组织部门',
      '时长(小时)',
      '开始时间',
      '结束时间',
      '状态',
      '地点',
      '名额',
      '已报名',
      '已签到',
      '考勤完成',
      '考勤超时',
    ]),
  );

  for (const a of rows) {
    const participants = store.db.participants.filter(
      (p) => p.activityId === a.id && p.signupStatus !== 'cancelled' && !p.removedAt,
    );
    const checkins = store.db.checkins.filter(
      (c) =>
        c.activityId === a.id &&
        (c.status === CHECKIN_STATUS.SUCCESS || c.status === CHECKIN_STATUS.PENDING_REVIEW),
    );
    const tasks = store.db.attendanceTasks.filter((t) => t.activityId === a.id);
    lines.push(
      csvRow([
        a.externalId ?? '',
        a.title,
        a.organizer,
        a.durationHours,
        a.startTime,
        a.endTime,
        a.status,
        a.location ?? '',
        a.quota ?? '',
        participants.length,
        checkins.length,
        tasks.filter((t) => t.status === 'done').length,
        tasks.filter((t) => t.status === 'missed').length,
      ]),
    );
  }

  return sendCsv(ctx, {
    content: lines.join('\n'),
    fileName: `活动汇总-${iso(new Date()).replace(/[:T]/g, '-').slice(0, 19)}.csv`,
    rowCount: rows.length,
    includeFullContact: false,
  });
}

/**
 * 权限与参数校验，并生成 CSV 内容。
 *
 * 抽出来是因为两个导出入口共用同一套权限规则与脱敏策略 ——
 * 如果各写一份，迟早会出现"一个入口忘了脱敏"。
 */
function prepareExport(ctx, activity, { requestedKind, includeFullContact }) {
  let kind = requestedKind;

  if (ctx.auth.kind === 'volunteer') {
    if (ctx.auth.activityId !== activity.id) {
      return fail('GRANT_EXPIRED', '你未获得该活动的访问授权');
    }
    // 方案 §6.4.8：「用户端仅可导出已结束活动」。
    if (activity.status !== 'finished') {
      return fail(
        'ACTIVITY_STATE_INVALID',
        '仅已结束的活动可以导出（活动结束后你仍可在 7 天留存期内导出）',
      );
    }
    // 志愿者只能导出自己的记录 —— 无论它请求什么 kind。
    kind = 'my_records';
    if (includeFullContact) {
      return fail('FORBIDDEN', '仅活动发布者可导出完整联系方式');
    }
  } else {
    const owned = requireOwnedActivity(ctx, activity.id);
    if (owned.__error) {
      return owned;
    }
  }

  const valid = ['checkin_list', 'attendance_detail', 'summary', 'my_records', 'participants'];
  if (!valid.includes(kind)) {
    return fail('BAD_REQUEST', `不支持的导出类型：${kind}`, [
      { field: 'kind', message: `可选值：${valid.join(' / ')}` },
    ]);
  }

  const job = {
    activityId: activity.id,
    kind,
    requestedBy: ctx.auth.kind === 'admin' ? ctx.auth.ownerId : ctx.auth.userNo,
    requestedByKind: ctx.auth.kind,
    includeFullContact,
  };

  const csv = renderCsv(job, activity, { includeFullContact });

  // 敏感导出留痕（决策 D-3）：
  // 默认脱敏不进审计，避免把审计日志淹没在正常操作里。
  if (includeFullContact) {
    store.db.exportAudits = store.db.exportAudits ?? [];
    store.db.exportAudits.unshift({
      at: iso(new Date()),
      activityId: activity.id,
      kind,
      requestedBy: job.requestedBy,
      ip: ctx.ip ?? null,
      rowCount: csv.rowCount,
      includesFullContact: true,
    });
    if (store.db.exportAudits.length > 200) {
      store.db.exportAudits.length = 200;
    }
    store.save();
  }

  return {
    content: csv.content,
    fileName: csv.fileName,
    rowCount: csv.rowCount,
    includeFullContact,
  };
}

/**
 * 以附件形式直接发送 CSV。
 *
 * 两个细节不能省：
 *   * **UTF-8 BOM** —— 否则 Excel 打开中文乱码（方案 §6.4.8 明文要求）；
 *   * `Content-Disposition` 用 `filename*=UTF-8''` 形式 —— 中文文件名
 *     用裸 `filename=` 会在部分浏览器/客户端上变成乱码或被截断。
 */
function sendCsv(ctx, { content, fileName, rowCount, includeFullContact }) {
  const res = ctx.res;
  const payload = Buffer.from(`\uFEFF${content ?? ''}`, 'utf8');
  const safeName = fileName ?? 'export.csv';
  res.writeHead(200, {
    'Content-Type': 'text/csv; charset=utf-8',
    'Content-Length': payload.length,
    // 同时给 filename（ASCII 兜底）与 filename*（UTF-8 正确名）。
    'Content-Disposition':
      `attachment; filename="export.csv"; ` +
      `filename*=UTF-8''${encodeURIComponent(safeName)}`,
    'Access-Control-Allow-Origin': '*',
    // 让客户端（尤其是 Web 端）能读到提示语。
    'X-Export-Rowcount': String(rowCount ?? 0),
    'X-Export-Notice': encodeURIComponent(
      includeFullContact
        ? '本文件含完整联系方式，仅限内部使用，请勿外传'
        : '本文件含个人信息，仅限内部使用',
    ),
  });
  res.end(payload);
  return undefined;
}

/** 下载早先任务式导出的文件（保留兼容）。 */
export function downloadExport(ctx) {
  const job = store.db.exports.find((e) => e.id === ctx.params.exportId);
  if (!job || job.status !== 'ready') {
    return fail('EXPORT_NOT_FOUND', '导出文件不存在或尚未生成');
  }
  return sendCsv(ctx, {
    content: job.content,
    fileName: job.fileName,
    rowCount: job.rowCount,
    includeFullContact: job.includeFullContact === true,
  });
}

/** 把一行单元格序列化为 CSV 行，按需加引号。 */
function csvRow(cells) {
  return cells
    .map((c) => {
      const s = c == null ? '' : String(c);
      return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    })
    .join(',');
}

/**
 * CSV 序列化。
 *
 * [includeFullContact] 为 `true` 时输出完整手机号——这是发布者现场打电话
 * 催人所需，但也是唯一会让完整号码落地的路径，因此：
 *   * 默认关闭；
 *   * 调用前已写入导出审计（谁、何时、多少行）；
 *   * 文件头会明确标注"含完整联系方式"，避免被当成普通名单随手转发。
 */
function renderCsv(job, activity, { includeFullContact = false } = {}) {
  const lines = [];
  const now = iso(new Date());
  // 表头固定加上「仅限内部使用」提示（README §3.3 底线③）。
  lines.push(csvRow([`# 志愿活动信息平台导出 · 仅限内部使用 · 生成时间 ${now}`]));
  lines.push(csvRow([`# 活动：${activity.title}（${activity.organizer}）`]));
  lines.push(csvRow([`# 时段：${activity.startTime} ~ ${activity.endTime}`]));
  if (includeFullContact) {
    lines.push(
      csvRow(['# ⚠️ 本文件含完整联系方式，请勿外传、勿公开张贴，用毕及时删除。']),
    );
  }
  lines.push(
    csvRow(['# 说明：考勤结果仅作现场管理参考，不作为志愿时长认定依据，不自动产生任何扣减。']),
  );
  lines.push('');

  /** 按导出选项决定手机号是否脱敏。 */
  const phoneOf = (p) => (includeFullContact ? (p.phone ?? '') : maskPhone(p.phone));

  let rowCount = 0;

  if (job.kind === 'participants' || job.kind === 'checkin_list') {
    lines.push(
      csvRow(['学号', '姓名', '手机号', '报名状态', '签到状态', '签到方式', '签到时间', '评分', '备注']),
    );
    let people = store.db.participants.filter((p) => p.activityId === activity.id);
    if (job.kind === 'checkin_list') {
      people = people.filter((p) => p.signupStatus !== SIGNUP_STATUS.CANCELLED && !p.removedAt);
    }
    for (const p of people) {
      const c = store.db.checkins.find(
        (x) =>
          x.activityId === activity.id &&
          x.userNo === p.userNo &&
          (x.status === CHECKIN_STATUS.SUCCESS || x.status === CHECKIN_STATUS.PENDING_REVIEW),
      );
      lines.push(
        csvRow([
          p.userNo,
          p.name,
          // 默认脱敏（文件会被转发、会被打印，明文号码一旦落地就收不回来）；
          // 发布者显式要求时才出完整号码，且该导出已进审计（决策 D-3）。
          phoneOf(p),
          p.signupStatus,
          c ? c.status : 'not_checked_in',
          c ? c.method : '',
          c ? c.serverTime : '',
          c && c.score != null ? c.score : '',
          p.removedAt ? `已移出（${p.removedAt}）` : c ? c.reason : '',
        ]),
      );
      rowCount += 1;
    }
  } else if (job.kind === 'attendance_detail') {
    lines.push(
      csvRow([
        '学号',
        '姓名',
        '抽查序号',
        '计划时刻',
        '响应截止',
        '状态',
        '响应时间',
        '距离(米)',
        '精度(米)',
        '是否人工补录',
        '考勤汇总',
        '备注',
      ]),
    );
    const tasks = store.db.attendanceTasks
      .filter((t) => t.activityId === activity.id)
      .sort((a, b) => Number(a.seq) - Number(b.seq));
    // 每人一行汇总等级。放在明细导出里是刻意的：
    // 发布者看明细时最常问的问题是"这个人整体算不算到岗"，
    // 让他再去另一个导出里对号会很难用。
    const summaryByUser = new Map(
      buildAttendanceSummary(activity).rows.map((r) => [r.userNo, r.attendanceSummary]),
    );
    for (const t of tasks) {
      const p = findParticipant(activity.id, t.userNo);
      lines.push(
        csvRow([
          t.userNo,
          p?.name ?? '',
          t.seq,
          t.scheduledAt,
          t.deadlineAt,
          t.status,
          t.respondedAt ?? '',
          t.distanceMeters ?? '',
          t.accuracy ?? '',
          t.manualFill ? '是' : '否',
          summaryLabel(summaryByUser.get(t.userNo) ?? 'unknown'),
          t.reviewNote ?? t.excusedReason ?? '',
        ]),
      );
      rowCount += 1;
    }
  } else if (job.kind === 'summary') {
    lines.push(csvRow(['学号', '姓名', '签到状态', '在岗完成', '在岗超时', '在岗豁免', '考勤汇总']));
    const summary = buildAttendanceSummary(activity);
    for (const r of summary.rows) {
      lines.push(
        csvRow([
          r.userNo,
          r.name,
          r.checkinStatus === 'checked_in' ? '已签到' : '未签到',
          r.attendanceDone,
          r.attendanceMissed,
          r.attendanceExcused,
          summaryLabel(r.attendanceSummary),
        ]),
      );
      rowCount += 1;
    }
  } else if (job.kind === 'my_records') {
    // 志愿者导出自己的记录：**只含本人**，不含他人信息。
    lines.push(csvRow(['项目', '内容']));
    const userNo = job.requestedBy;
    const p = findParticipant(activity.id, userNo);
    const c = store.db.checkins
      .filter((x) => x.activityId === activity.id && x.userNo === userNo)
      .sort((a, b) => parseTime(b.serverTime) - parseTime(a.serverTime))[0];
    const tasks = store.db.attendanceTasks.filter(
      (t) => t.activityId === activity.id && t.userNo === userNo,
    );
    const rows = [
      ['活动名称', activity.title],
      ['组织部门', activity.organizer],
      ['活动时段', `${activity.startTime} ~ ${activity.endTime}`],
      ['志愿时长（展示值）', `${activity.durationHours} 小时`],
      ['本人学号', userNo],
      ['本人姓名', p?.name ?? ''],
      ['报名状态', p?.signupStatus ?? ''],
      ['签到结果', c ? c.status : '未签到'],
      ['签到时间', c ? c.serverTime : ''],
      ['签到方式', c ? c.method : ''],
      ['未通过原因', c ? (c.reason ?? '') : ''],
      ['在岗抽查完成', String(tasks.filter((t) => t.status === TASK_STATUS.DONE).length)],
      ['在岗抽查超时', String(tasks.filter((t) => t.status === TASK_STATUS.MISSED).length)],
      ['在岗抽查豁免', String(tasks.filter((t) => t.status === TASK_STATUS.EXCUSED).length)],
      ['免责说明', '考勤结果仅作现场管理参考，不作为志愿时长认定依据。'],
    ];
    for (const [k, v] of rows) {
      lines.push(csvRow([k, v]));
      rowCount += 1;
    }
  }

  const stamp = now.replace(/[:T]/g, '-').slice(0, 19);
  return {
    fileName: `${activity.title}-${job.kind}-${stamp}.csv`,
    content: lines.join('\n'),
    rowCount,
  };
}

function summaryLabel(s) {
  switch (s) {
    case SUMMARY.FULL:
      return '全勤';
    case SUMMARY.PARTIAL:
      return '部分完成';
    case SUMMARY.INSUFFICIENT:
      return '证据不足';
    case SUMMARY.ABSENT:
      return '缺席';
    default:
      return '未知';
  }
}
