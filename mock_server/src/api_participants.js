/**
 * 名单维护与邀请码（《移动端应用开发方案》§4.6、§4.7）。
 *
 * 关键设计：
 *   * **名单由活动发布者维护**，用户端无自助报名（方案 §1.3 范围外）；
 *   * 批量导入**逐行报告结果**，无法匹配的行标为「待确认」而不是丢弃（验收 A8）；
 *   * **软删除**：移出名单**不删除历史签到与考勤记录**，仅标注「已移出（时间）」
 *     （方案 §14.1-7）；
 *   * 邀请码**一次性**、仅显示一次、必须一对一私发（方案 §4.7、§14.1-2）。
 */

import { CHECKIN_STATUS, DEFAULTS, ERR, SIGNUP_STATUS, TASK_STATUS } from './constants.js';
import { fail, requireOwnedActivity } from './api_auth.js';
import {
  activeParticipants,
  addMinutes,
  findParticipant,
  iso,
  newId,
  parseTime,
  store,
} from './store.js';
import { settleOverdueTasks } from './attendance_engine.js';
import { boardCounts, isActiveParticipant, presentParticipant } from './presenters.js';

// ─────────────────────────────────────────────────────────────────────────
// 校验（与服务端字段字典一致）
// ─────────────────────────────────────────────────────────────────────────

const USER_NO_RE = /^[A-Za-z0-9]{4,20}$/;
const PHONE_RE = /^1[3-9]\d{9}$/;
const PHONE_SUFFIX_RE = /^\d{4}$/;

/** 取手机号后四位（支持完整手机号或仅后四位两种输入）。 */
function suffixOf(phone) {
  if (!phone) {
    return null;
  }
  const p = String(phone).trim();
  if (PHONE_SUFFIX_RE.test(p)) {
    return p;
  }
  if (PHONE_RE.test(p)) {
    return p.slice(-4);
  }
  return null;
}

/** 解析一行「学号 / 姓名 / 手机号」，兼容 Tab、逗号、中文逗号、分号、多空格。 */
function splitLine(line) {
  return line
    .split(/[\t,，;；|]+|\s{2,}/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

// ─────────────────────────────────────────────────────────────────────────
// 名单查询 / 增删
// ─────────────────────────────────────────────────────────────────────────

export function listParticipants(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  const activity = owned;
  // 惰性结算超时任务，保证名单上的在岗统计是当前值。
  settleOverdueTasks(activity);

  const { filter } = ctx.query;
  let items = store.db.participants.filter((p) => p.activityId === activity.id);

  if (filter === 'active') {
    items = items.filter(isActiveParticipant);
  } else if (filter === 'removed') {
    items = items.filter((p) => !isActiveParticipant(p));
  } else if (filter === 'pending_confirm') {
    items = items.filter((p) => p.signupStatus === SIGNUP_STATUS.PENDING_CONFIRM);
  } else if (filter === 'not_checked_in') {
    // 「一键筛出未签到者」需要它（方案 §4.8），且必须排除已移出的人。
    items = items.filter((p) => {
      if (!isActiveParticipant(p)) {
        return false;
      }
      const has = store.db.checkins.some(
        (c) =>
          c.activityId === activity.id &&
          c.userNo === p.userNo &&
          (c.status === CHECKIN_STATUS.SUCCESS || c.status === CHECKIN_STATUS.PENDING_REVIEW),
      );
      return !has;
    });
  } else if (filter === 'pending_review') {
    items = items.filter((p) =>
      store.db.checkins.some(
        (c) =>
          c.activityId === activity.id &&
          c.userNo === p.userNo &&
          c.status === CHECKIN_STATUS.PENDING_REVIEW,
      ),
    );
  } else if (filter === 'not_bound') {
    // 尚未绑定设备的名单条目：发布者据此判断谁的邀请码还没发出去/还没用。
    items = items.filter((p) => !p.boundDeviceId);
  }

  store.save();
  return {
    items: items.map((p) => presentParticipant(activity.id, p)),
    total: items.length,
    counts: boardCounts(activity.id),
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 单个添加
// ─────────────────────────────────────────────────────────────────────────

/** 单个添加。 */
export function addParticipant(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  const activity = owned;
  const { userNo, name, phone } = ctx.body ?? {};

  const errors = [];
  if (!userNo || !USER_NO_RE.test(String(userNo).trim())) {
    errors.push({ field: 'userNo', message: '学号格式不正确（4–20 位字母或数字）' });
  }
  if (!name || String(name).trim().length === 0) {
    errors.push({ field: 'name', message: '请填写姓名' });
  }
  if (phone && !PHONE_RE.test(String(phone).trim())) {
    errors.push({ field: 'phone', message: '手机号应为 11 位' });
  }
  if (errors.length > 0) {
    return fail('BAD_REQUEST', '名单信息校验未通过', errors);
  }

  const existing = findParticipant(activity.id, String(userNo).trim());
  if (existing && existing.signupStatus !== SIGNUP_STATUS.CANCELLED && !existing.removedAt) {
    return fail('PARTICIPANT_DUPLICATED');
  }

  const quota = activity.quota;
  if (quota != null && activeParticipants(activity.id).length >= quota) {
    return fail('QUOTA_EXCEEDED');
  }

  if (existing) {
    /*
      已移出的人重新加入：复用原记录，清掉移出标记（历史签到与考勤保留）。

      ⚠️ `phoneSuffix` **必须跟着 phone 一起更新**。

      真机测试抓到的 bug：这里原先只写 `existing.phone = ...`，
      漏了 `existing.phoneSuffix`。后果是"移出再加回来"的人
      phoneSuffix 停留在旧值（或空），而绑定接口的二次校验
      比的正是 phoneSuffix —— 于是**用正确的手机号后四位也永远不匹配**。

      更糟的是错误提示是"姓名或手机号后四位不匹配"，
      把志愿者和发布者引向错误方向（反复核对姓名与号码），
      而真实原因是服务端字段没同步。

      顺带修一个历史数据分支：早期受此 bug 影响的记录可能
      只有 phone 没有 phoneSuffix，这里补上。
    */
    existing.signupStatus = SIGNUP_STATUS.SIGNED;
    existing.removedAt = null;
    existing.removedBy = null;
    existing.name = String(name).trim();
    if (phone) {
      existing.phone = String(phone).trim();
      existing.phoneSuffix = suffixOf(phone);
    } else if (!existing.phoneSuffix && existing.phone) {
      existing.phoneSuffix = suffixOf(existing.phone);
    }
  } else {
    store.db.participants.push({
      activityId: activity.id,
      userNo: String(userNo).trim(),
      name: String(name).trim(),
      phone: phone ? String(phone).trim() : null,
      phoneSuffix: suffixOf(phone),
      signupStatus: SIGNUP_STATUS.SIGNED,
      addedAt: iso(new Date()),
      addedBy: ctx.auth.ownerId,
      removedAt: null,
      removedBy: null,
      boundDeviceId: null,
      inviteCodeUsedAt: null,
      grantExpiresAt: null,
    });
  }

  activity.enrolled = activeParticipants(activity.id).length;
  store.save();
  return {
    item: presentParticipant(activity.id, findParticipant(activity.id, String(userNo).trim())),
    enrolled: activity.enrolled,
  };
}

/**
 * 批量导入（§4.6、验收 A8）。
 *
 * 支持三种入参：
 *   * `{ text: "学号\t姓名\n..." }` —— 批量粘贴 / Excel 两列粘贴；
 *   * `{ rows: [[userNo, name, phone?], ...] }` —— 已解析的二维数组；
 *   * `{ csv: "..." }` —— CSV 文本（与 text 同解析路径）。
 *
 * 返回**逐行报告**：合法行入库，错误行逐条给出原因。
 */
export function importParticipants(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  const activity = owned;
  const body = ctx.body ?? {};

  /** @type {Array<{row:number, cells:string[]}>} */
  const incoming = [];

  if (Array.isArray(body.rows)) {
    body.rows.forEach((r, i) => {
      const cells = Array.isArray(r) ? r.map((c) => String(c ?? '').trim()) : [];
      incoming.push({ row: i + 1, cells: cells.filter((c) => c.length > 0) });
    });
  } else {
    const text = String(body.text ?? body.csv ?? '');
    const lines = text.split(/\r\n|\r|\n/);
    let headerSeen = false;

    lines.forEach((line, i) => {
      const cells = splitLine(line);

      // 真正的空行：整行只有空白，或只由一个制表符/分隔符构成
      // （Excel 复制一列空单元格时会带出来）。直接跳过，不算数据行。
      if (cells.length === 0) {
        return;
      }

      if (!headerSeen) {
        const joined = cells.join('');
        if (joined.includes('学号') || joined.includes('姓名') || joined.includes('手机')) {
          headerSeen = true;
          return; // 跳过表头，后续行号仍按原文件计
        }
        // 表头之前出现的单列内容，当成粘贴时带进来的说明行/标题行跳过，
        // 例如「2024 级志愿者名单」。
        // ⚠️ 只在**表头之前**做这个宽容处理：表头之后的单列行是**缺列的数据行**，
        // 必须走下去报「缺少姓名」，否则用户会以为全都导进去了。
        if (cells.length < 2) {
          return;
        }
      }

      incoming.push({ row: i + 1, cells });
    });
  }

  if (incoming.length === 0) {
    return fail('BAD_REQUEST', '未解析到任何数据行，请检查粘贴内容');
  }

  const existingUserNos = new Set(
    store.db.participants
      .filter((p) => p.activityId === activity.id && p.signupStatus !== SIGNUP_STATUS.CANCELLED && !p.removedAt)
      .map((p) => p.userNo),
  );

  const results = [];
  let accepted = 0;
  let rejected = 0;
  let pendingConfirm = 0;

  for (const { row, cells } of incoming) {
    if (cells.length === 0) {
      results.push({ row, accepted: false, reason: '整行为空' });
      rejected += 1;
      continue;
    }
    // 注意：只有 1 列时**不报「列数不足」**，而是继续走到「缺少姓名」，
    // 因为 `1003<Tab>` 这种「学号填了、姓名空着」的输入比「这一行格式全错」
    // 更常见，用户需要的提示是"补姓名"而不是"重新分列"。
    if (cells.length > 3) {
      results.push({
        row,
        accepted: false,
        reason: '最多接受「学号 / 姓名 / 手机号」三列，请检查是否有多余分隔符',
      });
      rejected += 1;
      continue;
    }

    const userNo = cells[0];
    const name = cells.length >= 2 ? cells[1] : '';
    const phone = cells.length >= 3 ? cells[2] : '';

    if (!USER_NO_RE.test(userNo)) {
      results.push({
        row,
        accepted: false,
        userNo,
        name,
        reason: '学号格式不正确（应为 4–20 位字母或数字）',
      });
      rejected += 1;
      continue;
    }
    if (!name) {
      results.push({ row, accepted: false, userNo, reason: '缺少姓名' });
      rejected += 1;
      continue;
    }
    if (phone && !PHONE_RE.test(phone) && !PHONE_SUFFIX_RE.test(phone)) {
      results.push({
        row,
        accepted: false,
        userNo,
        name,
        reason: '手机号应为 11 位，或仅填后四位',
      });
      rejected += 1;
      continue;
    }

    // 配额检查。
    const quota = activity.quota;
    if (quota != null && activeParticipants(activity.id).length >= quota) {
      results.push({ row, accepted: false, userNo, name, reason: '活动名额已满' });
      rejected += 1;
      continue;
    }

    // ── 二次校验与重复判定（§14.1-2「二次校验（必做）」+ §4.6「活动内重复」）──
    //
    // 「重复」的定义是这个接口的核心语义，必须精确：
    //
    //   * **这行不带来任何新信息** → 重复。判据：姓名与库里一致，且要么没带手机号，
    //     要么所带手机号后四位与库里一致。重导一遍同一份 Excel 就属于这类，
    //     必须报「已存在该学号」，不能悄悄让它过。
    //   * **带了新信息且能对上**（库里没有手机号后四位，这次补上了）→ 更新。
    //   * **信息冲突**（姓名或后四位与库里对不上）→ 标「待确认」，交由发布者判断。
    //
    // ⚠️ 关键约束：**不能用本次粘贴的手机号去覆盖库里已存的后四位再比对**，
    // 那是拿用户自己填的值和自己比，永远相等 —— 等于没有二次校验。
    const existing = findParticipant(activity.id, userNo);
    let status = SIGNUP_STATUS.SIGNED;
    let crossCheckNote = null;
    let dedup = false;

    if (existing) {
      const nameMatches = existing.name === name;
      const suffix = suffixOf(phone);
      const suffixMatches =
        Boolean(suffix) && Boolean(existing.phoneSuffix) && suffix === existing.phoneSuffix;
      const suffixConflicts =
        Boolean(suffix) && Boolean(existing.phoneSuffix) && suffix !== existing.phoneSuffix;

      if (nameMatches && !suffixConflicts) {
        // 姓名一致且手机号不冲突。
        if (!phone || suffixMatches) {
          // 一点新信息都没有 → 重复导入。
          dedup = true;
        } else {
          // 姓名一致、库里原先没有后四位、这次补上了 → 视为补充信息。
          status = SIGNUP_STATUS.SIGNED;
        }
      } else if (!nameMatches && suffixMatches) {
        // 姓名不同但手机号后四位一致 → 同一人改了名字或录入时写错，放行更新。
        status = SIGNUP_STATUS.SIGNED;
      } else {
        // 存在冲突（姓名不一致且手机号也对不上，或后四位直接冲突）→ 待确认。
        status = SIGNUP_STATUS.PENDING_CONFIRM;
        crossCheckNote = '姓名或手机号后四位与既有记录不一致，请核对';
      }
    }

    if (dedup) {
      results.push({ row, accepted: false, userNo, name, reason: '名单中已存在该学号' });
      rejected += 1;
      continue;
    }

    if (existing) {
      if (status === SIGNUP_STATUS.PENDING_CONFIRM) {
        // 冲突行**一个字段都不写**。
        //
        // 理由：这一行的姓名与手机号已经与库里对不上，任何一个值都可能是错的。
        // 如果照写，就等于「用户的错数据静默覆盖了发布者手里的对数据」，
        // 而发布者还以为自己只是"标了个待确认"。保留原值，等他核对完再改。
        existing.signupStatus = SIGNUP_STATUS.PENDING_CONFIRM;
      } else {
        existing.signupStatus = status;
        existing.name = name;
        existing.phone = phone && PHONE_RE.test(phone) ? phone : existing.phone;
        existing.phoneSuffix = suffixOf(phone) ?? existing.phoneSuffix;
        existing.removedAt = null;
        existing.removedBy = null;
      }
    } else {
      store.db.participants.push({
        activityId: activity.id,
        userNo,
        name,
        phone: phone && PHONE_RE.test(phone) ? phone : null,
        phoneSuffix: suffixOf(phone),
        signupStatus: status,
        addedAt: iso(new Date()),
        addedBy: ctx.auth.ownerId,
        removedAt: null,
        removedBy: null,
        boundDeviceId: null,
        inviteCodeUsedAt: null,
        grantExpiresAt: null,
      });
    }

    existingUserNos.add(userNo);
    accepted += 1;
    if (status === SIGNUP_STATUS.PENDING_CONFIRM) {
      pendingConfirm += 1;
    }
    results.push({
      row,
      accepted: true,
      userNo,
      name,
      status,
      reason: crossCheckNote,
    });
  }

  activity.enrolled = activeParticipants(activity.id).length;
  store.save();

  return {
    total: incoming.length,
    accepted,
    rejected,
    pendingConfirm,
    rows: results,
    enrolled: activity.enrolled,
  };
}

/**
 * 移出名单 —— **软删除**（§4.6、§14.1-7）。
 *
 * 关键行为：**不删除历史签到与考勤记录**，仅在名单与记录上标注
 * 「已移出（时间）」。这些记录仍随「活动终态 + 7 天」的留存期一并清理。
 */
export function removeParticipant(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  const activity = owned;
  // ⚠️ 路径参数名是 `pid`（网页方案 §6.4.3），不是 `userNo`。
  //
  // 契约里 `pid` 是 participant 的主键；本 Mock 以 userNo 作为活动内唯一键
  //（方案 §4.3 明确「userNo 活动内唯一」），因此 `pid` 实际收到的是学号。
  //
  // 保留 `userNo` 作为兜底：路由改名时若漏改这里，取到 `undefined` 会让
  // 「移出名单」在**看起来一切正常**的情况下永远失败并报"名单中不存在该学号"，
  // 极难排查（实测踩到过）。
  const userNo = ctx.params.pid ?? ctx.params.userNo;
  if (userNo == null || userNo === '') {
    return fail('BAD_REQUEST', '缺少要移出的学号/工号', [
      { field: 'pid', message: '缺少要移出的学号/工号' },
    ]);
  }
  const p = findParticipant(activity.id, userNo);
  if (!p) {
    return fail('NOT_IN_PARTICIPANT_LIST', '名单中不存在该学号');
  }
  if (p.signupStatus === SIGNUP_STATUS.CANCELLED || p.removedAt) {
    return { item: presentParticipant(activity.id, p), alreadyRemoved: true };
  }

  const now = new Date();
  p.signupStatus = SIGNUP_STATUS.CANCELLED;
  p.removedAt = iso(now);
  p.removedBy = ctx.auth.ownerId;
  activity.enrolled = activeParticipants(activity.id).length;

  // 该人的未发生抽查一并豁免——他已不在名单，不该继续被抽查。
  let excused = 0;
  for (const t of store.db.attendanceTasks) {
    if (t.activityId === activity.id && t.userNo === userNo && t.status === TASK_STATUS.PENDING) {
      t.status = TASK_STATUS.EXCUSED;
      t.excusedAt = iso(now);
      t.excusedReason = '已移出名单';
      excused += 1;
    }
  }

  store.save();
  return {
    item: presentParticipant(activity.id, p),
    excusedTasks: excused,
    historicalRecordsKept: true,
    note: '历史签到与考勤记录已保留并标注「已移出（时间）」，随活动终态 +7 天一并清理',
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 邀请码（§4.7、§14.1-2）
// ─────────────────────────────────────────────────────────────────────────

/** 生成一次性邀请码：8 位大写字母数字，避开易混淆字符。 */
function generateInviteCode() {
  // 去掉 0/O、1/I/L，减少发布者一对一私发时抄错的可能。
  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  let out = '';
  for (let i = 0; i < 8; i++) {
    out += alphabet[Math.floor(Math.random() * alphabet.length)];
  }
  return out;
}

/**
 * 为名单中每人生成**一次性邀请码**（§4.7）。
 *
 * ⚠️ 安全约定：明文**仅在本次响应中返回**，之后接口不再提供（`listInviteCodes`
 * 只返回状态，不返回码值）。这逼迫发布者在一对一私发时当场复制，
 * 避免码值长期停留在一个可被随意读取的地方。
 */
export function issueInviteCodes(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  const activity = owned;
  const targets = ctx.body?.userNos;

  let people = activeParticipants(activity.id);
  if (Array.isArray(targets) && targets.length > 0) {
    const wanted = new Set(targets.map(String));
    people = people.filter((p) => wanted.has(p.userNo));
    if (people.length === 0) {
      return fail('NOT_IN_PARTICIPANT_LIST', '指定的学号都不在有效名单中');
    }
  }
  if (people.length === 0) {
    return fail('BAD_REQUEST', '名单为空，请先导入名单');
  }

  // 邀请码随活动存续，但不超过「活动结束 + 留存期」，避免长期有效的凭证。
  const expiresAt = iso(addMinutes(parseTime(activity.endTime), DEFAULTS.RETENTION_DAYS * 24 * 60));

  const issued = [];
  const skipped = [];
  for (const p of people) {
    const existing = store.db.inviteCodes.find(
      (c) => c.activityId === activity.id && c.userNo === p.userNo,
    );
    if (existing) {
      if (existing.usedAt) {
        skipped.push({ userNo: p.userNo, name: p.name, reason: '已绑定使用' });
        continue;
      }
      // 未使用：重新签发（旧码作废），因为明文已无法再次展示。
      existing.code = generateInviteCode();
      existing.issuedAt = iso(new Date());
      existing.expiresAt = expiresAt;
      existing.reissued = (existing.reissued ?? 0) + 1;
      issued.push({ userNo: p.userNo, name: p.name, inviteCode: existing.code, expiresAt });
      continue;
    }
    const record = {
      activityId: activity.id,
      userNo: p.userNo,
      name: p.name,
      code: generateInviteCode(),
      issuedAt: iso(new Date()),
      expiresAt,
      usedAt: null,
      issuedBy: ctx.auth.ownerId,
    };
    store.db.inviteCodes.push(record);
    issued.push({ userNo: p.userNo, name: p.name, inviteCode: record.code, expiresAt });
  }

  store.save();
  return {
    items: issued,
    skipped,
    // 提醒文案直接进数据，UI 不必记这条规则（README §3.2/§3.3）。
    warning: '邀请码为一次性凭证，请一对一私发，不要公开张贴或群发。',
    displayOnce: true,
  };
}

/** 邀请码状态查询：**不返回明文**。 */
export function listInviteCodes(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  const items = store.db.inviteCodes
    .filter((c) => c.activityId === ctx.params.id)
    .map((c) => ({
      userNo: c.userNo,
      name: c.name,
      usedAt: c.usedAt,
      expiresAt: c.expiresAt,
      reissued: c.reissued ?? 0,
      // 明文不可再次获取：这是「仅显示一次」的实现方式。
      masked: `${c.code.slice(0, 2)}****${c.code.slice(-2)}`,
    }));
  return { items, total: items.length };
}

/** 看板（§4.8）。 */
export function activityBoard(ctx) {
  const owned = requireOwnedActivity(ctx, ctx.params.id);
  if (owned.__error) {
    return owned;
  }
  const activity = owned;
  settleOverdueTasks(activity);
  store.save();

  const counts = boardCounts(activity.id);
  const includeParticipants = ctx.query.includeParticipants === 'true';

  return {
    activityId: activity.id,
    ...counts,
    dataDestroyAt: activity.terminalAt
      ? iso(addMinutes(parseTime(activity.terminalAt), DEFAULTS.RETENTION_DAYS * 24 * 60))
      : null,
    disclaimer: '考勤结果仅作现场管理参考，不作为志愿时长认定依据，不自动产生任何扣减。',
    participants: includeParticipants
      ? store.db.participants
          .filter((p) => p.activityId === activity.id)
          .map((p) => presentParticipant(activity.id, p))
      : [],
  };
}
