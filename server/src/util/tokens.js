/**
 * 令牌生成与常量。
 *
 * ## 为什么用**不透明随机令牌**而不是 JWT
 *
 * JWT 的好处是无状态、不需要查库；代价是**无法撤销**。
 * 这套系统有两个必须能撤销的场景：
 *
 *   * 管理端重新登录时，旧令牌必须立刻失效
 *     （否则手机上留着的旧令牌还能改数据）；
 *   * 发布者把某个志愿者移出名单时，那个人的活动授权必须立刻失效。
 *
 * 而 schema 里已经为 `admin_session.token` / `activity_grant.token`
 * 建了索引 —— 本就是按"可查库校验的不透明令牌"设计的。
 *
 * 所以这里用 `crypto.randomBytes(32)` 生成 64 位十六进制串：
 * 熵足够（256 bit），不可猜测，且撤销只需一行 UPDATE/DELETE。
 */

import { randomBytes } from 'node:crypto';

/** 生成一个令牌。 */
export function newToken() {
  return randomBytes(32).toString('hex');
}

/**
 * 生成邀请码。
 *
 * 用 `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` —— 去掉了容易看混的
 * `I / O / 0 / 1`。邀请码是要**口头或手抄**给志愿者的，
 * 形近字符会直接造成"码对不上"的客诉。
 */
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/** 生成一个 8 位邀请码。 */
export function newInviteCode(length = 8) {
  const bytes = randomBytes(length);
  let out = '';
  for (let i = 0; i < length; i += 1) {
    out += CODE_ALPHABET[bytes[i] % CODE_ALPHABET.length];
  }
  return out;
}

/** 管理端令牌种类标识（放进 ctx.auth.kind）。 */
export const AUTH_KIND = Object.freeze({
  admin: 'admin',
  volunteer: 'volunteer',
  anonymous: 'anonymous',
});
