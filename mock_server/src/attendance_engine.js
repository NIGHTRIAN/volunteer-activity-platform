/**
 * 在岗抽查任务引擎（《移动端应用开发方案》§6.2、§14.1-3）。
 *
 * 独立成模块的理由：活动状态流转（api_activities）与签到/在岗响应（api_checkin）
 * 都需要它，放在任一侧都会形成循环依赖。
 *
 * 三条硬性约束：
 *   1. **服务端生成**，App 不承担任何定时判定；
 *   2. 幂等键 `(activityId, userNo, seq)`，重复调用安全；
 *   3. 超时判定在 `deadline + 2min` 生效，并**保留通知记录**，
 *      以区分「人不在」与「通知没到」（方案 §13-A5）。
 */

import { DEFAULTS } from './constants.js';
import { addMinutes, iso, newId, parseTime, store } from './store.js';

/** 抽查时刻序列。与 App 侧 `Activity.plannedAttendanceSlots()` 口径一致。 */
export function planSlots(activity) {
  const start = parseTime(activity.startTime);
  const end = parseTime(activity.endTime);
  const firstDelay = activity.attendanceFirstDelay ?? DEFAULTS.ATTENDANCE_FIRST_DELAY_MIN;
  const interval = activity.attendanceInterval ?? DEFAULTS.ATTENDANCE_INTERVAL_MIN;
  // 留白 30 分钟：取 15 会让 2 小时活动产出 4 次，与验收 A20 要求的 3 次矛盾。
  // 详见 constants.js 中 ATTENDANCE_LAST_TASK_MARGIN_MIN 的推导说明。
  const lastAllowed = addMinutes(end, -DEFAULTS.ATTENDANCE_LAST_TASK_MARGIN_MIN);
  const step = interval > 0 ? interval : DEFAULTS.ATTENDANCE_INTERVAL_MIN;

  const slots = [];
  let cursor = addMinutes(start, firstDelay);
  let guard = 0;
  // guard 防御异常参数（interval 为 0 或负）造成死循环。
  while (cursor <= lastAllowed && guard < 500) {
    slots.push(new Date(cursor));
    cursor = addMinutes(cursor, step);
    guard += 1;
  }
  return slots;
}

/**
 * 生成/补齐在岗抽查任务。
 *
 * ## 只为「已签到」的人生成（决策 D-6，采用网页方案 §4.5）
 *
 * ⚠️ 两方案冲突：
 *   * 移动端方案 §6.2 —— 为**所有名单成员**生成；
 *   * **网页方案 §4.5 —— 为「已签到且在名单中」的参与者创建**。
 *
 * 已决定采用**网页方案**，理由是这条更符合"防脱岗"的本意：
 *   * 抽查的目的是确认「到场的人没有中途离开」。没签到的人根本没到场，
 *     给他记一串 `missed` 毫无信息量；
 *   * 会给考勤汇总的分母灌水。方案 §13-A5 已承认抽查可能**误判**
 *     （"通知没到"被记成"人不在"），分母越大越容易冤枉人；
 *   * 与网页方案 §6.4.7 的汇总口径（`full`/`partial`/`insufficient`/`absent`）更自洽 ——
 *     只对到场者评价在岗表现，未到场者由签到状态直接判定为 `absent`。
 *
 * ## 幂等（方案 §14.1-3）
 *
 *   * 已存在的任务**保持原状**（已过期按原规则结案，不追溯改写）；
 *   * 缺失的**新增时段**补生成；
 *   * 因此活动时间被改长后，新增时段会被补上，而历史判定不变；
 *   * 幂等键：`(activityId, userNo, seq)`。
 *
 * @returns {number} 新建任务数
 */
export function regenerateAttendanceTasks(activity, { preserveExisting = true } = {}) {
  const slots = planSlots(activity);

  // 只取**已签到**且在有效名单中的人。
  // 「已签到」的口径与 §6.1 一致：success 或 pending_review 都算到场
  //（pending_review 是"证据不足待人工确认"，人在场是大概率，因此也生成抽查，
  //  否则一旦人工复核慢了，这人就完全不会被防脱岗覆盖）。
  const people = store.db.participants.filter((p) => {
    if (p.activityId !== activity.id) return false;
    if (p.signupStatus === 'cancelled' || p.removedAt) return false;
    return store.db.checkins.some(
      (c) =>
        c.activityId === activity.id &&
        c.userNo === p.userNo &&
        (c.status === 'success' || c.status === 'pending_review'),
    );
  });

  let created = 0;

  for (const p of people) {
    for (let i = 0; i < slots.length; i++) {
      const seq = i + 1;
      const exists = store.db.attendanceTasks.find(
        (t) => t.activityId === activity.id && t.userNo === p.userNo && t.seq === seq,
      );
      if (exists) {
        if (!preserveExisting && exists.status === 'pending') {
          exists.scheduledAt = iso(slots[i]);
          exists.deadlineAt = iso(addMinutes(slots[i], activity.attendanceResponseWindow ?? 5));
        }
        continue;
      }
      store.db.attendanceTasks.push({
        id: newId('task-'),
        activityId: activity.id,
        userNo: p.userNo,
        seq,
        scheduledAt: iso(slots[i]),
        deadlineAt: iso(addMinutes(slots[i], activity.attendanceResponseWindow ?? 5)),
        status: 'pending',
        notifiedAt: null,
        respondedAt: null,
        geoLat: null,
        geoLng: null,
        accuracy: null,
        manualFill: false,
        filledBy: null,
      });
      created += 1;
    }
  }
  return created;
}

/**
 * 把已过宽限期的 pending 任务结案为 `missed`。
 *
 * 由任何读接口调用（惰性结算），这样 Mock 不需要后台定时器也能表现正确状态。
 * 真实服务端用定时任务，行为必须一致。
 */
export function settleOverdueTasks(activity, now = new Date()) {
  const graceMs = DEFAULTS.ATTENDANCE_MISS_GRACE_MIN * 60_000;
  let settled = 0;
  for (const t of store.db.attendanceTasks) {
    if (t.activityId !== activity.id || t.status !== 'pending') {
      continue;
    }
    const deadline = parseTime(t.deadlineAt);
    if (now.getTime() > deadline.getTime() + graceMs) {
      t.status = 'missed';
      t.settledAt = iso(now);
      settled += 1;
    }
  }
  return settled;
}

/** 任务计数。 */
export function countTasks(activityId) {
  const tasks = store.db.attendanceTasks.filter((t) => t.activityId === activityId);
  return {
    total: tasks.length,
    pending: tasks.filter((t) => t.status === 'pending').length,
    done: tasks.filter((t) => t.status === 'done').length,
    missed: tasks.filter((t) => t.status === 'missed').length,
    excused: tasks.filter((t) => t.status === 'excused').length,
  };
}

/**
 * 考勤汇总（网页方案 §6.4.7）。
 *
 * 判定阈值（决策 D-7，采用网页方案）：
 *   * `full`         —— 无 `missed`
 *   * `partial`      —— 完成率 ≥ 0.7
 *   * `insufficient` —— 有完成但不足 0.7，或全部被豁免/尚未发生
 *   * `absent`       —— 没有有效签到
 *
 * ⚠️ 移动端方案 §4.8 的判据是「有 missed 且 done>0 → partial」，没有阈值。
 * 已决定采用网页方案的 **0.7 完成率**，因为"3 次里完成 2 次"和
 * "10 次里完成 6 次"的风险程度明显不同，前者不该与后者同列。
 *
 * ⚠️ 结果仅作**现场管理参考**，不自动产生任何时长扣减或权益影响。
 */
export function buildAttendanceSummary(activity) {
  const tasks = store.db.attendanceTasks.filter((t) => t.activityId === activity.id);
  const byUser = new Map();
  for (const t of tasks) {
    if (!byUser.has(t.userNo)) {
      byUser.set(t.userNo, { done: 0, missed: 0, excused: 0, pending: 0 });
    }
    byUser.get(t.userNo)[t.status] += 1;
  }

  const rows = [];
  for (const [userNo, c] of byUser) {
    const p = store.db.participants.find(
      (x) => x.activityId === activity.id && x.userNo === userNo,
    );
    const checkin = store.db.checkins.find(
      (x) => x.activityId === activity.id && x.userNo === userNo && x.status === 'success',
    );

    // 完成率的分母只算**已定案**的任务：pending 尚未发生，excused 被豁免，
    // 两者都不该计入分母（网页方案 §5.3：「未发生的任务置 excused，不计入分母」）。
    const settled = c.done + c.missed;
    const rate = settled === 0 ? null : c.done / settled;

    let summary;
    if (!checkin) {
      // 没签到：无论抽查如何都记为缺席，在岗表现无从谈起。
      summary = 'absent';
    } else if (settled === 0) {
      // 签到过，但抽查全部被豁免或尚未发生 → 证据不足，**不能判缺席**，否则冤枉人。
      summary = 'insufficient';
    } else if (c.missed === 0) {
      summary = 'full';
    } else if (rate >= DEFAULTS.ATTENDANCE_PARTIAL_MIN_RATE) {
      summary = 'partial';
    } else {
      summary = 'insufficient';
    }

    rows.push({
      userNo,
      name: p?.name ?? '',
      checkinStatus: checkin ? 'checked_in' : 'not_checked_in',
      attendanceDone: c.done,
      attendanceMissed: c.missed,
      attendanceExcused: c.excused,
      attendancePending: c.pending,
      /** 完成率（0–1）；无已定案任务时为 null。 */
      attendanceRate: rate == null ? null : Math.round(rate * 100) / 100,
      attendanceSummary: summary,
    });
  }

  return {
    activityId: activity.id,
    generatedAt: iso(new Date()),
    // 把免责声明写进数据里，前端不必记这条规则，也不会漏展示。
    disclaimer: '考勤结果仅作现场管理参考，不作为志愿时长认定依据，不自动产生任何扣减。',
    rows,
  };
}

/**
 * 按 seq 找任务。
 *
 * 幂等键的一部分：`(activityId, userNo, seq)`。
 */
export function findTaskBySeq(activityId, userNo, seq) {
  return (
    store.db.attendanceTasks.find(
      (t) => t.activityId === activityId && t.userNo === userNo && t.seq === Seq(seq),
    ) ?? null
  );
}

function Seq(v) {
  return Number(v);
}
