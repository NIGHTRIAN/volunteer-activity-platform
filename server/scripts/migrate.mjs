/**
 * 迁移脚本。
 *
 * 用法：
 *   node scripts/migrate.mjs            # 按当前配置建表
 *   DB_DRIVER=mysql node scripts/migrate.mjs
 *
 * ⚠️ 当前的"迁移"是幂等的建表（`CREATE TABLE IF NOT EXISTS`）。
 * 它**不会修改已存在的表结构** —— 所以"加一列"这类变更必须走
 * 版本化迁移文件。第一次需要时不要偷懒，直接上 `migrations/00X_*.sql`
 * 与 `schema_migrations` 表（见 src/db/index.js 的说明）。
 */

import { loadConfig, validateConfig } from '../src/config.js';
import { connect, migrate, close } from '../src/db/index.js';
import { createLogger } from '../src/logger.js';

const config = loadConfig();
const logger = createLogger({ level: config.logLevel });

const problems = validateConfig(config);
if (problems.length > 0) {
  logger.error('配置有误，已中止迁移');
  for (const p of problems) {
    logger.error(`  - ${p}`);
  }
  process.exit(1);
}

logger.info(`迁移目标：${config.db.driver}`);
if (config.db.driver === 'sqlite') {
  logger.info(`  数据文件：${config.db.sqliteFile}`);
} else {
  logger.info(`  数据库：${config.db.host}:${config.db.port}/${config.db.database}`);
}

const conn = await connect(config);
try {
  const { tables } = await migrate(conn);
  logger.info(`迁移完成：${tables} 张表`);

  // 打印实际存在的表，证明 DDL 真的生效（而不是被静默忽略）。
  const rows = await conn.query(
    conn.driver === 'sqlite'
      ? `SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`
      : `SELECT table_name AS name FROM information_schema.tables WHERE table_schema = ? ORDER BY table_name`,
    conn.driver === 'sqlite' ? [] : [config.db.database],
  );
  logger.info(`实际表：${rows.map((r) => r.name).join(', ')}`);
} catch (e) {
  logger.error('迁移失败', e);
  process.exitCode = 1;
} finally {
  await close(conn);
}
