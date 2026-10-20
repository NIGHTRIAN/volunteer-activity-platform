/**
 * Build the acceptance package.
 *
 * Produces a self-contained folder that another person can unzip and run
 * on a clean Windows machine WITHOUT installing Node, Docker, or MySQL.
 *
 * ## What is bundled
 *
 *   node/           a copy of the Node runtime (required: node:sqlite is
 *                   built in, so there is no other dependency at all)
 *   server/         sync service source (no npm install needed -- it uses
 *                   only Node built-in modules in sqlite mode)
 *   web/dist/       prebuilt frontend (so the receiver never runs a build)
 *   contract/       shared contract constants (required by server imports)
 *   data/           empty; the database is created on first run
 *   启动.cmd        double-click launcher
 *   使用说明.md     Chinese instructions for the reviewer
 *
 * ## Why bundle the Node runtime
 *
 * The receiver is a reviewer, not a developer. Asking them to install
 * Node 22+ (and get the major version right -- node:sqlite needs 22+) is a
 * realistic failure mode, and it turns "验收" into "配置环境".
 *
 * The runtime is ~89 MB compressed less; that is the price of a package
 * that just works. A slimmer variant without the runtime is also produced
 * for cases where the receiver does have Node installed.
 *
 * Usage: node tools/build-package.mjs
 */

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, '..');
const OUT_ROOT = path.join(ROOT, 'dist-package');
const STAMP = new Date().toISOString().slice(0, 10);
const PKG_NAME = `志愿活动信息平台-网页验收包-${STAMP}`;

const NODE_SRC = 'D:\\dsh\\resources\\runtime\\primary-runtime\\dependencies\\node';

function log(msg) {
  process.stdout.write(`${msg}\n`);
}

function rmrf(p) {
  fs.rmSync(p, { recursive: true, force: true });
}

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true });
}

/** Copy a directory tree, skipping a few never-shipped names. */
function copyDir(src, dst, { skip = [] } = {}) {
  ensureDir(dst);
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    if (skip.includes(entry.name)) {
      continue;
    }
    const s = path.join(src, entry.name);
    const d = path.join(dst, entry.name);
    if (entry.isDirectory()) {
      copyDir(s, d, { skip });
    } else if (entry.isFile()) {
      fs.copyFileSync(s, d);
    }
  }
}

function dirSize(dir) {
  let total = 0;
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) {
        walk(p);
      } else if (e.isFile()) {
        total += fs.statSync(p).size;
      }
    }
  };
  walk(dir);
  return total;
}

function mb(bytes) {
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

// ══════════════════════════════════════════════════════════════════════
// 1) 先构建前端 —— 包里必须带**已构建**的产物，不能让接收方去 build
// ══════════════════════════════════════════════════════════════════════

log('');
log('=== 1/5 构建前端 ===');

const distIndex = path.join(ROOT, 'web', 'dist', 'index.html');
if (!fs.existsSync(distIndex)) {
  log('  web/dist 不存在，尝试构建…');
  try {
    execFileSync(
      'cmd.exe',
      ['/c', 'tools\\web.cmd', 'run', 'build'],
      { cwd: ROOT, stdio: 'inherit' },
    );
  } catch (e) {
    throw new Error(
      `前端构建失败：${e.message}\n` +
        '包内必须包含已构建的产物，否则接收方要自己装 Node 并构建 —— 那就不叫验收包了。',
    );
  }
} else {
  log('  使用已有的 web/dist（如需重建，先删除该目录）');
}

const distFiles = fs.readdirSync(path.join(ROOT, 'web', 'dist'), { recursive: true });
log(`  dist 就绪：${distFiles.length} 个条目，${mb(dirSize(path.join(ROOT, 'web', 'dist')))}`);

// ══════════════════════════════════════════════════════════════════════
// 2) 组装目录
// ══════════════════════════════════════════════════════════════════════

log('');
log('=== 2/5 组装文件 ===');

const build = (withRuntime) => {
  const name = withRuntime ? PKG_NAME : `${PKG_NAME}-需自备Node`;
  const out = path.join(OUT_ROOT, name);
  rmrf(out);
  ensureDir(out);

  // server：去掉 node_modules（本项目 sqlite 模式零依赖）与已有数据
  copyDir(path.join(ROOT, 'server'), path.join(out, 'server'), {
    skip: ['node_modules', 'data', '.env'],
  });

  // contract：服务端 import 它，缺了整个服务起不来
  copyDir(path.join(ROOT, 'contract'), path.join(out, 'contract'));

  // 前端产物
  copyDir(path.join(ROOT, 'web', 'dist'), path.join(out, 'web', 'dist'));

  // 数据目录留空（首次运行自动建库）
  ensureDir(path.join(out, 'data'));

  // 运行时
  if (withRuntime) {
    log('  复制 Node 运行时（约 89 MB，这是"免安装"的代价）…');
    copyDir(NODE_SRC, path.join(out, 'node'));
  }

  return { out, name, withRuntime };
};

const full = build(true);
const slim = build(false);

log(`  ${full.name}  (含运行时)`);
log(`  ${slim.name}  (不含运行时)`);

// ══════════════════════════════════════════════════════════════════════
// 3) 写启动脚本与说明
// ══════════════════════════════════════════════════════════════════════

log('');
log('=== 3/5 写启动脚本与说明 ===');

/**
 * 启动脚本。
 *
 * ⚠️ 写成 .cmd 而不是 .ps1：目标机器默认的执行策略会拒绝 .ps1，
 * 而验收包的第一要求是"双击就能跑"。为此牺牲一些可读性是值得的。
 *
 * ⚠️ **必须纯 ASCII**：cmd.exe 用 GBK 解码 .cmd，中文注释会变成
 * 要执行的乱码命令（本项目已在这上面踩过一次）。
 */
function launcher(withRuntime) {
  // NOTE: the runtime's executable lives at node\bin\node.exe, not node\node.exe
  // (the distribution has bin/ + node_modules/ + LICENSE). Getting this wrong
  // produces "spawn ... ENOENT" only at run time on the receiver's machine,
  // which is exactly the failure the self-check below is meant to catch.
  const nodeLine = withRuntime
    ? 'set "NODE_EXE=%~dp0node\\bin\\node.exe"'
    : 'set "NODE_EXE=node"';
  return `@echo off
setlocal
REM Launcher for the acceptance package. Double-click to run.
REM
REM ASCII-only on purpose: cmd.exe decodes .cmd with the OEM codepage
REM (GBK on Chinese Windows), so non-ASCII comment lines become garbage
REM that cmd then tries to EXECUTE.

title Volunteer Platform - Web Acceptance

set "HERE=%~dp0"
if "%HERE:~-1%"=="\\" set "HERE=%HERE:~0,-1%"

${nodeLine}

REM Use the bundled runtime when present; otherwise fall back to PATH.
if /i not "%NODE_EXE%"=="node" (
  if not exist "%NODE_EXE%" (
    echo [ERROR] Bundled Node runtime not found at:
    echo         %NODE_EXE%
    echo         The package may be incomplete - please re-extract it.
    pause
    exit /b 1
  )
) else (
  where node >nul 2>&1
  if errorlevel 1 (
    echo [ERROR] Node.js 22 or newer is required but was not found on PATH.
    echo         Install it from https://nodejs.org/ then run this again.
    pause
    exit /b 1
  )
)

REM Data lives next to the executable so the folder stays self-contained.
if not exist "%HERE%\\data" mkdir "%HERE%\\data"
set "DB_SQLITE_FILE=%HERE%\\data\\volunteer.db"
set "STATIC_DIR=%HERE%\\web\\dist"
set "HOST=0.0.0.0"
if "%PORT%"=="" set "PORT=8080"
set "NODE_ENV=dev"

echo.
echo ============================================================
echo   Volunteer Activity Platform - Web Acceptance
echo ============================================================
echo.
echo   This window IS the server. Keep it open.
echo   Close it (or press Ctrl+C) to stop.
echo.
echo   Addresses:
echo     Local   http://127.0.0.1:%PORT%/
echo     Others  http://THIS-PC-LAN-IP:%PORT%/   (same Wi-Fi only)
echo.
echo   The local address is opened in your browser shortly.
echo.

REM Open the browser after a short delay so the server can bind first.
start "" /min cmd /c "timeout /t 3 >nul & start "" http://127.0.0.1:%PORT%/"

cd /d "%HERE%\\server"
"%NODE_EXE%" src/server.js

echo.
echo Server stopped. Press any key to close.
pause >nul
`;
}

for (const pkg of [full, slim]) {
  // 启动脚本：纯 ASCII，文件名用英文避免编码问题
  fs.writeFileSync(path.join(pkg.out, 'START.cmd'), launcher(pkg.withRuntime), 'ascii');

  // 说明文档：UTF-8。用 .md 是因为 Windows 记事本也能打开。
  const nodeNote = pkg.withRuntime
    ? '本包**已内置 Node 运行时**，无需安装任何东西。'
    : '本包**不含 Node 运行时**，需要先安装 Node.js 22 或更新版本（https://nodejs.org/）。';

  const readme = `# 志愿活动信息平台 · 网页验收包

## 这是什么

《网页开发方案》中 **Web 前端 + 同步服务** 的可运行版本。
解压后双击即可在浏览器里查看，**不需要安装数据库，不需要 Docker**。

${nodeNote}

---

## 怎么运行（三步）

1. 把整个文件夹解压到任意位置（**路径不要含中文**，避免个别工具出问题）；
2. 双击 **\`START.cmd\`**；
3. 浏览器会自动打开 <http://127.0.0.1:8080/>。若没有自动打开，手动在浏览器地址栏输入这个地址。

> **黑色命令行窗口就是服务器本身**，请保持它开着。
> 关掉窗口（或按 \`Ctrl+C\`）即停止服务。
> 再次使用只需重新双击 \`START.cmd\`。

### 换端口

如果 8080 被占用，在该窗口里先执行：

\`\`\`
set PORT=8090
\`\`\`

再双击 \`START.cmd\`。或者在命令行里：

\`\`\`
set PORT=8090 && START.cmd
\`\`\`

### 让别人也能看（同一 Wi-Fi）

1. 查本机 IP：\`ipconfig\`，找到「无线局域网适配器 WLAN」下的 IPv4 地址；
2. 把 \`http://那个IP:8080/\` 发给对方。

前提：对方与你在同一个网络，且 Windows 防火墙允许 Node 接收连接
（首次运行时系统可能会弹窗询问，选「允许」）。

### 从外网看

需要内网穿透（如 cpolar / ngrok）或把包部署到服务器。
本包自带 \`docker-compose.yml\` 与 \`deploy/nginx.conf\`，供有服务器的环境使用。

---

## 里面有什么

\`\`\`
START.cmd            双击启动
server/              同步服务源码（Node.js，零外部依赖）
web/dist/            已构建好的前端（不需要再 build）
contract/            三端共用的契约常量
data/                数据库（首次运行自动创建 volunteer.db）
node/                Node 运行时（仅"含运行时"版本有）
docs/                部署与验证文档
\`\`\`

---

## 可以验收什么

| 页面 | 地址 |
|---|---|
| 活动列表（筛选 / 分页 / 统计图） | \`/\` |
| 活动详情（含分享链接） | \`/#/activity/1\` |
| 我的收藏（存本机浏览器） | \`/#/favorites\` |

**接口自检**（浏览器直接打开）：

- \`/api/health\` —— 服务是否正常
- \`/api/contract\` —— 服务端自述：实现了哪些接口、错误码、约束
- \`/api/activities\` —— 活动列表原始数据
- \`/api/activities/export\` —— 导出 CSV（会下载文件，可用 Excel 打开验证中文不乱码）

演示数据覆盖**发布中 / 进行中 / 已结束 / 已取消**四种状态，
以及**已过 7 天留存期**的记录（应不可见）。

---

## 已知限制（如实说明，不是缺陷隐瞒）

| 项 | 说明 |
|---|---|
| **只读** | 本包只实现列表 / 详情 / 统计 / 导出。上报、状态流转、名单、签到、复核、考勤属下一阶段（P2），**尚未实现** |
| 管理员邀请码 | 默认 \`1111\`（方案 §12.1 既定设计）。当前没有登录界面 |
| MySQL | 本包默认用 SQLite（零依赖）。MySQL 适配器代码已就绪，但**未在真实 MySQL 上验证过** |
| Docker / Nginx | 配置已提供，但**未在有 Docker/Nginx 的机器上验证过** |
| 打印为 PDF | 样式已写（\`@media print\`），未实际打印验证 |

---

## 出问题时

**窗口一闪就关**：在命令行里手动运行以看到错误：

\`\`\`
cd server
node src/server.js
\`\`\`

**端口被占用**：\`set PORT=8090\` 后重试。

**页面空白**：确认窗口没有报错；按 \`F12\` 看控制台。
常见原因是 \`web/dist\` 缺失 —— 那说明解压不完整，请重新解压。

**想重置数据**：关掉窗口，删除 \`data\\volunteer.db\`（连同 \`-shm\` / \`-wal\`
后缀的同名文件，如果有），重新双击 \`START.cmd\`。

> 包内数据库是**空库出厂**，首次启动会**自动写入演示数据**。
> 因此删库重启即回到初始的演示活动。

---

## 为什么包里没有你的开发数据

打包时数据库是空的，演示数据在**首次启动时**由服务写入。这样：

* 不会把你开发时删改过的数据混进验收包；
* 接收方拿到的是干净的、状态齐全的演示集；
* 想恢复初始状态，删掉 \`data\\volunteer.db\` 重启即可。

演示数据的时间是**相对运行时**生成的（"明天开始""三天前结束"），
所以不会出现"过几天再看全部变成已结束"的情况。

---

生成时间：${STAMP}
`;
  fs.writeFileSync(path.join(pkg.out, '使用说明.md'), readme, 'utf8');

  // 文档：让对方能看到验证方法与已知缺口
  ensureDir(path.join(pkg.out, 'docs'));
  for (const f of ['web-server.md', 'acceptance-checklist.md', 'web-development-plan.md']) {
    const src = path.join(ROOT, 'docs', f);
    if (fs.existsSync(src)) {
      fs.copyFileSync(src, path.join(pkg.out, 'docs', f));
    }
  }

  // 部署相关（给有服务器的环境用）
  for (const f of ['docker-compose.yml', '.env.example']) {
    const src = path.join(ROOT, f);
    if (fs.existsSync(src)) {
      fs.copyFileSync(src, path.join(pkg.out, f));
    }
  }
  const nginx = path.join(ROOT, 'deploy', 'nginx.conf');
  if (fs.existsSync(nginx)) {
    ensureDir(path.join(pkg.out, 'deploy'));
    fs.copyFileSync(nginx, path.join(pkg.out, 'deploy', 'nginx.conf'));
  }
}

log('  已写入 START.cmd / 使用说明.md / docs / 部署配置');

// ══════════════════════════════════════════════════════════════════════
// 4) 自检：用打好的包**实际启动一次**并请求页面
// ══════════════════════════════════════════════════════════════════════

log('');
log('=== 4/5 用打好的包自检（真实启动 + 真实请求）===');

const nodeExe = full.withRuntime
  ? path.join(full.out, 'node', 'bin', 'node.exe')
  : process.execPath;

log(`  运行时：${nodeExe}`);

const probe = await runSelfCheck(full.out, nodeExe);
if (!probe.ok) {
  log('');
  log('  ❌ 自检失败：');
  for (const line of probe.failures) {
    log(`     - ${line}`);
  }
  process.exitCode = 1;
} else {
  log('  ✅ 自检通过');
  for (const line of probe.checks) {
    log(`     ${line}`);
  }
}

// ══════════════════════════════════════════════════════════════════════
// 5) 压缩
// ══════════════════════════════════════════════════════════════════════

log('');
log('=== 5/5 压缩 ===');

for (const pkg of [full, slim]) {
  const zip = path.join(OUT_ROOT, `${pkg.name}.zip`);
  rmrf(zip);
  try {
    execFileSync(
      'powershell',
      [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-Command',
        `Compress-Archive -Path '${pkg.out}' -DestinationPath '${zip}' -CompressionLevel Optimal -Force`,
      ],
      { stdio: 'pipe' },
    );
    log(`  ${path.basename(zip)} : ${mb(fs.statSync(zip).size)}`);
  } catch (e) {
    log(`  ⚠️ 压缩 ${pkg.name} 失败：${e.message}`);
  }
}

log('');
log(`输出目录：${OUT_ROOT}`);
log('');

// ══════════════════════════════════════════════════════════════════════
// 自检实现
// ══════════════════════════════════════════════════════════════════════

async function runSelfCheck(pkgDir, nodeExe) {
  const { spawn } = await import('node:child_process');
  const checks = [];
  const failures = [];

  const port = 8097; // 刻意用一个不常用的端口，避免撞上正在开发的实例
  const dataDir = path.join(pkgDir, 'data');
  rmrf(dataDir);
  ensureDir(dataDir);

  const child = spawn(nodeExe, ['src/server.js'], {
    cwd: path.join(pkgDir, 'server'),
    env: {
      ...process.env,
      PORT: String(port),
      HOST: '127.0.0.1',
      DB_DRIVER: 'sqlite',
      DB_SQLITE_FILE: path.join(dataDir, 'volunteer.db'),
      STATIC_DIR: path.join(pkgDir, 'web', 'dist'),
      NODE_ENV: 'dev',
      LOG_LEVEL: 'error',
      ACCESS_LOG: 'false',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let stderr = '';
  child.stderr.on('data', (d) => {
    stderr += d.toString();
  });

  // 等服务绑定。
  const base = `http://127.0.0.1:${port}`;
  let up = false;
  for (let i = 0; i < 40; i++) {
    try {
      const r = await fetch(`${base}/api/health`);
      if (r.ok) {
        up = true;
        break;
      }
    } catch {
      // 还没起来。
    }
    await new Promise((r) => setTimeout(r, 250));
  }

  if (!up) {
    child.kill();
    return {
      ok: false,
      checks,
      failures: [`服务未能在 10 秒内启动。stderr：${stderr.slice(0, 400)}`],
    };
  }

  try {
    // 1) API 可用
    const health = await (await fetch(`${base}/api/health`)).json();
    if (health.code === 0 && health.data.driver === 'sqlite') {
      checks.push('API /api/health 正常（driver=sqlite）');
    } else {
      failures.push(`/api/health 返回异常：${JSON.stringify(health).slice(0, 160)}`);
    }

    // 2) 首页可访问（证明静态服务生效）
    const indexRes = await fetch(`${base}/`);
    const indexText = await indexRes.text();
    if (indexRes.ok && indexText.includes('id="app"')) {
      checks.push('首页 HTML 由包内静态服务返回');
    } else {
      failures.push(`首页异常：HTTP ${indexRes.status}`);
    }

    // 3) 前端资源可加载
    const assetMatch = indexText.match(/src="(\/assets\/[^"]+\.js)"/);
    if (assetMatch) {
      const a = await fetch(`${base}${assetMatch[1]}`);
      if (a.ok && (a.headers.get('content-type') ?? '').includes('javascript')) {
        checks.push(`前端资源可加载：${assetMatch[1]}`);
      } else {
        failures.push(`前端资源异常：${assetMatch[1]} → HTTP ${a.status}`);
      }
    } else {
      failures.push('首页里找不到 /assets/*.js 引用');
    }

    // 4) 首次启动应自动带演示数据 —— 空页面无法验收
    const list = await (await fetch(`${base}/api/activities`)).json();
    if (list.code === 0 && list.data.total >= 5) {
      checks.push(`首次启动自动写入演示数据（${list.data.total} 条可见）`);
    } else {
      failures.push(
        `演示数据未自动写入（total=${list.data?.total}）。` +
          '接收方会看到一个空列表，无法验收筛选/统计/详情/导出。',
      );
    }

    // 5) 状态覆盖：筛选与统计才有东西可看
    const statuses = new Set(list.data.items.map((a) => a.status));
    const needed = ['published', 'ongoing', 'finished', 'cancelled'];
    const missing = needed.filter((s) => !statuses.has(s));
    if (missing.length === 0) {
      checks.push('演示数据覆盖四种状态');
    } else {
      failures.push(`演示数据缺少状态：${missing.join(', ')}`);
    }

    // 6) 路径穿越必须被拒
    const evil = await fetch(`${base}/../server/src/config.js`);
    const evilText = await evil.text();
    if (!evilText.includes('loadConfig')) {
      checks.push('路径穿越被拒绝');
    } else {
      failures.push('路径穿越未被拦住 —— 能读到包外文件！');
    }

    // 7) 导出接口可用（验收要点之一）
    const csv = await fetch(`${base}/api/activities/export`);
    const csvText = await csv.text();
    if (csv.ok && csvText.includes('活动名称')) {
      checks.push('CSV 导出可用（含表头）');
      if (/[^\u0000-\u007f]/.test(csvText.slice(0, 200))) {
        checks.push('CSV 含中文表头（UTF-8 编码正确）');
      }
    } else {
      failures.push(`CSV 导出异常：HTTP ${csv.status}`);
    }

    // 8) 契约自述可用
    const contract = await (await fetch(`${base}/api/contract`)).json();
    if (contract.code === 0 && Array.isArray(contract.data.endpoints)) {
      checks.push(`契约自述可用（${contract.data.endpoints.length} 个端点）`);
    } else {
      failures.push('/api/contract 异常');
    }
    void indexText;
  } finally {
    child.kill();
    // 等进程真的退出，避免占着端口影响下一次构建
    await new Promise((r) => setTimeout(r, 500));
  }

  return { ok: failures.length === 0, checks, failures };
}
