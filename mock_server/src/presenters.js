/**
 * DTO 序列化层。
 *
 * 独立成模块的理由：`api_participants.js` 与 `api_checkin.js` 都需要
 * 「名单条目 → 响应体」的转换，放在任一侧都会形成循环依赖。
 *
 * 另一条职责：**所有对外字段在这里统一脱敏**。手机号只出掩码，
 * 明文永不出接口——这样即使某个 handler 忘了处理，也不会漏出去
 * （README §3.3 底线②）。
 */

import { CHECKIN_STATUS, SIGNUP_STATUS, TASK_STATUS } from './constants.js';
import { iso, store } from './store.js';

/** 手机号脱敏：`138****5678`。 */
export function maskPhone(phone) {
  if (!phone) {
    return null;
  }
  const p = String(phone);
  if (p.length < 7) {
    return `${p.slice(0, 1)}****`;
  }
  return `${p.slice(0, 3)}****${p.slice(-4)}`;
}

/** 联系方式脱敏（可能含手机号或座机，混在文本里）。 */
export function maskContact(contact) {
  if (!contact) {
    return null;
  }
  const s = String(contact);
  const phone = /1[3-9]\d{9}/.exec(s);
  if (phone) {
    const p = phone[0];
    return s.replace(p, `${p.slice(0, 3)}****${p.slice(-4)}`);
  }
  return s;
}

/**
 * 内部报名状态 → **契约线值**（网页方案 §4.3：`registered` / `cancelled`）。
 *
 * 内部用 `signed` 表示"已入库"、`pending_confirm` 表示"二次校验存疑"。
 * 契约只授权了两个值，因此线上统一映射为 `registered`，
 * 而"待确认"这个细分通过 `crossCheckPending` 布尔字段单独下发——
 * 因为它是**我方扩展**（方案 §6.4.3 只说"（可选）姓名/手机号后四位二次校验"，
 * 没说状态怎么表达）。
 */
function toWireSignupStatus(internal) {
  return internal === SIGNUP_STATUS.CANCELLED ? 'cancelled' : 'registered';
}

/**
 * 名单条目 → 响应体。
 *
 * 汇总该人的签到状态与在岗统计，让管理端看板**一次请求**就能渲染整行，
 * 不必为每行再查一次签到与抽查。
 */
export function presentParticipant(activityId, p) {
  const tasks = store.db.attendanceTasks.filter(
    (t) => t.activityId === activityId && t.userNo === p.userNo,
  );
  const checkin = store.db.checkins.find(
    (c) =>
      c.activityId === activityId &&
      c.userNo === p.userNo &&
      (c.status === CHECKIN_STATUS.SUCCESS || c.status === CHECKIN_STATUS.PENDING_REVIEW),
  );
  return {
    // 方案 §4.3 有自增主键 `id`。本 Mock 以 userNo 作为活动内唯一键
    //（方案 §4.3 明确「userNo 活动内唯一」），因此 id 直接复用 userNo，
    // 这样 `DELETE /participants/{pid}` 的 pid 与 userNo 一致，不会让客户端困惑。
    id: p.userNo,
    activityId,
    userNo: p.userNo,
    name: p.name,
    // 只出掩码。
    phone: maskPhone(p.phone),
    signupStatus: toWireSignupStatus(p.signupStatus),
    /** 我方扩展：该行是否处于"二次校验待确认"。 */
    crossCheckPending: p.signupStatus === SIGNUP_STATUS.PENDING_CONFIRM,
    // 名单行的签到状态。**线值取自 `CHECKIN_STATUS`**（success /
    // pending_review / none）—— 与 `checkin.status` 用同一套词表。
    //
    // 早期这里是 `checked_in` / `not_checked_in`，与 `checkin.status` 的
    // `success` 不一致，导致客户端解析出"未知"（实测：看板上所有已签到的人
    // 都显示成未知状态）。`none` 表示"尚无记录"，它是比 `not_checked_in`
    // 更准确的描述：没签到可能是因为活动还没开始，而不是"判定为未签到"。
    checkinStatus: checkin ? checkin.status : 'none',
    removedAt: p.removedAt ?? null,
    removedBy: p.removedBy ?? null,
    grantExpiresAt: p.grantExpiresAt ?? null,
    inviteCodeIssued: store.db.inviteCodes.some(
      (c) => c.activityId === activityId && c.userNo === p.userNo,
    ),
    inviteCodeUsedAt: p.inviteCodeUsedAt ?? null,
    attendanceDone: tasks.filter((t) => t.status === TASK_STATUS.DONE).length,
    attendanceMissed: tasks.filter((t) => t.status === TASK_STATUS.MISSED).length,
    attendanceExcused: tasks.filter((t) => t.status === TASK_STATUS.EXCUSED).length,
    checkinAt: checkin?.serverTime ?? null,
    boundDeviceId: p.boundDeviceId ?? null,
  };
}

/**
 * 名单条目是否仍在有效名单内。
 *
 * 「已移出」的判定统一走这里，避免各处对 `signupStatus` 与 `removedAt`
 * 的语义理解不一致——方案 §14.1-7 要求两者都要考虑。
 */
export function isActiveParticipant(p) {
  return p.signupStatus !== SIGNUP_STATUS.CANCELLED && !p.removedAt;
}

/** 在岗任务 → 响应体。 */
export function presentTask(t) {
  return {
    id: t.id,
    activityId: t.activityId,
    userNo: t.userNo,
    seq: t.seq,
    scheduledAt: t.scheduledAt,
    deadlineAt: t.deadlineAt,
    status: t.status,
    notifiedAt: t.notifiedAt,
    respondedAt: t.respondedAt,
    geoLat: t.geoLat,
    geoLng: t.geoLng,
    accuracy: t.accuracy,
    manualFill: t.manualFill === true,
    filledBy: t.filledBy ?? null,
    // 精度不足或越界时转人工：这两个字段让志愿者看到「为什么还没算完成」。
    needsManualReview: t.needsManualReview === true,
    reviewNote: t.reviewNote ?? null,
  };
}

/** 签到记录 → 响应体。 */
export function presentCheckin(c) {
  return {
    id: c.id,
    activityId: c.activityId,
    userNo: c.userNo,
    name: c.name,
    method: c.method,
    status: c.status,
    reason: c.reason,
    geoLat: c.geoLat,
    geoLng: c.geoLng,
    accuracy: c.accuracy,
    score: c.score,
    scoreBreakdown: c.scoreBreakdown ?? [],
    distanceMeters: c.distanceMeters,
    mockLocationDetected: c.mockLocationDetected,
    clientTime: c.clientTime,
    serverTime: c.serverTime,
    reviewedAt: c.reviewedAt,
    reviewedBy: c.reviewedBy,
    reviewNote: c.reviewNote,
    deviceId: c.deviceId,
    appVersion: c.appVersion,
    offlineBackfill: c.offlineBackfill,
    coordinateVerdict: c.coordinateVerdict ?? null,
    // 人工介入标记。与 `method` 分开：`method` 记录**最初是怎么报上来的**
    // （gps / manual），这两个字段记录**是否有人工介入**。
    // 混在一个字段里会让审计看不出"这条是自动通过的还是发布者补的"。
    reviewedBy: c.reviewedBy ?? null,
    verifiedByOwner: c.verifiedByOwner === true,
    manualBy: c.manualBy ?? null,
  };
}

/**
 * 活动 → 响应体。
 *
 * 两处关键处理：
 *   * `contact` 一律脱敏（README §3.3 底线②）；
 *   * 志愿者视角**不下发 `ownerId`**，减少信息面（方案 §5 只要求"我的记录"）。
 *
 * @param {object} activity
 * @param {{forVolunteer?: string|null}} opts 传入学号时附加"我的"字段
 */
export function presentActivity(activity, { forVolunteer = null } = {}) {
  if (!activity) {
    return null;
  }
  const out = {
    ...activity,
    contact: maskContact(activity.contact),
    enrolled: store.db.participants.filter(
      (p) => p.activityId === activity.id && isActiveParticipant(p),
    ).length,
  };

  if (forVolunteer) {
    const p = store.db.participants.find(
      (x) => x.activityId === activity.id && x.userNo === forVolunteer,
    );
    const checkin = store.db.checkins.find(
      (c) =>
        c.activityId === activity.id &&
        c.userNo === forVolunteer &&
        (c.status === CHECKIN_STATUS.SUCCESS || c.status === CHECKIN_STATUS.PENDING_REVIEW),
    );
    out.mySignupStatus = p?.signupStatus ?? null;
    out.myCheckinStatus = checkin?.status ?? null;
    out.pendingAttendanceCount = store.db.attendanceTasks.filter(
      (t) => t.activityId === activity.id && t.userNo === forVolunteer && t.status === TASK_STATUS.PENDING,
    ).length;
    delete out.ownerId;
  }

  return out;
}

/**
 * 看板四态计数（方案 §4.8）。
 *
 * 「已签到 / 待人工确认 / 未签到」三者之和必须等于有效名单人数——
 * 这是看板可信的前提，因此把「已移出」单独计一个数，不混进未签到里。
 */
export function boardCounts(activityId) {
  const all = store.db.participants.filter((p) => p.activityId === activityId);
  const active = all.filter(isActiveParticipant);
  const removed = all.filter((p) => !isActiveParticipant(p));

  let checkedIn = 0;
  let pendingReview = 0;
  for (const p of active) {
    const c = store.db.checkins.find(
      (x) =>
        x.activityId === activityId &&
        x.userNo === p.userNo &&
        (x.status === CHECKIN_STATUS.SUCCESS || x.status === CHECKIN_STATUS.PENDING_REVIEW),
    );
    if (!c) {
      continue;
    }
    if (c.status === CHECKIN_STATUS.SUCCESS) {
      checkedIn += 1;
    } else {
      pendingReview += 1;
    }
  }

  const tasks = store.db.attendanceTasks.filter((t) => t.activityId === activityId);
  return {
    activityId,
    checkedIn,
    pendingReview,
    notCheckedIn: active.length - checkedIn - pendingReview,
    removed: removed.length,
    attendancePending: tasks.filter((t) => t.status === TASK_STATUS.PENDING).length,
    attendanceDone: tasks.filter((t) => t.status === TASK_STATUS.DONE).length,
    attendanceMissed: tasks.filter((t) => t.status === TASK_STATUS.MISSED).length,
    attendanceExcused: tasks.filter((t) => t.status === TASK_STATUS.EXCUSED).length,
    servingNow: tasks.filter((t) => t.status === TASK_STATUS.DONE).length,
    serverTime: iso(new Date()),
  };
}
