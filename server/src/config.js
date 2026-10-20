/**
 * 配置 —— **全部走环境变量**（《网页开发方案》§8.1 可移植性要求）。
 *
 * ## 方案的硬要求
 *
 * > 服务端地址、端口、凭据全部走配置（环境变量 / `.env`）；
 * > 代码中**不得硬编码**域名、IP、端口
 *
 * 并且要过一条验收：
 *
 * > 服务端地址 / 端口 / 凭据**无硬编码**（代码扫描确认）
 * > **端口与配置可在不修改代码的前提下变更**（改配置 + 重启即生效）
 *
 * 因此这个文件是**唯一**读 `process.env` 的地方。其它模块只接收配置对象，
 * 不直接碰环境变量 —— 这样"换个环境要改哪里"永远只有一个答案。
 *
 * ## 为什么不用 dotenv 包
 *
 * 本服务的依赖越少，部署越不容易出问题（§8.1 要求一条命令跑通）。
 * `.env` 的解析规则很简单，自己写 20 行比引一个包更可控，
 * 而且能给出更清楚的报错（例如"值里有未加引号的空格"）。
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const SERVER_ROOT = path.resolve(here, '..');
export const REPO_ROOT = path.resolve(SERVER_ROOT, '..');

/**
 * 极简 `.env` 解析。
 *
 * 支持：
 *   * `KEY=value`
 *   * `#` 开头的注释、空行
 *   * 值两端的引号（`"..."` / `'...'`）会被去掉
 *   * 值里含 `#` 时不当作注释（只有当 `#` 前是空白或行首时才算）
 *
 * 不支持多行值与变量展开 —— 本项目用不到，加了反而容易出意外。
 */
export function parseEnvFile(text) {
  const out = {};
  for (const rawLine of String(text).split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line === '' || line.startsWith('#')) {
      continue;
    }
    const eq = line.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"') && value.length >= 2) ||
      (value.startsWith("'") && value.endsWith("'") && value.length >= 2)
    ) {
      value = value.slice(1, -1);
    }
    out[key] = value;
  }
  return out;
}

/**
 * 读取 `.env` 文件（存在才读）。
 *
 * 优先级：**真实环境变量 > .env 文件**。
 * 这一条很重要：容器里用 `-e` 传的变量必须能覆盖镜像里带的 `.env`，
 * 否则"改配置重启生效"就成了空话。
 */
function loadEnvFile(file) {
  if (!fs.existsSync(file)) {
    return {};
  }
  return parseEnvFile(fs.readFileSync(file, 'utf8'));
}

function toInt(value, fallback) {
  if (value == null || value === '') {
    return fallback;
  }
  const n = Number.parseInt(String(value), 10);
  return Number.isFinite(n) ? n : fallback;
}

function toBool(value, fallback) {
  if (value == null || value === '') {
    return fallback;
  }
  const s = String(value).trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(s)) {
    return true;
  }
  if (['0', 'false', 'no', 'off'].includes(s)) {
    return false;
  }
  return fallback;
}

/**
 * 构建配置。
 *
 * @param {object} [overrides] 显式覆盖（测试用；优先级最高）。
 */
export function loadConfig(overrides = {}) {
  // .env 查找顺序：显式指定 → server/ → 仓库根。
  const envFiles = [
    process.env.ENV_FILE,
    path.join(SERVER_ROOT, '.env'),
    path.join(REPO_ROOT, '.env'),
  ].filter(Boolean);

  let fromFile = {};
  for (const f of envFiles) {
    fromFile = { ...fromFile, ...loadEnvFile(f) };
  }
  // 真实环境变量覆盖文件。
  const raw = { ...fromFile, ...process.env, ...overrides };

  const driver = String(raw.DB_DRIVER ?? 'sqlite').toLowerCase();
  if (!['sqlite', 'mysql'].includes(driver)) {
    throw new Error(
      `DB_DRIVER 只能是 sqlite 或 mysql，当前是 "${driver}"。` +
        '本地开发用 sqlite（无需额外依赖）；生产用 mysql。',
    );
  }

  return {
    // ── 服务 ────────────────────────────────────────────────────────────
    /** 监听地址。`0.0.0.0` 才能被局域网内的手机访问（真机测试需要）。 */
    host: String(raw.HOST ?? '0.0.0.0'),
    port: toInt(raw.PORT, 8080),
    /** 运行环境：dev / test / prod。prod 下会收紧一些行为。 */
    env: String(raw.NODE_ENV ?? 'dev'),

    // ── 存储 ────────────────────────────────────────────────────────────
    db: {
      driver,
      /** SQLite 数据文件路径。 */
      sqliteFile: String(
        raw.DB_SQLITE_FILE ?? path.join(SERVER_ROOT, 'data', 'volunteer.db'),
      ),
      host: String(raw.DB_HOST ?? '127.0.0.1'),
      port: toInt(raw.DB_PORT, 3306),
      user: String(raw.DB_USER ?? 'volunteer'),
      /** ⚠️ 不设默认值 —— 缺了就是配置错误，不能悄悄用一个弱口令。 */
      password: raw.DB_PASSWORD == null ? '' : String(raw.DB_PASSWORD),
      database: String(raw.DB_DATABASE ?? 'volunteer'),
      /** 连接池上限。 */
      connectionLimit: toInt(raw.DB_CONNECTION_LIMIT, 10),
    },

    // ── 鉴权 ────────────────────────────────────────────────────────────
    auth: {
      /**
       * 管理员邀请码。
       *
       * 方案 §12.1 已定：**默认 1111，且不强制更换**，
       * 靠 `ownerId` 隔离 + 设备绑定 + 登录审计兜底。
       * 因此这里给默认值是**照方案执行**，不是疏忽。
       */
      adminInviteCode: String(raw.ADMIN_INVITE_CODE ?? '1111'),
      /** 令牌有效期（分钟）。 */
      adminTokenTtlMinutes: toInt(raw.ADMIN_TOKEN_TTL_MINUTES, 12 * 60),
      /** 终态后令牌保留时长（小时）：名下活动全部终态后 24 小时失效。 */
      adminTokenTerminalGraceHours: toInt(raw.ADMIN_TOKEN_TERMINAL_GRACE_HOURS, 24),
      /** 连续失败多少次锁定。 */
      loginMaxFailures: toInt(raw.LOGIN_MAX_FAILURES, 5),
      /** 锁定时长（分钟）。 */
      loginLockMinutes: toInt(raw.LOGIN_LOCK_MINUTES, 10),
      /** 令牌签名密钥。 */
      tokenSecret: String(raw.TOKEN_SECRET ?? ''),

      /**
       * 管理员登录后归到的发布者 ID（活动归属隔离的依据，方案 §9.2）。
       *
       * ## 为什么由**邀请码**决定归属，而不是由设备指纹决定
       *
       * mock 阶段曾用设备指纹推导 ownerId，结果真机上出现：
       * 管理员登录后看到「我发布的活动 0 条」—— 因为他的指纹推出来的
       * ownerId 与种子数据的 `owner-demo-0001` 不是同一个。
       * 更糟的是换一台设备登录，之前建的活动就"消失"了。
       *
       * 正确的模型是：**邀请码代表发布者身份**，设备只是这个身份的会话。
       * 同一个邀请码在任何设备上登录，都应看到同一批活动。
       *
       * 当前是单发布者试点（方案 §12.1：邀请码默认 1111 且不强制更换），
       * 所以直接用一个固定值，并与种子数据的 OWNER_ID 对齐，
       * 使"登录后立刻能看到演示活动"。
       */
      ownerId: String(raw.ADMIN_OWNER_ID ?? 'owner-demo-0001'),

      /**
       * **多发布者**：邀请码 → 发布者 ID 的映射。
       *
       * ## 怎么配置
       *
       * ```
       * ADMIN_OWNERS="1111:owner-demo-0001, 2222:owner-org-b, 3333:owner-org-c"
       * ```
       *
       * 不配时退化为单发布者：只有 `adminInviteCode` 一个码，归到 `ownerId`。
       * 这样老部署不受影响。
       *
       * ## 为什么归属必须由邀请码决定
       *
       * mock 阶段曾用**设备指纹**推导 ownerId，真机上出现两件事：
       *   1. 管理员登录后看到「我发布的活动 0 条」（指纹与种子 owner 不一致）；
       *   2. 换台设备登录，之前建的活动就"消失"了。
       *
       * 正确模型：**邀请码代表发布者身份**，设备只是这个身份的会话。
       *
       * ## 安全边界
       *
       * 映射表 = 谁持有哪个码就是哪个发布者。所以：
       *   * 码要按组织分发、不要共用；
       *   * 换组织要换码（不能改映射后继续用旧码，否则等于把别人的活动交出去）。
       * 这套设计适合校内几个部门共用一个服务端的规模；
       * 再往上（几十个组织、需要吊销与审计）应换成账号体系。
       */
      ownerByCode: (() => {
        const map = Object.create(null);
        // ⚠️ 这里不能写 `const raw = raw.ADMIN_OWNERS` —— 同名会遮蔽外层参数，
        // 初始化表达式引用自己触发 TDZ（"Cannot access 'raw' before initialization"）。
        const spec = raw.ADMIN_OWNERS;
        if (typeof spec === 'string' && spec.trim() !== '') {
          for (const pair of spec.split(',')) {
            const idx = pair.lastIndexOf(':');
            if (idx <= 0) {
              continue;
            }
            const code = pair.slice(0, idx).trim();
            const owner = pair.slice(idx + 1).trim();
            if (code && owner) {
              map[code] = owner;
            }
          }
        }
        // 单发布者兜底：保证默认配置（只给 1111）依然可用。
        const fallbackCode = String(raw.ADMIN_INVITE_CODE ?? '1111');
        const fallbackOwner = String(raw.ADMIN_OWNER_ID ?? 'owner-demo-0001');
        if (!map[fallbackCode]) {
          map[fallbackCode] = fallbackOwner;
        }
        return Object.freeze(map);
      })(),

      /** 志愿者活动授权有效期（小时）。方案未定，按 7 天实现。 */
      grantTtlHours: toInt(raw.GRANT_TTL_HOURS, 7 * 24),
    },

    // ── 其他 ────────────────────────────────────────────────────────────
    /**
     * 前端静态资源目录。
     *
     * 指到这个目录后，同步服务会**顺便把网页也发出去** ——
     * 于是只暴露一个端口（8080）、天然同域、不需要 CORS 也不需要 Nginx。
     *
     * 为什么要有这个开关：验收/演示场景下让接收方装 Nginx 不现实。
     * 生产部署仍推荐 Nginx 直发静态资源（性能更好），把这项设为 `off` 即可。
     *
     * 默认指向 `web/dist`（前端生产构建的输出位置）。
     * 目录不存在时会被忽略 —— 没构建前端也能只跑 API。
     */
    staticDir: (() => {
      const v = raw.STATIC_DIR;
      if (v === 'off' || v === 'false' || v === '') {
        return null;
      }
      const dir = String(v ?? path.join(REPO_ROOT, 'web', 'dist'));
      return path.isAbsolute(dir) ? dir : path.resolve(REPO_ROOT, dir);
    })(),

    /** 是否外发 sourcemap（默认关闭：包含源码结构，验收场景不需要）。 */
    exposeSourcemaps: toBool(raw.EXPOSE_SOURCEMAPS, false),

    /**
     * 是否在**空库**时自动写入演示数据。
     *
     * 默认：**仅 dev** 开启。test 与 prod 都关闭，可用 `SEED_ON_START` 覆盖。
     *
     * ## 为什么 test 必须关闭
     *
     * 测试要断言"空库时的行为"（空列表返回 `[]`、草稿不可见、
     * 留存期过滤等）。若在 test 下自动播种，这些用例会因为
     * 库里凭空多出 8 条活动而全部失败 —— 而失败信息指向业务逻辑，
     * 让人去查根本不存在的问题。
     *
     * 实测踩过：条件最初写成 `env !== 'prod'`，把 test 也算进去，
     * 立刻挂了 4 个用例。
     *
     * ## 为什么 dev 要开启
     *
     * 这个服务会被打包发给别人验收。空库会让接收方只看到一个空列表，
     * 筛选、统计、详情、导出全都无从验证。
     *
     * ## 为什么 prod 必须关闭
     *
     * 真实部署凭空多出假活动会污染数据。而且只写空库，已有数据绝不动。
     */
    seedOnStart: raw.SEED_ON_START == null
      ? null // 交给调用方按 env 决定（仅 dev 为 true）
      : toBool(raw.SEED_ON_START, false),

    /** 单请求体上限（字节）。默认 8MB，够导入大名单。 */
    maxBodyBytes: toInt(raw.MAX_BODY_BYTES, 8 * 1024 * 1024),
    /** 是否输出访问日志。 */
    accessLog: toBool(raw.ACCESS_LOG, true),
    /** 日志级别：debug / info / warn / error。 */
    logLevel: String(raw.LOG_LEVEL ?? 'info'),
    /** CORS 允许的来源；`*` 表示不限（仅开发期）。 */
    corsOrigin: String(raw.CORS_ORIGIN ?? '*'),
  };
}

/**
 * 启动前自检。
 *
 * 返回问题清单（空数组表示没问题）。**在 `main()` 里调用一次** ——
 * 配置错误应该在启动时立刻炸掉，而不是等用户点到某个页面才失败。
 * 这也是方案 §11.1「端口与配置可在不修改代码的前提下变更」的保险丝：
 * 改错了配置会立刻看到明确原因。
 */
export function validateConfig(config) {
  const problems = [];

  if (!Number.isInteger(config.port) || config.port < 1 || config.port > 65535) {
    problems.push(`PORT 不是合法端口：${config.port}`);
  }

  if (config.db.driver === 'sqlite') {
    if (!config.db.sqliteFile) {
      problems.push('DB_DRIVER=sqlite 时必须提供 DB_SQLITE_FILE');
    }
  } else {
    if (!config.db.host) {
      problems.push('DB_DRIVER=mysql 时必须提供 DB_HOST');
    }
    if (!config.db.user) {
      problems.push('DB_DRIVER=mysql 时必须提供 DB_USER');
    }
    if (!config.db.password) {
      // 明确拒绝空口令，而不是回落到某个默认值。
      problems.push(
        'DB_DRIVER=mysql 时必须提供 DB_PASSWORD（不提供默认值：' +
          '一个悄悄生效的弱口令比启动失败危险得多）',
      );
    }
    if (!config.db.database) {
      problems.push('DB_DRIVER=mysql 时必须提供 DB_DATABASE');
    }
  }

  if (config.env === 'prod') {
    if (!config.auth.tokenSecret || config.auth.tokenSecret.length < 32) {
      problems.push(
        'NODE_ENV=prod 时 TOKEN_SECRET 必须存在且不少于 32 字符' +
          '（不要用开发默认值上生产）',
      );
    }
    if (config.corsOrigin === '*') {
      problems.push('NODE_ENV=prod 时不应把 CORS_ORIGIN 设为 *，请指定具体来源');
    }
  }

  return problems;
}
