/**
 * 写入演示数据。
 *
 * 用法：
 *   node scripts/seed.mjs          # 只在空库时写入
 *   FORCE=1 node scripts/seed.mjs  # 强制写入（会追加，不清理）
 */

import { loadConfig } from '../src/config.js';
import { connect, migrate, close } from '../src/db/index.js';
import { activityRepo } from '../src/stores/activity.js';
import { seedDemoData } from '../src/seed/demo.js';
import { createLogger } from '../src/logger.js';

const config = loadConfig();
const logger = createLogger({ level: config.logLevel });

const conn = await connect(config);
await migrate(conn);

const repos = { activities: activityRepo(conn) };

try {
  const result = await seedDemoData(repos, (m) => logger.info(m));

  const all = await repos.activities.search({ page: 1, size: 100, includeExpired: true });
  const visible = await repos.activities.search({ page: 1, size: 100 });
  const hidden = all.total - visible.total;
  logger.info(`库中活动：共 ${all.total} 条，未过留存期 ${visible.total} 条，已隐藏 ${hidden} 条`);
  // 演示数据里有 2 条刻意超过 7 天留存期（提前结束的与一个月前的），
  // 用来验证"终态 +7 天不可访问"确实生效。差额不等于 2 就说明
  // 留存期的过滤逻辑有问题 —— 这是这条日志真正在断言的东西。
  if (hidden !== 2) {
    logger.warn(
      `预期有 2 条被留存期隐藏，实际 ${hidden} 条。` +
        '请检查 isExpired / search 的留存期过滤（终态 + 7 天）。',
    );
  }
  logger.info(
    '按状态：' +
      Object.entries(
        visible.items.reduce((acc, a) => {
          acc[a.status] = (acc[a.status] ?? 0) + 1;
          return acc;
        }, {}),
      )
        .map(([k, v]) => `${k}=${v}`)
        .join(' '),
  );
  process.exitCode = result.skipped ? 0 : 0;
} catch (e) {
  logger.error('写入演示数据失败', e);
  process.exitCode = 1;
} finally {
  await close(conn);
}
