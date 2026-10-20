#!/usr/bin/env node
// adb-ui.mjs — 以文字方式读取 Android 界面（Flutter 也能读）
//
// 为什么需要：Flutter 用 Skia 自绘，但会向无障碍服务暴露语义树，
// uiautomator 拿到的是同一棵树的 XML 投影 —— 文本与坐标都可用。
// 在没有图像能力的环境下，这是验证界面 + 定位点击坐标的可靠手段。
//
// 用法：
//   node tools/adb-ui.mjs                列出所有带文字或可点击的元素
//   node tools/adb-ui.mjs 签到           只列出文本/描述包含关键字的元素
//   node tools/adb-ui.mjs --all          连无文字的节点也列出
//   node tools/adb-ui.mjs --json         输出 JSON（便于程序处理）
import { execFileSync } from 'node:child_process';

const ADB = 'D:\\dev-tools\\android-sdk\\platform-tools\\adb.exe';
const REMOTE = '/sdcard/ui-dump.xml';

function adb(args) {
  return execFileSync(ADB, args, { encoding: 'utf8' });
}

const argv = process.argv.slice(2);
const jsonOut = argv.includes('--json');
const all = argv.includes('--all');
// 只把"不以连字符开头"的参数当搜索词。
// （一开始只排除了 `--xxx`，于是 `-Grep 关键词` 这种写法会把 `-Grep`
//   自己当成搜索词，永远搜不到东西 —— 排查时浪费了不少时间。）
const grep = argv.find((a) => !a.startsWith('-')) ?? '';

try {
  adb(['shell', 'uiautomator', 'dump', REMOTE]);
} catch (e) {
  const msg = String(e.stdout || '') + String(e.stderr || '');
  if (!msg.includes('dumped')) {
    console.error('uiautomator dump 失败：', msg.slice(0, 300));
    process.exit(1);
  }
}

const xml = adb(['exec-out', 'cat', REMOTE]);
try { adb(['shell', 'rm', REMOTE]); } catch { /* ignore */ }

// 解析 <node ...>：属性顺序不固定，逐个提取需要的属性
const nodes = [];
const nodeRe = /<node\b([^>]*?)\/?>/g;
let m;
while ((m = nodeRe.exec(xml)) !== null) {
  const attrs = m[1];
  const attr = (name) => {
    const r = new RegExp(`${name}="([^"]*)"`).exec(attrs);
    return r ? r[1] : '';
  };
  const bounds = attr('bounds');
  const bm = /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/.exec(bounds);
  if (!bm) continue;
  const [, x1, y1, x2, y2] = bm.map(Number);
  const text = attr('text') || attr('content-desc') || '';
  const clickable = attr('clickable') === 'true';
  if (!all && !text && !clickable) continue;
  if (grep && !text.includes(grep)) continue;
  nodes.push({
    text,
    clickable,
    tapX: Math.round((x1 + x2) / 2),
    tapY: Math.round((y1 + y2) / 2),
    w: x2 - x1,
    h: y2 - y1,
    bounds: `[${x1},${y1}][${x2},${y2}]`,
  });
}

if (jsonOut) {
  console.log(JSON.stringify(nodes, null, 2));
} else {
  if (nodes.length === 0) {
    console.log('（没有匹配的元素）');
  } else {
    for (const n of nodes) {
      const mark = n.clickable ? '●' : ' ';
      const label = n.text || '(无文字)';
      console.log(`${mark} ${label}`);
      console.log(`      tap ${n.tapX} ${n.tapY}   ${n.bounds}`);
    }
    console.log(`\n共 ${nodes.length} 个元素。● = 可点击`);
  }
}
