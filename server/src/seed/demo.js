/**
 * 演示数据。
 *
 * ## 为什么需要它
 *
 * 新库是空的，而 Web 列表页、筛选栏、统计图都需要**有分布的数据**
 * 才能看出对不对：只有一条记录时，"按状态筛选"和"按时间范围筛选"
 * 都看不出问题。
 *
 * 因此这里刻意造出**覆盖各状态、跨越多个月份**的数据。
 *
 * ## 时间锚定
 *
 * 所有时间**相对当前时刻**计算，不用固定日期。理由：固定日期在
 * 某一天跑得通，过几天就变成"全部已结束"，
 * 演示与联调会莫名其妙地失败 —— 移动端阶段踩过这个坑。
 *
 * ## 只写入空库
 *
 * 已有数据时直接返回，不覆盖开发者手工造的数据。
 */

import { ACTIVITY_STATUS } from '../contract.js';
import { toIso, addMinutesIso } from '../util/time.js';

/** 相对当前的分钟偏移 → ISO。 */
function at(minutesFromNow) {
  return addMinutesIso(new Date(), minutesFromNow);
}

const OWNER_ID = 'owner-demo-0001';

/**
 * 演示活动。
 *
 * 状态分布刻意覆盖全部五种，便于验证筛选与统计；
 * 时间分布跨越过去与未来，便于验证时间范围筛选。
 */
function demoActivities() {
  return [
    {
      externalId: 'DEMO-2025-0001',
      title: '图书馆书架整理志愿服务',
      organizer: '校青年志愿者协会',
      durationHours: 3,
      // 已开始 40 分钟 → **进行中**，且在签到窗口内（可现场演示签到）
      startTime: at(-40),
      endTime: at(140),
      location: '南湖校区图书馆三层',
      locationType: 'indoor',
      geoLat: 34.2175,
      geoLng: 117.1425,
      checkinRadius: 200,
      attendanceFirstDelay: 20,
      attendanceInterval: 30,
      status: ACTIVITY_STATUS.ONGOING,
      tags: ['图书整理', '校内'],
      summary: '协助整理三层社科类书架，按索书号归位，并登记破损书籍。',
      description:
        '工作内容：按索书号将归还图书归位；登记破损与缺页图书；协助读者检索。\n\n' +
        '注意事项：请穿平底鞋，书架区禁止饮食。现场有馆员带教。',
      contact: '13800000001',
      quota: 20,
    },
    {
      externalId: 'DEMO-2025-0002',
      title: '校园文明劝导志愿活动',
      organizer: '校学生会',
      durationHours: 2,
      // 明天开始 → 已发布，未开始
      startTime: at(20 * 60),
      endTime: at(22 * 60),
      location: '南湖校区东门广场',
      locationType: 'outdoor',
      geoLat: 34.2196,
      geoLng: 117.1438,
      checkinRadius: 150,
      status: ACTIVITY_STATUS.PUBLISHED,
      tags: ['文明劝导', '校内'],
      summary: '在上下课高峰时段引导非机动车有序停放，劝导不文明行为。',
      description: '分为两个班次，每班 1 小时。提供反光背心与劝导牌。',
      contact: '13800000002',
      quota: 12,
    },
    {
      externalId: 'DEMO-2025-0003',
      title: '实验室安全巡查志愿岗',
      organizer: '实验室与设备管理处',
      durationHours: 1.5,
      // 三天前结束 → 已结束
      startTime: at(-3 * 24 * 60),
      endTime: at(-3 * 24 * 60 + 90),
      location: '理科楼 A 座',
      locationType: 'indoor',
      geoLat: 34.216,
      geoLng: 117.1447,
      checkinRadius: 150,
      status: ACTIVITY_STATUS.FINISHED,
      tags: ['实验室', '安全巡查'],
      summary: '协助巡查实验室用电与危化品存放，记录并上报隐患。',
      description: '需提前 10 分钟到值班室领取巡查表。巡查路线由值班老师指定。',
      contact: '13800000003',
      quota: 8,
    },
    {
      externalId: 'DEMO-2025-0004',
      title: '校运动会志愿服务（因雨天取消）',
      organizer: '体育学院',
      durationHours: 6,
      startTime: at(-1 * 24 * 60),
      endTime: at(-1 * 24 * 60 + 360),
      location: '南湖校区田径场',
      locationType: 'outdoor',
      geoLat: 34.2205,
      geoLng: 117.1415,
      checkinRadius: 400,
      status: ACTIVITY_STATUS.CANCELLED,
      tags: ['运动会', '赛事服务'],
      summary: '协助检录、计时与器材管理，维持赛道秩序。',
      description: '原定两天，因持续降雨取消。',
      contact: '13800000004',
      quota: 30,
      cancelReason: '当日持续降雨，场地湿滑，经与体育学院协商取消',
    },
    {
      externalId: 'DEMO-2025-0005',
      title: '社区敬老院陪伴服务',
      organizer: '校青年志愿者协会',
      durationHours: 4,
      // 一周后 → 已发布
      startTime: at(7 * 24 * 60),
      endTime: at(7 * 24 * 60 + 240),
      location: '泉山区幸福敬老院',
      locationType: 'indoor',
      geoLat: 34.2351,
      geoLng: 117.1268,
      checkinRadius: 150,
      status: ACTIVITY_STATUS.PUBLISHED,
      tags: ['敬老', '校外'],
      summary: '陪伴老人聊天、协助整理内务、表演小节目。',
      description: '集合地点为校门口，统一乘车前往。请勿携带贵重物品。',
      contact: '13800000005',
      quota: 15,
    },
    {
      externalId: 'DEMO-2025-0006',
      title: '校园绿化养护志愿活动',
      organizer: '后勤管理处',
      durationHours: 2.5,
      // 一个月前结束 → 已过较久，用于验证"历史活动"筛选
      startTime: at(-30 * 24 * 60),
      endTime: at(-30 * 24 * 60 + 150),
      location: '南湖校区校友林',
      locationType: 'outdoor',
      geoLat: 34.2183,
      geoLng: 117.1409,
      checkinRadius: 300,
      status: ACTIVITY_STATUS.FINISHED,
      tags: ['绿化', '校内'],
      summary: '协助修剪绿篱、清理枯枝与浇水，配合园林师傅作业。',
      description: '工具由后勤处提供，请自备手套。',
      contact: '13800000006',
      quota: 25,
    },
    {
      externalId: 'DEMO-2025-0007',
      title: '考研自习室秩序维护',
      organizer: '图书馆',
      durationHours: 3,
      // 两小时后开始 → 已发布，即将开始
      startTime: at(120),
      endTime: at(300),
      location: '南湖校区图书馆一层自习区',
      locationType: 'indoor',
      geoLat: 34.2177,
      geoLng: 117.1421,
      checkinRadius: 150,
      status: ACTIVITY_STATUS.PUBLISHED,
      tags: ['图书馆', '秩序维护'],
      summary: '协助维护自习室安静有序，劝导占座与饮食行为。',
      description: '每 30 分钟巡视一次，填写巡视记录表。',
      contact: '13800000007',
      quota: 6,
    },
    {
      externalId: 'DEMO-2025-0008',
      title: '旧书捐赠整理与登记',
      organizer: '校青年志愿者协会',
      durationHours: 5,
      // 已结束 10 天 → 仍在留存期内（终态 +7 天？不，已过 → 应不可见）
      // 刻意留一条**超过留存期**的：验证"7 天后不可访问"确实生效。
      startTime: at(-10 * 24 * 60),
      endTime: at(-10 * 24 * 60 + 300),
      location: '大学生活动中心',
      locationType: 'indoor',
      geoLat: 34.2189,
      geoLng: 117.1432,
      checkinRadius: 150,
      status: ACTIVITY_STATUS.FINISHED,
      tags: ['旧书', '公益'],
      summary: '整理捐赠图书，分类登记并打包，供乡村学校使用。',
      description: '需搬运，建议穿长裤。',
      contact: '13800000008',
      quota: 18,
      // 终态时刻设为 10 天前 → 已过 7 天留存期
      terminalAtOverride: at(-10 * 24 * 60 + 300),
    },
  ];
}

/**
 * 写入演示数据。
 *
 * @param {object} repos 含 `activities` 仓储
 * @param {(msg: string) => void} [log]
 */
/**
 * 把一批活动规格写进库（供两套种子共用）。
 *
 * 两个调用方：
 *   * [seedDemoData]  —— **测试用**：8 条覆盖全部状态，验证筛选/统计/分页；
 *   * [seedShowcaseData] —— **演示用**：只有 2 条，给验收者一个干净的画面。
 *
 * 分开是因为两者目标相反：测试要"分布足够杂"，演示要"一眼看得懂"。
 */
async function insertActivities(repos, specs, log) {
  let inserted = 0;
  for (const spec of specs) {
    const now = toIso(new Date());
    const isFinished = spec.status === ACTIVITY_STATUS.FINISHED;
    const isCancelled = spec.status === ACTIVITY_STATUS.CANCELLED;

    // 终态时刻：已结束用结束时间，已取消用结束时间之后。
    // 允许 spec 覆盖（用于造"已过留存期"的数据）。
    let terminalAt = null;
    if (spec.terminalAtOverride) {
      terminalAt = spec.terminalAtOverride;
    } else if (isFinished) {
      terminalAt = spec.endTime;
    } else if (isCancelled) {
      terminalAt = spec.endTime;
    }

    const activity = {
      ...spec,
      ownerId: OWNER_ID,
      seq: 0,
      version: 1,
      enrolled: 0,
      createdAt: spec.startTime,
      updatedAt: spec.startTime,
      publishedAt: spec.status === ACTIVITY_STATUS.DRAFT ? null : spec.startTime,
      startedAt: spec.status === ACTIVITY_STATUS.ONGOING ? spec.startTime : null,
      finishedAt: isFinished ? spec.endTime : null,
      cancelledAt: isCancelled ? terminalAt : null,
      terminalAt,
      cancelReason: spec.cancelReason ?? null,
      signupDeadline: null,
      checkinWindowBefore: 30,
      checkinWindowAfter: 60,
      attendanceResponseWindow: 5,
    };
    delete activity.terminalAtOverride;

    await repos.activities.create(activity);
    inserted += 1;
  }
  return inserted;
}

/**
 * 测试用种子：8 条，覆盖全部状态与多个月份。
 *
 * ⚠️ **不要把它换成 2 条**：`server.test.mjs` 里有十几处依赖
 * "各状态都至少有一条、且跨越多个月份"，换成展示档会让那些用例
 * 变成"筛选结果为 0"，但报错会指向业务逻辑，很难查。
 */
export async function seedDemoData(repos, log = () => {}) {
  const existing = await repos.activities.search({ page: 1, size: 1, includeExpired: true });
  if (existing.total > 0) {
    log(`已有 ${existing.total} 条活动，跳过种子数据`);
    return { inserted: 0, skipped: true };
  }
  const inserted = await insertActivities(repos, demoActivities(), log);
  log(`已写入 ${inserted} 条演示活动`);
  return { inserted, skipped: false };
}

// ─────────────────────────────────────────────────────────────────────────
// 展示档：只留两个活动
// ─────────────────────────────────────────────────────────────────────────

/**
 * 展示档的两个活动。
 *
 * ## 为什么只留两个
 *
 * 演示时列表里堆 8 条会让验收者不知道看哪个；而"一条都没有"又看不出
 * 列表、筛选、看板长什么样。两条刚好覆盖演示最需要的两种状态：
 *
 *   1. **进行中** —— 能演示现场看板、名单、签到/复核、在岗抽查；
 *   2. **已发布**（几天后）—— 能演示"浏览活动 / 报名中"的样子。
 *
 * 第一条还带了名单与两条签到（1 已通过 + 1 待复核），
 * 这样打开看板就是"有数据"的样子，不用先花 5 分钟造数据。
 */
function showcaseActivities() {
  return [
    {
      externalId: 'DEMO-SHOW-0001',
      title: '图书馆书架整理志愿服务',
      organizer: '校青年志愿者协会',
      durationHours: 3,
      // 已开始 40 分钟、还有 2 小时 20 分结束 → 进行中，且签到窗口开着
      startTime: at(-40),
      endTime: at(140),
      location: '南湖校区图书馆三层',
      locationType: 'indoor',
      geoLat: 34.2175,
      geoLng: 117.1425,
      checkinRadius: 200,
      attendanceFirstDelay: 20,
      attendanceInterval: 30,
      status: ACTIVITY_STATUS.ONGOING,
      tags: ['图书整理', '校内'],
      summary: '协助整理三层社科类书架，按索书号归位，并登记破损书籍。',
      description:
        '工作内容：按索书号将归还图书归位；登记破损与缺页图书；协助读者检索。\n\n' +
        '注意事项：请穿平底鞋，书架区禁止饮食。现场有馆员带教。',
      contact: '13800000001',
      quota: 20,
    },
    {
      externalId: 'DEMO-SHOW-0002',
      title: '社区敬老院陪伴服务',
      organizer: '校青年志愿者协会',
      durationHours: 4,
      // 三天后开始 → 已发布、报名中
      startTime: at(3 * 24 * 60),
      endTime: at(3 * 24 * 60 + 240),
      location: '泉山区幸福敬老院',
      locationType: 'outdoor',
      geoLat: 34.2351,
      geoLng: 117.1235,
      checkinRadius: 300,
      status: ACTIVITY_STATUS.PUBLISHED,
      tags: ['敬老', '校外'],
      summary: '陪伴老人聊天、协助整理内务、表演小节目。',
      description:
        '工作内容：分组陪伴老人聊天；协助整理房间与活动室；准备 10 分钟小节目。\n\n' +
        '注意事项：着装整洁，提前 10 分钟在敬老院门口集合。',
      contact: '13800000002',
      quota: 12,
    },
  ];
}

/** 展示档活动里的名单（配合活动 1 演示看板）。 */
const SHOWCASE_ROSTER = [
  { userNo: '2026101', name: '张伟', phone: '13800000101', college: '计算机科学与技术学院' },
  { userNo: '2026102', name: '李娜', phone: '13800000102', college: '外国语言文化学院' },
  { userNo: '2026103', name: '王强', phone: '13800000103', college: '安全工程学院' },
  { userNo: '2026104', name: '赵敏', phone: '13800000104', college: '信息与控制工程学院' },
];

/**
 * 展示档种子：2 个活动 + 名单 + 两条签到 + 一条在岗抽查。
 *
 * 只在空库写入，不覆盖已有数据。
 */
export async function seedShowcaseData(repos, db, log = () => {}) {
  const existing = await repos.activities.search({ page: 1, size: 1, includeExpired: true });
  if (existing.total > 0) {
    log(`已有 ${existing.total} 条活动，跳过展示数据`);
    return { inserted: 0, skipped: true };
  }

  const inserted = await insertActivities(repos, showcaseActivities(), log);
  const activities = await repos.activities.search({ page: 1, size: 50, includeExpired: true });
  const ongoing = activities.items.find((a) => a.status === ACTIVITY_STATUS.ONGOING);
  if (!ongoing) {
    log(`已写入 ${inserted} 条展示活动`);
    return { inserted, skipped: false };
  }
  const activityId = String(ongoing.id);

  // ① 名单
  for (const p of SHOWCASE_ROSTER) {
    await db.execute(
      `INSERT INTO participant
         (activity_id, user_no, name, phone, phone_suffix, college, signup_status,
          created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, 'registered', ?, ?)`,
      [
        activityId,
        p.userNo,
        p.name,
        p.phone,
        p.phone.slice(-4),
        p.college,
        toIso(new Date()),
        toIso(new Date()),
      ],
    );
  }

  // ② 两条签到：一条已通过、一条待复核 —— 打开看板就是"有数据"的样子
  const seedCheckin = async ({ userNo, name, status, score, breakdown, distance }) => {
    await db.execute(
      `INSERT INTO checkin
         (activity_id, user_no, name, method, status, geo_lat, geo_lng, accuracy,
          score, score_breakdown, distance_meters, client_time, server_time,
          wifi_matched, campus_ip_matched, offline_backfill)
       VALUES (?, ?, ?, 'geo', ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 1, 0)`,
      [
        activityId,
        userNo,
        name,
        status,
        ongoing.geoLat,
        ongoing.geoLng,
        distance,
        score,
        JSON.stringify(breakdown),
        distance <= 5 ? 0.8 : 12.5,
        toIso(new Date()),
        toIso(new Date()),
      ],
    );
  };

  await seedCheckin({
    userNo: '2026101',
    name: '张伟',
    status: 'success',
    score: 60,
    distance: 20,
    breakdown: [
      { reason: '围栏内且距中心 8m（≤50m）', points: 40 },
      { reason: '校园网 IP 命中', points: 10 },
      { reason: '多次采样一致', points: 10 },
    ],
  });
  await seedCheckin({
    userNo: '2026102',
    name: '李娜',
    status: 'pending_review',
    score: 45,
    distance: 60,
    breakdown: [
      { reason: '围栏内且距中心 60m（50–200m）', points: 25 },
      { reason: '校园网 IP 命中', points: 10 },
      { reason: '多次采样一致', points: 10 },
    ],
  });

  // ③ 一条已完成的在岗抽查，让"考勤"一栏不是空的
  await db.execute(
    `INSERT INTO attendance_task
       (activity_id, user_no, seq, scheduled_at, deadline_at, status,
        responded_at, geo_lat, geo_lng, accuracy)
     VALUES (?, ?, 1, ?, ?, 'done', ?, ?, ?, 25)`,
    [
      activityId,
      '2026101',
      at(-15),
      at(-10),
      at(-12),
      ongoing.geoLat,
      ongoing.geoLng,
    ],
  );

  log(`已写入 ${inserted} 条展示活动（含名单 ${SHOWCASE_ROSTER.length} 人、签到 2 条）`);
  return { inserted, skipped: false };
}

export { OWNER_ID };
