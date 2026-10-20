/**
 * 服务端签到判定与风险评分（《移动端应用开发方案》§6.1）。
 *
 * ⚠️ 这个文件是**服务端判定权的权威实现**。方案 §2 明确「签到判定权一律在服务端，
 * 客户端只上报证据」，因此客户端不得复制这套判定逻辑——App 侧只展示服务端返回的
 * `status` / `score` / `scoreBreakdown`。
 *
 * 判定闭环：
 *   1. 门槛校验（活动状态、时间窗、名单、精度、模拟定位、重复签到）
 *   2. 风险评分（围栏距离 + 网络辅证 + 停留验证 + 反作弊扣分）
 *   3. 阈值判定：>=60 success；30–59 或命中模拟定位 pending_review；<30 rejected
 *
 * 坐标系：**输入必须是 WGS-84**。混用 GCJ-02/BD-09 会让围栏整体偏移 50～500m
 * （方案 §13-A7、验收用例 A14）。
 */

import {
  CHECKIN_ALLOWED_STATUSES,
  CHECKIN_METHOD,
  CHECKIN_STATUS,
  DEFAULTS,
  ERR,
  TERMINAL_STATUSES,
  msgOf,
} from './constants.js';

const EARTH_RADIUS_M = 6371008.8;

/** 经纬度 → 球面距离（米），Haversine。 */
export function distanceMeters(a, b) {
  const d2r = Math.PI / 180;
  const lat1 = a.lat * d2r;
  const lat2 = b.lat * d2r;
  const dLat = (b.lat - a.lat) * d2r;
  const dLng = (b.lng - a.lng) * d2r;
  const sinHalfLat = Math.sin(dLat / 2);
  const sinHalfLng = Math.sin(dLng / 2);
  const h =
    sinHalfLat * sinHalfLat + Math.cos(lat1) * Math.cos(lat2) * sinHalfLng * sinHalfLng;
  return EARTH_RADIUS_M * 2 * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** 活动围栏中心与半径。 */
export function fenceOf(activity) {
  return {
    center: { lat: Number(activity.geoLat), lng: Number(activity.geoLng) },
    radius: Number(activity.checkinRadius ?? DEFAULTS.DEFAULT_CHECKIN_RADIUS_M),
  };
}

/** 签到窗口。 */
export function checkinWindowOf(activity) {
  const start = new Date(activity.startTime);
  const end = new Date(activity.endTime);
  return {
    opensAt: new Date(start.getTime() - (activity.checkinWindowBefore ?? 15) * 60_000),
    closesAt: new Date(end.getTime() + (activity.checkinWindowAfter ?? 15) * 60_000),
  };
}

/**
 * 坐标系合理性检查。
 *
 * 服务端无法知道客户端用了哪个 SDK，但能识别典型症状：
 * 上报点在围栏外、偏移量落在 GCJ-02 的特征区间内、且方向偏东北。
 * 这时给出**明确原因**（而不是含糊的「不在范围内」），运维才能定位到坐标系问题。
 */
export function inspectCoordinateShift(reported, fence) {
  const dist = distanceMeters(reported, fence.center);
  if (dist <= fence.radius) {
    return { shifted: false, distance: dist, verdict: 'normal' };
  }
  const inGcjBand = dist >= 30 && dist <= 700 + fence.radius;
  const northeast = reported.lat >= fence.center.lat && reported.lng >= fence.center.lng;
  if (inGcjBand && northeast) {
    return { shifted: true, distance: dist, verdict: 'suspected_unconverted_gcj02' };
  }
  return { shifted: false, distance: dist, verdict: 'outside_fence' };
}

/**
 * 模拟定位检测（服务端侧可验证的部分）。
 *
 * ⚠️ 诚实说明：Mock 服务**无法**真正读取 Android 的 `Location.isFromMockProvider`
 * 或 iOS 的越狱检测。真实实现里这条判据主要由客户端上报
 * `mockLocationDetected`，服务端做交叉验证：
 *   * 客户端上报为 true；
 *   * 或证据自相矛盾（精度异常完美、多次采样坐标完全相同、速度不合理）。
 *
 * 交叉验证的意义：客户端可以伪造 `mockLocationDetected: false`，
 * 但很难同时把坐标、精度、时间戳做成物理上自洽的一组。这只是提高门槛，
 * **不是可靠防线**——方案的定位是「检测到即强制转人工」，并通过人工复核兜底
 * （方案 §13-A2）。
 *
 * @param {object} input
 * @param {boolean} input.clientFlagged 客户端上报的检测结果
 * @param {Array<object>} input.samples 定位采样序列
 * @returns {{detected: boolean, reasons: string[]}}
 */
export function detectMockLocation({ clientFlagged, samples = [], speed }) {
  const reasons = [];

  // ① 权威判据：Android 系统给的 isMock 标志。
  //    这条最可靠（只有系统层能可靠知道是否在改写位置），命中即转人工。
  if (clientFlagged === true) {
    reasons.push('客户端检测到模拟定位');
  }

  // ② 弱判据：多次采样"逐位相同"。
  //
  // ⚠️ 这条曾被当成强判据（完全相同就 -60），**真机测试证明是错的**：
  //    Android 融合定位在设备静止时直接返回缓存值，志愿者老实站着不动
  //    就会得到 3 个逐位相同的采样。于是真人被判成作弊，
  //    方案 §6.1 的"自动通过"路径实际永远走不到。
  //
  //    而且与同一套评分表里的"采样一致 +10"直接矛盾。
  //
  //    现在必须再叠加"精度好得不像真机"才成立：
  //    室内/城市静止的真机精度典型 20–50 m，
  //    而改写定位的工具通常直接写一个理想值（≤5 m）。
  if (samples.length >= 2) {
    const allSame = samples.every(
      (s) =>
        Math.abs(Number(s.geoLat) - Number(samples[0].geoLat)) < 1e-9 &&
        Math.abs(Number(s.geoLng) - Number(samples[0].geoLng)) < 1e-9,
    );
    if (allSame) {
      const accs = samples.map((s) => Number(s.accuracy));
      const identicalAccuracy = accs.every((a) => a === accs[0]);
      const implausiblyPerfect =
        Number.isFinite(accs[0]) && accs[0] > 0 && accs[0] <= DEFAULTS.MOCK_PERFECT_ACCURACY_M;
      if (identicalAccuracy && implausiblyPerfect) {
        reasons.push(
          `多次采样坐标与精度完全一致，且精度异常理想（±${accs[0]}m），疑似模拟定位`,
        );
      }
    }
  }

  // ③ 速度不合理：>120 m/s（432 km/h）远超任何步行/骑行场景。
  if (typeof speed === 'number' && speed > 120) {
    reasons.push(`上报速度异常（${speed.toFixed(0)} m/s）`);
  }
  return { detected: reasons.length > 0, reasons };
}

/**
 * 计算风险评分。
 *
 * 逐条对应方案 §6.1 的评分表，每一项都写进 `scoreBreakdown`，
 * 让管理端的「待人工确认列表」能展示**为什么**是这个分数（方案 §4.8）。
 *
 * @param {object} args
 * @param {object} args.activity 活动（含围栏参数）
 * @param {object} args.submission 客户端提交的证据
 * @param {object} args.context 服务端上下文：{ recentInsideFence, sameDeviceOtherUsers, lastCheckin }
 * @returns {{score:number, status:string, reason:string, distance:number, items:Array<{reason:string,points:number}>}}
 */
export function scoreCheckin({ activity, submission, context = {} }) {
  const items = [];
  const fence = fenceOf(activity);

  const lat = Number(submission.geoLat);
  const lng = Number(submission.geoLng);
  const accuracy = Number(submission.accuracy);
  const hasFix = Number.isFinite(lat) && Number.isFinite(lng) && !(lat === 0 && lng === 0);

  // ── 模拟定位：命中即强制转人工，不参与自动通过（方案 §6.1）────────────
  const mock = detectMockLocation({
    clientFlagged: submission.mockLocationDetected === true,
    samples: submission.samples ?? [],
    speed: submission.speed,
  });

  if (!hasFix) {
    // 无有效坐标：只能转人工，不能自动驳回——可能是设备定位模块故障，
    // 现场还有动态码/人工补录等降级手段可用（方案 §7「不得出现死路」）。
    items.push({ reason: '未收到有效定位坐标', points: 0 });
    return {
      score: 0,
      status: CHECKIN_STATUS.PENDING_REVIEW,
      reason: '未收到有效定位坐标，已转人工确认',
      distance: null,
      items,
    };
  }

  const reported = { lat, lng };
  const shift = inspectCoordinateShift(reported, fence);

  // ── 精度门槛（方案 §6.1）──────────────────────────────────────────
  // >100m 该证据**不计分**（而不是直接驳回）。
  const accuracyUsable = Number.isFinite(accuracy) && accuracy > 0 && accuracy <= DEFAULTS.MAX_USABLE_ACCURACY_M;

  // ── 围栏距离 ──────────────────────────────────────────────────────
  if (accuracyUsable) {
    if (shift.distance <= DEFAULTS.TIGHT_ACCURACY_M) {
      items.push({
        reason: `围栏内且距中心 ${shift.distance.toFixed(0)}m（≤50m）`,
        points: DEFAULTS.SCORE_INSIDE_FENCE_TIGHT,
      });
    } else if (shift.distance <= fence.radius) {
      items.push({
        reason: `围栏内且距中心 ${shift.distance.toFixed(0)}m（50–100m）`,
        points: DEFAULTS.SCORE_INSIDE_FENCE_LOOSE,
      });
    } else if (shift.distance <= fence.radius * 1.5) {
      // 围栏外但在 1.5 倍半径内：少量宽容分，避免边界抖动直接判死。
      // 验收用例 A12 要求「1.5 倍半径外」被驳回，因此宽容带止于 1.5 倍。
      items.push({
        reason: `紧邻围栏外（${shift.distance.toFixed(0)}m，半径 ${fence.radius}m）`,
        points: 0,
      });
    } else {
      items.push({
        reason: shift.shifted
          ? `距围栏中心 ${shift.distance.toFixed(0)}m，且偏移量与坐标系未转换特征相符`
          : `距围栏中心 ${shift.distance.toFixed(0)}m，超出活动签到范围`,
        points: 0,
      });
    }
  } else {
    items.push({
      reason: Number.isFinite(accuracy)
        ? `定位精度 ${accuracy.toFixed(0)}m，超过 100m 门槛，该证据不计分`
        : '未上报定位精度，该证据不计分',
      points: 0,
    });
  }

  // ── 网络辅证 ──────────────────────────────────────────────────────
  if (context.wifiMatched) {
    items.push({ reason: 'Wi-Fi BSSID 命中活动场地', points: DEFAULTS.SCORE_WIFI_BSSID_MATCHED });
  }
  if (context.campusIpMatched) {
    items.push({ reason: '校园网 IP 命中', points: DEFAULTS.SCORE_CAMPUS_IP_MATCHED });
  }

  // ── 停留验证：签到前 60 秒内已有围栏内定位（§6.1 +15）─────────────
  if (context.recentInsideFence) {
    items.push({
      reason: '签到前 60 秒内已有围栏内定位（停留验证）',
      points: DEFAULTS.SCORE_RECENT_INSIDE_FENCE,
    });
  }

  // ── 采样一致性（§6.1 +10）─────────────────────────────────────────
  const samples = submission.samples ?? [];
  if (samples.length >= 2) {
    const first = samples[0];
    const consistent = samples.every(
      (s) => distanceMeters({ lat: Number(s.geoLat), lng: Number(s.geoLng) }, {
        lat: Number(first.geoLat),
        lng: Number(first.geoLng),
      }) <= 30,
    );
    if (consistent) {
      items.push({ reason: '多次采样一致', points: DEFAULTS.SCORE_SAMPLES_CONSISTENT });
    } else {
      items.push({ reason: '多次采样差异较大', points: 0 });
    }
  }

  // ── 反作弊扣分 ────────────────────────────────────────────────────
  if (mock.detected) {
    items.push({
      reason: `模拟定位：${mock.reasons.join('；')}`,
      points: DEFAULTS.PENALTY_MOCK_LOCATION,
    });
  }
  if (context.sameDeviceOtherUsers > 0) {
    items.push({
      reason: `同一设备本活动内已有 ${context.sameDeviceOtherUsers} 个其他账号签到`,
      points: DEFAULTS.PENALTY_MULTI_ACCOUNT_SAME_DEVICE,
    });
  }
  if (context.trajectoryAnomaly) {
    items.push({ reason: context.trajectoryAnomaly, points: DEFAULTS.PENALTY_TRAJECTORY_ANOMALY });
  }

  const score = items.reduce((sum, it) => sum + it.points, 0);

  // ── 阈值判定（方案 §6.1）──────────────────────────────────────────
  // 模拟定位**命中即转人工**，无论分数多少。
  if (mock.detected) {
    return {
      score,
      status: CHECKIN_STATUS.PENDING_REVIEW,
      reason: '检测到模拟定位，已转人工确认',
      distance: shift.distance,
      items,
      coordinateVerdict: shift.verdict,
    };
  }

  if (score >= DEFAULTS.SCORE_SUCCESS_THRESHOLD) {
    return {
      score,
      status: CHECKIN_STATUS.SUCCESS,
      reason: '定位证据充分，自动通过',
      distance: shift.distance,
      items,
      coordinateVerdict: shift.verdict,
    };
  }

  if (score >= DEFAULTS.SCORE_PENDING_REVIEW_THRESHOLD) {
    return {
      score,
      status: CHECKIN_STATUS.PENDING_REVIEW,
      reason: `证据强度不足（评分 ${score}），已转人工确认`,
      distance: shift.distance,
      items,
      coordinateVerdict: shift.verdict,
    };
  }

  // <30：明确驳回，但**必须给出可操作的原因**（验收用例 A12 要求"原因明确"）。
  //
  // 设计取舍：坐标系提示是**附加信息**，不替代「不在签到范围内」这个主因。
  // 因为从服务端看，「用了未转换的高德坐标」和「人真的在 300 米外」在数值上
  // 无法区分（见 inspectCoordinateShift 的说明）。把坐标系当成主因会把
  // 跑错场地的志愿者引向错误的排查方向，代价比多一句提示大得多。
  let reason = `不在签到范围内（距场地约 ${Math.round(shift.distance)} 米，签到半径 ${fence.radius} 米）`;
  if (!accuracyUsable) {
    reason = Number.isFinite(accuracy) && accuracy > DEFAULTS.MAX_USABLE_ACCURACY_M
      ? `定位精度不足（${Math.round(accuracy)} 米，需 ≤100 米），且证据强度不足，无法通过`
      : '未获得足够的定位证据，无法通过';
  }
  if (shift.shifted) {
    reason +=
      '。另外，偏移方向与坐标系未转换的特征相符——若你使用的是高德/腾讯地图，' +
      '请联系发布者核对坐标系是否为 WGS-84';
  }

  return {
    score,
    status: CHECKIN_STATUS.REJECTED,
    reason,
    distance: shift.distance,
    items,
    coordinateVerdict: shift.verdict,
  };
}

/**
 * 签到前置门槛校验（网页方案 §6.4.5 判定顺序①②）。
 *
 * 返回 `null` 表示通过门槛、可进入评分；否则返回可发送的业务错误。
 * 门槛与评分分离的理由：门槛问题（不在时间窗、不在名单）是**确定性的业务拒绝**，
 * 不应被评分宽容带掩盖。
 *
 * ⚠️ 返回的是错误**名称**而不是线码值：方案只授权了 8 个码值，
 * 多个细分共享同一个码，必须靠名称区分文案与 HTTP 状态。
 */
export function checkGate({ activity, userNo, participant, now, isBackfill }) {
  if (!activity) {
    return { code: ERR.ACTIVITY_NOT_FOUND, message: msgOf('ACTIVITY_NOT_FOUND') };
  }
  if (TERMINAL_STATUSES.includes(activity.status)) {
    return {
      code: ERR.ACTIVITY_STATE_INVALID,
      message: `活动${activity.status === 'cancelled' ? '已取消' : '已结束'}，签到已关闭`,
    };
  }
  if (!CHECKIN_ALLOWED_STATUSES.includes(activity.status)) {
    return {
      code: ERR.ACTIVITY_STATE_INVALID,
      message: '活动尚未开放签到',
    };
  }

  // 名单校验（方案 §6.4.5：`userNo ∈ 该活动 participant` 且未取消）
  if (!participant) {
    return {
      code: ERR.NOT_IN_PARTICIPANT_LIST,
      message: msgOf('NOT_IN_PARTICIPANT_LIST'),
    };
  }
  if (participant.signupStatus === 'cancelled' || participant.removedAt) {
    return {
      code: ERR.NOT_IN_PARTICIPANT_LIST,
      message: '你已被移出本次活动名单',
    };
  }

  // 时间窗校验：**超窗补传不在这里拒绝**，而是标记为补传后转人工（移动端方案 §6.4）。
  if (!isBackfill) {
    const win = checkinWindowOf(activity);
    if (now < win.opensAt) {
      return {
        code: ERR.OUTSIDE_CHECKIN_WINDOW,
        message: `签到将于 ${isoLocal(win.opensAt)} 开放`,
      };
    }
    if (now > win.closesAt) {
      return {
        code: ERR.OUTSIDE_CHECKIN_WINDOW,
        message: `签到时段已于 ${isoLocal(win.closesAt)} 结束，请联系发布者人工补录`,
      };
    }
  }

  return null;
}

/** 简化的本地时间展示，与 App 侧 `yyyy-MM-dd HH:mm` 一致。 */
export function isoLocal(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
    `${pad(date.getHours())}:${pad(date.getMinutes())}`
  );
}

/**
 * 生成抽查计划序列（方案 §6.2）。
 *
 * 规则：首次 `startTime + attendanceFirstDelay`，间隔 `attendanceInterval`，
 * 末次不晚于 `endTime − 15min`。2 小时活动默认得到 3 次（T+15 / T+45 / T+75）。
 *
 * 幂等键是 `(activityId, userNo, seq)`，因此对同一活动重复调用本函数是安全的
 * （方案 §14.1-3「新增时段补生成；幂等」）。
 */
export function planAttendanceSlots(activity) {
  const start = new Date(activity.startTime);
  const end = new Date(activity.endTime);
  const firstDelay = activity.attendanceFirstDelay ?? DEFAULTS.ATTENDANCE_FIRST_DELAY_MIN;
  const interval = activity.attendanceInterval ?? DEFAULTS.ATTENDANCE_INTERVAL_MIN;
  const margin = DEFAULTS.ATTENDANCE_LAST_TASK_MARGIN_MIN;

  const lastAllowed = addMin(end, -margin);
  const step = interval > 0 ? interval : DEFAULTS.ATTENDANCE_INTERVAL_MIN;

  const slots = [];
  let cursor = addMin(start, firstDelay);
  let guard = 0;
  while (cursor <= lastAllowed && guard < 500) {
    slots.push(new Date(cursor));
    cursor = addMin(cursor, step);
    guard += 1;
  }
  return slots;
}

function addMin(date, minutes) {
  return new Date(date.getTime() + minutes * 60_000);
}
