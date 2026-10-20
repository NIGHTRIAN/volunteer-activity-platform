/**
 * 静态文件服务 —— 让同步服务顺便把前端页面也发出去。
 *
 * ## 为什么要把静态资源塞进 API 服务
 *
 * 方案 §8.2 要求**前后端同域**（规避 CORS）。生产形态是 Nginx 反代，
 * 但"发给别人验收"这个场景下，要求对方装 Nginx 是不现实的。
 *
 * 内置静态服务之后：
 *   * 只暴露**一个端口**（8080），对方不用理解"两个服务"；
 *   * 天然同域，`/api` 相对路径直接可用，CORS 完全不是问题；
 *   * 一条命令 `node src/server.js` 就能给人看。
 *
 * 代价是生产环境多一层 JS 静态服务（性能不如 Nginx）。因此这里
 * 保持实现**极简且正确**，不试图取代 Nginx：生产部署仍走
 * `deploy/nginx.conf`，静态资源由 Nginx 直接发。
 *
 * ## 安全上必须做对的三件事
 *
 * 1. **防路径穿越**：`/../../etc/passwd` 之类必须被拒。
 *    做法是解析出真实路径后，确认它仍在静态根目录内 ——
 *    只做字符串 `startsWith` 判断是不够的（`..` 与符号链接都能绕过）。
 * 2. **只发白名单类型**：不根据扩展名瞎猜，避免把源码当文本发出去。
 * 3. **哈希资源长缓存、index.html 不缓存**：
 *    否则发布新版本后用户仍加载旧的 index.html，指向已删除的资源，
 *    表现为整页白屏。
 */

import fs from 'node:fs';
import path from 'node:path';

/**
 * 扩展名 → Content-Type。
 *
 * 原则：只列**确实会出现在静态目录里**的类型。白名单而不是"猜 MIME"，
 * 是因为猜错会让浏览器用错误的方式解释文件（例如把脚本当图片），
 * 而白名单外的文件直接 404，行为可预期。
 *
 * `.apk` 是唯一的例外：它不属于"前端产物"，而是**内网分发手机安装包**。
 * 部署到机房的电脑上时，让手机浏览器直接下载 APK 比"数据线拷贝"省事得多，
 * 且服务端本来就托管着网页，多托管两个安装包不增加任何风险
 * （APK 是静态文件，不会被执行）。
 */
const MIME = new Map([
  ['.html', 'text/html; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.mjs', 'text/javascript; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.svg', 'image/svg+xml'],
  ['.png', 'image/png'],
  ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'],
  ['.webp', 'image/webp'],
  ['.ico', 'image/x-icon'],
  ['.woff', 'font/woff'],
  ['.woff2', 'font/woff2'],
  ['.map', 'application/json; charset=utf-8'],
  ['.txt', 'text/plain; charset=utf-8'],
  ['.apk', 'application/vnd.android.package-archive'],
]);

/**
 * 解析请求路径到磁盘上的真实文件。
 *
 * 返回 `null` 表示"不该由静态服务处理"（不存在或是目录）。
 *
 * ⚠️ 路径穿越防护是这里最关键的逻辑。攻击方式不止 `../`：
 * 还有 URL 编码（`%2e%2e%2f`）、以及**符号链接**。
 * 因此必须：
 *   1. 先解码（`decodeURIComponent`）；
 *   2. 用 `path.resolve` 归一化；
 *   3. 用 `realpath` 解析符号链接；
 *   4. 最后确认结果仍在 root 之内，且带**路径分隔符**前缀 ——
 *      否则 `/srv/wwwroot-evil` 会被误判为在 `/srv/wwwroot` 之内。
 */
export function resolveStaticFile(root, urlPath) {
  let decoded;
  try {
    decoded = decodeURIComponent(urlPath.split('?')[0]);
  } catch {
    // 非法百分号编码。
    return null;
  }

  // 去掉开头的斜杠，避免 resolve 把它当成绝对路径。
  const relative = decoded.replace(/^\/+/, '');

  // 空路径 → 首页。
  const target = relative === '' ? 'index.html' : relative;

  const resolved = path.resolve(root, target);

  // 归一化后必须仍在 root 内（此处用 resolve 后的字符串比较，
  // 因为符号链接在下一步才解析）。
  if (!isInside(root, resolved)) {
    return null;
  }

  // 解析符号链接后再判一次 —— 一个指向 root 之外的链接同样危险。
  let real;
  try {
    real = fs.realpathSync(resolved);
  } catch {
    return null; // 不存在。
  }
  let realRoot;
  try {
    realRoot = fs.realpathSync(root);
  } catch {
    return null;
  }
  if (!isInside(realRoot, real)) {
    return null;
  }

  let stat;
  try {
    stat = fs.statSync(real);
  } catch {
    return null;
  }
  if (!stat.isFile()) {
    return null;
  }

  return { file: real, size: stat.size, mtime: stat.mtime };
}

/** `child` 是否严格位于 `parent` 之内。 */
function isInside(parent, child) {
  const rel = path.relative(parent, child);
  // 空串表示同一个路径（不是"之内"）；以 .. 开头表示在外面；
  // 绝对路径表示不同盘符。
  return rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel);
}

/**
 * 发送静态文件。
 *
 * @returns {boolean} 是否已处理（`false` 表示调用方应继续走 API 逻辑）
 */
export function serveStatic(req, res, { root, urlPath, exposeSourcemaps = false }) {
  const hit = resolveStaticFile(root, urlPath);
  if (!hit) {
    return false;
  }

  const ext = path.extname(hit.file).toLowerCase();

  // sourcemap 默认不外发：它包含完整源码结构，
  // 对"发给别人验收"这种场景没有必要。
  if (ext === '.map' && !exposeSourcemaps) {
    return false;
  }

  const type = MIME.get(ext);
  if (!type) {
    // 白名单之外的类型一律不发 —— 避免把 .db / .env 之类当文本读出去。
    return false;
  }

  /*
    缓存策略：
      * 带内容哈希的产物（/assets/xxx-HASH.js）→ 永久缓存；
      * index.html 与其余未哈希资源 → 不缓存。

    index.html 必须不缓存：它会引用带哈希的资源名，一旦缓存了旧版本，
    发布新版后浏览器仍去请求已删除的旧文件，结果整页白屏。
  */
  const isHashed = /-[A-Za-z0-9_-]{8,}\.(?:js|css|woff2?|svg|png|jpe?g|webp)$/.test(hit.file);
  const cacheControl = isHashed
    ? 'public, max-age=31536000, immutable'
    : 'no-cache, must-revalidate';

  const headers = {
    'Content-Type': type,
    'Content-Length': hit.size,
    'Cache-Control': cacheControl,
    // 基础安全头。nosniff 阻止浏览器猜测类型（某些 XSS 的入口）。
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
  };

  // 条件请求：让浏览器缓存真正生效（否则每次都重下）。
  const inm = req.headers['if-none-match'];
  const etag = `W/"${hit.size}-${hit.mtime.getTime()}"`;
  headers.ETag = etag;
  if (inm === etag) {
    res.writeHead(304, headers);
    res.end();
    return true;
  }

  if (req.method === 'HEAD') {
    res.writeHead(200, headers);
    res.end();
    return true;
  }

  res.writeHead(200, headers);
  fs.createReadStream(hit.file).pipe(res);
  return true;
}

export { MIME };
