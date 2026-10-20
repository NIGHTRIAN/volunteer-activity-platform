/**
 * 签到证据判定（方案 §6.1 评分表）。
 *
 * ## 这份实现的口径来源
 *
 * 不是凭空写的：mock_server 的 `scoring.js` 是真机测试期间反复修正过的版本，
 * 本次移植**逐条对齐**，并且双方都从 `contract/constants.js` 的
 * `DEFAULTS` 取权重与阈值 —— 只有一套数字。
 *
 * ## 移植时必须保留的几个"踩过的坑"
 *
 * 1. **模拟定位的判定条件**
 *    早期只要"多次采样完全一致"就判伪造，误杀了静止在室内的真实用户
 *    （GPS 抖动小本来正常）。现在要求**坐标与精度都完全一致 且 精度 ≤5m**。
 *
 * 2. **精度 >100m 是"不计分"，不是"直接驳回"**
 *    设备定位模块偶发劣化是常事，直接驳回会让志愿者没有申诉通道。
 *    不计分后通常会落到"待确认"，仍有人工兜底。
 *
 * 3. **无有效坐标转人工，不驳回**
 *    现场还有人工补录等降级手段（方案 §7「不得出现死路」）。
 *
 * 4. **围栏外 1.5 倍半径内给 0 分而不是负分**
 *    边界抖动不该被判死，但也不能加分 —— 验收用例 A12 要求
 *    1.5 倍半径外必须被驳回。
 */

import { CHECKIN_STATUS, DEFAULTS } from './contract.js';

/** 两点间距离（米，WGS-84 球面近似）。 */
export function distanceMeters(a, b) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const lat1 = toRad(a.lat);
  const lat2 = toRad(b.lat);
  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

/** 活动的围栏中心与半径。 */
export function fenceOf(activity) {
  return {
    lat: Number(activity.geoLat),
    lng: Number(activity.geoLng),
    radius: Number(activity.checkinRadius ?? DEFAULTS.checkinRadiusOutdoor),
  };
}

/**
 * 检测模拟定位。
 *
 * @returns {{detected: boolean, reason: string|null}}
 */
export function detectMockLocation({ clientFlagged, samples = [] }) {
  if (clientFlagged === true) {
    return { detected: true, reason: '设备上报定位来自模拟位置提供者' };
  }
  if (!Array.isArray(samples) || samples.length < DEFAULTS.minSamplesForConsistency) {
    return { detected: false, reason: null };
  }

  const first = samples[0];
  const allSameCoord = samples.every(
    (s) => Math.abs(Number(s.lat) - Number(first.lat)) < 1e-9 &&
      Math.abs(Number(s.lng) - Number(first.lng)) < 1e-9,
  );
  const allSameAccuracy = samples.every(
    (s) => Number(s.accuracy) === Number(first.accuracy),
  );
  const perfectAccuracy = Number(first.accuracy) > 0 &&
    Number(first.accuracy) <= DEFAULTS.mockPerfectAccuracyMeters;

  if (allSameCoord && allSameAccuracy && perfectAccuracy) {
    return {
      detected: true,
      reason: '多次采样坐标与精度完全一致，且精度异常理想（±' +
        `${Number(first.accuracy).toFixed(0)}m），疑似模拟定位`,
    };
  }
  return { detected: false, reason: null };
}

/** 多个采样是否算"一致"（用于 +10 分）。 */
export function samplesConsistent(samples = []) {
  if (!Array.isArray(samples) || samples.length < DEFAULTS.minSamplesForConsistency) {
    return { consistent: false, spreadMeters: null };
  }
  const valid = samples.filter((s) => Number.isFinite(Number(s.lat)) && Number.isFinite(Number(s.lng)));
  if (valid.length < DEFAULTS.minSamplesForConsistency) {
    return { consistent: false, spreadMeters: null };
  }
  // 展开的最大距离：任意两点的最大间距（用与首点的最大距离近似，够用且 O(n)）。
  let maxSpread = 0;
  for (const s of valid) {
    maxSpread = Math.max(
      maxSpread,
      distanceMeters(
        { lat: Number(valid[0].lat), lng: Number(valid[0].lng) },
        { lat: Number(s.lat), lng: Number(s.lng) },
      ),
    );
  }
  // 50m 内视为一致：定位抖动在室内可能到几十米，再严格会大量误判。
  return { consistent: maxSpread <= 50, spreadMeters: maxSpread };
}

/**
 * 主评分函数。
 *
 * @param {object} p
 * @param {object} p.activity 活动（含 geoLat/geoLng/checkinRadius/白名单）
 * @param {object} p.submission 归一化后的证据
 * @param {object} [p.context] `{ wifiMatched, campusIpMatched, recentInsideFence, multiAccountSameDevice, trajectoryAnomaly }`
 */
export function scoreCheckin({ activity, submission, context = {} }) {
  const items = [];
  const fence = fenceOf(activity);

  const lat = Number(submission.geoLat);
  const lng = Number(submission.geoLng);
  const accuracy = Number(submission.accuracy);
  const hasFix =
    Number.isFinite(lat) && Number.isFinite(lng) && !(lat === 0 && lng === 0);

  const mock = detectMockLocation({
    clientFlagged: submission.mockLocationDetected === true,
    samples: submission.samples ?? [],
  });

  // 无坐标：转人工而不是驳回（设备故障不该让人当场失去申诉机会）。
  if (!hasFix) {
    items.push({ reason: '未收到有效定位坐标', points: 0 });
    return {
      score: 0,
      status: CHECKIN_STATUS.PENDING_REVIEW,
      reason: '未收到有效定位坐标，已转人工确认',
      distanceMeters: null,
      items,
      mockLocationDetected: mock.detected,
    };
  }

  const distance = distanceMeters({ lat, lng }, fence);
  const accuracyUsable =
    Number.isFinite(accuracy) && accuracy > 0 && accuracy <= DEFAULTS.maxUsableAccuracyMeters;

  // ── 围栏分 ──────────────────────────────────────────────────────────
  if (accuracyUsable) {
    if (distance <= DEFAULTS.tightAccuracyMeters) {
      items.push({
        reason: `围栏内且距中心 ${distance.toFixed(0)}m（≤${DEFAULTS.tightAccuracyMeters}m）`,
        points: DEFAULTS.scoreInsideFenceTight,
      });
    } else if (distance <= fence.radius) {
      items.push({
        reason: `围栏内且距中心 ${distance.toFixed(0)}m（${DEFAULTS.tightAccuracyMeters}–${fence.radius}m）`,
        points: DEFAULTS.scoreInsideFenceLoose,
      });
    } else if (distance <= fence.radius * DEFAULTS.fenceToleranceFactor) {
      items.push({
        reason: `紧邻围栏外（${distance.toFixed(0)}m，半径 ${fence.radius}m）`,
        points: 0,
      });
    } else {
      items.push({
        reason: `距围栏中心 ${distance.toFixed(0)}m，超出活动签到范围`,
        points: 0,
      });
    }
  } else {
    items.push({
      reason: Number.isFinite(accuracy)
        ? `定位精度 ${accuracy.toFixed(0)}m，超过 ${DEFAULTS.maxUsableAccuracyMeters}m 门槛，该证据不计分`
        : '未上报定位精度，该证据不计分',
      points: 0,
    });
  }

  // ── 网络辅证 ────────────────────────────────────────────────────────
  if (context.wifiMatched) {
    items.push({
      reason: 'Wi-Fi BSSID 命中活动场地',
      points: DEFAULTS.scoreWifiBssidMatched,
    });
  }
  if (context.campusIpMatched) {
    items.push({
      reason: '校园网 IP 命中',
      points: DEFAULTS.scoreCampusIpMatched,
    });
  }
  if (context.recentInsideFence) {
    items.push({
      reason: '近期有场内定位记录',
      points: DEFAULTS.scoreRecentInsideFence,
    });
  }

  // ── 采样一致性 ──────────────────────────────────────────────────────
  const consistency = samplesConsistent(submission.samples ?? []);
  if (consistency.consistent) {
    items.push({
      reason: '多次采样一致',
      points: DEFAULTS.scoreSamplesConsistent,
    });
  }

  // ── 扣分项 ──────────────────────────────────────────────────────────
  if (mock.detected) {
    items.push({ reason: mock.reason, points: DEFAULTS.penaltyMockLocation });
  }
  if (context.multiAccountSameDevice) {
    items.push({
      reason: '同一设备上出现多个账号',
      points: DEFAULTS.penaltyMultiAccountSameDevice,
    });
  }
  if (context.trajectoryAnomaly) {
    items.push({ reason: context.trajectoryAnomaly, points: DEFAULTS.penaltyTrajectoryAnomaly });
  }

  const score = items.reduce((sum, i) => sum + i.points, 0);

  /*
    模拟定位与轨迹异常是**一票否决**：即使总分很高也转人工。
    这类证据的"高分"本身就说明它在伪装，不能让它自动通过。
  */
  const vetoed = mock.detected || Boolean(context.trajectoryAnomaly);

  let status;
  let reason;
  if (vetoed) {
    status = CHECKIN_STATUS.PENDING_REVIEW;
    reason = mock.detected
      ? '检测到疑似模拟定位，已转人工确认'
      : '轨迹异常，已转人工确认';
  } else if (score >= DEFAULTS.scoreSuccessThreshold) {
    status = CHECKIN_STATUS.SUCCESS;
    reason = '定位证据充分，自动通过';
  } else if (score >= DEFAULTS.scorePendingReviewThreshold) {
    status = CHECKIN_STATUS.PENDING_REVIEW;
    reason = `证据强度不足（评分 ${score}），已转人工确认`;
  } else {
    status = CHECKIN_STATUS.REJECTED;
    reason = `定位证据不足（评分 ${score}），未通过`;
  }

  return {
    score,
    status,
    reason,
    distanceMeters: distance,
    items,
    mockLocationDetected: mock.detected,
  };
}

/**
 * 签到门槛检查（在评分**之前**）。
 *
 * @returns {{ok: true} | {ok: false, code: string, message: string}}
 */
export function checkGate({ activity, participant, now, existingCheckin }) {
  const t = now instanceof Date ? now.getTime() : Date.parse(now);

  if (existingCheckin) {
    return { ok: false, code: 'ALREADY_CHECKED_IN', message: '你已完成签到' };
  }
  if (!participant || participant.removedAt) {
    return { ok: false, code: 'NOT_IN_PARTICIPANT_LIST', message: '你不在本次活动名单中' };
  }

  const start = Date.parse(activity.startTime);
  const end = Date.parse(activity.endTime);
  const opensAt = start - Number(activity.checkinWindowBefore ?? 30) * 60_000;
  const closesAt = end + Number(activity.checkinWindowAfter ?? 60) * 60_000;

  if (t < opensAt) {
    return { ok: false, code: 'OUTSIDE_CHECKIN_WINDOW', message: '签到尚未开放' };
  }
  if (t > closesAt) {
    return { ok: false, code: 'OUTSIDE_CHECKIN_WINDOW', message: '签到时段已结束' };
  }
  return { ok: true };
}
