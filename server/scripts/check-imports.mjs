/**
 * 检查所有模块能否被解析。
 *
 * ## 为什么需要这个脚本
 *
 * 相对路径的层数写错（`'../../x'` vs `'../../../x'`）**不会在写代码时
 * 报错**，只有在真的 import 到那个模块时才炸。本项目已经因此摔了三次
 * （`http/envelope.js`、`seed/demo.js`，以及契约门面的由来）。
 *
 * 这类错误特别烦人：`node --check` 只做语法检查，**不解析 import**，
 * 所以它一路绿；而测试如果没覆盖到那条路径，也会一路绿。
 *
 * 这个脚本对 `src/` 与 `scripts/` 下的每个 `.js`/`.mjs` 逐个 `import()`，
 * 把问题在**最早的时刻**暴露出来。
 *
 * 用法：node scripts/check-imports.mjs
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

/** 递归收集源码文件。 */
function collect(dir) {
  const out = [];
  if (!fs.existsSync(dir)) {
    return out;
  }
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'node_modules' || entry.name === 'data') {
        continue;
      }
      out.push(...collect(full));
    } else if (/\.m?js$/.test(entry.name)) {
      out.push(full);
    }
  }
  return out;
}

const files = [...collect(path.join(serverRoot, 'src')), ...collect(path.join(serverRoot, 'scripts'))];

let failed = 0;
for (const f of files) {
  const rel = path.relative(serverRoot, f).replace(/\\/g, '/');
  // server.js 直接运行会去监听端口；只检查它能否解析，不真正执行副作用。
  const skipExecute = rel === 'src/server.js';
  try {
    const mod = await import(pathToFileURL(f).href);
    void mod;
    console.log(`ok    ${rel}`);
  } catch (e) {
    // server.js 被直接 import 时不会自动 listen（有 main-check），
    // 但仍可能因为别的原因失败 —— 一律报出来。
    failed += 1;
    const first = String(e.message).split('\n')[0];
    console.log(`FAIL  ${rel} -> ${first}`);
    if (skipExecute) {
      console.log('      （注意：这是入口文件，失败原因可能与环境有关）');
    }
  }
}

console.log(`\n检查 ${files.length} 个文件，失败 ${failed} 个`);
process.exit(failed > 0 ? 1 : 0);
