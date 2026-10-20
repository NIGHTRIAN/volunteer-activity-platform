/**
 * 路由形状防漂移测试。
 *
 * ## 这条测试是为了拦住一类真实的 bug
 *
 * 真机报障：**管理端点「通过」复核签到，提示「接口不存在」**。
 *
 * 根因：客户端 `CheckinPaths.review(id)` 拼出来是 **`/checkins/{id}/review`**
 * （路径段），而服务端注册成了 **`/checkins/:checkinId:review`**
 * （动作后缀）。两者永远匹配不上 → 404。
 *
 * 更糟的是**当时测试也没抓到**：用例里手写的路径同样是错的 `:review`，
 * 于是测试与实现一起错、互相印证，全绿。这跟"字段名对不上"是同一类错误
 * ——**测试必须使用客户端真正会拼出来的那个字符串**。
 *
 * ## 这里怎么防
 *
 * 路径字符串**逐字抄自**
 * `packages/shared_core/lib/src/contract/api_paths.dart`。
 * 对每个（方法, 路径）组合直接问路由器能不能匹配上。
 *
 * 两侧都有锁：
 *   * 本文件锁"服务端是否认识这些路径"；
 *   * `shared_core/test/api_paths_test.dart` 锁"构造器产出的形状"。
 *
 * ⚠️ 改这里的路径前，先确认 `api_paths.dart` 里对应构造器的真实输出。
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { buildRouter } from '../src/server.js';

/**
 * **两端 App / 网页实际会调用**的路径 —— 服务端必须全部认识。
 *
 * 缺任意一条，用户看到的就是「接口不存在」。
 */
const REQUIRED = [
  // 健康检查与契约自述
  ['GET', '/health', '存活检查'],
  ['GET', '/contract', '契约自述'],

  // AuthPaths
  ['POST', '/auth/admin/login', '管理端登录'],
  ['POST', '/auth/bind', '志愿者绑定'],
  ['GET', '/auth/admin/me', '管理端当前身份'],
  ['GET', '/auth/me', '志愿者当前授权'],
  ['GET', '/changes', '增量同步'],

  // ActivityPaths
  ['GET', '/activities', '活动列表'],
  ['GET', '/activities/export', '列表导出（网页）'],
  ['GET', '/activities/organizers', '部门字典（网页筛选）'],
  ['POST', '/activities:upsert', '活动上报'],
  ['GET', '/activities/1', '活动详情'],
  ['GET', '/activities/1/export', '单活动导出'],
  ['POST', '/activities/1:transition', '状态流转'],
  ['GET', '/activities/1/board', '现场看板'],
  ['GET', '/activities/1/attendance', '考勤汇总'],

  // ParticipantPaths
  ['GET', '/activities/1/participants', '名单'],
  ['POST', '/activities/1/participants', '加人'],
  ['POST', '/activities/1/participants:import', '批量导入'],
  ['DELETE', '/activities/1/participants/2021001', '移出名单'],
  ['POST', '/activities/1/invite-codes', '生成邀请码'],
  ['GET', '/activities/1/invite-codes', '邀请码列表（掩码）'],

  // CheckinPaths
  ['POST', '/activities/1/checkins', '提交签到'],
  ['GET', '/activities/1/checkins', '签到记录列表（管理端）'],
  ['GET', '/activities/1/checkins/mine', '本人签到记录（用户端）'],
  // ⚠️ 就是这一条踩过坑：它是**路径段**，不是 `:review` 动作后缀。
  ['POST', '/checkins/1/review', '人工复核签到'],

  // AttendancePaths
  ['GET', '/activities/1/attendance/tasks', '在岗任务'],
  ['POST', '/activities/1/attendance/manual', '手动发起在岗抽查'],
  ['POST', '/attendances/1:confirm', '确认在岗'],
];

/**
 * 契约里有、但**服务端尚未实现**的路径。
 *
 * 这些是 `api_paths.dart` 里已声明、当前两个 App 与网页都还没用到的接口。
 * 列在这里有两个作用：
 *   1. 让"未实现的契约"可见，而不是靠记忆；
 *   2. 谁把它们实现了，就把条目移到 `REQUIRED` —— 那时它们会被真正校验。
 *
 * 注意：**不要**为了让测试变绿而把实际用到的路径挪到这里。
 */
const PENDING = [
  ['GET', '/auth/admin/audits', '登录审计'],
  ['GET', '/auth/admin/export-audits', '导出审计'],
  ['PATCH', '/activities/1', '已发布活动的受限编辑'],
  ['GET', '/activities/1/changes', '规则变更记录'],
  ['POST', '/activities/1/checkins/manual', '人工补录签到'],
  ['POST', '/attendances/1:remind', '在岗提醒'],
];

test('路由形状：客户端真实用到的每条路径，服务端都必须认识', () => {
  const router = buildRouter();
  const missing = [];

  for (const [method, path, label] of REQUIRED) {
    if (!router.match(method, path)) {
      missing.push(`${method} ${path}  （${label}）`);
    }
  }

  assert.deepEqual(
    missing,
    [],
    '以下路径服务端匹配不上 —— 客户端会收到 404「接口不存在」：\n  ' +
      missing.join('\n  '),
  );
});

test('路由形状：未实现的契约路径要如实标注（不能悄悄消失）', () => {
  /*
    这条**不**断言它们必须匹配 —— 它们确实还没实现。
    它只确保这份清单不会因为有人"顺手删掉"而失去可见性：
    如果某条已经被实现了，就应该显式移到 REQUIRED，而不是留在这里冒充缺口。
  */
  const router = buildRouter();
  const alreadyImplemented = PENDING.filter(([method, path]) => router.match(method, path));

  assert.deepEqual(
    alreadyImplemented.map(([, path, label]) => `${path}（${label}）`),
    [],
    '这些已经实现了，请从 PENDING 移到 REQUIRED，让它们被真正校验。',
  );
});

test('路由形状：复核接口按**路径段**注册（本次报障的回归）', () => {
  /*
    同一个文件里，在岗确认确实是 `:confirm` 动作后缀，
    所以很容易被照着抄成 `:review`。这条把正确形态钉住。

    同时验证参数解析 —— handler 靠 `ctx.params.checkinId` 取 id。
  */
  const router = buildRouter();
  const matched = router.match('POST', '/checkins/abc/review');
  assert.ok(matched, '`/checkins/{id}/review` 必须能匹配');
  assert.equal(matched.params.checkinId, 'abc', 'checkinId 要能被解析出来');

  // 错误形态（动作后缀）不应被当成正确解 —— 它现在匹配不上，
  // 若将来有人"补"了一条 :review 路由，这里会提醒去看看到底哪种才是契约。
  assert.equal(
    router.match('POST', '/checkins/abc:review'),
    null,
    '不要为了兼容而再加一条 `:review` 路由：契约是路径段形式，多一条只会掩盖问题',
  );
});

test('路由形状：在岗确认是动作后缀，参数解析正确', () => {
  const router = buildRouter();
  const matched = router.match('POST', '/attendances/42:confirm');
  assert.ok(matched, '`/attendances/{id}:confirm` 必须能匹配');
  assert.equal(matched.params.taskId, '42');
});

test('路由形状：详情与流转共存时各自命中正确的路由', () => {
  const router = buildRouter();

  const detail = router.match('GET', '/activities/7');
  assert.ok(detail, '详情路由应匹配');
  assert.equal(detail.params.id, '7');

  const transition = router.match('POST', '/activities/7:transition');
  assert.ok(transition, '流转路由应匹配');
  assert.equal(transition.params.id, '7', '动作后缀不能被当成 id 的一部分');
});

test('路由形状：具体子资源优先于 `/activities/:id`（顺序回归）', () => {
  /*
    `organizers` / `export` 必须排在 `/activities/:id` 之前，
    否则会被当成活动 id 吃掉，导出请求变成"活动 export 不存在"。
  */
  const router = buildRouter();

  const organizers = router.match('GET', '/activities/organizers');
  assert.ok(organizers, 'organizers 必须能匹配');
  assert.notEqual(organizers.params.id, 'organizers', '不能被当成活动 id');

  const exportList = router.match('GET', '/activities/export');
  assert.ok(exportList, '列表导出必须能匹配');
  assert.notEqual(exportList.params.id, 'export', '不能被当成活动 id');
});
