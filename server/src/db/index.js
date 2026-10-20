/**
 * 数据库连接层 —— 存储抽象。
 *
 * ## 为什么接口是 `async`，而 SQLite 其实是同步的
 *
 * `node:sqlite` 的 `DatabaseSync` 是**同步** API，包成 `async` 会有一点点
 * 额外的微任务开销。但这是刻意的：MySQL 驱动必然是异步的。
 * 如果 SQLite 版本写成同步、调用方也按同步写，那么将来切 MySQL 时
 * **所有业务代码都要改**——那正好违背方案 §8.1「换配置即生效、不改代码」。
 *
 * 用 `async` 把差异挡在这一层，业务代码两边一致。
 *
 * ## 事务
 *
 * 提供 `transaction(fn)`：把一组写操作包在一个事务里。
 * 只提供 `BEGIN` / `COMMIT` / `ROLLBACK` 三种显式语句 —— 不做嵌套事务的
 * 保存点管理，因为本项目没有嵌套写的场景，加了反而增加出错面。
 */

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

import { dialectFor, uniqueIndexes } from './dialect.js';
import { TABLES, INDEXES, COLUMN_ADDITIONS } from './schema.js';

const require = createRequire(import.meta.url);

/**
 * 打开 SQLite 数据库（`node:sqlite`，零外部依赖）。
 *
 * @param {string} file 数据文件路径；`:memory:` 表示内存库（测试用）。
 */
function openSqlite(file) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = require('node:sqlite'));
  } catch (e) {
    throw new Error(
      '当前 Node 不支持内置的 node:sqlite（需要 Node 22+）。' +
        '请升级 Node，或改用 DB_DRIVER=mysql。原始错误：' +
        e.message,
    );
  }

  if (file !== ':memory:') {
    fs.mkdirSync(path.dirname(file), { recursive: true });
  }

  const db = new DatabaseSync(file);
  // 外键约束：SQLite 默认**关闭**，不开的话引用完整性形同虚设。
  db.exec('PRAGMA foreign_keys = ON');
  // WAL 模式：读写并发更好（一边有请求在写，另一边仍能查）。
  if (file !== ':memory:') {
    db.exec('PRAGMA journal_mode = WAL');
  }

  return {
    driver: 'sqlite',
    dialect: dialectFor('sqlite'),
    db,
    async query(sql, params = []) {
      return db.prepare(sql).all(...params);
    },
    async queryOne(sql, params = []) {
      return db.prepare(sql).get(...params) ?? null;
    },
    async execute(sql, params = []) {
      const r = db.prepare(sql).run(...params);
      return { changes: Number(r.changes ?? 0), lastInsertId: Number(r.lastInsertRowid ?? 0) };
    },
    async exec(sql) {
      db.exec(sql);
    },
    async close() {
      db.close();
    },
  };
}

/**
 * 打开 MySQL 连接池。
 *
 * ⚠️ 本机没有 MySQL 环境，因此这一支**未经真实数据库验证**。
 * 代码结构已打通，首次在有 MySQL 的机器上部署时必须：
 *   1. 先跑迁移（`npm run migrate`）；
 *   2. 跑全部测试（`npm test`，用 DB_DRIVER=mysql）。
 * 详见 docs/web-server.md。
 */
async function openMysql(cfg) {
  let mysql;
  try {
    // 动态导入：没装 mysql2 时不应影响 sqlite 路径。
    mysql = await import('mysql2/promise');
  } catch (e) {
    throw new Error(
      'DB_DRIVER=mysql 需要 mysql2 依赖，但它没有安装。' +
        '请执行：npm install mysql2。原始错误：' +
        e.message,
    );
  }

  // 方案 §3：MySQL 5.7/8.0，utf8mb4。
  const pool = mysql.createPool({
    host: cfg.host,
    port: cfg.port,
    user: cfg.user,
    password: cfg.password,
    database: cfg.database,
    waitForConnections: true,
    connectionLimit: cfg.connectionLimit,
    charset: 'utf8mb4',
    // 时间由应用层以 ISO 字符串写入，不让驱动做时区转换。
    timezone: 'Z',
    dateStrings: true,
  });

  return {
    driver: 'mysql',
    dialect: dialectFor('mysql'),
    pool,
    async query(sql, params = []) {
      const [rows] = await pool.query(sql, params);
      return rows;
    },
    async queryOne(sql, params = []) {
      const [rows] = await pool.query(sql, params);
      return rows[0] ?? null;
    },
    async execute(sql, params = []) {
      const [r] = await pool.query(sql, params);
      return {
        changes: Number(r.affectedRows ?? 0),
        lastInsertId: Number(r.insertId ?? 0),
      };
    },
    async exec(sql) {
      await pool.query(sql);
    },
    async close() {
      await pool.end();
    },
  };
}

/**
 * 建立连接。
 *
 * @param {ReturnType<import('../config.js').loadConfig>} config
 */
export async function connect(config) {
  const conn = config.db.driver === 'mysql'
    ? await openMysql(config.db)
    : openSqlite(config.db.sqliteFile);

  return wrapWithHelpers(conn);
}

/** 加上事务与便捷方法。 */
function wrapWithHelpers(conn) {
  let txDepth = 0;

  return {
    ...conn,

    /**
     * 在一个事务里执行 `fn`。
     *
     * 只支持一层：进入时若已在事务里，直接执行 `fn` 而不开新事务
     * （避免保存点管理的复杂度）。本项目没有嵌套写的场景。
     *
     * `fn` 抛异常 → 回滚，异常继续向上抛（调用方据此返回 5xx/4xx）。
     */
    async transaction(fn) {
      if (txDepth > 0) {
        return fn(this);
      }
      txDepth += 1;
      await conn.exec('BEGIN');
      try {
        const result = await fn(this);
        await conn.exec('COMMIT');
        return result;
      } catch (e) {
        try {
          await conn.exec('ROLLBACK');
        } catch {
          // 回滚本身失败（例如连接已断）时不要掩盖原始异常。
        }
        throw e;
      } finally {
        txDepth -= 1;
      }
    },

    /**
     * 取下一个全局序号 —— **增量同步的游标**。
     *
     * ⚠️ 为什么用序号而不是时间戳：实测踩到过。同一毫秒内可以发生多次写入
     * （种子数据一次写入 5 个活动，时间戳完全相同），于是
     * `updated_at > cursor` 要么漏掉同毫秒的记录、要么为了不漏而整体回退，
     * 后者会让那批记录被反复下发。**时间戳不构成全序，不能当游标。**
     *
     * 实现是单行计数器表的就地自增。**必须在 `transaction()` 里调用** ——
     * 这样序号与业务写入同属一个事务：事务回滚时序号也回滚，
     * 不会出现"序号跳号"或"两批数据共用同一序号"。
     */
    async nextSeq() {
      // 确保计数器行存在（幂等）。
      //
      // 用 `ON CONFLICT DO NOTHING` 而不是 SQLite 专有的 `INSERT OR IGNORE`：
      // SQLite 3.24+ 与 MySQL 8.0+ 都支持这个标准写法，
      // 而 `INSERT OR IGNORE` 在 MySQL 上会直接语法错误 ——
      // 那意味着"换驱动即失效"，正是 §8.1 要避免的。
      await conn.exec(
        'INSERT INTO seq_counter (id, value) VALUES (1, 0) ON CONFLICT (id) DO NOTHING',
      );
      await conn.exec('UPDATE seq_counter SET value = value + 1 WHERE id = 1');
      const row = await conn.queryOne('SELECT value FROM seq_counter WHERE id = 1');
      return Number(row?.value ?? 1);
    },
  };
}

/**
 * 建表与索引（幂等，可重复执行）。
 *
 * ## ⚠️ 索引必须用"容忍已存在"的写法，不能依赖 IF NOT EXISTS
 *
 * `CREATE TABLE IF NOT EXISTS` 两边都支持，所以建表可以照写。
 * 但**`CREATE INDEX IF NOT EXISTS` 是 SQLite 扩展，MySQL 不支持** ——
 * 在 MySQL 上执行会直接语法错误。
 *
 * 这曾经是个真 bug：迁移脚本第二次执行时（容器每次启动都会跑一次）
 * 会在 MySQL 上崩掉，而 SQLite 上完全正常 —— 也就是说
 * "本机测得好好的，一上生产就起不来"。
 *
 * 处置：先查已存在的索引名，跳过它们；再对剩下的执行普通
 * `CREATE INDEX`。这样两边都不依赖方言扩展，且重复执行安全。
 *
 * ## 关于将来的表结构变更
 *
 * `CREATE TABLE IF NOT EXISTS` **不会**修改已存在的表结构。
 * 所以"加一列"这类变更必须走真正的版本化迁移
 * （`migrations/00X_*.sql` + `schema_migrations` 表）。
 * 第一次需要时不要偷懒 —— 直接上版本化迁移。
 */
export async function migrate(conn) {
  const d = conn.dialect;

  // 1) 建表（幂等，两边都支持 IF NOT EXISTS）。
  for (const [name, ddl] of Object.entries(TABLES)) {
    await conn.exec(ddl(d));
    void name;
  }

  /*
    1.5) 增量列：老库补列（幂等）。

    `CREATE TABLE IF NOT EXISTS` 对已存在的表不做任何事，
    所以后加的列必须单独 ALTER，否则老库会一直缺列，
    报错是运行时的 "no such column"，很难联想到"迁移没做"。
  */
  await applyColumnAdditions(conn);

  // 2) 查出已存在的索引名，稍后跳过。
  const existing = await existingIndexNames(conn);

  // 3) 建索引。UNIQUE 约束的索引也在这里建 —— 它们是幂等与去重的地基，
  //    不能因为"已经存在"就跳过不检查。
  let created = 0;
  for (const sql of [...uniqueIndexes(), ...INDEXES]) {
    const name = indexNameOf(sql);
    if (name && existing.has(name)) {
      continue;
    }
    await conn.exec(sql);
    created += 1;
  }

  return { tables: Object.keys(TABLES).length, indexesCreated: created };
}

/** 从 `CREATE [UNIQUE] INDEX [IF NOT EXISTS] name ON ...` 里取出索引名。 */
function indexNameOf(sql) {
  const m = /CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w$]+)/i.exec(sql);
  return m ? m[1] : null;
}

/** 各驱动下已有的索引名集合。 */
async function existingIndexNames(conn) {
  const names = new Set();
  try {
    if (conn.driver === 'sqlite') {
      const rows = await conn.query(
        `SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'`,
      );
      for (const r of rows) {
        names.add(r.name);
      }
    } else {
      // MySQL：按当前库过滤。用 table_schema = DATABASE() 避免拿到别的库。
      const rows = await conn.query(
        `SELECT DISTINCT index_name AS name FROM information_schema.statistics
          WHERE table_schema = DATABASE()`,
      );
      for (const r of rows) {
        names.add(r.name);
      }
    }
  } catch {
    /*
      查不到已存在索引时**不能**直接失败：那会把"能跑"变成"跑不了"。
      退化为"全部尝试创建"，由驱动报错暴露真实问题。
      对 SQLite 来说查 sqlite_master 几乎不可能失败，
      这一支主要是给权限受限的 MySQL 账号留的余地。
    */
    return new Set();
  }
  return names;
}

/** 关闭连接（供优雅退出用）。 */
export async function close(conn) {
  if (conn && typeof conn.close === 'function') {
    await conn.close();
  }
}

/**
 * 幂等地补齐增量列。
 *
 * 先查目标表已有的列，只对缺失的列执行 `ALTER TABLE ... ADD COLUMN`。
 * SQLite 与 MySQL 的列信息查询方式不同，分别处理。
 */
async function applyColumnAdditions(conn) {
  const d = conn.dialect;
  /** @type {Map<string, Set<string>>} */
  const known = new Map();

  const columnsOf = async (table) => {
    if (known.has(table)) {
      return known.get(table);
    }
    const set = new Set();
    try {
      if (conn.driver === 'sqlite') {
        const rows = await conn.query(`PRAGMA table_info(${table})`);
        for (const r of rows) {
          set.add(String(r.name));
        }
      } else {
        const rows = await conn.query(
          `SELECT column_name AS name FROM information_schema.columns
            WHERE table_schema = DATABASE() AND table_name = ?`,
          [table],
        );
        for (const r of rows) {
          set.add(String(r.name));
        }
      }
    } catch {
      /*
        查不到列信息时**不能直接失败**：那会把"能用"变成"起不来"。
        退化为"尝试执行 ALTER"，由驱动的"列已存在"报错暴露真实状态；
        这里吞掉该错误（ALREADY EXISTS 是幂等的正常情况）。
      */
    }
    known.set(table, set);
    return set;
  };

  for (const item of COLUMN_ADDITIONS) {
    const cols = await columnsOf(item.table);
    if (cols.has(item.column)) {
      continue;
    }
    try {
      await conn.exec(item.ddl(d));
    } catch (e) {
      // 并发启动两个进程时可能都被判定为缺列，其中一个会失败；
      // 列已存在属于正常情况，忽略。
      if (!/duplicate|already exists|exists/i.test(String(e?.message ?? ''))) {
        throw e;
      }
    }
  }
}