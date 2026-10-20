/**
 * 硬编码扫描（方案 §11.1 的验收项）。
 *
 * ## 方案原文要求
 *
 * > 服务端地址 / 端口 / 凭据**无硬编码**（代码扫描确认）
 * > **端口与配置可在不修改代码的前提下变更**（改配置 + 重启即生效）
 *
 * ## 为什么必须自动化
 *
 * 这类问题靠人工 review 一定会漏：在本地快速试一下时写死一个
 * `http://127.0.0.1:8080` 太顺手了，而它在本地**完全能跑通**，
 * 只有换到另一台机器才暴露 —— 那时已经离开发很远了。
 *
 * 这个脚本把"能不能换环境"变成一条可执行的断言。
 *
 * 用法：node scripts/check-hardcoded.mjs
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

/**
 * 检查规则。
 *
 * 每条给出：正则、说明、以及**允许出现的文件/位置**。
 *
 * 关键点是"允许清单"必须存在且很小 —— 否则规则会变成
 * "到处都是例外"，等于没有规则。
 */
const RULES = [
  {
    id: 'hardcoded-host',
    // 业务代码里出现具体 IP 或域名（注释里的示例地址不算）。
    pattern: /(?:https?:\/\/)(?:\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}|(?:[\w-]+\.)+[a-z]{2,})/gi,
    message: '出现了硬编码的地址（应走配置 / 环境变量）',
    // 127.0.0.1 与 localhost 作为默认值是可接受的（本机开发）。
    allow: /^https?:\/\/(?:127\.0\.0\.1|localhost)(?::\d+)?/i,
    // 注释与文档字符串里举例说明不算违规。
    skipIfLineMatches: /^\s*(?:\*|\/\/|#)/,
  },
  {
    id: 'hardcoded-port-literal',
    pattern: /\bport\s*[:=]\s*(\d{2,5})\b/gi,
    message: '端口疑似写死（应读配置）',
    // config.js 是**唯一**允许给默认端口的地方。
    allowFiles: ['src/config.js'],
  },
  {
    id: 'hardcoded-password',
    /*
      ⚠️ 不要用 `\b(?:password|...)\b`。

      最初写成"词边界 + password + 等号 + 引号"的形式，实测**漏检**了
      最常见的写法：常量名是 `DB_PASSWORD` 时，`password` 前面是下划线，
      而 `\b` 要求前面是非单词字符、下划线属于单词字符，于是不匹配。

      这条规则是用来防真实泄露的，漏检等于失效。因此改成用 `[\w$]*`
      包住关键词（允许前后缀），并以 `(?![\w$])` 收尾，避免匹配到
      `passwordless` 这类无关词。

      注意：本注释本身**不能**写出真实的赋值写法，否则扫描器会
      把它自己文档里的示例当成违规 —— 这一点也是实测遇到的
      （扫描器一开始报了它自己）。
    */
    pattern: /[\w$]*(?:password|passwd|pwd)[\w$]*\s*[:=]\s*['"]([^'"]*)['"]/gi,
    message: '硬编码的密码（应走配置 / 环境变量）',
    // 只允许空串：它表示"必须由配置提供"，是明确表态而非遗漏。
    allow: /[:=]\s*['"]\s*['"]/,
    allowFiles: [],
  },
  {
    id: 'hardcoded-secret',
    pattern: /[\w$]*(?:secret|apiKey|api_key|token)[\w$]*\s*[:=]\s*['"]([^'"]*)['"]/gi,
    message: '硬编码的密钥/令牌',
    // 空串与明显的占位值可以（表示"必须由配置提供"）。
    allow: /[:=]\s*['"]\s*['"]|['"](?:\$\{|<|xxx|placeholder|CHANGE_ME)/i,
    allowFiles: [],
  },
];

/** 递归收集要检查的源文件。 */
function collect(dir, exts = ['.js', '.mjs', '.cjs']) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (['node_modules', 'data', '.git'].includes(entry.name)) {
        continue;
      }
      out.push(...collect(full, exts));
    } else if (exts.includes(path.extname(entry.name))) {
      out.push(full);
    }
  }
  return out;
}

const files = [
  ...collect(path.join(serverRoot, 'src')),
  ...collect(path.join(serverRoot, 'scripts')),
];

const violations = [];

for (const file of files) {
  const rel = path.relative(serverRoot, file).replace(/\\/g, '/');
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);

  for (const rule of RULES) {
    if (rule.allowFiles?.includes(rel)) {
      continue;
    }
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (rule.skipIfLineMatches?.test(line)) {
        continue;
      }
      // 重置 lastIndex：正则带 g 标志时会在多次 exec 间保留状态，
      // 不重置会导致漏检 —— 这是很容易犯的错。
      rule.pattern.lastIndex = 0;
      const m = rule.pattern.exec(line);
      if (!m) {
        continue;
      }
      if (rule.allow?.test(m[0])) {
        continue;
      }
      violations.push({
        rule: rule.id,
        file: rel,
        line: i + 1,
        text: line.trim().slice(0, 110),
        message: rule.message,
      });
    }
  }
}

if (violations.length === 0) {
  console.log(`硬编码扫描通过：检查 ${files.length} 个文件，未发现问题。`);
  console.log('（方案 §11.1：服务端地址 / 端口 / 凭据无硬编码）');
  process.exit(0);
}

console.log(`硬编码扫描发现 ${violations.length} 处问题：\n`);
for (const v of violations) {
  console.log(`  [${v.rule}] ${v.file}:${v.line}`);
  console.log(`      ${v.message}`);
  console.log(`      ${v.text}\n`);
}
console.log(
  '处置方式：把值移到环境变量 / .env，并在 src/config.js 里读取。\n' +
    '方案 §8.1 要求「代码与配置无需改动即可换环境」，硬编码会让这条失效。',
);
process.exit(1);
