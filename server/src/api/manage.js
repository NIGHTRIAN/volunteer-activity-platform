/**
 * 管理端写入接口：活动上报、状态流转、名单维护、发码。
 *
 * ## 为什么这些接口必须校验"归属"
 *
 * 每个写接口都先 `assertActivityOwnership`。少写一处的后果不是报错，
 * 而是**静默地改到了别人的数据** —— 这类问题在验收时几乎发现不了，
 * 只有等到"两个发布者互相覆盖"才会暴露，而那时数据已经脏了。
 *
 * ## 为什么所有响应都要与 App 的模型对齐
 *
 * App 用 `Activity.fromJson` / `Participant.fromJson` / `ImportReport.fromJson`
 * 直接解析 `data`。字段名差一个，解析就得到一堆空值，而界面
 * **不会报错**（`jsonStringOr(..., '')` 有默认值）—— 表现为"发布成功了但列表是空的"。
 */

import {
  ACTIVITY_STATUS,
  ATTENDANCE_MODE,
  STATUS_TRANSITIONS,
  TERMINAL_STATUSES,
  DEFAULTS,
  PAGING,
} from '../contract.js';
import { ApiError } from '../http/envelope.js';
import { makeActivity, rowToActivity } from '../stores/activity.js';
import { assertActivityOwnership, requireAdmin } from './auth.js';
import { parseTime, toIso, nowIso } from '../util/time.js';
import { newInviteCode } from '../util/tokens.js';

// ─────────────────────────────────────────────────────────────────────────
// 小工具
// ─────────────────────────────────────────────────────────────────────────

/** 必填字符串。 */
function reqStr(value, field, label, maxLen = 0) {
  const v = typeof value === 'string' ? value.trim() : '';
  if (!v) {
    throw new ApiError('BAD_REQUEST', `${label}不能为空`, [
      { field, message: `${label}不能为空` },
    ]);
  }
  if (maxLen && v.length > maxLen) {
    throw new ApiError('BAD_REQUEST', `${label}不能超过 ${maxLen} 字`, [
      { field, message: `不能超过 ${maxLen} 字` },
    ]);
  }
  return v;
}

/**
 * 可选字符串字段：缺省 / 非字符串 → 空串；超长 → 报错。
 *
 * 学院、手机号这类字段是**选填**的，不能像必填项那样直接抛错；
 * 但也不能无限长（会把界面撑坏、把导出文件撑大）。
 */
function optionalStr(value, label, maxLen = 0) {
  if (typeof value !== 'string') {
    return '';
  }
  const s = value.trim();
  if (maxLen > 0 && s.length > maxLen) {
    throw new ApiError('BAD_REQUEST', `${label}不能超过 ${maxLen} 个字符`);
  }
  return s;
}

/** 可选数字（带范围）。`null`/`undefined`/空串 → null。 */
function optNum(value, field, label, { min = -Infinity, max = Infinity } = {}) {
  if (value === null || value === undefined || value === '') {
    return null;
  }
  const n = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(n)) {
    throw new ApiError('BAD_REQUEST', `${label}不是有效数字`, [
      { field, message: '不是有效数字' },
    ]);
  }
  if (n < min || n > max) {
    throw new ApiError('BAD_REQUEST', `${label}超出范围（${min}–${max}）`, [
      { field, message: `超出范围（${min}–${max}）` },
    ]);
  }
  return n;
}

/**
 * 学号 / 工号的格式。
 *
 * ## 为什么要校验
 *
 * 真机与端到端测试都暴露过：导入 `bad!!` 这种值服务端**照单全收**，
 * 于是名单里躺着一行永远绑不上、也永远签不上的记录。
 * 发布者看到的是"名单有 20 人、签到的只有 19 人"，很难联想到是某一行的学号打错了。
 *
 * 约束取"4–20 位字母或数字"：
 *   * 太短（1–3 位）几乎不可能是真实学号；
 *   * 允许字母是因为工号/留学生学号常含字母；
 *   * 不允许连字符与空格 —— 那是复制粘贴带进来的脏字符，且会导致绑定失败。
 */
const USER_NO_PATTERN = /^[A-Za-z0-9]{2,32}$/;

/** 校验学号格式，返回错误文案或 null。 */
function userNoProblem(userNo) {
  if (!USER_NO_PATTERN.test(userNo)) {
    return '学号应为 2–32 位字母或数字（不能有空格、连字符或特殊符号）';
  }
  return null;
}

/** 手机号掩码（方案 §12.1：导出默认脱敏，列表也一律不下发完整号码）。 */
function maskPhone(phone) {
  if (typeof phone !== 'string' || phone.length !== 11) {
    return null;
  }
  return `${phone.slice(0, 3)}****${phone.slice(7)}`;
}

/** 取手机号后四位（二次校验用）。 */
function phoneSuffix(phone) {
  if (typeof phone !== 'string') {
    return null;
  }
  const digits = phone.replace(/\D/g, '');
  return digits.length >= 4 ? digits.slice(-4) : null;
}

/** 名单行 → 与 `Participant.fromJson` 对齐的报文。 */
function participantToWire(row) {
  return {
    userNo: row.user_no,
    name: row.name ?? '',
    ...(row.college ? { college: row.college } : {}),
    ...(row.phone ? { phone: maskPhone(row.phone) } : {}),
    signupStatus: row.signup_status === 'registered' ? 'signed' : row.signup_status,
    checkinStatus: row.checkin_status ?? 'none',
    ...(row.removed_at ? { removedAt: row.removed_at } : {}),
    inviteCodeIssued: Boolean(row.invite_code_used_at),
    ...(row.grant_expires_at ? { grantExpiresAt: row.grant_expires_at } : {}),
    attendanceDone: Number(row.attendance_done ?? 0),
    attendanceMissed: Number(row.attendance_missed ?? 0),
    attendanceExcused: Number(row.attendance_excused ?? 0),
  };
}

/** 活动表行 → 与 `Activity.fromJson` 对齐的报文（复用仓储的映射）。 */
function activityToWire(activity) {
  return activity;
}

// ─────────────────────────────────────────────────────────────────────────
// 活动上报
// ─────────────────────────────────────────────────────────────────────────

/**
 * `POST /activities:upsert` —— 批量上报活动。
 *
 * 契约是**部分成功**语义：能收的收，不能收的逐行给出字段级原因。
 * 不做"一行错就整批回滚"：App 上传的是一屏录入的结果，
 * 全回滚会让用户重填 20 条，而其中 19 条本来是对的。
 */
export async function upsertActivities(ctx) {
  const auth = requireAdmin(ctx);
  const batch = Array.isArray(ctx.body?.batch) ? ctx.body.batch : null;
  if (!batch || batch.length === 0) {
    throw new ApiError('BAD_REQUEST', '缺少 batch');
  }

  const created = [];
  const updated = [];
  const rejected = [];

  for (let i = 0; i < batch.length; i += 1) {
    try {
      const raw = batch[i] ?? {};
      const externalId = reqStr(raw.externalId, 'externalId', '外部编号', 64);
      const title = reqStr(raw.title, 'title', '活动名称', 60);
      const organizer = reqStr(raw.organizer, 'organizer', '发布方', 50);

      const startTime = parseTime(raw.startTime);
      if (!startTime) {
        throw new ApiError('BAD_REQUEST', '开始时间格式无效', [
          { field: 'startTime', message: '格式无效' },
        ]);
      }
      const endTime = parseTime(raw.endTime) ?? startTime;
      if (endTime.getTime() <= startTime.getTime()) {
        throw new ApiError('BAD_REQUEST', '结束时间必须晚于开始时间', [
          { field: 'endTime', message: '必须晚于开始时间' },
        ]);
      }

      const geoLat = optNum(raw.geoLat, 'geoLat', '纬度', { min: -90, max: 90 });
      const geoLng = optNum(raw.geoLng, 'geoLng', '经度', { min: -180, max: 180 });
      if (geoLat === null || geoLng === null) {
        /*
          坐标必填。

          没有坐标的活动，志愿者能看到却**永远签不上**（围栏判定必然失败），
          比看不到更糟 —— 用户会以为定位功能坏了。
        */
        throw new ApiError('BAD_REQUEST', '请在地图上选择活动位置', [
          { field: geoLat === null ? 'geoLat' : 'geoLng', message: '坐标必填' },
        ]);
      }

      const locationType = raw.locationType === 'indoor' ? 'indoor' : 'outdoor';
      const radius =
        optNum(raw.checkinRadius, 'checkinRadius', '签到半径', {
          min: DEFAULTS.checkinRadiusMin,
          max: DEFAULTS.checkinRadiusMax,
        }) ??
        (locationType === 'indoor'
          ? DEFAULTS.checkinRadiusIndoor
          : DEFAULTS.checkinRadiusOutdoor);

      const status = raw.status === 'draft' ? ACTIVITY_STATUS.DRAFT : ACTIVITY_STATUS.PUBLISHED;

      const existing = await ctx.repos.activities.findByExternalId(auth.ownerId, externalId);

      /*
        抽查方式：`auto`（按间隔自动生成）或 `manual`（发布者现场手动触发）。

        不传就沿用已有值，新建时用 auto —— 老客户端不传这个字段时行为不变。
      */
      const attendanceModeRaw =
        raw.attendanceMode === undefined || raw.attendanceMode === null
          ? (existing?.attendanceMode ?? DEFAULTS.attendanceMode)
          : String(raw.attendanceMode);
      if (![ATTENDANCE_MODE.AUTO, ATTENDANCE_MODE.MANUAL].includes(attendanceModeRaw)) {
        throw new ApiError('BAD_REQUEST', '抽查方式只能是 auto 或 manual', [
          { field: 'attendanceMode', message: '只能是 auto 或 manual' },
        ]);
      }

      /*
        已发布活动的**关键规则字段不可改**（方案 §4.5 冻结）。
        允许改的只有标题/简介/联系方式这类"说明性"字段。

        这条如果放过去，发布者可以在签到开始后偷偷把半径从 200m 改成 2km，
        那前面所有判定记录就都失去说服力了。
      */
      if (existing && existing.status !== ACTIVITY_STATUS.DRAFT) {
        const frozen = [
          ['startTime', startTime.getTime(), parseTime(existing.startTime)?.getTime()],
          ['endTime', endTime.getTime(), parseTime(existing.endTime)?.getTime()],
          ['geoLat', geoLat, existing.geoLat],
          ['geoLng', geoLng, existing.geoLng],
          ['checkinRadius', radius, existing.checkinRadius],
          ['attendanceMode', attendanceModeRaw, existing.attendanceMode ?? DEFAULTS.attendanceMode],
        ].filter(([, a, b]) => {
          /*
            ⚠️ 这里**不能**一律用 `Number(a) !== Number(b)` 比较。

            `attendanceMode` 是字符串（'auto'/'manual'），`Number('auto')` 是 NaN，
            而 `NaN !== NaN` 恒为 true —— 于是"编辑活动"永远被判成
            "改了冻结字段"，已发布的活动连标题都改不了。
            按类型分别比较才是对的。
          */
          if (typeof a === 'string' || typeof b === 'string') {
            return String(a ?? '') !== String(b ?? '');
          }
          return Number(a) !== Number(b);
        });
        if (frozen.length > 0) {
          throw new ApiError(
            'ACTIVITY_RULE_FROZEN',
            `已发布活动的关键字段不可修改：${frozen.map(([f]) => f).join('、')}`,
            frozen.map(([field]) => ({ field, message: '已冻结' })),
          );
        }
      }

      const seq = await ctx.db.nextSeq();
      const base = { ...existing };
      const candidate = {
        ...makeActivity({
          externalId,
          title,
          organizer,
          durationHours:
            optNum(raw.durationHours, 'durationHours', '时长', { min: 0.5, max: 72 }) ??
            Math.max(0.5, (endTime - startTime) / 3_600_000),
          startTime: toIso(startTime),
          endTime: toIso(endTime),
          status: existing?.status ?? status,
          ownerId: auth.ownerId,
          location: raw.location ?? '',
          locationType,
          geoLat,
          geoLng,
          checkinRadius: radius,
          attendanceMode: attendanceModeRaw,
          quota: optNum(raw.quota, 'quota', '人数上限', { min: 1, max: 100000 }),
          summary: typeof raw.summary === 'string' ? raw.summary.slice(0, 120) : '',
          description: typeof raw.description === 'string' ? raw.description : '',
          contact: typeof raw.contact === 'string' ? raw.contact.slice(0, 50) : null,
          tags: base.tags ?? [],
        }),
        // 保留原有的创建时间与已报名人数
        createdAt: existing?.createdAt ?? toIso(new Date()),
        enrolled: existing?.enrolled ?? 0,
        version: (existing?.version ?? 0) + 1,
        seq,
        updatedAt: toIso(new Date()),
        publishedAt:
          existing?.publishedAt ??
          (status === ACTIVITY_STATUS.PUBLISHED ? toIso(new Date()) : null),
      };

      /*
        网络白名单：只在**显式给出**时才覆盖。

        区分"没传"和"传了空数组"很重要：
        前者是"这次不关心这项"（例如只改标题），后者才是"清空白名单"。
        混为一谈会导致"改个标题就把场地 Wi-Fi 配置抹掉"。
      */
      if (Array.isArray(raw.wifiBssids)) {
        candidate.wifiBssids = raw.wifiBssids.map(String).filter(Boolean);
      } else if (existing?.wifiBssids) {
        candidate.wifiBssids = existing.wifiBssids;
      }
      if (Array.isArray(raw.campusIpPrefixes)) {
        candidate.campusIpPrefixes = raw.campusIpPrefixes.map(String).filter(Boolean);
      } else if (existing?.campusIpPrefixes) {
        candidate.campusIpPrefixes = existing.campusIpPrefixes;
      }

      if (existing) {
        await ctx.repos.activities.update(existing.id, candidate);
        updated.push(existing.id);
      } else {
        const id = await ctx.repos.activities.create(candidate);
        created.push(String(id));
      }
    } catch (e) {
      if (e instanceof ApiError) {
        rejected.push({ index: i, errors: e.errors.length > 0 ? e.errors : [{ field: '', message: e.message }] });
      } else {
        throw e;
      }
    }
  }

  return {
    accepted: created.length + updated.length,
    created,
    updated,
    rejected,
    note: rejected.length === 0 ? '全部受理' : `部分行被拒绝（${rejected.length} 行）`,
  };
}

/**
 * `POST /activities/{id}:transition` —— 状态流转。
 *
 * 只允许契约里的流转（`STATUS_TRANSITIONS`）。任意跳转会破坏
 * 后续所有判定依赖的前置条件（例如没开始就结束，抽查任务无从生成）。
 */
export async function transitionActivity(ctx) {
  const raw = await ctx.repos.activities.findById(ctx.params.id);
  const activity = await assertActivityOwnership(ctx, raw);

  const to = reqStr(ctx.body?.to, 'to', '目标状态');
  const from = activity.status;

  /*
    ## 乐观锁：客户端带上它认知里的状态（`from`）

    App 的流转请求里一直有 `from`（`activity.status.wire`），但服务端早期
    **完全忽略**了它 —— 于是"拿着过期认知硬写"畅通无阻：
    发布者 A 打开页面看到「已发布」，此时 B 已把它变成「进行中」，
    A 再点「取消」仍然会成功，而且服务端是按**自己的**当前状态校验的，
    A 以为自己取消的是"未开始的活动"。

    带上 `from` 后：与当前状态不符就返回 40901，让客户端刷新后再决定。

    `from` 缺省时**不强制** —— 命令行/脚本调用可以不带；
    但 App 会一直带，所以真实用户路径上是受保护的。
  */
  const claimedFrom = typeof ctx.body?.from === 'string' ? ctx.body.from.trim() : '';
  if (claimedFrom && claimedFrom !== from) {
    throw new ApiError(
      'VERSION_CONFLICT',
      `活动状态已变化（当前为「${from}」），请刷新后重试`,
    );
  }

  const allowed = STATUS_TRANSITIONS[from] ?? [];
  if (!allowed.includes(to)) {
    throw new ApiError(
      'ACTIVITY_STATE_INVALID',
      `不能从「${from}」直接变为「${to}」`,
    );
  }

  let cancelReason = '';
  if (to === ACTIVITY_STATUS.CANCELLED) {
    /*
      ⚠️ 字段名是 **`reason`**，不是 `cancelReason`。

      App 发的是 `{'from':…, 'to':'cancelled', 'reason': …}`
      （见 `activity_page.dart` 的 `_transition`）。服务端原来只读
      `cancelReason`，于是不管用户填了什么都是空串 →
      永远返回"取消原因至少 5 个字" → **取消活动在 App 上完全不可用**。

      保留 `cancelReason` 作为兼容别名，避免老脚本失效。
    */
    const rawReason = ctx.body?.reason ?? ctx.body?.cancelReason;
    cancelReason = typeof rawReason === 'string' ? rawReason.trim() : '';
    // 契约：取消原因至少 5 个字（要给志愿者一个说得过去的交代）。
    if (cancelReason.length < 5) {
      throw new ApiError('CANCEL_REASON_TOO_SHORT', null, [
        { field: 'reason', message: '取消原因至少 5 个字' },
      ]);
    }
  }

  const now = toIso(new Date());
  const patch = {
    ...activity,
    status: to,
    version: (activity.version ?? 1) + 1,
    updatedAt: now,
    seq: await ctx.db.nextSeq(),
  };
  if (to === ACTIVITY_STATUS.ONGOING) {
    patch.startedAt = now;
  }
  if (to === ACTIVITY_STATUS.FINISHED) {
    patch.finishedAt = now;
    patch.terminalAt = now;
  }
  if (to === ACTIVITY_STATUS.CANCELLED) {
    patch.cancelledAt = now;
    patch.terminalAt = now;
    patch.cancelReason = cancelReason;
  }
  if (to === ACTIVITY_STATUS.PUBLISHED) {
    patch.publishedAt = now;
  }

  await ctx.repos.activities.update(activity.id, patch);

  /*
    ## 终态时把「待响应」的抽查置为**已豁免**

    真机报障：活动取消后，用户端还在显示在岗抽查、还在催确认。
    记录里这些任务一直是 `pending`，过了截止时间还会被结算成 `missed`
    （超时/缺席）—— 活动都取消了，人根本没法去确认，却要背一次缺席。

    `excused` 这个状态早就在表结构和统计里了，但**从来没有任何地方写入过**。
    现在补上：取消 → 未发生的抽查一律豁免；结束 → 还没响应的也豁免
    （活动已结束，再催没有意义，也不该记成缺席）。
  */
  if (
    to === ACTIVITY_STATUS.CANCELLED ||
    to === ACTIVITY_STATUS.FINISHED
  ) {
    try {
      await ctx.db.execute(
        `UPDATE attendance_task
            SET status = ?, excused_at = ?, excused_reason = ?
          WHERE activity_id = ? AND status = ?`,
        [
          'excused',
          now,
          to === ACTIVITY_STATUS.CANCELLED ? '活动已取消，本次抽查不再需要' : '活动已结束，未响应的抽查不计',
          String(activity.id),
          'pending',
        ],
      );
    } catch (e) {
      // 豁免失败不能让状态流转失败：否则活动取消不了，问题更大。
      ctx.logger?.warn?.('豁免待响应抽查失败', e);
    }
  }

  /*
    发布即冻结规则快照（方案 §5.2）。

    存在的意义是**保护管理者**：判定依据不被事后改写，争议时有据可依。
    写成"尽力而为"：快照失败不应让发布本身失败，但要留日志 ——
    否则发布者会看到"发布失败"，而活动其实已经发布了。
  */
  if (to === ACTIVITY_STATUS.PUBLISHED) {
    try {
      await ctx.db.execute(
        `INSERT INTO rule_snapshot (activity_id, revision, payload, reason, changed_by, created_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [
          String(activity.id),
          patch.version,
          JSON.stringify({
            startTime: patch.startTime,
            endTime: patch.endTime,
            geoLat: patch.geoLat,
            geoLng: patch.geoLng,
            checkinRadius: patch.checkinRadius,
            checkinWindowBefore: patch.checkinWindowBefore,
            checkinWindowAfter: patch.checkinWindowAfter,
            wifiBssids: patch.wifiBssids ?? [],
            campusIpPrefixes: patch.campusIpPrefixes ?? [],
          }),
          '发布冻结',
          ctx.auth.ownerId,
          now,
        ],
      );
    } catch (e) {
      ctx.logger?.warn?.('写入规则快照失败（发布已生效）', { error: e.message });
    }
  }

  const latest = await ctx.repos.activities.findById(activity.id);
  const response = { activity: activityToWire(latest), from, to };

  /*
    终态要顺带告知两件事（方案 §14.1-6 / 验收 A6）：

      * 结束：业务数据在留存期（7 天）后**销毁且不可恢复**，
        必须当场提示去导出 —— 事后才说，数据可能已经没了；
      * 取消：**不可撤销**，并回显原因。

    客户端不一定要展示，但契约里有；更重要的是
    "不可恢复"这句话必须由服务端给出，不能靠前端自己编天数。
  */
  if (to === ACTIVITY_STATUS.FINISHED) {
    const terminalAt = parseTime(latest.terminalAt) ?? parseTime(now) ?? new Date();
    const destroyAt = new Date(
      terminalAt.getTime() + DEFAULTS.retentionDays * 24 * 3_600_000,
    );
    response.dataDestroyAt = toIso(destroyAt);
    response.reminder =
      `活动已结束。业务数据将在 ${DEFAULTS.retentionDays} 天后` +
      `（${String(response.dataDestroyAt).slice(0, 10)}）自动销毁且不可恢复，` +
      '如需留存请及时导出。';
  }
  if (to === ACTIVITY_STATUS.CANCELLED) {
    response.irreversible = true;
    response.reminder = `活动已取消，不可撤销。原因：${cancelReason}`;
  }

  return response;
}

// ─────────────────────────────────────────────────────────────────────────
// 名单
// ─────────────────────────────────────────────────────────────────────────

/** 名单查询（带签到状态联查）。 */
async function loadParticipants(ctx, activityId) {
  return ctx.db.query(
    `SELECT p.*,
            (SELECT c.status FROM checkin c
              WHERE c.activity_id = p.activity_id AND c.user_no = p.user_no
              ORDER BY c.id DESC LIMIT 1) AS checkin_status
       FROM participant p
      WHERE p.activity_id = ?
      ORDER BY p.id`,
    [activityId],
  );
}

/** `GET /activities/{id}/participants` */
export async function listParticipants(ctx) {
  const raw = await ctx.repos.activities.findById(ctx.params.id);
  const activity = await assertActivityOwnership(ctx, raw);
  const activityId = String(activity.id);

  const rows = await loadParticipants(ctx, activityId);
  const items = rows.map(participantToWire);

  const counts = {
    activityId,
    checkedIn: items.filter((p) => p.checkinStatus === 'success').length,
    pendingReview: items.filter((p) => p.checkinStatus === 'pending_review').length,
    notCheckedIn: items.filter((p) => p.checkinStatus === 'none').length,
    removed: 0,
    attendancePending: 0,
    attendanceDone: 0,
    attendanceMissed: 0,
    attendanceExcused: 0,
    servingNow: 0,
  };

  return { items, total: items.length, counts };
}

/**
 * `POST /activities/{id}/participants` —— 加一个人。
 *
 * 活动内学号唯一（方案 §4.6）。重复加必须报冲突而不是静默重复 ——
 * 重复会让看板出现两个同名行，而发布者会以为"系统算错了人数"。
 */
export async function addParticipant(ctx) {
  const raw = await ctx.repos.activities.findById(ctx.params.id);
  const activity = await assertActivityOwnership(ctx, raw);
  const activityId = String(activity.id);

  const userNo = reqStr(ctx.body?.userNo, 'userNo', '学号', 32);
  const name = reqStr(ctx.body?.name, 'name', '姓名', 64);
  const phone = typeof ctx.body?.phone === 'string' ? ctx.body.phone.trim() : '';
  const college = optionalStr(ctx.body?.college, '学院', 64);

  const userNoError = userNoProblem(userNo);
  if (userNoError) {
    throw new ApiError('BAD_REQUEST', userNoError, [
      { field: 'userNo', message: userNoError },
    ]);
  }

  const dup = await ctx.db.queryOne(
    'SELECT id FROM participant WHERE activity_id = ? AND user_no = ?',
    [activityId, userNo],
  );
  if (dup) {
    throw new ApiError('PARTICIPANT_DUPLICATED', `名单中已存在学号 ${userNo}`);
  }

  const now = nowIso();
  await ctx.db.execute(
    `INSERT INTO participant
       (activity_id, user_no, name, phone, phone_suffix, college, signup_status,
        removed_at, removed_by, grant_expires_at, invite_code_used_at,
        bound_device_id, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, 'registered', NULL, NULL, NULL, NULL, NULL, ?, ?)`,
    [activityId, userNo, name, phone || null, phoneSuffix(phone), college || null, now, now],
  );
  await syncEnrolled(ctx, activityId);

  const row = await ctx.db.queryOne(
    'SELECT *, NULL AS checkin_status FROM participant WHERE activity_id = ? AND user_no = ?',
    [activityId, userNo],
  );
  return { item: participantToWire(row) };
}

/** `DELETE /activities/{id}/participants/{userNo}` —— 移出名单（软删）。 */
export async function removeParticipant(ctx) {
  const raw = await ctx.repos.activities.findById(ctx.params.id);
  const activity = await assertActivityOwnership(ctx, raw);
  const activityId = String(activity.id);
  const userNo = ctx.params.userNo;

  const row = await ctx.db.queryOne(
    'SELECT * FROM participant WHERE activity_id = ? AND user_no = ?',
    [activityId, userNo],
  );
  if (!row) {
    throw new ApiError('NOT_IN_PARTICIPANT_LIST', '名单中没有这个人');
  }

  const now = nowIso();
  /*
    软删除：记录保留并标注移出时间（方案 §12.1-4）。
    不物理删除是因为历史签到/在岗记录还引用着它；
    硬删会让"这个人到底来没来过"永远无法回答。
  */
  await ctx.db.execute(
    `UPDATE participant
        SET signup_status = 'cancelled', removed_at = ?, removed_by = ?, updated_at = ?
      WHERE id = ?`,
    [now, ctx.auth.ownerId, now, row.id],
  );

  // 同时作废该人的活动授权：否则他手机上还能继续签到。
  await ctx.db.execute(
    `UPDATE activity_grant SET revoked_at = ?
      WHERE activity_id = ? AND user_no = ? AND revoked_at IS NULL`,
    [now, activityId, userNo],
  );

  await syncEnrolled(ctx, activityId);

  const updated = await ctx.db.queryOne('SELECT * FROM participant WHERE id = ?', [row.id]);
  return { item: participantToWire({ ...updated, removed_at: now }) };
}

/**
 * 重算并写回 `activity.enrolled`。
 *
 * `enrolled` 是**只读派生值**（schema 注释已注明），由名单维护。
 * 不把它做成接口可写字段，是因为一旦允许外部直接写，
 * 就会出现"显示 20 人、名单 3 人"这种自相矛盾的数据，
 * 而用户只会认为"系统坏了"。
 */
async function syncEnrolled(ctx, activityId) {
  await ctx.db.execute(
    `UPDATE activity
        SET enrolled = (SELECT COUNT(*) FROM participant
                         WHERE activity_id = ? AND removed_at IS NULL)
      WHERE id = ?`,
    [activityId, activityId],
  );
}

/**
 * `POST /activities/{id}/participants:import` —— 批量导入。
 *
 * 每行是 `[学号, 姓名, 手机号?]`。逐行给出结果，
 * 不做整批回滚（现场导入 50 行有 3 行手机号格式不对，
 * 回滚会让发布者重导 47 行正确数据）。
 */
export async function importParticipants(ctx) {
  const raw = await ctx.repos.activities.findById(ctx.params.id);
  const activity = await assertActivityOwnership(ctx, raw);
  const activityId = String(activity.id);

  const rows = Array.isArray(ctx.body?.rows) ? ctx.body.rows : null;
  if (!rows || rows.length === 0) {
    throw new ApiError('BAD_REQUEST', '没有可导入的数据');
  }

  const now = nowIso();
  const results = [];
  let accepted = 0;

  for (let i = 0; i < rows.length; i += 1) {
    const cells = Array.isArray(rows[i]) ? rows[i] : [];
    const userNo = String(cells[0] ?? '').trim();
    const name = String(cells[1] ?? '').trim();
    const phone = String(cells[2] ?? '').trim();
    // 第 4 列是学院（客户端已归一化列序：学号/姓名/手机号/学院）
    const college = String(cells[3] ?? '').trim();

    if (!userNo || !name) {
      results.push({ row: i + 1, accepted: false, reason: '学号或姓名为空' });
      continue;
    }
    const userNoError = userNoProblem(userNo);
    if (userNoError) {
      results.push({ row: i + 1, userNo, name, accepted: false, reason: userNoError });
      continue;
    }
    const dup = await ctx.db.queryOne(
      'SELECT id FROM participant WHERE activity_id = ? AND user_no = ?',
      [activityId, userNo],
    );
    if (dup) {
      results.push({ row: i + 1, userNo, name, accepted: false, reason: '名单中已存在该学号' });
      continue;
    }
    await ctx.db.execute(
      `INSERT INTO participant
         (activity_id, user_no, name, phone, phone_suffix, college, signup_status,
          removed_at, removed_by, grant_expires_at, invite_code_used_at,
          bound_device_id, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, 'registered', NULL, NULL, NULL, NULL, NULL, ?, ?)`,
      [activityId, userNo, name, phone || null, phoneSuffix(phone), college || null, now, now],
    );
    accepted += 1;
    results.push({ row: i + 1, userNo, name, accepted: true });
  }

  await syncEnrolled(ctx, activityId);

  return {
    total: rows.length,
    accepted,
    rejected: rows.length - accepted,
    pendingConfirm: 0,
    rows: results,
  };
}

/**
 * `POST /activities/{id}/invite-codes` —— 生成邀请码。
 *
 * 语义要点：
 *   * 已有**未使用**的码就复用，避免每次点都换一个新码
 *     （发布者刚念给志愿者，再点一下码就变了，现场直接乱套）；
 *   * 已用过的码不展示（那是"已绑定"，重发才是新码）；
 *   * 重发走 UPDATE（`invite_code` 在 (activity, user) 上唯一）。
 */
export async function issueInviteCodes(ctx) {
  const raw = await ctx.repos.activities.findById(ctx.params.id);
  const activity = await assertActivityOwnership(ctx, raw);
  const activityId = String(activity.id);

  const only = Array.isArray(ctx.body?.userNos) ? ctx.body.userNos.map(String) : null;

  const rows = await ctx.db.query(
    `SELECT * FROM participant
      WHERE activity_id = ? AND removed_at IS NULL
      ORDER BY id`,
    [activityId],
  );

  const items = [];
  const skipped = [];

  for (const row of rows) {
    if (only && !only.includes(row.user_no)) {
      continue;
    }
    const unused = await ctx.repos.inviteCodes.findUnusedByUser(activityId, row.user_no);
    if (unused) {
      items.push({
        userNo: row.user_no,
        name: row.name,
        inviteCode: unused.code,
        expiresAt: unused.expiresAt,
      });
      continue;
    }
    const issued = await ctx.repos.inviteCodes.create({
      activityId,
      userNo: row.user_no,
      code: newInviteCode(),
    });
    if (!issued) {
      skipped.push({ userNo: row.user_no, name: row.name, reason: '生成失败' });
      continue;
    }
    items.push({
      userNo: row.user_no,
      name: row.name,
      inviteCode: issued.code,
      expiresAt: issued.expiresAt,
    });
  }

  return {
    items,
    skipped,
    // 一次性展示只对"安全敏感"的场景有意义；邀请码本身就是发给本人的，不需要。
    displayOnce: false,
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 邀请码列表（明文只给一次，这里只给掩码）
// ─────────────────────────────────────────────────────────────────────────

/**
 * 把邀请码打码。
 *
 * 契约（方案 §5.2）：**明文只在签发响应里出现一次**。
 * 之后再查列表只能看掩码 —— 这样"码被路过的人看到"的影响面最小，
 * 而发布者仍能确认"这个人到底发没发过码"。
 *
 * 打码保留首尾各 2 位，便于发布者与手里的记录对号（例如核对是不是同一条）。
 */
function maskInviteCode(code) {
  const s = String(code ?? '');
  if (s.length <= 4) {
    return '****';
  }
  return `${s.slice(0, 2)}****${s.slice(-2)}`;
}

/**
 * `GET /activities/{id}/invite-codes` —— 邀请码列表（掩码）。
 *
 * 原来这个接口只实现了 POST（发码），GET 是 404。
 * 后果：发布者发完码、页面一刷新，就再也查不到"谁发过、谁还没发"，
 * 只能靠名单上的 `inviteCodeIssued` 猜。端到端用例直接把它测出来了。
 */
export async function listInviteCodes(ctx) {
  const raw = await ctx.repos.activities.findById(ctx.params.id);
  const activity = await assertActivityOwnership(ctx, raw);
  const activityId = String(activity.id);

  const rows = await ctx.db.query(
    `SELECT i.*, p.name
       FROM invite_code i
       LEFT JOIN participant p
         ON p.activity_id = i.activity_id AND p.user_no = i.user_no
      WHERE i.activity_id = ?
      ORDER BY i.id`,
    [activityId],
  );

  const items = rows.map((r) => ({
    userNo: r.user_no,
    name: r.name ?? '',
    // ⚠️ **不**下发 inviteCode：明文只在签发那一次出现。
    masked: maskInviteCode(r.code),
    ...(r.expires_at ? { expiresAt: r.expires_at } : {}),
    ...(r.used_at ? { usedAt: r.used_at } : {}),
    reissued: Number(r.reissued ?? 0),
  }));

  return { items, total: items.length };
}

// ─────────────────────────────────────────────────────────────────────────
// 增量同步
// ─────────────────────────────────────────────────────────────────────────

/**
 * `GET /changes` —— 按序号游标增量拉取活动变更（方案 §6.4.9）。
 *
 * ## 为什么用 seq 而不是时间戳
 *
 * 同一毫秒内可能写入多条，时间戳无法给出**全序**；用时间戳做游标会
 * "漏掉"或"重复"边界上的那一条，而客户端无从察觉（只是少了一条活动）。
 * seq 是单调整数，天然不重不漏。
 *
 * 返回：
 *   * 不带 `since` → `fullSnapshot: true` + 全量（客户端首次对齐用）
 *   * 带 `since`   → 只返回 seq 更大的
 *   * `nextCursor` 一定是**字符串**（游标不该被当成数字处理，避免精度问题）
 */
export async function listChanges(ctx) {
  const auth = requireAdmin(ctx);
  const ownerId = auth.ownerId;

  const sinceRaw = ctx.query?.since;
  const since = Number.parseInt(String(sinceRaw ?? ''), 10);
  const fullSnapshot = !Number.isFinite(since) || since < 0;

  const seqRow = await ctx.db.queryOne('SELECT value FROM seq_counter WHERE id = 1');
  const currentSeq = Number(seqRow?.value ?? 0);

  const rows = await ctx.db.query(
    'SELECT * FROM activity WHERE owner_id = ? ORDER BY seq',
    [ownerId],
  );

  const selected = fullSnapshot
    ? rows
    : rows.filter((r) => Number(r.seq ?? 0) > since);

  const maxItemSeq = selected.reduce(
    (max, r) => Math.max(max, Number(r.seq ?? 0)),
    0,
  );
  // 快照时游标取"当前全局序号"，保证之后的增量只含新写入；
  // 增量时若没有新数据就保持原游标（下次查询仍然为空，不会重复吐）。
  const nextCursor = fullSnapshot
    ? String(Math.max(currentSeq, maxItemSeq))
    : String(Math.max(maxItemSeq, since));

  return {
    fullSnapshot,
    items: selected.map((r) => rowToActivity(r)).filter(Boolean),
    nextCursor,
    hasMore: false,
  };
}
// ─────────────────────────────────────────────────────────────────────────
// 手动抽查
// ─────────────────────────────────────────────────────────────────────────

/**
 * `POST /activities/{id}/attendance/manual` —— 发布者现场手动发起一次抽查。
 *
 * ## 为什么需要
 *
 * 自动抽查适合常规活动：开始后 15 分钟第一次、之后每 30 分钟一次。
 * 但很多真实场景不适合：
 *   * 两小时的短活动，自动发 3–4 次，人一直被打断；
 *   * 发布者只想在某个人身上点一次名（"刚才好像走了"）；
 *   * 临时加场、时间没排准，自动时刻表对不上。
 *
 * 所以提供**手动模式**：不自动生成，发布者在看板上点一下才发一条。
 *
 * ## 为什么不让人在终态活动上抽查
 *
 * 活动已结束/取消还发抽查，参与者在现场也响应不了 —— 只会制造
 * 一批"超时未响应"，把本来干净的考勤弄脏。
 */
export async function manualAttendance(ctx) {
  const raw = await ctx.repos.activities.findById(ctx.params.id);
  const activity = await assertActivityOwnership(ctx, raw);
  const activityId = String(activity.id);

  if (TERMINAL_STATUSES.includes(activity.status)) {
    throw new ApiError('BAD_REQUEST', '活动已结束或已取消，不能再发起抽查');
  }

  const windowMinutes = Number(
    activity.attendanceResponseWindow ?? DEFAULTS.attendanceResponseWindowMinutes,
  );
  const now = new Date();
  const deadline = new Date(now.getTime() + windowMinutes * 60_000);

  /*
    抽查对象：
      * 显式传了 `userNos` → 就用这些（发布者点名）；
      * 没传 → 默认"已成功签到、且当前没有待响应任务"的人。
    默认值这样定，是因为"再发一次"只会催同一批人，反而更烦。
  */
  let targets = Array.isArray(ctx.body?.userNos)
    ? ctx.body.userNos.map((v) => String(v).trim()).filter(Boolean)
    : null;

  if (!targets) {
    /*
      口径要与**自动抽查**一致：自动生成发生在"签到受理（成功或待确认）"之后，
      也就是"只要不是被驳回的人都算到场"。这里若只取 success，
      待人工确认的人就永远抽不到 —— 而他们恰恰是最需要现场核实的一批。
    */
    const rows = await ctx.db.query(
      `SELECT DISTINCT user_no FROM checkin
        WHERE activity_id = ? AND status <> ?`,
      [activityId, 'rejected'],
    );
    targets = rows.map((r) => r.user_no);
  }

  if (targets.length === 0) {
    return { created: [], skipped: [], total: 0, message: '还没有已签到的人，无需抽查' };
  }

  const pendingRows = await ctx.db.query(
    `SELECT DISTINCT user_no FROM attendance_task
      WHERE activity_id = ? AND status = ?`,
    [activityId, 'pending'],
  );
  const alreadyPending = new Set(pendingRows.map((r) => r.user_no));

  const maxRow = await ctx.db.queryOne(
    'SELECT COALESCE(MAX(seq), 0) AS mx FROM attendance_task WHERE activity_id = ?',
    [activityId],
  );
  let seq = Number(maxRow?.mx ?? 0) + 1;

  const created = [];
  const skipped = [];
  for (const userNo of targets) {
    if (alreadyPending.has(userNo)) {
      // 已经有一条待响应：再发一条只会让界面出现两条相同抽查。
      skipped.push({ userNo, reason: '已有待响应的抽查' });
      continue;
    }
    await ctx.db.execute(
      `INSERT INTO attendance_task
         (activity_id, user_no, seq, scheduled_at, deadline_at, status)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [activityId, userNo, seq, toIso(now), toIso(deadline), 'pending'],
    );
    created.push({ userNo, seq });
    seq += 1;
  }

  return {
    created,
    skipped,
    total: created.length,
    responseWindowMinutes: windowMinutes,
    deadlineAt: toIso(deadline),
  };
}