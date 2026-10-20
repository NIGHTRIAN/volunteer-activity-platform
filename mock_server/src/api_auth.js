/**
 * 认证与身份。
 *
 * 覆盖：
 *   * 管理端邀请码登录（默认 `1111`，服务端可配置；5 次失败锁 10 分钟；设备指纹绑定）
 *     —— 方案 §4.1、§2、验收用例 A1/A2/A3
 *   * 志愿者最小身份绑定（学号 + 一次性邀请码；姓名/手机号后四位二次校验）
 *     —— 方案 §5.2、§14.1-2、验收用例 A9/A10
 *   * 令牌校验与归属隔离 —— 方案 §2、验收用例 A4
 */

import { ACTIVITY_STATUS, CATALOG, DEFAULTS, ERR, TERMINAL_STATUSES, msgOf } from './constants.js';
import {
  addMinutes,
  auditLogin,
  findAdminByToken,
  findGrantByToken,
  findInviteCode,
  findParticipant,
  findVisibleActivity,
  grantExpiryFor,
  iso,
  newId,
  parseTime,
  store,
} from './store.js';

/// 取某个细分错误的默认文案。
///
/// 实现在 `constants.js`（避免循环依赖）。这里**先 import 再 re-export**：
/// `export { x } from './y'` 只做转发、**不建立本地绑定**，本文件自己调用时会报
/// "msgOf is not defined"。
export { msgOf };


/**
 * 构造一个可被 router 识别的业务错误。
 *
 * @param {string|number} nameOrCode 语义名（推荐，如 `'NOT_IN_PARTICIPANT_LIST'`）
 *   或旧的线码值（兼容用，会退化为该码值的默认文案与 HTTP 状态）
 * @param {string} [message] 覆盖默认文案（例如要带上具体次数、时间等上下文）
 * @param {Array} [errors] 字段级错误
 * @param {number} [httpStatus] 覆盖 HTTP 状态
 */
export function fail(nameOrCode, message = null, errors = [], httpStatus = null) {
  const def = typeof nameOrCode === 'string' ? CATALOG[nameOrCode] : null;

  const code = def ? def.code : nameOrCode;
  const resolvedMessage = message ?? (def ? def.message : null) ?? '未知错误';
  const resolvedHttp = httpStatus ?? (def ? def.http : null) ?? 400;

  return {
    __error: {
      code,
      message: resolvedMessage,
      errors,
      httpStatus: resolvedHttp,
    },
  };
}

/** 管理员邀请码：环境变量优先，其次是方案默认值。 */
export function adminInviteCode() {
  return process.env.ADMIN_INVITE_CODE ?? DEFAULTS.DEFAULT_ADMIN_INVITE_CODE;
}

// ─────────────────────────────────────────────────────────────────────────
// 健康检查与契约自述
// ─────────────────────────────────────────────────────────────────────────

export function health() {
  return {
    status: 'ok',
    service: 'volunteer-mock-server',
    apiVersion: DEFAULTS.API_VERSION,
    activities: store.db.activities.length,
    participants: store.db.participants.length,
    checkins: store.db.checkins.length,
    attendanceTasks: store.db.attendanceTasks.length,
    dataFile: store.filePath,
  };
}

/**
 * 契约自述接口。
 *
 * 让两端 App 的开发者**无需翻文档**就能确认当前 Mock 实现了哪些路径、
 * 判定阈值是什么。这是 A0 阶段减少沟通成本的关键。
 */
export function contractSelfDescription() {
  return {
    apiVersion: DEFAULTS.API_VERSION,
    /** Base URL 含 `/api` 前缀（网页方案 §6.1）。 */
    baseUrl: '/api',
    envelope: {
      // ⚠️ 契约字段是 **`msg`**（网页方案 §6.1）。
      success: '{ code: 0, msg, data, errors: [], traceId, serverTime }',
      failure: '{ code: <非0>, msg, data: null, errors: [ { field, message, row? } ] }',
      note: '为兼容早期客户端，响应里同时下发 message（与 msg 同值）；新代码只应读 msg。',
    },
    headers: {
      request: [
        'Authorization',
        'X-Api-Version',
        'X-Client-Version',
        // 契约名是 X-Idempotency-Key（网页方案 §6.1）。也接受无前缀的
        // Idempotency-Key，便于手工调试。
        'X-Idempotency-Key',
        'X-Device-Id',
      ],
      response: ['X-Api-Version'],
    },
    pagination: {
      request: ['page 从 1 起', 'size 默认 20、上限 100'],
      response: ['items', 'total', 'page', 'size', 'hasMore', 'stats'],
      note: '字段是 size，不是 pageSize；pageSize 仅作兼容输入。',
    },
    errorCodes: {
      note:
        '方案 §6.1 只授权 8 个码值，业务细分共享码值，' +
        '因此**码值反查是不可逆的**：请用族级谓词判断该做什么，精确原因读 msg。',
      authorized: [0, 40001, 40101, 40301, 40401, 40901, 42901, 50001],
      local: { '-1': '离线（仅客户端本地使用）', '-2': '超时', '-99': '未知错误' },
    },
    endpoints: [
      ['GET', '/health', '健康检查'],
      ['GET', '/contract', '本接口：契约自述'],
      ['POST', '/auth/admin/login', '管理端邀请码登录'],
      ['GET', '/auth/admin/me', '管理端身份'],
      ['GET', '/auth/admin/audits', '登录审计（时间/设备/IP）'],
      ['GET', '/auth/admin/export-audits', '敏感导出审计（含完整联系方式的导出）'],
      ['POST', '/auth/bind', '志愿者绑定（学号 + 一次性邀请码）'],
      ['GET', '/auth/me', '志愿者身份'],
      ['GET', '/activities', '活动列表（筛选 + 分页 + 统计）'],
      ['GET', '/activities/:id', '活动详情'],
      ['POST', '/activities:upsert', '批量上报（batch[]，幂等键 externalId，部分失败仍 200）'],
      ['PATCH', '/activities/:id', '非关键字段自由编辑'],
      ['POST', '/activities/:id:transition', '状态流转（{from,to,reason}，from 为乐观锁）'],
      ['GET', '/activities/:id/changes', '规则变更记录'],
      ['GET', '/activities/:id/participants', '名单'],
      ['POST', '/activities/:id/participants', '单个添加'],
      ['POST', '/activities/:id/participants:import', '批量导入（逐行报告）'],
      ['DELETE', '/activities/:id/participants/:pid', '软删除（移出名单，pid 为学号）'],
      ['POST', '/activities/:id/invite-codes', '生成一次性邀请码'],
      ['GET', '/activities/:id/invite-codes', '邀请码状态'],
      ['POST', '/activities/:id/checkins', '提交签到证据（嵌套报文，服务端判定）'],
      ['GET', '/activities/:id/checkins', '签到列表（管理端）'],
      ['GET', '/activities/:id/checkins/mine', '本人签到'],
      ['POST', '/checkins/:checkinId/review', '人工复核'],
      ['POST', '/activities/:id/checkins/manual', '现场点名补录（拒定位时的降级路径）'],
      ['GET', '/activities/:id/attendance/tasks', '在岗任务（前台轮询入口）'],
      ['POST', '/attendances/:taskId:confirm', '确认在岗（零输入；全局资源路径）'],
      ['POST', '/attendances/:taskId:remind', '催办'],
      ['POST', '/activities/:id/attendance/manual', '在岗人工补录'],
      ['GET', '/activities/:id/board', '签到与在岗看板'],
      ['GET', '/activities/:id/attendance', '考勤汇总'],
      ['GET', '/changes', '增量同步（since 游标，7 天幂等窗口）'],
      ['GET', '/activities/:id/export', '导出单活动（直接下载 CSV，带 UTF-8 BOM）'],
      ['GET', '/export/activities', '批量导出活动汇总（时间段 + 状态）'],
      ['GET', '/exports/:exportId/download', '下载任务式导出文件（兼容）'],
      ['POST', '/dev/reset', '重置数据（仅开发）'],
    ],
    // ── 契约里值得客户端特别注意的取舍 ──────────────────────────────
    clientNotes: [
      '签到判定完全在服务端；响应到达前客户端只能显示"提交中"，不得自行判定通过。',
      '在岗确认是 POST /attendances/{taskId}:confirm（全局资源路径），不挂在活动下。',
      '导出是 GET 直接下载，不是"建任务→轮询"。',
      '抽查任务只为**已签到者**生成（决策 D-6），因此必须先签到、后生成任务。',
      '不启用动态签到码（决策 D-2）；拒定位时的降级路径是"管理端现场核实 + 人工补录"。',
      '导出默认脱敏；显式 includeFullContact=true 才出完整号码，且会进敏感审计。',
      'checkin.location.samples 接受数组（我方扩展，用于采样一致性交叉验证）或数量。',
    ],
    scoring: {
      successThreshold: DEFAULTS.SCORE_SUCCESS_THRESHOLD,
      pendingReviewThreshold: DEFAULTS.SCORE_PENDING_REVIEW_THRESHOLD,
      maxUsableAccuracyMeters: DEFAULTS.MAX_USABLE_ACCURACY_M,
      mockLocationForcesManualReview: true,
      note: '模拟定位命中即强制转人工，不自动通过；客户端不做任何判定。',
    },
    attendance: {
      firstDelayMinutes: DEFAULTS.ATTENDANCE_FIRST_DELAY_MIN,
      intervalMinutes: DEFAULTS.ATTENDANCE_INTERVAL_MIN,
      responseWindowMinutes: DEFAULTS.ATTENDANCE_RESPONSE_WINDOW_MIN,
      missGraceMinutes: DEFAULTS.ATTENDANCE_MISS_GRACE_MIN,
      pushEnabled: false,
      note: '不启用推送：由 App 前台轮询拉取；App 不承担任何定时判定。',
    },
    retention: {
      days: DEFAULTS.RETENTION_DAYS,
      note: '活动终态 + 7 天，凭证与业务数据一并销毁，仅保留销毁日志。',
    },
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 鉴权
// ─────────────────────────────────────────────────────────────────────────

/** 取 Bearer 令牌。 */
function bearer(headers) {
  const raw = headers['authorization'];
  if (typeof raw !== 'string') {
    return null;
  }
  const m = /^Bearer\s+(.+)$/i.exec(raw.trim());
  return m ? m[1] : null;
}

/**
 * 鉴权并把结果挂到 `ctx.auth`。
 *
 * @returns 出错时返回可发送的业务错误；通过时返回 `null` 并设置 `ctx.auth`。
 */
export function authenticate(ctx, mode) {
  const token = bearer(ctx.headers);

  /*
    ── `optional` 模式：有令牌就解析，没令牌就当匿名 ──────────────────

    真机测试抓到的越权：`GET /activities` 原先**完全没有 auth 选项**，
    于是 `authenticate` 从不执行、`ctx.auth` 一直是空对象 `{}`。
    结果 `listActivities` 里 `ctx.auth.kind === 'admin'` 恒为 false，
    走的是"非管理员"分支（只排除草稿）——**管理员能看到所有发布者的活动**。

    实测：owner-mvcchx26m0glavl3 的管理员拿到了 6 条属于
    owner-demo-0001 的活动，自己的 0 条。而界面上写的是「**我发布的**活动」。

    这个路由必须同时服务两种调用方：
      * 网页端（Vue）**匿名**浏览公开活动列表 —— 不能强制登录；
      * 管理端 App —— 带令牌，应当只看自己名下的。

    所以需要"可选鉴权"：有令牌就解析到 ctx.auth，让 handler 自己做归属过滤；
    没令牌就保持匿名（公开列表）。
  */
  if (mode === 'optional' && !token) {
    ctx.auth = {};
    return null;
  }

  if (!token) {
    return fail('UNAUTHORIZED');
  }

  const admin = findAdminByToken(token);
  if (admin) {
    // ── 管理端令牌生命周期（方案 §6.3）───────────────────────────────
    // = 名下活动存续期；全部活动进入终态后 24 小时失效。
    const activeCount = store.db.activities.filter(
      (a) => a.ownerId === admin.ownerId && !TERMINAL_STATUSES.includes(a.status),
    ).length;
    if (activeCount === 0) {
      const allTerminalAt = store.db.activities
        .filter((a) => a.ownerId === admin.ownerId)
        .map((a) => parseTime(a.terminalAt))
        .filter(Boolean)
        .sort((x, y) => y - x)[0];
      if (allTerminalAt) {
        const expireAt = addMinutes(allTerminalAt, DEFAULTS.ADMIN_TOKEN_IDLE_EXPIRY_H * 60);
        if (new Date() > expireAt) {
          return fail('ADMIN_TOKEN_EXPIRED');
        }
      }
    }
    ctx.auth = { kind: 'admin', ownerId: admin.ownerId, deviceId: admin.deviceId, token };
    if (mode === 'volunteer') {
      return fail('ROLE_NOT_ALLOWED', '该接口仅限志愿者身份');
    }
    return null;
  }

  const grant = findGrantByToken(token);
  if (grant) {
    // ── 活动级授权到期（网页方案 §4.7：活动终态 + 7 天）─────────────
    const activity = findVisibleActivity(grant.activityId);
    const expiresAt = parseTime(grant.expiresAt);
    if (!activity || (expiresAt && new Date() > expiresAt)) {
      return fail('GRANT_EXPIRED');
    }
    // 设备指纹绑定（方案 §6.3）。
    const deviceId = ctx.headers['x-device-id'];
    if (deviceId && grant.deviceId && deviceId !== grant.deviceId) {
      return fail('DEVICE_MISMATCH');
    }
    ctx.auth = {
      kind: 'volunteer',
      userNo: grant.userNo,
      activityId: grant.activityId,
      deviceId: grant.deviceId,
      token,
    };
    if (mode === 'admin') {
      return fail('ROLE_NOT_ALLOWED', '该接口仅限管理端身份');
    }
    return null;
  }

  return fail('UNAUTHORIZED');
}

/**
 * 校验活动的归属（方案 §2「管理者只能操作自己创建的活动」）。
 *
 * 返回活动对象，或返回业务错误。验收用例 A4 依赖这里：越权必须返回 `40301`
 * 且**数据不变**。
 */
export function requireOwnedActivity(ctx, activityId) {
  const activity = findVisibleActivity(activityId);
  if (!activity) {
    return fail('ACTIVITY_NOT_FOUND');
  }
  if (activity.ownerId !== ctx.auth.ownerId) {
    return fail('FORBIDDEN');
  }
  return activity;
}

// ─────────────────────────────────────────────────────────────────────────
// 管理端登录（§4.1）
// ─────────────────────────────────────────────────────────────────────────

export function adminLogin(ctx) {
  const { inviteCode, deviceId } = ctx.body ?? {};
  const ip = ctx.ip;

  if (typeof inviteCode !== 'string' || inviteCode.trim().length === 0) {
    return fail('BAD_REQUEST', '请填写管理员邀请码', [
      { field: 'inviteCode', message: '请填写管理员邀请码' },
    ]);
  }
  if (typeof deviceId !== 'string' || deviceId.trim().length === 0) {
    return fail('BAD_REQUEST', '缺少设备标识', [
      { field: 'deviceId', message: '缺少设备标识（X-Device-Id）' },
    ]);
  }

  // 锁定检查（验收用例 A3：连续 5 次错误 → 锁 10 分钟）。
  const failKey = ip ?? 'unknown';
  const rec = store.db.loginFailures[failKey] ?? { count: 0, lockedUntil: null };
  if (rec.lockedUntil && new Date() < new Date(rec.lockedUntil)) {
    const remainingS = Math.ceil((new Date(rec.lockedUntil) - new Date()) / 1000);
    auditLogin({ deviceId, ip, success: false, failureReason: '锁定中' });
    store.save();
    return fail(
      ERR.ADMIN_CODE_LOCKED,
      `错误次数过多，请在 ${Math.ceil(remainingS / 60)} 分钟后重试`,
      [],
      423,
    );
  }

  if (inviteCode.trim() !== adminInviteCode()) {
    rec.count = (rec.count ?? 0) + 1;
    if (rec.count >= DEFAULTS.ADMIN_CODE_MAX_ATTEMPTS) {
      rec.lockedUntil = iso(addMinutes(new Date(), DEFAULTS.ADMIN_CODE_LOCK_MIN));
      rec.count = 0;
    }
    store.db.loginFailures[failKey] = rec;
    auditLogin({ deviceId, ip, success: false, failureReason: '邀请码错误' });
    store.save();
    const left = Math.max(0, DEFAULTS.ADMIN_CODE_MAX_ATTEMPTS - (rec.count ?? 0));
    return fail(
      ERR.ADMIN_CODE_INVALID,
      rec.lockedUntil ? msgOf('ADMIN_CODE_LOCKED') : `邀请码错误，还可尝试 ${left} 次`,
      [{ field: 'inviteCode', message: '邀请码错误' }],
      401,
    );
  }

  // 登录成功：清零失败计数。
  delete store.db.loginFailures[failKey];

  // 设备指纹绑定：同一设备复登复用同一 ownerId；新设备创建新 ownerId。
  // 这是开发期 Mock 的简化实现——真实服务端应由「系统所有者按人发码」决定 ownerId
  // （方案 §13-A1 的收紧路径），此处不做人员识别。
  let admin = store.db.admins.find((a) => a.deviceId === deviceId);
  if (!admin) {
    admin = {
      ownerId: newId('owner-'),
      deviceId,
      token: newId('adm-'),
      createdAt: iso(new Date()),
      lastLoginAt: null,
      loginCount: 0,
    };
    store.db.admins.push(admin);
  }
  admin.token = newId('adm-');
  admin.lastLoginAt = iso(new Date());
  admin.loginCount = (admin.loginCount ?? 0) + 1;

  auditLogin({ deviceId, ip, success: true, ownerId: admin.ownerId });
  store.save();

  const activeCount = store.db.activities.filter(
    (a) => a.ownerId === admin.ownerId && !TERMINAL_STATUSES.includes(a.status),
  ).length;

  return {
    token: admin.token,
    deviceId: admin.deviceId,
    ownerId: admin.ownerId,
    // 令牌失效时刻：名下活动全部终态后 24 小时。仍有在效活动时给出远期占位。
    expiresAt:
      activeCount > 0
        ? iso(addMinutes(new Date(), 365 * 24 * 60))
        : iso(addMinutes(new Date(), DEFAULTS.ADMIN_TOKEN_IDLE_EXPIRY_H * 60)),
    activeActivityCount: activeCount,
    serverTime: iso(new Date()),
  };
}

export function adminMe(ctx) {
  const activeCount = store.db.activities.filter(
    (a) => a.ownerId === ctx.auth.ownerId && !TERMINAL_STATUSES.includes(a.status),
  ).length;
  return {
    ownerId: ctx.auth.ownerId,
    deviceId: ctx.auth.deviceId,
    activeActivityCount: activeCount,
    serverTime: iso(new Date()),
  };
}

/** 登录审计查询（方案 §2 缓解措施③）。 */
export function adminAudits(ctx) {
  return {
    items: store.db.loginAudits.slice(0, Number(ctx.query.limit ?? 50)),
  };
}

/**
 * 敏感导出审计查询（决策 D-3）。
 *
 * 只有「导出含完整联系方式」这一种操作会进这里。保留它的理由：
 * 一旦有人导出了完整手机号名单，事后必须能回答"谁、什么时候、导了多少行"。
 * 脱敏导出不进此表，避免把审计日志淹没在正常操作里。
 */
export function exportAudits(ctx) {
  const items = (store.db.exportAudits ?? []).slice(0, Number(ctx.query.limit ?? 50));
  return {
    items,
    total: (store.db.exportAudits ?? []).length,
    note: '仅记录「导出含完整联系方式」的操作；默认脱敏导出不入审计。',
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 志愿者绑定（§5.2）
// ─────────────────────────────────────────────────────────────────────────

export function volunteerBind(ctx) {
  const { activityId, userNo, inviteCode, name, phoneSuffix, deviceId } = ctx.body ?? {};

  const errors = [];
  if (!activityId) {
    errors.push({ field: 'activityId', message: '缺少活动标识' });
  }
  if (!userNo) {
    errors.push({ field: 'userNo', message: '请填写学号/工号' });
  }
  if (!inviteCode) {
    errors.push({ field: 'inviteCode', message: '请填写发布者发放的一次性邀请码' });
  }
  if (!deviceId) {
    errors.push({ field: 'deviceId', message: '缺少设备标识' });
  }
  if (errors.length > 0) {
    return fail('BAD_REQUEST', '绑定信息不完整', errors);
  }

  const activity = findVisibleActivity(activityId);
  if (!activity) {
    return fail('ACTIVITY_NOT_FOUND');
  }

  // ── 邀请码校验（§5.2：有效且未使用）──────────────────────────────
  const invite = findInviteCode(activityId, String(inviteCode).trim());
  if (!invite) {
    return fail('INVITE_CODE_INVALID', msgOf('INVITE_CODE_INVALID'), [
      { field: 'inviteCode', message: '邀请码无效' },
    ]);
  }
  // 邀请码是「一对一私发」的，因此必须与该学号配对（§14.1-2）。
  if (invite.userNo !== String(userNo).trim()) {
    return fail('INVITE_CODE_INVALID', '该邀请码不属于此学号', [
      { field: 'inviteCode', message: '该邀请码不属于此学号' },
    ]);
  }
  if (invite.usedAt) {
    /*
      ## 幂等恢复：同一设备重试应当拿回原授权

      真机测试抓到的死锁：首个绑定请求**服务端已经成功**
      （邀请码消费、grant 签发、名单绑定全部落库），
      但客户端在切换网络的瞬间超时、没收到响应 ——
      用户看到「网络超时」，重试却得到「该邀请码已被使用」，
      **从此永远绑不上**，只能找发布者重新发码。

      这不是罕见边界：一次网络抖动就能把用户锁死，
      而服务端明明已经把授权准备好了。

      判据（必须同时满足才幂等返回）：

        1. 邀请码的 `usedByDeviceId` 与本次 `deviceId` **相同**；
        2. 该活动下确实存在 (userNo, deviceId) 匹配的 grant。

      安全上等价：`deviceId` 本身就是绑定凭据 ——
      能复现它说明请求仍来自同一台机器。
      **码被别人用了**（不同 deviceId）时仍然拒绝，一次性语义不变。
    */
    const sameDevice =
      invite.usedByDeviceId != null && invite.usedByDeviceId === String(deviceId);
    const priorGrant = store.db.grants.find(
      (g) =>
        g.activityId === activityId &&
        g.userNo === String(userNo).trim() &&
        g.deviceId === String(deviceId),
    );

    if (sameDevice && priorGrant) {
      return {
        token: priorGrant.token,
        activityId,
        userNo: priorGrant.userNo,
        name: priorGrant.name,
        deviceId,
        expiresAt: priorGrant.expiresAt,
        serverTime: iso(new Date()),
        // 让客户端/测试能区分"首次绑定"与"重试恢复"
        idempotentReplay: true,
        note: '同一设备重复绑定，已返回原授权（上次绑定其实已成功）',
      };
    }

    return fail('INVITE_CODE_INVALID', '该邀请码已被使用', [
      { field: 'inviteCode', message: '该邀请码已被使用' },
    ]);
  }
  if (invite.expiresAt && new Date() > parseTime(invite.expiresAt)) {
    return fail('INVITE_CODE_INVALID', '该邀请码已过期', [
      { field: 'inviteCode', message: '该邀请码已过期' },
    ]);
  }

  // ── 名单校验（§5.2：学号 ∈ 该活动名单）───────────────────────────
  const participant = findParticipant(activityId, String(userNo).trim());
  if (!participant || participant.signupStatus === 'cancelled' || participant.removedAt) {
    // 验收用例 A10：非名单用户绑定应被拒绝并提示明确文案。
    return fail('NOT_IN_PARTICIPANT_LIST', msgOf('NOT_IN_PARTICIPANT_LIST'));
  }

  // ── 二次校验（§14.1-2，必做）─────────────────────────────────────
  // 姓名或手机号后四位至少一项匹配。两者都提供且都不匹配时报 20006。
  if (name != null || phoneSuffix != null) {
    const nameMatches = name != null && String(name).trim() === participant.name;
    const suffixMatches =
      phoneSuffix != null && participant.phoneSuffix && String(phoneSuffix).trim() === participant.phoneSuffix;
    if (!nameMatches && !suffixMatches) {
      return fail('IDENTITY_MISMATCH', msgOf('IDENTITY_MISMATCH'), [
        { field: 'name', message: '姓名或手机号后四位与名单不匹配' },
      ]);
    }
  }

  // ── 设备绑定冲突 ─────────────────────────────────────────────────
  const existing = store.db.grants.find((g) => g.activityId === activityId && g.userNo === participant.userNo);
  if (existing && existing.deviceId && existing.deviceId !== deviceId) {
    return fail('DEVICE_ALREADY_BOUND', msgOf('DEVICE_ALREADY_BOUND'), [
      { field: 'deviceId', message: '该身份已绑定其他设备，请联系发布者解绑' },
    ]);
  }

  // ── 签发令牌与活动级授权 ─────────────────────────────────────────
  // 授权到期 = 活动终态 + 7 天；活动未终结时给一个随活动结束日推算的上限。
  const expiresAt = grantExpiryFor(activity);  let grant = existing;
  if (grant) {
    grant.token = newId('vol-');
    grant.deviceId = deviceId;
    grant.expiresAt = iso(expiresAt);
  } else {
    grant = {
      token: newId('vol-'),
      activityId,
      userNo: participant.userNo,
      name: participant.name,
      deviceId,
      expiresAt: iso(expiresAt),
      createdAt: iso(new Date()),
    };
    store.db.grants.push(grant);
  }

  invite.usedAt = iso(new Date());
  invite.usedByDeviceId = deviceId;
  participant.inviteCodeUsedAt = invite.usedAt;
  participant.boundDeviceId = deviceId;
  participant.boundAt = iso(new Date());

  store.save();

  return {
    token: grant.token,
    activityId,
    userNo: grant.userNo,
    name: grant.name,
    deviceId,
    expiresAt: grant.expiresAt,
    serverTime: iso(new Date()),
  };
}

export function volunteerMe(ctx) {
  const grant = store.db.grants.find((g) => g.token === ctx.auth.token);
  const activity = findVisibleActivity(ctx.auth.activityId);
  return {
    userNo: ctx.auth.userNo,
    activityId: ctx.auth.activityId,
    name: grant?.name ?? null,
    expiresAt: grant?.expiresAt ?? null,
    activityStatus: activity?.status ?? null,
    activityTitle: activity?.title ?? null,
    serverTime: iso(new Date()),
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 仅开发：重置
// ─────────────────────────────────────────────────────────────────────────

/**
 * `/dev/*` 接口是否可用。
 *
 * ## 为什么必须显式开关，而不是"反正这只是 mock"
 *
 * mock 常常被拿去反代到手机上做真机联调（本项目就是这么用的），
 * 于是它的端口**确实会暴露在局域网**上。此时 `/dev/reset`
 * 就是一个"谁都能调、一调清空全部演示数据"的后门 ——
 * 而且调用者不需要任何身份。
 *
 * 因此默认**关闭**，只有显式设置 `MOCK_ALLOW_DEV=1` 才开放。
 * 生产环境（`NODE_ENV=production`）里即使设了也**不开放**：
 * 那种配置只可能是误操作。
 */
function devEndpointsAllowed() {
  if (process.env.NODE_ENV === 'production') {
    return false;
  }
  return process.env.MOCK_ALLOW_DEV === '1';
}

/** 不满足条件时抛出"接口不存在"（不暴露它其实是权限问题）。 */
function requireDevEndpoints() {
  if (!devEndpointsAllowed()) {
    return fail('ACTIVITY_NOT_FOUND', '接口不存在');
  }
  return null;
}

export function devReset(ctx) {
  const denied = requireDevEndpoints();
  if (denied) {
    return denied;
  }
  // 防止误把 Mock 暴露到公网后被随手清库：要求显式确认参数。
  if (ctx.body?.confirm !== 'RESET') {
    return fail('BAD_REQUEST', '请传 { "confirm": "RESET" } 以确认重置');
  }
  store.reset();
  return { reset: true, dataFile: store.filePath };
}

/**
 * 仅开发：演示「设备时间不准」与「离线补传超窗」的构造助手。
 *
 * 方案 §9 要求识别设备时间偏差过大；§6.4 要求超窗补传一律转待人工确认。
 * 这个接口让联调时不用真的改手机时间就能验证这两条。
 */
export function devTimeTravelExample(ctx) {
  const denied = requireDevEndpoints();
  if (denied) {
    return denied;
  }
  const { activityId, minutesAgo } = ctx.body ?? {};
  const activity = findVisibleActivity(activityId);
  if (!activity) {
    return fail('ACTIVITY_NOT_FOUND');
  }
  const past = addMinutes(new Date(), -Number(minutesAgo ?? 120));
  return {
    hint: '把客户端 clientTime 设为该值即可模拟超窗补传；服务端会将其转为 pending_review。',
    clientTime: iso(past),
    activityStatus: activity.status,
    activityStatusHint:
      activity.status === ACTIVITY_STATUS.PUBLISHED
        ? '活动已发布但未开始（可验证「不在签到时段内」）'
        : null,
  };
}
