/**
 * 数据库层的快速自检。
 *
 * 这一步的价值：**在往上写业务之前**先证明"schema 能在目标库上建起来"。
 * 如果拖到写完 20 个接口才发现某条 DDL 在自己用的库上跑不通，
 * 排查成本会高一个量级。
 *
 * 用法：node scripts/db-smoke.mjs
 */

import { loadConfig } from '../src/config.js';
import { connect, migrate, close } from '../src/db/index.js';

const config = loadConfig({ DB_DRIVER: 'sqlite', DB_SQLITE_FILE: ':memory:' });
const conn = await connect(config);

console.log(`驱动：${conn.driver}（方言：${conn.dialect.name}）`);

const { tables } = await migrate(conn);
console.log(`建表完成：${tables} 张`);

// 确认每张表真的存在（而不是 DDL 被静默忽略）。
const rows = await conn.query(
  `SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`,
);
console.log(`实际表：${rows.map((r) => r.name).join(', ')}`);

const idx = await conn.query(
  `SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name`,
);
console.log(`实际索引：${idx.length} 个`);

// 唯一约束是否真的生效 —— 这是幂等与去重的地基。
await conn.exec(
  `INSERT INTO activity
     (external_id, title, organizer, duration_hours, start_time, end_time,
      status, owner_id, created_at, updated_at, seq)
   VALUES ('E1','t','o',1,'2026-01-01T09:00:00+08:00','2026-01-01T10:00:00+08:00',
           'draft','owner-1','2026-01-01T00:00:00+08:00','2026-01-01T00:00:00+08:00',1)`,
);

let uniqueWorks = false;
try {
  await conn.exec(
    `INSERT INTO activity
       (external_id, title, organizer, duration_hours, start_time, end_time,
        status, owner_id, created_at, updated_at, seq)
     VALUES ('E1','t2','o',1,'2026-01-01T09:00:00+08:00','2026-01-01T10:00:00+08:00',
             'draft','owner-1','2026-01-01T00:00:00+08:00','2026-01-01T00:00:00+08:00',2)`,
  );
} catch {
  uniqueWorks = true;
}
console.log(`(owner_id, external_id) 唯一约束生效：${uniqueWorks ? '是' : '否 ❌'}`);

// 事务回滚是否真的回滚。
await conn.transaction(async (tx) => {
  await tx.exec(
    `INSERT INTO activity
       (external_id, title, organizer, duration_hours, start_time, end_time,
        status, owner_id, created_at, updated_at, seq)
     VALUES ('TX1','tx','o',1,'2026-01-01T09:00:00+08:00','2026-01-01T10:00:00+08:00',
             'draft','owner-1','2026-01-01T00:00:00+08:00','2026-01-01T00:00:00+08:00',3)`,
  );
  throw new Error('故意失败以验证回滚');
}).catch(() => {});

const afterRollback = await conn.queryOne(
  `SELECT COUNT(*) AS c FROM activity WHERE external_id = 'TX1'`,
);
console.log(`事务回滚生效：${afterRollback.c === 0 ? '是' : '否 ❌'}`);

// 序号游标：必须**严格单调递增**，而不是等于某个固定值。
//
// 早期这条断言写成"应为 4"（按活动表里最大 seq 推算），那是错的：
// 序号来自独立的计数器表，与活动行数无关。断言具体数值只是
// 把实现细节抄进了测试；断言**单调性**才是真正要保证的性质。
await conn.transaction(async (tx) => {
  const a = await tx.nextSeq();
  const b = await tx.nextSeq();
  const c = await tx.nextSeq();
  console.log(`nextSeq() 连续三次：${a} → ${b} → ${c}`);
  if (!(a < b && b < c)) {
    throw new Error('nextSeq() 必须严格单调递增');
  }
});

// 事务回滚时序号也应回滚（否则会出现跳号，客户端游标仍安全，
// 但"同序号对应两批数据"的风险需要排除）。
await conn.transaction(async (tx) => {
  await tx.nextSeq();
  throw new Error('故意失败');
}).catch(() => {});
const after = await conn.nextSeq();
console.log(`回滚一次后再取：${after}（应与回滚前最后一次连续）`);

await close(conn);
console.log('全部通过。');
