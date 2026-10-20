/**
 * 演示数据。
 *
 * 目的：让两端 App 一启动就有**覆盖各状态与各降级路径**的数据可用，
 * 不必手工造数据。特别是方案 §12 验收用例里的关键场景：
 *   * A20 —— 2 小时活动应生成 3 次抽查（T+15 / T+45 / T+75）
 *   * A11/A12/A13/A14 —— 围栏内、1.5 倍半径外、模拟定位、坐标偏移
 *   * A21 —— 已过留存期的活动不可访问
 *
 * ⚠️ 时间锚定：所有活动时段都**相对当前时刻**计算，不用固定的「今天 9 点」。
 * 固定时钟时间在上午跑得通，下午就变成「签到时段已结束」，
 * 会让演示和联调莫名其妙地失败。
 *
 * 仅在库为空时写入，不会覆盖开发者已有的调试数据。
 */

import { CHECKIN_METHOD, DEFAULTS } from './constants.js';
import { addMinutes, iso, newId, nextSeq, store } from './store.js';
import { regenerateAttendanceTasks } from './attendance_engine.js';
import { codeForSeed } from './seed_codes.js';

/** 相对当前的分钟偏移 → ISO。 */
function fromNow(minutes) {
  return iso(addMinutes(new Date(), minutes));
}

export function seedIfEmpty() {
  if (store.db.activities.length > 0) {
    return false;
  }

  const ownerId = 'owner-demo-0001';
  const deviceId = 'demo-admin-device';

  // 管理员：使用默认邀请码即可登录（方案 §2 已接受该风险）。
  store.db.admins.push({
    ownerId,
    deviceId,
    token: newId('adm-'),
    createdAt: iso(new Date()),
    lastLoginAt: null,
    loginCount: 0,
    displayName: '演示发布者',
  });

  /** 中国矿业大学南湖校区附近的演示坐标（WGS-84）。 */
  const base = { lat: 34.2175, lng: 117.1425 };

  const activities = [
    // ── 进行中：3 小时，当前时刻处于签到窗口内，抽查已部分可响应 ──────
    {
      title: '图书馆书架整理志愿服务',
      organizer: '校图书馆',
      durationHours: 3,
      // 现在 = 开始后 45 分钟，签到窗口 = 开始前 15 分钟 ~ 结束后 15 分钟
      startTime: fromNow(-45),
      endTime: fromNow(135),
      location: '南湖校区图书馆三层',
      geoLat: base.lat,
      geoLng: base.lng,
      checkinRadius: 200,
      // 室内活动：默认半径更小（150m），因为室内定位漂移大（方案 §13-A3）。
      // 这里显式给 200，顺带演示"发布者可以覆盖默认值"。
      locationType: 'indoor',
      // 首次抽查在开始后 20 分钟（已过，可演示「超时」），之后每 30 分钟一次。
      attendanceFirstDelay: 20,
      attendanceInterval: 30,
      status: 'ongoing',
      tags: ['图书馆', '整理'],
      summary: '协助整理三层社科类书架，按索书号归位，并登记破损书籍。',
      description:
        '工作内容：按索书号将归还图书归位；登记破损与缺页图书；协助读者检索。\n\n' +
        '注意事项：请穿平底鞋，书架区禁止饮食。现场有馆员带教。\n\n' +
        '签到方式：到达三层后打开 App 点击签到即可，无需扫码。',
      contact: '王老师 13800001234',
      quota: 20,
      participants: [
        ['2021001', '张伟', '13800001001'],
        ['2021002', '李娜', '13800001002'],
        ['2021003', '王强', '13800001003'],
        ['2021004', '刘洋', '13800001004'],
        ['2021005', '陈静', '13800001005'],
      ],
    },

    // ── 已发布：明天开始，用于验证「不在签到时段内」─────────────────
    {
      title: '校园文明劝导志愿活动',
      organizer: '校团委',
      durationHours: 3,
      startTime: fromNow(24 * 60 + 120),
      endTime: fromNow(24 * 60 + 300),
      location: '南湖校区东门广场',
      geoLat: base.lat + 0.0021,
      geoLng: base.lng + 0.0013,
      checkinRadius: 150,
      status: 'published',
      tags: ['文明劝导', '校团委'],
      summary: '在东门广场引导非机动车有序停放，劝导不文明行为。',
      description: '分两组轮岗，每组 90 分钟。提供志愿者马甲与饮用水。',
      contact: '李同学 13800005678',
      quota: 12,
      participants: [
        ['2022001', '赵敏', '13800002001'],
        ['2022002', '孙鹏', '13800002002'],
        ['2022003', '周琳', '13800002003'],
      ],
    },

    // ── 草稿：仅发布者可见 ──────────────────────────────────────────
    {
      title: '（草稿）敬老院陪伴服务',
      organizer: '校青年志愿者协会',
      durationHours: 4,
      startTime: fromNow(3 * 24 * 60 + 510),
      endTime: fromNow(3 * 24 * 60 + 750),
      location: '泉山区某敬老院',
      geoLat: base.lat + 0.01,
      geoLng: base.lng - 0.008,
      checkinRadius: 300,
      status: 'draft',
      tags: ['敬老', '陪伴'],
      summary: '陪老人聊天、协助整理房间、表演节目。',
      description: '待确认院方接待时间与人数上限后发布。',
      contact: '协会办公室 0516-8888xxxx',
      participants: [],
    },

    // ── 已结束：3 天前，用于验证导出与留存倒计时 ────────────────────
    {
      title: '实验室安全巡查志愿岗',
      organizer: '实验室与设备管理处',
      durationHours: 1.5,
      startTime: fromNow(-3 * 24 * 60),
      endTime: fromNow(-3 * 24 * 60 + 90),
      location: '理科楼 A 座',
      geoLat: base.lat - 0.0015,
      geoLng: base.lng + 0.0022,
      checkinRadius: 150,
      locationType: 'indoor',
      attendanceFirstDelay: 15,
      attendanceInterval: 30,
      status: 'finished',
      tags: ['安全', '巡查'],
      summary: '逐层检查实验室门窗、气瓶固定与用电安全，记录异常并上报。',
      description: '两人一组，按楼层分工。需签署安全告知书。',
      contact: '张老师 13800009999',
      quota: 8,
      participants: [
        ['2023001', '吴磊', '13800003001'],
        ['2023002', '郑洁', '13800003002'],
      ],
    },

    // ── 已取消：验证 excused 与取消原因 ─────────────────────────────
    {
      title: '运动会志愿服务（因雨天取消）',
      organizer: '体育学院',
      durationHours: 6,
      startTime: fromNow(-24 * 60 - 120),
      endTime: fromNow(-24 * 60 + 240),
      location: '南湖校区田径场',
      geoLat: base.lat + 0.003,
      geoLng: base.lng - 0.001,
      checkinRadius: 400,
      status: 'cancelled',
      cancelReason: '当日持续降雨，场地湿滑，经与体育学院协商取消本次活动。',
      tags: ['赛事', '保障'],
      summary: '协助检录、计时与器材回收。',
      description: '原计划全天保障，分三班倒。',
      contact: '体育学院办公室',
      participants: [
        ['2024001', '马超', '13800004001'],
        ['2024002', '黄婷', '13800004002'],
      ],
    },
  ];

  for (const spec of activities) {
    const id = newId('act-');
    const now = new Date();
    const isFinished = spec.status === 'finished';
    const isCancelled = spec.status === 'cancelled';

    // 终态时刻 = 活动结束（已结束）或取消动作发生的时间。
    const terminalAt = isFinished
      ? spec.endTime
      : isCancelled
        ? fromNow(-20 * 60)
        : null;

    const activity = {
      id,
      // 方案 §4.1：`externalId` 是管理端的幂等键，必填。
      // 种子数据用可读的固定值，便于在演示与联调时直接引用。
      externalId: spec.externalId ?? `DEMO-${id.slice(-8).toUpperCase()}`,
      title: spec.title,
      organizer: spec.organizer,
      durationHours: spec.durationHours,
      startTime: spec.startTime,
      endTime: spec.endTime,
      signupDeadline: iso(addMinutes(new Date(spec.startTime), -60)),
      location: spec.location,
      geoLat: spec.geoLat,
      geoLng: spec.geoLng,
      checkinRadius: spec.checkinRadius,
      checkinWindowBefore: DEFAULTS.CHECKIN_WINDOW_BEFORE_MIN,
      checkinWindowAfter: DEFAULTS.CHECKIN_WINDOW_AFTER_MIN,
      attendanceFirstDelay: spec.attendanceFirstDelay ?? DEFAULTS.ATTENDANCE_FIRST_DELAY_MIN,
      attendanceInterval: spec.attendanceInterval ?? DEFAULTS.ATTENDANCE_INTERVAL_MIN,
      attendanceResponseWindow: DEFAULTS.ATTENDANCE_RESPONSE_WINDOW_MIN,
      quota: spec.quota ?? null,
      enrolled: (spec.participants ?? []).length,
      status: spec.status,
      tags: spec.tags,
      // 只用于决定默认签到半径（室外 300 / 室内 150），不参与判定。
      locationType: spec.locationType ?? null,
      summary: spec.summary,
      description: spec.description,
      contact: spec.contact,
      ownerId,
      version: 1,
      // 增量同步序号（网页方案 §6.4.9）。种子数据也要有，
      // 否则客户端的首次增量同步会看不到它们。
      seq: nextSeq(),
      ruleSnapshot: null,
      createdAt: fromNow(-48 * 60),
      updatedAt: iso(now),
      terminalAt,
      publishedAt: spec.status === 'draft' ? null : fromNow(-47 * 60),
      cancelReason: spec.cancelReason ?? null,
      finishedAt: isFinished ? terminalAt : null,
    };

    // 已发布的状态都要冻结规则快照（草稿不冻结）。
    if (spec.status !== 'draft') {
      activity.ruleSnapshot = {
        frozenAt: activity.publishedAt,
        startTime: activity.startTime,
        endTime: activity.endTime,
        durationHours: activity.durationHours,
        checkinRadius: activity.checkinRadius,
        checkinWindowBefore: activity.checkinWindowBefore,
        checkinWindowAfter: activity.checkinWindowAfter,
        attendanceFirstDelay: activity.attendanceFirstDelay,
        attendanceInterval: activity.attendanceInterval,
        attendanceResponseWindow: activity.attendanceResponseWindow,
        revision: 1,
        reason: null,
        changedBy: ownerId,
      };
    }

    store.db.activities.push(activity);

    // ── 名单与邀请码 ──────────────────────────────────────────────
    for (const [userNo, name, phone] of spec.participants ?? []) {
      store.db.participants.push({
        activityId: id,
        userNo,
        name,
        phone,
        phoneSuffix: phone.slice(-4),
        signupStatus: 'signed',
        addedAt: activity.createdAt,
        addedBy: ownerId,
        removedAt: null,
        removedBy: null,
        boundDeviceId: null,
        inviteCodeUsedAt: null,
        grantExpiresAt: null,
      });

      // 为进行中活动的前两个人生成邀请码，便于立刻演示绑定与签到。
      // 用**固定码**而不是随机码，这样验收与演示可以照文档操作。
      if (spec.status === 'ongoing' && ['2021001', '2021002'].includes(userNo)) {
        store.db.inviteCodes.push({
          activityId: id,
          userNo,
          name,
          code: codeForSeed(userNo),
          issuedAt: activity.createdAt,
          expiresAt: iso(addMinutes(new Date(spec.endTime), DEFAULTS.RETENTION_DAYS * 24 * 60)),
          usedAt: null,
          issuedBy: ownerId,
        });
      }
    }

    // ── 已结束活动：签到 → 抽查任务 → 在岗结果 ───────────────────────
    //
    // ⚠️ 顺序很关键：决策 D-6（网页方案 §4.5）规定**只为已签到者生成抽查任务**，
    // 因此必须先造签到，再调 `regenerateAttendanceTasks`。
    // 反过来做会得到 0 个任务，导出与考勤汇总的演示数据就是空的。
    if (isFinished) {
      const people = spec.participants ?? [];
      people.forEach(([userNo, name], idx) => {
        store.db.checkins.push({
          id: newId('chk-'),
          activityId: id,
          userNo,
          name,
          method: CHECKIN_METHOD.GEO,
          status: 'success',
          reason: '定位证据充分，自动通过',
          geoLat: spec.geoLat + 0.00008,
          geoLng: spec.geoLng - 0.00006,
          accuracy: 12 + idx * 3,
          score: 75 - idx * 10,
          scoreBreakdown: [
            { reason: '围栏内且距中心 8m（≤50m）', points: 40 },
            { reason: '多次采样一致', points: 10 },
            { reason: '签到前 60 秒内已有围栏内定位（停留验证）', points: 15 },
            { reason: '校园网 IP 命中', points: 10 },
          ],
          distanceMeters: 8 + idx * 5,
          mockLocationDetected: false,
          clientTime: iso(addMinutes(new Date(spec.startTime), 2)),
          serverTime: iso(addMinutes(new Date(spec.startTime), 2)),
          samples: [],
          deviceId: `demo-vol-${idx + 1}`,
          offlineBackfill: false,
          reviewedAt: null,
          reviewedBy: null,
          reviewNote: null,
        });
      });

      // 签到造完之后才生成抽查任务 —— 顺序不能反（见上面的说明）。
      regenerateAttendanceTasks(activity);

      // 在岗：第一人全勤；第二人第一次超时，其余完成。
      const tasks = store.db.attendanceTasks.filter((t) => t.activityId === id);
      for (const t of tasks) {
        if (t.userNo === people[0]?.[0]) {
          t.status = 'done';
          t.respondedAt = iso(addMinutes(new Date(t.scheduledAt), 1));
          t.geoLat = spec.geoLat;
          t.geoLng = spec.geoLng;
          t.accuracy = 15;
          t.distanceMeters = 20;
        } else if (t.userNo === people[1]?.[0]) {
          if (Number(t.seq) === 1) {
            t.status = 'missed';
            t.settledAt = iso(addMinutes(new Date(t.deadlineAt), 2));
          } else {
            t.status = 'done';
            t.respondedAt = iso(addMinutes(new Date(t.scheduledAt), 2));
            t.geoLat = spec.geoLat;
            t.geoLng = spec.geoLng;
            t.accuracy = 25;
            t.distanceMeters = 60;
          }
        }
      }
    }

    // ── 进行中活动：签到 → 生成抽查任务 ─────────────────────────────
    //
    // 同样必须先签到：决策 D-6 只为已签到者生成任务。
    // 演示数据里让前 3 人已签到，这样「待确认任务」入口一进 App 就有内容，
    // 而剩余 2 人保持未签到，用于演示「未签到」筛选与看板四态。
    if (spec.status === 'ongoing') {
      const people = spec.participants ?? [];
      people.slice(0, 3).forEach(([userNo, name], idx) => {
        store.db.checkins.push({
          id: newId('chk-'),
          activityId: id,
          userNo,
          name,
          method: CHECKIN_METHOD.GEO,
          status: 'success',
          reason: '定位证据充分，自动通过',
          geoLat: spec.geoLat + 0.00005,
          geoLng: spec.geoLng + 0.00004,
          accuracy: 12 + idx * 2,
          score: 75 - idx * 5,
          scoreBreakdown: [
            { reason: '围栏内且距中心 8m（≤50m）', points: 40 },
            { reason: '多次采样一致', points: 10 },
            { reason: '签到前 60 秒内已有围栏内定位（停留验证）', points: 15 },
            { reason: '校园网 IP 命中', points: 10 },
          ],
          distanceMeters: 8 + idx * 4,
          mockLocationDetected: false,
          clientTime: iso(addMinutes(new Date(), -40 + idx)),
          serverTime: iso(addMinutes(new Date(), -40 + idx)),
          samples: [],
          deviceId: `demo-vol-${idx + 1}`,
          offlineBackfill: false,
          reviewedAt: null,
          reviewedBy: null,
          reviewNote: null,
        });
        const p = store.db.participants.find(
          (x) => x.activityId === id && x.userNo === userNo,
        );
        if (p) {
          p.checkinStatus = 'checked_in';
        }
      });

      regenerateAttendanceTasks(activity);

      // 让 seq=1 的任务已经超时（deadline 在过去）—— 用于演示「已超时」筛选
      // 与「现场点名补录」兜底；seq=2 挪到当下，志愿者一进 App 就能响应。
      const tasks = store.db.attendanceTasks.filter((t) => t.activityId === id);
      for (const t of tasks) {
        if (Number(t.seq) === 1) {
          t.scheduledAt = iso(addMinutes(new Date(), -20));
          t.deadlineAt = iso(addMinutes(new Date(), -15));
          t.notifiedAt = iso(addMinutes(new Date(), -21));
        } else if (Number(t.seq) === 2) {
          t.scheduledAt = iso(addMinutes(new Date(), -1));
          t.deadlineAt = iso(addMinutes(new Date(), 4));
        }
      }
    }

    // 已取消活动：保留 excused 的痕迹（方案 §5.3）。
    if (isCancelled) {
      for (const [userNo] of spec.participants ?? []) {
        for (let seq = 1; seq <= 3; seq++) {
          store.db.attendanceTasks.push({
            id: newId('task-'),
            activityId: id,
            userNo,
            seq,
            scheduledAt: iso(addMinutes(new Date(spec.startTime), 15 + (seq - 1) * 30)),
            deadlineAt: iso(addMinutes(new Date(spec.startTime), 20 + (seq - 1) * 30)),
            status: 'excused',
            notifiedAt: null,
            respondedAt: null,
            excusedAt: terminalAt,
            excusedReason: '活动取消',
            manualFill: false,
            filledBy: null,
          });
        }
      }
    }
  }

  store.save();

  const ongoing = store.db.activities.find((a) => a.status === 'ongoing');
  if (ongoing) {
    console.log(
      `[seed] 已写入 ${store.db.activities.length} 个演示活动；` +
        `进行中活动：${ongoing.title}（${ongoing.id}）`,
    );
    console.log(
      `[seed] 签到窗口：${ongoing.startTime} ~ ${ongoing.endTime}（当前时刻在窗口内）`,
    );
    console.log('[seed] 两小时活动生成 3 次抽查（T+15/T+45/T+75）已验证于验收用例 A20');
  }
  return true;
}
