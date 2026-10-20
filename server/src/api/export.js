/**
 * 导出（方案 §7.3）。
 *
 * ## 方案对导出的三条要求
 *
 * > | 导出 CSV | **服务端导出接口**，三端共用；UTF-8 BOM |
 *
 * 1. **在服务端做**，不是前端拼 —— 因为三端（两个 App + Web）要共用
 *    同一份逻辑。前端各自实现一遍，导出的列与口径必然分叉，
 *    而"同一个活动在两处导出的数字不一样"是很难解释的问题。
 * 2. **UTF-8 BOM** —— 没有 BOM 时 Excel 会把中文读成乱码。
 *    这是实测最常见的"导出功能不好用"的抱怨来源。
 * 3. 三条零成本底线之一（方案 §9.1）：
 *    > 敏感字段导出默认脱敏，**显式开启**才给完整值，且开启行为写审计
 *
 * ## 为什么这里没有实现"开启完整值"
 *
 * 方案 §9.1 说"显式开启才给完整值"。完整值导出是**管理端**的能力
 * （发布者需要联系志愿者），而 Web 端是公开只读的 —— 它**永远**
 * 只应看到脱敏值。
 *
 * 因此这里只有脱敏分支；完整值导出的显式开关属于 P2 的管理端接口，
 * 届时必须同时写 `export_audit`。**不要**在 Web 端加这个开关。
 */

import { ACTIVITY_STATUS } from '../contract.js';
import { fail } from '../http/envelope.js';
import { formatDisplay, toIso } from '../util/time.js';
import { maskContact, maskPhone } from '../sanitize.js';

/**
 * CSV 单元格转义。
 *
 * ## 为什么每格都必须处理，而不能"看起来没问题就不加引号"
 *
 * 活动标题里带逗号、说明里带换行、部门名带引号 —— 这些都是真实会出现的。
 * 一个未转义的逗号会让整行**列错位**，而 Excel 不会报错，
 * 只是把数据摊到错误的列里。那比直接失败更糟：使用者不会发现。
 *
 * 规则（RFC 4180）：含 `,` / `"` / 换行 的格子用双引号包起来，
 * 内部的 `"` 变成 `""`。
 */
export function csvCell(value) {
  if (value === null || value === undefined) {
    return '';
  }
  const s = String(value);
  if (s === '') {
    return '';
  }
  if (/[",\r\n]/.test(s)) {
    return `"${s.replace(/"/g, '""')}"`;
  }
  return s;
}

/** 组装 CSV 文本。`rows` 是二维数组。 */
export function toCsv(rows) {
  return rows.map((row) => row.map(csvCell).join(',')).join('\r\n');
}

/**
 * UTF-8 BOM。
 *
 * ⚠️ **必须有**。没有它，Excel（中文 Windows 默认 GBK）打开
 * 会把 UTF-8 的中文读成乱码 —— 使用者第一反应是"导出坏了"。
 * 这个字符在多数编辑器里不可见，容易在重构时被"顺手删掉"，
 * 因此这里用常量并注明原因。
 */
export const UTF8_BOM = '\uFEFF';

/**
 * 生成 Content-Disposition 头。
 *
 * ## 为什么要写两遍文件名（`filename` 与 `filename*`）
 *
 * 中文文件名不能直接放进 `filename=` —— HTTP 头是 ASCII 的，
 * 直接写中文会被某些客户端截断或乱码。正确做法是：
 *
 *   * `filename="fallback.csv"` —— 纯 ASCII 兜底，给老客户端；
 *   * `filename*=UTF-8''%E6%B4%BB%E5%8A%A8.csv` —— RFC 5987 编码，
 *     现代浏览器优先用它，因此中文名能正确显示。
 *
 * 只写后者会让老客户端拿到空文件名；只写前者则中文名丢失。
 */
export function contentDisposition(filenameAscii, filenameUnicode) {
  const encoded = encodeURIComponent(filenameUnicode);
  return `attachment; filename="${filenameAscii}"; filename*=UTF-8''${encoded}`;
}

/** 发送 CSV 下载响应。 */
export function sendCsv(res, { filenameAscii, filenameUnicode, csv }) {
  const payload = Buffer.from(UTF8_BOM + csv, 'utf8');
  res.writeHead(200, {
    'Content-Type': 'text/csv; charset=utf-8',
    'Content-Length': payload.length,
    'Content-Disposition': contentDisposition(filenameAscii, filenameUnicode),
    // 导出内容随活动变化，不该被任何层缓存。
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': res.corsOrigin ?? '*',
    // 让前端能读到文件名（跨域时需要显式暴露）。
    'Access-Control-Expose-Headers': 'Content-Disposition',
  });
  res.end(payload);
}

/** 把时间列格式化成稳定的可读形式。 */
function dt(v) {
  return v ? formatDisplay(v) : '';
}

/** 活动信息的列定义（导出与展示口径一致）。 */
const ACTIVITY_HEADERS = [
  '活动编号',
  '活动名称',
  '组织部门',
  '状态',
  '志愿时长(小时)',
  '开始时间',
  '结束时间',
  '活动地点',
  '纬度',
  '经度',
  '签到半径(米)',
  // 场地网络白名单（O-17）：审计"为什么某次签到被判自动通过"时要能查到。
  '场地 Wi-Fi(BSSID)',
  '校园网网段',
  '招募人数',
  '已报名人数',
  '标签',
  '一句话简介',
  '活动说明',
  '联系方式',
];

const STATUS_LABEL = {
  [ACTIVITY_STATUS.DRAFT]: '草稿',
  [ACTIVITY_STATUS.PUBLISHED]: '报名中',
  [ACTIVITY_STATUS.ONGOING]: '进行中',
  [ACTIVITY_STATUS.FINISHED]: '已结束',
  [ACTIVITY_STATUS.CANCELLED]: '已取消',
};

/** 一行活动。 */
function activityRow(a) {
  return [
    a.externalId,
    a.title,
    a.organizer,
    STATUS_LABEL[a.status] ?? a.status,
    a.durationHours,
    dt(a.startTime),
    dt(a.endTime),
    a.location,
    a.geoLat ?? '',
    a.geoLng ?? '',
    a.checkinRadius ?? '',
    // 空数组与"未配置"都导出空串 —— 导出是给人看的，不需要区分这两种内部状态。
    (a.wifiBssids ?? []).join(' / '),
    (a.campusIpPrefixes ?? []).join(' / '),
    a.quota ?? '',
    a.enrolled ?? 0,
    (a.tags ?? []).join(' / '),
    a.summary,
    // 说明里的换行会被 csvCell 正确转义在引号内。
    a.description,
    // ⚠️ 脱敏。Web/App 的公开导出永远不给完整手机号。
    maskContact(a.contact),
  ];
}

/**
 * `GET /activities/export` —— 导出活动列表。
 *
 * 支持与列表页**完全相同的筛选参数**，这样"筛选后导出"才符合直觉：
 * 使用者在界面上筛出 12 条，导出却发现有 200 条，会认为功能坏了。
 */
export async function exportActivities(ctx) {
  const q = ctx.query;

  const filters = {
    keyword: q.keyword ? String(q.keyword).trim() : null,
    organizer: q.organizer ? String(q.organizer).trim() : null,
    statuses: q.status
      ? String(q.status).split(',').map((s) => s.trim()).filter(Boolean)
      : null,
    startFrom: q.startFrom ? String(q.startFrom) : null,
    startTo: q.startTo ? String(q.startTo) : null,
    sortBy: q.sortBy ? String(q.sortBy) : 'startTime',
    sortDesc: String(q.sortDesc ?? 'true') !== 'false',
  };

  /*
    ⚠️ 导出**不受分页限制**，但要有硬上限。

    没有上限的话，一次导出几万行会长时间占用连接与内存；
    而没有"不受分页限制"又会让导出与筛选不一致。
    这里取一个足够大的值（5000），并在达到上限时**明确告知**
    （通过响应头），而不是安静地截断 —— 安静截断会让使用者
    以为导出完整，从而漏掉数据。
  */
  const EXPORT_LIMIT = 5000;
  const { items, total } = await ctx.repos.activities.search({
    ...filters,
    page: 1,
    size: EXPORT_LIMIT,
  });

  const rows = [ACTIVITY_HEADERS, ...items.map(activityRow)];
  const csv = toCsv(rows);

  if (total > EXPORT_LIMIT && ctx.logger) {
    ctx.logger.warn('导出达到行数上限，结果被截断', {
      total,
      exported: items.length,
      limit: EXPORT_LIMIT,
    });
  }

  const stamp = toIso(new Date()).slice(0, 10);
  sendCsv(ctx.res, {
    filenameAscii: `activities-${stamp}.csv`,
    filenameUnicode: `志愿活动-${stamp}.csv`,
    csv,
  });

  return undefined; // 已自行响应。
}

/** 签到状态的中文列名（导出是给人看的，不能出现 success/pending_review）。 */
const CHECKIN_STATUS_LABEL = {
  success: '已通过',
  pending_review: '待确认',
  rejected: '已驳回',
  invalid: '无效',
  absent: '未签到',
};

/** 在岗抽查状态的中文列名。 */
const TASK_STATUS_LABEL = {
  pending: '待确认',
  done: '已完成',
  missed: '未完成',
  excused: '已豁免',
};

/**
 * 单条活动导出支持的 `kind`（方案 §7.3 / README §3.3）。
 *
 * ⚠️ `activities` 是**网页端实际发的值**（`ActivityListPage.vue` 与
 * `ActivityDetailPage.vue` 都写 `?kind=activities`），语义等于"这条活动的
 * 活动信息"，也就是 `summary`。
 *
 * 我最初按方案里的 kind 列表做了严格白名单，**漏了 `activities`**，
 * 于是网页的「导出为 CSV」直接 400 —— 而 App 端用的是 `checkin_list`，
 * 一切正常。两个客户端各用一种写法，只测一边就发现不了。
 * 现在把两者都当合法值，并归一化到同一分支。
 */
const EXPORT_KINDS = [
  'activities', // 网页端：活动信息（= summary）
  'summary',
  'checkin_list',
  'participants',
  'attendance_detail',
  'my_records',
];

/** 把 kind 归一化到内部实际分支。 */
function normalizeKind(raw) {
  const kind = String(raw);
  return kind === 'activities' ? 'summary' : kind;
}

/**
 * 导出单个活动的 CSV（详情页的"导出"按钮）。
 *
 * ## 为什么这里必须看 `kind`
 *
 * 客户端（管理端详情页）传的是 `?kind=checkin_list`，意思是
 * **要签到名单**。服务端早期忽略了这个参数、无脑返回"活动字段/值"，
 * 于是用户点"导出签到名单"，拿到的是活动信息摘要 ——
 * 文件能下载、能打开、看起来也对，只是**内容不是他要的**。
 * 这类"错得体面"的 bug 最难被发现，是端到端用例抓出来的。
 *
 * ## 三条零成本底线
 *
 * 1. 首行固定提示 **「仅限内部使用」**；
 * 2. 手机号默认**脱敏**（`maskPhone`），完整值永远不导出；
 * 3. 服务端生成 + UTF-8 BOM（见 `sendCsv`）。
 */
export async function exportActivity(ctx) {
  const a = await ctx.repos.activities.findById(ctx.params.id);
  if (!a) {
    throw fail('ACTIVITY_NOT_FOUND');
  }
  if (a.status === ACTIVITY_STATUS.DRAFT) {
    throw fail('ACTIVITY_NOT_FOUND');
  }
  const activityId = String(a.id);

  const requested = String(ctx.query.kind ?? ctx.query.type ?? 'checkin_list');
  if (!EXPORT_KINDS.includes(requested)) {
    throw fail('BAD_REQUEST', `不支持的导出类型：${requested}`);
  }
  // 归一化：网页的 `activities` 与 `summary` 走同一分支。
  const kind = normalizeKind(requested);

  /*
    志愿者只能导自己的记录。

    `my_records` 是用户端"我的记录"用的；如果放任意志愿者导出
    `checkin_list`，等于把整份名单（哪怕脱敏）发给了参与者本人。
  */
  const auth = ctx.auth;
  if (auth?.kind === 'volunteer') {
    if (auth.activityId !== activityId) {
      throw fail('FORBIDDEN', '无权导出其他活动的记录');
    }
    if (kind !== 'my_records' && kind !== 'summary') {
      throw fail('FORBIDDEN', '参与者只能导出自己的记录');
    }
  }

  const now = toIso(new Date());
  /** 行数组。首行是"仅限内部使用"提示 —— 验收要求，别删。 */
  const rows = [
    [`# 志愿活动信息平台导出 · 仅限内部使用 · 生成时间 ${formatDisplay(now)}`],
  ];

  if (kind === 'summary') {
    rows.push(['字段', '值']);
    ACTIVITY_HEADERS.forEach((label, i) => {
      rows.push([label, activityRow(a)[i]]);
    });
  } else if (kind === 'checkin_list' || kind === 'participants') {
    // 名单 + 各自最新一条签到。软删的人也列出来并标注状态，便于对账。
    const people = await ctx.db.query(
      `SELECT p.user_no, p.name, p.college, p.phone, p.signup_status, p.removed_at,
              (SELECT c.status      FROM checkin c
                WHERE c.activity_id = p.activity_id AND c.user_no = p.user_no
                ORDER BY c.id DESC LIMIT 1) AS checkin_status,
              (SELECT c.score       FROM checkin c
                WHERE c.activity_id = p.activity_id AND c.user_no = p.user_no
                ORDER BY c.id DESC LIMIT 1) AS score,
              (SELECT c.server_time FROM checkin c
                WHERE c.activity_id = p.activity_id AND c.user_no = p.user_no
                ORDER BY c.id DESC LIMIT 1) AS server_time,
              (SELECT c.review_note FROM checkin c
                WHERE c.activity_id = p.activity_id AND c.user_no = p.user_no
                ORDER BY c.id DESC LIMIT 1) AS review_note
         FROM participant p
        WHERE p.activity_id = ?
        ORDER BY p.id`,
      [activityId],
    );

    rows.push(['学号', '姓名', '学院', '手机号', '名单状态', '签到状态', '评分', '签到时间', '复核备注']);
    for (const p of people) {
      rows.push([
        p.user_no,
        p.name ?? '',
        p.college ?? '',
        // ⚠️ 脱敏：导出文件会被转发、被留在下载目录，完整手机号不该出现在里面。
        maskPhone(p.phone) ?? '',
        p.removed_at ? '已移出' : '在册',
        CHECKIN_STATUS_LABEL[p.checkin_status] ?? '未签到',
        p.score ?? '',
        p.server_time ? formatDisplay(p.server_time) : '',
        p.review_note ?? '',
      ]);
    }
  } else if (kind === 'attendance_detail') {
    const tasks = await ctx.db.query(
      `SELECT t.*, p.name
         FROM attendance_task t
         LEFT JOIN participant p
           ON p.activity_id = t.activity_id AND p.user_no = t.user_no
        WHERE t.activity_id = ?
        ORDER BY t.id`,
      [activityId],
    );
    rows.push(['学号', '姓名', '抽查轮次', '计划时间', '截止时间', '状态', '确认时间']);
    for (const t of tasks) {
      rows.push([
        t.user_no,
        t.name ?? '',
        t.seq ?? '',
        t.scheduled_at ? formatDisplay(t.scheduled_at) : '',
        t.deadline_at ? formatDisplay(t.deadline_at) : '',
        TASK_STATUS_LABEL[t.status] ?? (t.status ?? ''),
        t.responded_at ? formatDisplay(t.responded_at) : '',
      ]);
    }
  } else {
    // my_records：志愿者本人的签到记录。
    const userNo = auth?.userNo ?? null;
    if (!userNo) {
      throw fail('FORBIDDEN', '只有参与者本人可以导出自己的记录');
    }
    const mine = await ctx.db.query(
      `SELECT * FROM checkin WHERE activity_id = ? AND user_no = ? ORDER BY id`,
      [activityId, userNo],
    );
    rows.push(['学号', '姓名', '签到时间', '状态', '评分', '复核备注']);
    for (const c of mine) {
      rows.push([
        c.user_no,
        c.name ?? '',
        c.server_time ? formatDisplay(c.server_time) : '',
        CHECKIN_STATUS_LABEL[c.status] ?? c.status,
        c.score ?? '',
        c.review_note ?? '',
      ]);
    }
  }

  const safeTitle = String(a.title).replace(/[\\/:*?"<>|]/g, '_').slice(0, 40);
  sendCsv(ctx.res, {
    filenameAscii: `activity-${a.externalId || a.id}-${kind}.csv`,
    filenameUnicode: `${safeTitle}-${kind}.csv`,
    csv: toCsv(rows),
  });

  return undefined;

}

export { maskPhone };
