#!/usr/bin/env node
/**
 * 清理业务数据，只留下**两个展示用活动**。
 *
 * ## 用途
 *
 * 演示/验收前把"测试造的活动、签到、名单"清干净，避免验收者在列表里
 * 看到一堆 `抽查验证A`、`历史记录验证 B` 之类的残留。
 *
 * 留下的是 `seedShowcaseData` 那两条：
 *   1. **进行中** 图书馆书架整理志愿服务（4 人名单 + 2 条签到 + 1 条在岗抽查）
 *   2. **已发布** 社区敬老院陪伴服务（3 天后开始）
 *
 * ## 会清掉什么
 *
 * 所有业务表（活动、名单、签到、在岗任务、邀请码、授权、会话、审计、变更记录）
 * 与自增序号。**不会**动 `.env` 或 `TOKEN_SECRET`。
 *
 * ## 用法
 *
 * ```bash
 * # 默认清服务端的库（server/data/volunteer.db）
 * node scripts/reset-demo.mjs
 *
 * # 指定库文件
 * DB_SQLITE_FILE=/path/to/volunteer.db node scripts/reset-demo.mjs
 * ```
 *
 * ⚠️ 只能在**服务已停止**时运行：SQLite 单文件，两个进程同时写会互相干扰。
 */

import { loadConfig } from '../src/config.js';
import { connect, migrate, close } from '../src/db/index.js';
import { activityRepo } from '../src/stores/activity.js';
import { seedShowcaseData } from '../src/seed/demo.js';

const config = loadConfig({ DB_DRIVER: process.env.DB_DRIVER ?? 'sqlite' });

/** 按"先子表后主表"的顺序清空，避免外键（若启用）报错。 */
const TABLES_IN_ORDER = [
  'attendance_task',
  'checkin',
  'invite_code',
  'activity_grant',
  'change_log',
  'export_audit',
  'login_audit',
  'admin_session',
  'participant',
  'activity',
];

const main = async () => {
  console.log('');
  console.log('  清理业务数据（保留 2 个展示活动）');
  console.log(`  数据库：${config.db.sqliteFile ?? '(mysql)'}`);
  console.log('');

  const db = await connect(config);
  await migrate(db);

  const repos = { activities: activityRepo(db) };

  console.log('  清空旧数据：');
  for (const table of TABLES_IN_ORDER) {
    try {
      const before = await db.queryOne(`SELECT COUNT(*) AS n FROM ${table}`);
      await db.execute(`DELETE FROM ${table}`);
      console.log(`    ${table.padEnd(16)} 删除 ${before?.n ?? 0} 条`);
    } catch (e) {
      // 表不存在就跳过（不同版本表结构可能少几张）
      console.log(`    ${table.padEnd(16)} 跳过（${e.message}）`);
    }
  }
  // 序号游标归零，避免新活动带着很大的 seq 影响增量同步的"看起来像旧的"
  try {
    await db.execute('UPDATE seq_counter SET value = 0 WHERE id = 1');
    console.log('    seq_counter      归零');
  } catch {
    // 没有这张表就算了
  }

  console.log('');
  console.log('  写入展示数据：');
  const result = await seedShowcaseData(repos, db, (m) => console.log(`    ${m}`));

  if (result.skipped) {
    console.log('    （跳过：库里还检测到活动）');
  }

  console.log('');
  const list = await repos.activities.search({ page: 1, size: 50, includeExpired: true });
  console.log(`  当前活动共 ${list.total} 个：`);
  for (const a of list.items) {
    console.log(`    #${a.id}  ${a.title}  [${a.status}]`);
  }
  console.log('');
  console.log('  完成。启动服务后：');
  console.log('    网页      http://127.0.0.1:8080/');
  console.log('    管理端    邀请码 1111');
  console.log('');

  await close(db);
};

main().catch((e) => {
  console.error('清理失败：', e);
  process.exitCode = 1;
});
