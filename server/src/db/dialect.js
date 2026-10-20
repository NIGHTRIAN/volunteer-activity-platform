/**
 * SQL 方言 —— 让同一份 schema 跑在 SQLite（开发）与 MySQL（生产）上。
 *
 * ## 为什么不用 ORM
 *
 * 方案 §3 对数据库的要求是 "MySQL 5.7/8.0，utf8mb4"，
 * 而本机（开发环境）没有 Docker 也没有 MySQL。
 * 如果引入 ORM，就得同时承担"ORM 的方言差异"与"两套驱动的行为差异"，
 * 出问题时很难判断是哪一层。
 *
 * 这里只做**最小必要的方言抽象**：类型与少量语法。
 * 查询语句本身两边基本一致，业务代码不必知道用的是哪个库。
 *
 * ## 时间一律存 ISO 8601 字符串
 *
 * 不依赖数据库的时区设置。理由：方案 §8.3 要求服务器时区为
 * `Asia/Shanghai` 且 NTP 必须启用 —— 也就是说**时区可能配错**。
 * 而签到窗口与在岗响应窗口都是时间敏感的，时区错了会集体偏移。
 * 存字符串 + 应用层统一解析，就把这个风险从"静默错判"降为"一眼可见"。
 */

/**
 * SQLite 方言。
 *
 * 用 `node:sqlite`（Node 22+ 内置）—— **零外部依赖**。
 * 这一点对本项目很重要：开发者在任何一台装了 Node 的机器上
 * clone 下来就能跑，不需要 Docker、不需要装 MySQL、不需要编译原生模块。
 */
export function sqliteDialect() {
  return {
    name: 'sqlite',

    /** 主键自增。 */
    pk: () => 'INTEGER PRIMARY KEY AUTOINCREMENT',
    bigint: () => 'INTEGER',
    int: () => 'INTEGER',
    intNull: () => 'INTEGER',
    decimal: () => 'REAL',
    bool: () => 'INTEGER',
    dt: () => 'TEXT',
    dtNull: () => 'TEXT',
    /** 定长字符串在 SQLite 里没有长度语义，但保留长度便于对照与将来迁移。 */
    str: (n) => `TEXT /* ≤${n} */`,
    text: () => 'TEXT',

    /** SQLite 不支持在 CREATE TABLE 里写 UNIQUE INDEX 子句，返回空串占位。 */
    uniqueIndexInline: () => '',

    /**
     * 占位符：SQLite 用 `?`。
     * MySQL 用 `?` 也一样，因此两边写法统一（这里保留方法是为了将来可能的差异）。
     */
    placeholder: () => '?',

    /** 批量插入时的自增主键回填方式（SQLite 用 last_insert_rowid()）。 */
    lastInsertIdSql: () => 'SELECT last_insert_rowid() AS id',
  };
}

/**
 * MySQL 方言。
 *
 * ⚠️ 本机**没有 MySQL 环境**，因此这一支的 DDL 与查询
 * **未经真实数据库验证**（见 docs/web-server.md 的说明）。
 * 代码结构上已经打通，但首次在有 MySQL 的机器上部署时
 * 必须先跑一遍迁移并跑全部测试。
 */
export function mysqlDialect() {
  return {
    name: 'mysql',

    pk: () => 'BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY',
    bigint: () => 'BIGINT',
    int: () => 'INT',
    intNull: () => 'INT NULL',
    decimal: () => 'DECIMAL(12,6)',
    bool: () => 'TINYINT(1)',
    dt: () => 'DATETIME(3)',
    dtNull: () => 'DATETIME(3) NULL',
    str: (n) => `VARCHAR(${n})`,
    text: () => 'TEXT',

    /**
     * MySQL 支持表内 UNIQUE KEY，但我们的建表语句是把索引单独发的
     * （见 schema.js 的 INDEXES），因此这里也返回空串，保持两边结构一致。
     */
    uniqueIndexInline: () => '',

    placeholder: () => '?',
    lastInsertIdSql: () => 'SELECT LAST_INSERT_ID() AS id',
  };
}

/** 按驱动名取方言。 */
export function dialectFor(driver) {
  switch (driver) {
    case 'sqlite':
      return sqliteDialect();
    case 'mysql':
      return mysqlDialect();
    default:
      throw new Error(`未知的数据库驱动：${driver}`);
  }
}

/**
 * UNIQUE 约束索引。
 *
 * 两边的 `CREATE TABLE` 都不写表内 UNIQUE（原因见上），
 * 因此唯一性必须在这里以独立索引的形式补上，
 * 否则**幂等与去重会静默失效** —— 那是最难发现的一类 bug。
 */
export function uniqueIndexes() {
  return [
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_activity_external
       ON activity (owner_id, external_id)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_participant
       ON participant (activity_id, user_no)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_invite_code
       ON invite_code (activity_id, user_no)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_attendance_task
       ON attendance_task (activity_id, user_no, seq)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_idempotency
       ON idempotency (scope, key_value)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_grant_token
       ON activity_grant (token)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_admin_token
       ON admin_session (token)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS uq_rule_revision
       ON rule_snapshot (activity_id, revision)`,
  ];
}
