/**
 * Mock 服务端入口。
 *
 * 零外部依赖（仅 Node 内置模块），因为它的使命是**让两端 App 在真实服务端就绪前
 * 能独立开发与联调**（方案 §1.4）。任何需要 `npm install` 的东西都会拖慢这个目标。
 *
 * 启动：
 *   node src/server.js                    # 默认 0.0.0.0:8080
 *   PORT=9000 node src/server.js          # 换端口
 *   ADMIN_INVITE_CODE=8888 node src/server.js
 *   MOCK_DATA_DIR=./.data-dev node src/server.js
 *
 * 局域网访问（真机联调，方案 §1.4「手机需能访问局域网 IP」）：
 *   默认监听 0.0.0.0，启动日志会打印可用的局域网地址。
 */

import http from 'node:http';
import os from 'node:os';
import { DEFAULTS } from './constants.js';
import { store } from './store.js';
import { handleRequest } from './router.js';
import { seedIfEmpty } from './seed.js';

const PORT = Number(process.env.PORT ?? 8080);
const HOST = process.env.HOST ?? '0.0.0.0';

/** 列出可用于真机联调的局域网地址。 */
function lanAddresses() {
  const out = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const iface of list ?? []) {
      if (iface.family === 'IPv4' && !iface.internal) {
        out.push(iface.address);
      }
    }
  }
  return out;
}

const server = http.createServer((req, res) => {
  const started = Date.now();
  handleRequest(req, res, { startedAt: started });
});

store.load();
seedIfEmpty();

if (process.argv.includes('--seed-only')) {
  console.log(`[mock] 数据已就绪：${store.filePath}`);
  process.exit(0);
}

server.listen(PORT, HOST, () => {
  const lines = [
    '',
    '  志愿活动信息平台 · 服务端 Mock',
    `  监听          http://${HOST}:${PORT}`,
    `  接口版本      ${DEFAULTS.API_VERSION}`,
    `  管理员邀请码  ${process.env.ADMIN_INVITE_CODE ?? DEFAULTS.DEFAULT_ADMIN_INVITE_CODE}` +
      `${process.env.ADMIN_INVITE_CODE ? '（来自环境变量）' : '（默认值，可用 ADMIN_INVITE_CODE 覆盖）'}`,
    `  数据文件      ${store.filePath}`,
    '',
    '  真机联调用地址（手机与电脑需在同一网络）：',
  ];
  const lan = lanAddresses();
  if (lan.length === 0) {
    lines.push('    （未检测到局域网地址）');
  } else {
    for (const ip of lan) {
      lines.push(`    http://${ip}:${PORT}`);
    }
  }
  lines.push(
    '',
    '  App 侧对应构建参数：',
    `    --dart-define=API_BASE_URL=http://${lan[0] ?? '127.0.0.1'}:${PORT}`,
    '',
    '  ⚠️ 本 Mock 仅供开发联调，未做鉴权加固与数据加密，不得用于任何生产环境。',
    '',
  );
  console.log(lines.join('\n'));
});

/** 优雅退出：确保内存中的改动已落盘。 */
function shutdown(signal) {
  console.log(`\n[mock] 收到 ${signal}，正在落盘并退出…`);
  try {
    store.save();
  } catch (err) {
    console.error(`[mock] 落盘失败：${err.message}`);
  }
  server.close(() => process.exit(0));
  // 兜底：3 秒内没关干净就强制退出。
  setTimeout(() => process.exit(0), 3000).unref();
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

/**
 * 兜底：任何未捕获异常都不应让服务进程退出。
 *
 * ## 为什么必须有
 *
 * 实测踩到过：一个 handler 里的 `TypeError` 冒泡到 `process`，
 * 导致**整个 Mock 进程退出**，客户端只看到 `ECONNRESET`。
 * 排查成本极高——客户端报的是网络错误，真正的原因是服务端崩了。
 *
 * 开发用的 Mock 尤其不能崩：联调时它同时服务多个客户端与测试，
 * 一次崩溃会让所有人以为是自己写错了。
 */
process.on('uncaughtException', (err) => {
  console.error('[mock] 未捕获异常（服务继续运行）：', err);
});

process.on('unhandledRejection', (reason) => {
  console.error('[mock] 未处理的 Promise 拒绝（服务继续运行）：', reason);
});
