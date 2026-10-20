/**
 * 鉴权相关的仓储：管理端会话、活动授权、邀请码、参与者绑定。
 *
 * ## 分层原则
 *
 * 这里只做**领域读写**，不做判定。所有"能不能登录""能不能绑定"
 * 的规则都在 `src/api/auth.js` 里 —— 因为那些规则要报具体错误码，
 * 而错误码属于接口层语义。
 */

import { newToken } from '../util/tokens.js';
import { nowIso, toIso, addMinutesIso, addDays } from '../util/time.js';

/** 判断一个 ISO 时间是否已过。 */
function isPast(iso, now = new Date()) {
  if (!iso) {
    return true;
  }
  const t = Date.parse(iso);
  return Number.isNaN(t) ? true : t <= now.getTime();
}

/**
 * 管理端会话仓储。
 *
 * 一个 owner 可以有多个会话（手机 + 平板）。**重新登录不会踢掉别的设备**，
 * 但本次登录会生成新令牌 —— App 端存的旧令牌随之失效
 * （真机测试时踩过：服务端每次登录轮换令牌，而 App 仍拿旧令牌请求 → 40101）。
 */
export function adminSessionRepo(conn) {
  return {
    async create({ ownerId, deviceId, ttlMinutes, now = new Date() }) {
      const token = newToken();
      const expiresAt = toIso(new Date(now.getTime() + ttlMinutes * 60_000));
      const r = await conn.execute(
        `INSERT INTO admin_session (owner_id, token, device_id, created_at, expires_at, last_seen_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [ownerId, token, deviceId, toIso(now), expiresAt, toIso(now)],
      );
      return { id: r.lastInsertId, token, expiresAt };
    },

    /** 按令牌查会话。**过期的返回 null** —— 过期判定不该外泄给调用方。 */
    async findByToken(token, now = new Date()) {
      if (!token) {
        return null;
      }
      const row = await conn.queryOne(
        'SELECT * FROM admin_session WHERE token = ?',
        [token],
      );
      if (!row) {
        return null;
      }
      if (isPast(row.expires_at, now)) {
        return null;
      }
      return {
        id: Number(row.id),
        ownerId: row.owner_id,
        deviceId: row.device_id,
        expiresAt: row.expires_at,
        createdAt: row.created_at,
      };
    },

    /** 记录最后一次使用时刻（用于"名下活动全部终态后 24h 失效"的判定）。 */
    async touch(id, now = new Date()) {
      await conn.execute('UPDATE admin_session SET last_seen_at = ? WHERE id = ?', [
        toIso(now),
        id,
      ]);
    },

    /**
     * 滑动续期：把到期时间推到 `now + ttl`。
     *
     * ## 为什么用"滑动过期"而不是 refresh 令牌
     *
     * 这是个校内试点系统：管理端一天里会反复用（发现场、复核）。
     * 只要**在用**就不该被踢出去；而真的闲置 12 小时，重新登录也合理。
     *
     * 滑动过期不需要客户端配合 —— App 里存的令牌不用换，
     * 也不用改两端的登录逻辑，风险最小。
     * （JWT 那类无状态令牌做不到这一点，这也是当初选不透明令牌的原因之一。）
     */
    async extend(id, ttlMinutes, now = new Date()) {
      const expiresAt = toIso(new Date(now.getTime() + ttlMinutes * 60_000));
      await conn.execute('UPDATE admin_session SET expires_at = ?, last_seen_at = ? WHERE id = ?', [
        expiresAt,
        toIso(now),
        id,
      ]);
      return expiresAt;
    },

    /** 清掉某个 owner 的过期会话（登录时顺手清，避免表无限增长）。 */
    async purgeExpired(ownerId, now = new Date()) {
      await conn.execute(
        'DELETE FROM admin_session WHERE owner_id = ? AND expires_at <= ?',
        [ownerId, toIso(now)],
      );
    },
  };
}

/** 登录审计（方案 §6.3：记录时间 / 设备 / IP）。 */
export function loginAuditRepo(conn) {
  return {
    async record({ ownerId, deviceId, ip, success, reason, now = new Date() }) {
      await conn.execute(
        `INSERT INTO login_audit (owner_id, device_id, ip, success, reason, at)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [ownerId ?? null, deviceId ?? null, ip ?? null, success ? 1 : 0, reason ?? null, toIso(now)],
      );
    },

    /**
     * 统计窗口内的失败次数（锁定判定用）。
     *
     * ## 为什么按 device_id **和** ip 分别统计，取较大者
     *
     * 只按设备算，攻击者换个设备就绕过；只按 IP 算，同一 NAT 后面的
     * 一栋宿舍楼会互相连坐。取两者较大值是折中：任一维度刷够了就锁。
     */
    async failuresSince({ deviceId, ip, sinceIso }) {
      const byDevice = deviceId
        ? await conn.queryOne(
            `SELECT COUNT(*) AS n FROM login_audit
             WHERE success = 0 AND device_id = ? AND at >= ?`,
            [deviceId, sinceIso],
          )
        : null;
      const byIp = ip
        ? await conn.queryOne(
            `SELECT COUNT(*) AS n FROM login_audit
             WHERE success = 0 AND ip = ? AND at >= ?`,
            [ip, sinceIso],
          )
        : null;
      return Math.max(Number(byDevice?.n ?? 0), Number(byIp?.n ?? 0));
    },
  };
}

/** 邀请码仓储（方案 §4.7）。 */
export function inviteCodeRepo(conn) {
  return {
    /** 按 (活动, 码) 查找。不在这里判过期 —— 由接口层给不同错误码。 */
    async find(activityId, code) {
      const row = await conn.queryOne(
        'SELECT * FROM invite_code WHERE activity_id = ? AND code = ? ORDER BY id DESC LIMIT 1',
        [activityId, code],
      );
      if (!row) {
        return null;
      }
      return {
        id: Number(row.id),
        activityId: row.activity_id,
        userNo: row.user_no,
        code: row.code,
        expiresAt: row.expires_at,
        usedAt: row.used_at,
        reissued: Number(row.reissued ?? 0),
        createdAt: row.created_at,
      };
    },

    async markUsed(id, now = new Date()) {
      await conn.execute('UPDATE invite_code SET used_at = ? WHERE id = ?', [toIso(now), id]);
    },

    /**
     * 发码（**重发是更新，不是插入**）。
     *
     * ## 为什么这里必须是 upsert
     *
     * schema 在 `invite_code (activity_id, user_no)` 上建了唯一约束：
     * 一个参与者在同一活动里**只能有一个当前邀请码**。
     *
     * 最初按"每次发码就 INSERT 一行"实现，结果真机上发布者第二次点
     * 「生成邀请码」直接报 `UNIQUE constraint failed` ——
     * 而发布者的意图只是"这个人说没收到，再发一次"。
     *
     * 正确语义：
     *   * 已有记录 → 换码、延长有效期、把 `used_at` 清零（新码还没用过）、
     *     `reissued + 1`（记录这是第几次重发，换设备绑定要据此放行）；
     *   * 没有记录 → 插入。
     */
    async create({ activityId, userNo, code, ttlHours = 24 * 7, now = new Date() }) {
      const expiresAt = toIso(new Date(now.getTime() + ttlHours * 3_600_000));
      const existing = await conn.queryOne(
        'SELECT id FROM invite_code WHERE activity_id = ? AND user_no = ?',
        [activityId, userNo],
      );
      if (existing) {
        await conn.execute(
          `UPDATE invite_code
              SET code = ?, expires_at = ?, used_at = NULL, reissued = reissued + 1
            WHERE id = ?`,
          [code, expiresAt, existing.id],
        );
        return { code, expiresAt, reissued: true };
      }
      await conn.execute(
        `INSERT INTO invite_code (activity_id, user_no, code, expires_at, used_at, reissued, created_at)
         VALUES (?, ?, ?, ?, NULL, 0, ?)`,
        [activityId, userNo, code, expiresAt, toIso(now)],
      );
      return { code, expiresAt, reissued: false };
    },

    /** 该参与者当前是否已有未使用的码（发码时复用，避免每次点都换一个）。 */
    async findUnusedByUser(activityId, userNo) {
      const row = await conn.queryOne(
        `SELECT * FROM invite_code
         WHERE activity_id = ? AND user_no = ? AND used_at IS NULL
         ORDER BY id DESC LIMIT 1`,
        [activityId, userNo],
      );
      return row ? { id: Number(row.id), code: row.code, expiresAt: row.expires_at } : null;
    },
  };
}

/** 活动授权仓储（方案 §4.7：令牌绑定设备指纹）。 */
export function grantRepo(conn) {
  return {
    async create({ activityId, userNo, name, deviceId, ttlHours, now = new Date() }) {
      const token = newToken();
      const expiresAt = toIso(new Date(now.getTime() + ttlHours * 3_600_000));
      const r = await conn.execute(
        `INSERT INTO activity_grant
           (activity_id, user_no, name, token, device_id, expires_at, created_at, revoked_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, NULL)`,
        [activityId, userNo, name ?? null, token, deviceId ?? null, expiresAt, toIso(now)],
      );
      return { id: r.lastInsertId, token, expiresAt };
    },

    async findByToken(token, now = new Date()) {
      if (!token) {
        return null;
      }
      const row = await conn.queryOne('SELECT * FROM activity_grant WHERE token = ?', [token]);
      if (!row) {
        return null;
      }
      if (row.revoked_at) {
        return null;
      }
      if (isPast(row.expires_at, now)) {
        return null;
      }
      return {
        id: Number(row.id),
        activityId: row.activity_id,
        userNo: row.user_no,
        name: row.name,
        deviceId: row.device_id,
        expiresAt: row.expires_at,
      };
    },

    /** 找某人某活动当前有效的授权（用于幂等重放 / 换设备判定）。 */
    async findActive(activityId, userNo, now = new Date()) {
      const row = await conn.queryOne(
        `SELECT * FROM activity_grant
         WHERE activity_id = ? AND user_no = ? AND revoked_at IS NULL AND expires_at > ?
         ORDER BY id DESC LIMIT 1`,
        [activityId, userNo, toIso(now)],
      );
      if (!row) {
        return null;
      }
      return {
        id: Number(row.id),
        token: row.token,
        deviceId: row.device_id,
        expiresAt: row.expires_at,
      };
    },

    async revoke(id, now = new Date()) {
      await conn.execute('UPDATE activity_grant SET revoked_at = ? WHERE id = ?', [
        toIso(now),
        id,
      ]);
    },
  };
}

/** 参与者仓储（只写绑定相关字段；名单增删在后续接口里补）。 */
export function participantRepo(conn) {
  return {
    async findOne(activityId, userNo) {
      const row = await conn.queryOne(
        'SELECT * FROM participant WHERE activity_id = ? AND user_no = ?',
        [activityId, userNo],
      );
      if (!row) {
        return null;
      }
      return {
        id: Number(row.id),
        activityId: row.activity_id,
        userNo: row.user_no,
        name: row.name,
        phone: row.phone,
        phoneSuffix: row.phone_suffix,
        signupStatus: row.signup_status,
        removedAt: row.removed_at,
        grantExpiresAt: row.grant_expires_at,
        inviteCodeUsedAt: row.invite_code_used_at,
        boundDeviceId: row.bound_device_id,
      };
    },

    /** 绑定成功后落库：设备指纹 + 授权到期时间 + 邀请码使用时间。 */
    async markBound(id, { deviceId, grantExpiresAt, now = new Date() }) {
      await conn.execute(
        `UPDATE participant
            SET bound_device_id = ?, grant_expires_at = ?, invite_code_used_at = ?, updated_at = ?
          WHERE id = ?`,
        [deviceId ?? null, grantExpiresAt ?? null, toIso(now), toIso(now), id],
      );
    },
  };
}

/** 顺带导出，方便调用方少 import 几行。 */
export { addMinutesIso, addDays, nowIso };
