/**
 * 演示用固定邀请码。
 *
 * 为什么不用随机码：验收用例与文档需要「照着操作就能复现」。
 * 随机码只适合真实签发（见 api_participants.js 的 generateInviteCode）。
 *
 * ⚠️ 这些码**只出现在种子数据里**，真实签发永远走随机路径。
 */

/** 学号 → 固定演示邀请码。 */
const SEED_CODES = {
  '2021001': 'K7M2P9QX',
  '2021002': 'R4T8W3NY',
};

/** 取演示码；未登记的学号用一个确定性派生的码，保证可复现。 */
export function codeForSeed(userNo) {
  if (SEED_CODES[userNo]) {
    return SEED_CODES[userNo];
  }
  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  let hash = 0;
  for (const ch of String(userNo)) {
    hash = (hash * 31 + ch.charCodeAt(0)) % 2147483647;
  }
  let out = '';
  for (let i = 0; i < 8; i++) {
    out += alphabet[hash % alphabet.length];
    hash = Math.floor(hash / alphabet.length) + 7 * (i + 1);
  }
  return out;
}
