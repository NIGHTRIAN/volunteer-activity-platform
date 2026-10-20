/**
 * 鉴权接口（方案 §5.2 / §4.7）：管理端登录、志愿者绑定活动。
 *
 * ## 这两个接口为什么是关键路径
 *
 * 没有它们，手机端**一个请求都发不出去**：App 启动后先要拿令牌，
 * 拿不到就停在登录页。服务端之前的 7 个只读接口只是让网页能看，
 * 手机端要"能用"，必须从这两个开始。
 *
 * ## 三条容易写错、且真机上已经踩过的规则
 *
 * 1. **邀请码是发布者身份，不是设备身份。**
 *    mock 阶段用设备指纹推导 ownerId，结果换设备登录后
 *    "我发布的活动"变成 0 条。现在 ownerId 由配置决定（见 config.js）。
 *
 * 2. **绑定必须幂等。**
 *    客户端提交后如果响应丢了（超时/断网），它会重试同一份证据。
 *    若服务端把第二次当成"邀请码已被使用"直接拒绝，
 *    用户就被**永久锁死**在绑定页 —— 而邀请码已经用掉了。
 *    所以同设备重试一律返回原授权。
 *
 * 3. **错误码要能指导用户下一步。**
 *    `身份不匹配` 和 `邀请码无效` 是两回事：前者要核对姓名/手机后四位，
 *    后者要找发布者重新要码。混成一个码会让用户徒劳地反复重试。
 */

import { TERMINAL_STATUSES } from '../contract.js';
import { ApiError } from '../http/envelope.js';
import { parseTime, toIso, nowIso } from '../util/time.js';

/** 从请求里取设备标识（body 优先，其次请求头）。 */
function pickDeviceId(ctx) {
  const fromBody = typeof ctx.body?.deviceId === 'string' ? ctx.body.deviceId.trim() : '';
  if (fromBody) {
    return fromBody;
  }
  const raw = ctx.headers?.['x-device-id'];
  return typeof raw === 'string' ? raw.trim() : '';
}

/** 必填字符串校验。 */
function requireString(value, field, label) {
  const v = typeof value === 'string' ? value.trim() : '';
  if (!v) {
    throw new ApiError('BAD_REQUEST', `${label}不能为空`, [
      { field, message: `${label}不能为空` },
    ]);
  }
  return v;
}

/**
 * 管理员登录。
 *
 * 请求：`{ inviteCode, deviceId }`
 * 响应：与 App 的 `AdminSession` 对齐。
 */
export async function adminLogin(ctx) {
  const { config, repos, ip, logger } = ctx;
  const deviceId = pickDeviceId(ctx);
  const inviteCode = requireString(ctx.body?.inviteCode, 'inviteCode', '邀请码');
  requireString(deviceId, 'deviceId', '设备标识');

  const now = new Date();

  /*
    锁定检查放在"校验邀请码"**之前**。

    顺序反了会泄露信息：错误邀请码能立刻得到"邀请码错误"，
    而被锁定的账号也能立刻得到"邀请码错误"——攻击者据此可判断
    自己是在被限流还是码错了。先判锁定，外部只能看到"已锁定"。
  */
  const sinceIso = toIso(new Date(now.getTime() - config.auth.loginLockMinutes * 60_000));
  const failures = await repos.loginAudit.failuresSince({ deviceId, ip, sinceIso });
  if (failures >= config.auth.loginMaxFailures) {
    await repos.loginAudit.record({
      deviceId,
      ip,
      success: false,
      reason: 'locked',
      now,
    });
    logger?.warn?.('管理端登录被锁定', { deviceId, ip, failures });
    throw new ApiError(
      'ADMIN_CODE_LOCKED',
      `连续 ${config.auth.loginMaxFailures} 次失败，请 ${config.auth.loginLockMinutes} 分钟后再试`,
    );
  }

  /*
    按「邀请码 → 发布者」映射判定身份（支持多发布者）。

    单发布者部署时不配 `ADMIN_OWNERS`，映射里只有默认码，
    行为与之前完全一致 —— 这条兼容性是有意的：
    老部署不该因为加了多发布者能力就要改配置。
  */
  const ownerIdOfCode = config.auth.ownerByCode?.[inviteCode];
  if (!ownerIdOfCode) {
    await repos.loginAudit.record({
      deviceId,
      ip,
      success: false,
      reason: 'invite_code_mismatch',
      now,
    });
    throw new ApiError('ADMIN_CODE_INVALID', '邀请码不正确');
  }

  // 归属由**邀请码**决定（多发布者），而不是配置里的单一 ownerId。
  const ownerId = ownerIdOfCode;

  // 顺手清掉该 owner 的过期会话，避免表无限增长。
  await repos.adminSession.purgeExpired(ownerId, now);

  const session = await repos.adminSession.create({
    ownerId,
    deviceId,
    ttlMinutes: config.auth.adminTokenTtlMinutes,
    now,
  });

  await repos.loginAudit.record({ ownerId, deviceId, ip, success: true, now });

  /*
    活跃活动数：登录页/首页会显示"我发布的活动 N 个"。
    统计口径必须与列表接口一致 —— 都排除终态（已结束 / 已取消）。
    不一致的话用户会看到"显示 3 个，点进去只有 1 个"。
  */
  const active = await ctx.db.queryOne(
    `SELECT COUNT(*) AS n FROM activity
      WHERE owner_id = ? AND status NOT IN (${TERMINAL_STATUSES.map(() => '?').join(',')})`,
    [ownerId, ...TERMINAL_STATUSES],
  );

  return {
    token: session.token,
    deviceId,
    ownerId,
    expiresAt: session.expiresAt,
    serverTime: nowIso(),
    activeActivityCount: Number(active?.n ?? 0),
  };
}

/**
 * 志愿者绑定活动。
 *
 * 请求：`{ activityId, userNo, inviteCode, deviceId, name?, phoneSuffix? }`
 * 响应：与 App 的 `VolunteerGrant` 对齐。
 */
export async function bindActivity(ctx) {
  const { config, repos } = ctx;
  const now = new Date();
  const deviceId = pickDeviceId(ctx);
  const activityIdRaw = requireString(ctx.body?.activityId, 'activityId', '活动编号');
  const userNo = requireString(ctx.body?.userNo, 'userNo', '学号');
  const inviteCode = requireString(ctx.body?.inviteCode, 'inviteCode', '邀请码');
  requireString(deviceId, 'deviceId', '设备标识');

  // 活动编号允许填"活动 id"或"外部编号"，因为发布者给志愿者的是后者。
  let activity = await repos.activities.findById(activityIdRaw);
  if (!activity) {
    const byExternal = await ctx.db.queryOne(
      'SELECT id FROM activity WHERE external_id = ?',
      [activityIdRaw],
    );
    if (byExternal?.id) {
      activity = await repos.activities.findById(String(byExternal.id));
    }
  }
  if (!activity) {
    // 过留存期与"不存在"用同一个错误码：不泄露活动曾经存在。
    throw new ApiError('ACTIVITY_NOT_FOUND');
  }

  /*
    ⚠️ 必须转成字符串再查子表。

    ctivityRepo.findById 返回的 id 是**数字**（库里的自增主键），
    而 participant.activity_id / invite_code.activity_id 是文本列。
    SQLite 里 ctivity_id = 1（数字）匹配不到 '1'（文本）——
    而且不报错，只是**查不到**，表现为"邀请码无效"。
    这个坑在真机上排查起来会非常费劲（码明明是对的）。
  */
  const activityId = String(activity.id);

  const invite = await repos.inviteCodes.find(activityId, inviteCode);
  if (!invite) {
    throw new ApiError('INVITE_CODE_INVALID');
  }
  if (invite.expiresAt && parseTime(invite.expiresAt) <= now) {
    throw new ApiError('INVITE_CODE_INVALID', '邀请码已过期，请向发布者重新索取');
  }
  if (invite.userNo !== userNo) {
    // 码是对的但发给别人：这是"身份不匹配"，不是"码无效"。
    throw new ApiError('IDENTITY_MISMATCH', '该邀请码不属于这个学号');
  }

  const participant = await repos.participants.findOne(activityId, userNo);
  if (!participant || participant.removedAt) {
    throw new ApiError('NOT_IN_PARTICIPANT_LIST');
  }

  /*
    二次校验：填了姓名或手机后四位就必须对上一个。

    注意是 **or** 而不是 and：现场最常见的情况是志愿者只记得其中一项。
    要求"两个都对"会把大量真实用户挡在门外，而这个校验的目的
    只是防止"捡到别人的邀请码"。
  */
  const name = typeof ctx.body?.name === 'string' ? ctx.body.name.trim() : '';
  const suffix = typeof ctx.body?.phoneSuffix === 'string' ? ctx.body.phoneSuffix.trim() : '';
  if (name || suffix) {
    const nameOk = name.length > 0 && participant.name === name;
    const suffixOk =
      suffix.length > 0 &&
      participant.phoneSuffix !== null &&
      participant.phoneSuffix !== undefined &&
      String(participant.phoneSuffix) === suffix;
    if (!nameOk && !suffixOk) {
      /*
        必须下发**字段级错误**，因为客户端无法靠错误码区分原因。

        契约只授权 8 个码值，`40301` 同时代表"越权 / 不在名单 / 身份不符 /
        设备不符"。App 的绑定页要靠 `errors[].field` 才能高亮出错的输入框。
        只给一句笼统提示，用户只能把两个框都改一遍，而且不知道改哪个。
      */
      const errors = [];
      if (name.length > 0 && !nameOk) {
        errors.push({ field: 'name', message: '与名单登记的不一致' });
      }
      if (suffix.length > 0 && !suffixOk) {
        errors.push({ field: 'phoneSuffix', message: '与名单登记的不一致' });
      }
      throw new ApiError('IDENTITY_MISMATCH', null, errors);
    }
  }

  const existing = await repos.grants.findActive(activityId, userNo, now);

  // ① 同设备重试 → 幂等返回原令牌。
  if (existing && existing.deviceId === deviceId) {
    return {
      token: existing.token,
      activityId,
      userNo,
      name: participant.name,
      deviceId,
      expiresAt: existing.expiresAt,
      serverTime: nowIso(),
      idempotentReplay: true,
    };
  }

  // ② 换设备：只有在邀请码"还没被用过"时才允许，否则拒绝。
  if (existing && existing.deviceId !== deviceId) {
    const codeStillFresh = !invite.usedAt || invite.reissued > 0;
    if (!codeStillFresh) {
      throw new ApiError(
        'DEVICE_ALREADY_BOUND',
        '该身份已绑定其他设备。换手机请联系发布者重新发码。',
      );
    }
    // 旧设备的授权作废，避免"两台手机都能签到"。
    await repos.grants.revoke(existing.id, now);
  }

  /*
    授权期限要**覆盖活动全程**，而不是固定 7 天。

    原来写死 `grantTtlHours`（7 天）：一个为期两周的长期志愿岗，
    第七天志愿者就会被要求重新绑定 —— 而他什么也没做错，
    现场也没有发布者能给他发新码。

    现在取 max(配置下限, 活动结束后再留 24 小时)。
    注意客户端会**本地**判 `expiresAt`（见 user_app/main.dart），
    所以这个时机必须在服务端就算对，不能靠滑动续期补救 ——
    否则 App 自己就把授权清掉了，服务端再怎么续也没用。
  */
  const endMs = parseTime(activity.endTime)?.getTime() ?? now.getTime();
  const hoursToCover = Math.max(0, (endMs - now.getTime()) / 3_600_000) + 24;
  const grantTtlHours = Math.max(config.auth.grantTtlHours, Math.ceil(hoursToCover));

  const grant = await repos.grants.create({
    activityId,
    userNo,
    name: participant.name,
    deviceId,
    ttlHours: grantTtlHours,
    now,
  });

  await repos.inviteCodes.markUsed(invite.id, now);
  await repos.participants.markBound(participant.id, {
    deviceId,
    grantExpiresAt: grant.expiresAt,
    now,
  });

  return {
    token: grant.token,
    activityId,
    userNo,
    name: participant.name,
    deviceId,
    expiresAt: grant.expiresAt,
    serverTime: nowIso(),
  };
}

/**
 * 解析请求里的令牌 → `ctx.auth`。
 *
 * 返回三种形态：
 *   * `{ kind: 'admin', ownerId, sessionId }`
 *   * `{ kind: 'volunteer', activityId, userNo, name, grantId }`
 *   * `{}` —— 未带令牌或令牌无效
 *
 * ## 为什么无效令牌不在这里抛错
 *
 * 因为**有些接口允许匿名**（公开活动列表、活动详情）。
 * 一个过期的令牌不该让"看活动列表"也失败 —— 那会让用户在
 * 令牌过期后连首页都打不开，而首页恰恰是他想"重新登录"的入口。
 *
 * 所以这里只负责"能认就认出来"，要不要强制由每个 handler 决定
 * （见 `requireAdmin` / `requireVolunteer`）。
 */
export async function resolveAuth(ctx) {
  const token = ctx.token;
  if (!token) {
    return {};
  }

  const session = await ctx.repos.adminSession.findByToken(token);
  if (session) {
    /*
      滑动续期。

      剩余有效期不足总时长的 1/4 时，把到期时间推到 now + TTL。
      这样"一直在用"的管理端永远不会被踢；真的闲置过期仍会失效。

      为什么要这个：令牌固定 12 小时，现场从早忙到晚必然中途掉登录，
      而发布者在复核到一半时被踢回登录页很难受（还会以为数据丢了）。

      只在快到期时才写库，避免每个请求都 UPDATE admin_session。
    */
    const ttlMinutes = ctx.config.auth.adminTokenTtlMinutes;
    const expiresMs = Date.parse(session.expiresAt);
    const remainingMs = expiresMs - Date.now();
    if (
      Number.isFinite(expiresMs) &&
      remainingMs > 0 &&
      remainingMs < ttlMinutes * 60_000 * 0.25
    ) {
      await ctx.repos.adminSession.extend(session.id, ttlMinutes);
    } else {
      // 记录一次使用：用于"名下活动全部终态 + 宽限期后失效"的判定。
      await ctx.repos.adminSession.touch(session.id);
    }
    return { kind: 'admin', ownerId: session.ownerId, sessionId: session.id };
  }

  const grant = await ctx.repos.grants.findByToken(token);
  if (grant) {
    return {
      kind: 'volunteer',
      activityId: grant.activityId,
      userNo: grant.userNo,
      name: grant.name,
      grantId: grant.id,
      deviceId: grant.deviceId,
    };
  }

  return {};
}

/** 要求管理端身份。 */
export function requireAdmin(ctx) {
  if (ctx.auth?.kind !== 'admin') {
    throw new ApiError('ADMIN_TOKEN_EXPIRED');
  }
  return ctx.auth;
}

/**
 * 要求志愿者身份，且授权必须属于该活动。
 *
 * `activityId` 传活动路由参数，避免"拿着 A 活动的令牌去操作 B 活动"。
 */
export function requireVolunteer(ctx, activityId) {
  if (ctx.auth?.kind !== 'volunteer') {
    throw new ApiError('UNAUTHORIZED');
  }
  if (activityId && ctx.auth.activityId !== activityId) {
    throw new ApiError('FORBIDDEN', '当前授权不属于这个活动');
  }
  return ctx.auth;
}

/**
 * 要求管理端身份，且活动属于这个发布者。
 *
 * ## 为什么归属校验必须在接口层显式做
 *
 * 只看"是不是管理员"是不够的：任何管理员都能凭 id 改别人的活动。
 * 而漏掉这一处的后果不是报错，是**静默地改错了数据**。
 * 所以宁可每次多写一行 `assertOwnership`，也不要指望仓储层兜底。
 */
export async function assertActivityOwnership(ctx, activity) {
  if (!activity) {
    throw new ApiError('ACTIVITY_NOT_FOUND');
  }
  const auth = requireAdmin(ctx);
  if (activity.ownerId !== auth.ownerId) {
    /*
      用 **403 无权操作该活动**，而不是伪装成 404。

      曾经写成 404（理由"不泄露活动是否存在"），但真机与端到端都证明那样更糟：
      管理端所有写接口都走这里，一律 404 会让发布者看到"活动不存在"，
      从而以为**自己的活动丢了** —— 实际只是点到了别人的活动（例如链接被转发）。

      而列表接口已做归属隔离，管理员本来就看不到别人的活动，
      "泄露存在性"的风险远小于"让人以为数据丢了"。

      注意：**公开详情**对草稿仍返回 404（那是不该泄露草稿内容），
      两者理由不同，别混。
    */
    throw new ApiError('FORBIDDEN', '无权操作该活动');
  }
  return activity;
}

/**
 * `GET /auth/admin/me` —— 当前管理端身份。
 *
 * 客户端用它确认"手里的令牌还有效吗、我是哪个发布者"，
 * 不必为了验证身份而先打一个业务接口（业务接口的失败原因会干扰判断）。
 */
export async function adminMe(ctx) {
  const auth = requireAdmin(ctx);
  const session = await ctx.repos.adminSession.findByToken(ctx.token);
  if (!session) {
    throw new ApiError('ADMIN_TOKEN_EXPIRED');
  }
  const active = await ctx.db.queryOne(
    `SELECT COUNT(*) AS n FROM activity
      WHERE owner_id = ? AND status NOT IN (?, ?)`,
    [auth.ownerId, 'finished', 'cancelled'],
  );
  return {
    ownerId: auth.ownerId,
    deviceId: session.deviceId,
    expiresAt: session.expiresAt,
    serverTime: nowIso(),
    activeActivityCount: Number(active?.n ?? 0),
  };
}

/**
 * `GET /auth/me` —— 当前志愿者授权（活动 + 学号 + 到期时间）。
 *
 * 用户端启动时用它确认"授权还在、还属于这个活动"，
 * 不必先打签到接口去试。
 */
export async function volunteerMe(ctx) {
  const auth = requireVolunteer(ctx);
  const activity = await ctx.repos.activities.findById(auth.activityId);
  if (!activity) {
    // 活动过了留存期 → 授权自然作废；给"授权过期"比"活动不存在"更贴切。
    throw new ApiError('GRANT_EXPIRED');
  }
  const grant = await ctx.repos.grants.findByToken(ctx.token);
  return {
    activityId: String(activity.id),
    activityTitle: activity.title,
    userNo: auth.userNo ?? null,
    name: auth.name ?? null,
    deviceId: grant?.deviceId ?? null,
    expiresAt: grant?.expiresAt ?? null,
    serverTime: nowIso(),
  };
}
