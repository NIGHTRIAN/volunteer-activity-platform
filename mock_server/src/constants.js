/**
 * 契约常量镜像。
 *
 * ⚠️ 这是 `packages/shared_core/lib/src/contract/field_dictionary.dart` 的 JS 镜像。
 * Mock 服务必须在**判定行为**上与 App 侧完全一致，否则联调时会互相打架。
 * 任何一侧改动都必须同步另一侧——这是 A0 契约冻结的一部分。
 *
 * 数值来源（按权威性排序）：
 *   1. 《网页开发方案》§6.1 通用约定、§4.1 活动字段字典（冻结版）、§6.4 关键接口
 *   2. 《移动端应用开发方案》§6.1 评分表、§6.2 抽查参数
 *   3. 两方案冲突处见 `docs/decisions.md` 与 `docs/contract-alignment-web-plan.md`
 */

export const DEFAULTS = {
  // ── 定位精度（§6.1）────────────────────────────────────────────────
  MAX_USABLE_ACCURACY_M: 100,
  TIGHT_ACCURACY_M: 50,

  // ── 风险评分（§6.1）────────────────────────────────────────────────
  SCORE_INSIDE_FENCE_TIGHT: 40,
  SCORE_INSIDE_FENCE_LOOSE: 25,
  SCORE_RECENT_INSIDE_FENCE: 15,
  SCORE_WIFI_BSSID_MATCHED: 20,
  SCORE_CAMPUS_IP_MATCHED: 10,
  SCORE_DWELL_VERIFIED: 15,
  SCORE_SAMPLES_CONSISTENT: 10,
  PENALTY_MOCK_LOCATION: -60,
  PENALTY_MULTI_ACCOUNT_SAME_DEVICE: -30,
  PENALTY_TRAJECTORY_ANOMALY: -40,

  /**
   * "伪造指纹"的精度上限（米）。
   *
   * 用于区分"模拟定位"与"真人站着不动"——这是真机测试发现的坑。
   *
   * ## 问题
   *
   * 原来的判据是："多次采样坐标与精度**完全一致** → 真实 GPS 几乎不可能
   * 这么干净 → 判为模拟定位，-60 并强制转人工"。
   *
   * 真机（Redmi Note 12T Pro，Android 15）实测：志愿者站在签到点上不动，
   * 3 次采样全部**逐位相同**（34.218196/117.137571/±30m）——
   * 因为 Android 的融合定位在设备静止时直接返回**缓存值**。
   * 于是 40(围栏)+10(采样一致)-60(模拟)= **-10 分，强制转人工**。
   *
   * 后果很严重：**方案 §6.1 的"自动通过"路径实际上永远走不到**。
   * 而且逻辑自相矛盾 —— 一边给"采样一致"加 10 分，一边又拿它当作弊证据。
   *
   * ## 现在的判据
   *
   * 完全一致**不足以下结论**，还必须精度好得不像真机：
   * 融合定位在室内/城市静止时典型精度是 20–50 m；
   * 而改写定位的作弊工具通常直接写一个理想值（0–5 m）。
   *
   * 所以要求 `accuracy <= 5 m` 且多次采样完全一致，才判为模拟定位。
   *
   * 真正可靠的判据是 Android 系统给的 `isMock` 标志（`clientFlagged`），
   * 那条**依然命中即转人工**，不受本阈值影响。
   */
  MOCK_PERFECT_ACCURACY_M: 5,

  // 判定门槛：>=60 success；30–59 pending_review；<30 rejected
  SCORE_SUCCESS_THRESHOLD: 60,
  SCORE_PENDING_REVIEW_THRESHOLD: 30,
  RECENT_INSIDE_FENCE_WINDOW_S: 60,

  // ── 抽查（§6.2）───────────────────────────────────────────────────
  ATTENDANCE_FIRST_DELAY_MIN: 15,
  ATTENDANCE_INTERVAL_MIN: 30,
  ATTENDANCE_RESPONSE_WINDOW_MIN: 5,
  ATTENDANCE_MISS_GRACE_MIN: 2,

  /**
   * 末次抽查距活动结束的最小留白（分钟）。
   *
   * ⚠️ 这个值是**被验收用例 A20 反推出来的**，不是随手取的：
   * 方案 §6.2 同时给了两条约束——
   *   (a)「末次不晚于 endTime − 15min」
   *   (b)「2 小时活动 3 次（T+15 / T+45 / T+75）」
   * 若留白取 15 分钟，2 小时活动的可用区间是 [15, 105]，30 分钟间隔会产出
   * **4 次**（T+15/45/75/105），与 (b) 矛盾。
   * 取 30 分钟则可用区间为 [15, 90]，恰好 3 次，与 (b) 一致。
   *
   * 因此以 (b) 为准，(a) 的「15min」理解为"末次抽查要留出足够的收尾时间"
   * 而非精确的 15 分钟。**此项已列入 docs/contract-assumptions.md 待后端确认。**
   */
  ATTENDANCE_LAST_TASK_MARGIN_MIN: 30,

  /**
   * 考勤汇总判为 `partial` 的最低完成率（网页方案 §6.4.7）。
   *
   * ⚠️ 移动端方案 §4.8 没有阈值，判据是「有 missed 且 done>0」。
   * 已决定采用网页方案的 0.7：因为"3 次里完成 2 次"（0.67）与
   * "10 次里完成 6 次"（0.6）的风险程度明显不同，不该同列。
   */
  ATTENDANCE_PARTIAL_MIN_RATE: 0.7,

  // ── 签到窗口（决策 D-5：采用网页方案 §4.1 冻结版字段字典）──────────
  //
  // ⚠️ 两方案冲突：移动端方案 §4.2 写 15/15，网页方案 §4.1 写 30/60。
  // 已决定采用**网页方案**：§4.1 是标注"冻结版"的字段字典，权威性更高，
  // 且移动端方案未为 15/15 给出理由。宽容窗口对现场更友好
  //（志愿者迟到 20 分钟仍能签到）。
  CHECKIN_WINDOW_BEFORE_MIN: 30,
  CHECKIN_WINDOW_AFTER_MIN: 60,

  // ── 签到半径（网页方案 §4.1）──────────────────────────────────────
  /** 范围下限（米）。低于 10 米时 GPS 精度本身就不可靠。 */
  MIN_CHECKIN_RADIUS_M: 10,
  /** 范围上限（米）。 */
  MAX_CHECKIN_RADIUS_M: 1000,
  /** 室外默认（米）。 */
  DEFAULT_CHECKIN_RADIUS_OUTDOOR_M: 300,
  /** 室内默认（米）。室内精度差，因此默认更小以免误判"在围栏内"。 */
  DEFAULT_CHECKIN_RADIUS_INDOOR_M: 150,
  /** 未指定场地类型时的默认（取室外值）。 */
  DEFAULT_CHECKIN_RADIUS_M: 300,

  // ── 活动字段长度约束（网页方案 §4.1）──────────────────────────────
  TITLE_MAX_CHARS: 60,
  ORGANIZER_MAX_CHARS: 50,
  SUMMARY_MAX_CHARS: 120,
  LOCATION_MAX_CHARS: 100,
  CONTACT_MAX_CHARS: 50,
  /** 时长上限（小时）。 */
  DURATION_MAX_HOURS: 999.9,
  /** 时长步长（小时）。 */
  DURATION_STEP_HOURS: 0.5,
  LIST_SUMMARY_MAX_CHARS: 60,

  // ── 降级手段 ──────────────────────────────────────────────────────
  //
  // 方案 §6.3 设计了动态签到码（签到码 5 分钟、在岗码 60 秒轮换、管理端全屏展示、
  // 预取续播）。本项目决定**不实现**该功能，理由见 docs/decisions.md D-2：
  //   1. 动态码证明不了"人在现场"—— 码可以被转发，防不住脱岗；
  //   2. 它引入轮换 / 预取 / 断网续播 / 时钟基准一整套额外逻辑，
  //      每一环都可能成为现场故障点；
  //   3. 拒定位权限时仍有**两级**兜底，不会出现死路（方案 §7 的硬性要求）：
  //      管理端现场核实（method = admin_scan）与人工补录（method = manual）。
  //
  // ⚠️ 影响验收用例 A16：原预期含"动态码"降级，现缩为后两条。

  // ── 身份与留存（§2、§14.1）─────────────────────────────────────────
  // 默认邀请码。方案 §2/§14.1/A2 定为 1111 且不强制更换；
  // 可由环境变量 ADMIN_INVITE_CODE 覆盖（对应「服务端可配置」）。
  DEFAULT_ADMIN_INVITE_CODE: '1111',
  ADMIN_CODE_MAX_ATTEMPTS: 5,
  ADMIN_CODE_LOCK_MIN: 10,
  ADMIN_TOKEN_IDLE_EXPIRY_H: 24,
  RETENTION_DAYS: 7,

  // ── 取消活动（§4.4）───────────────────────────────────────────────
  /** 取消原因最少字数。取消不可逆，因此要求填写实质原因而非「取消」二字。 */
  CANCEL_REASON_MIN_LENGTH: 5,

  /** 活动名称、简介等展示字段的长度上限。 */
  TITLE_MAX_CHARS: 60,
  LIST_SUMMARY_MAX_CHARS: 60,

  // ── 契约版本（§1.4）────────────────────────────────────────────────
  API_VERSION: 'v1',
};

/**
 * 细分错误目录：语义名 → { code, message, http }。
 *
 * **这是错误的唯一真源。**
 *
 * 为什么需要它：方案只授权了 8 个线码值，而业务需要区分几十种情形。
 * 如果用 `ERR_HTTP[code]` 反查 HTTP 状态，同码值的细分会互相覆盖
 * （例如"不在名单中"需要 403、"参数错"需要 400，但两者线码都是 40001/40301）。
 *
 * 因此改用**语义名**索引：调用方写 `fail('NOT_IN_PARTICIPANT_LIST')`，
 * 由本表同时给出线码、文案与 HTTP 状态。这样：
 *   * 线码严格符合方案；
 *   * 每个细分保留自己的 HTTP 状态与文案；
 *   * 客户端判断靠 `errors[].field` 与文案，不靠码值。
 */
export const CATALOG = {
  OK: { code: 0, message: '成功', http: 200 },

  // ── 40001 参数错误 ──────────────────────────────────────────────────
  BAD_REQUEST: { code: 40001, message: '请求参数有误', http: 400 },
  IDEMPOTENCY_CONFLICT: { code: 40001, message: '重复请求且内容不一致', http: 409 },
  API_VERSION_UNSUPPORTED: { code: 40001, message: '当前版本过旧，请升级应用', http: 400 },
  OUTSIDE_CHECKIN_WINDOW: { code: 40001, message: '不在签到时段内', http: 409 },
  CANCEL_REASON_TOO_SHORT: { code: 40001, message: '取消原因至少 5 个字', http: 400 },

  // ── 40101 未认证 ────────────────────────────────────────────────────
  UNAUTHORIZED: { code: 40101, message: '登录状态已失效', http: 401 },
  ADMIN_CODE_INVALID: { code: 40101, message: '邀请码错误', http: 401 },
  ADMIN_CODE_LOCKED: { code: 40101, message: '错误次数过多，账号已锁定', http: 423 },
  INVITE_CODE_INVALID: { code: 40101, message: '邀请码无效或已被使用', http: 401 },
  GRANT_EXPIRED: { code: 40101, message: '本次活动授权已过期', http: 401 },
  ADMIN_TOKEN_EXPIRED: { code: 40101, message: '管理端登录已过期，请重新登录', http: 401 },

  // ── 40301 越权 ──────────────────────────────────────────────────────
  FORBIDDEN: { code: 40301, message: '无权操作该活动', http: 403 },
  NOT_IN_PARTICIPANT_LIST: { code: 40301, message: '你不在本次活动名单中', http: 403 },
  IDENTITY_MISMATCH: { code: 40301, message: '姓名或手机号后四位不匹配', http: 403 },
  DEVICE_ALREADY_BOUND: { code: 40301, message: '该身份已绑定其他设备', http: 403 },
  DEVICE_MISMATCH: { code: 40301, message: '设备校验未通过，请重新绑定', http: 403 },
  ROLE_NOT_ALLOWED: { code: 40301, message: '当前身份无权访问', http: 403 },

  // ── 40401 不存在 ────────────────────────────────────────────────────
  ACTIVITY_NOT_FOUND: { code: 40401, message: '活动不存在或已过留存期', http: 404 },
  EXPORT_NOT_FOUND: { code: 40401, message: '导出文件不存在或已过期', http: 404 },
  ATTENDANCE_TASK_NOT_FOUND: { code: 40401, message: '在岗任务不存在', http: 404 },

  // ── 40901 状态冲突 ──────────────────────────────────────────────────
  ACTIVITY_STATE_INVALID: { code: 40901, message: '当前活动状态不支持该操作', http: 409 },
  VERSION_CONFLICT: { code: 40901, message: '状态已更新，请重试', http: 409 },
  ACTIVITY_RULE_FROZEN: { code: 40901, message: '已发布活动的关键字段不可修改', http: 409 },
  ALREADY_CHECKED_IN: { code: 40901, message: '你已完成签到', http: 409 },
  PARTICIPANT_DUPLICATED: { code: 40901, message: '名单中已存在该学号', http: 409 },
  QUOTA_EXCEEDED: { code: 40901, message: '活动名额已满', http: 409 },
  ATTENDANCE_TASK_CLOSED: { code: 40901, message: '该在岗确认已结束', http: 409 },

  // ── 42901 限流 ──────────────────────────────────────────────────────
  TOO_MANY_REQUESTS: { code: 42901, message: '操作过于频繁，请稍后重试', http: 429 },

  // ── 50001 服务异常 ──────────────────────────────────────────────────
  SERVER_ERROR: { code: 50001, message: '服务暂时不可用，请稍后重试', http: 500 },
};

/**
 * 兼容层：语义名 → 线码值。
 *
 * 保留 `ERR.XXX` 是为了让业务代码里的比较语句（`code === ERR.FORBIDDEN`）
 * 继续可读。注意**多个名字会映射到同一个数**，这是设计使然。
 */
export const ERR = Object.fromEntries(
  Object.entries(CATALOG).map(([name, def]) => [name, def.code]),
);

/**
 * 取某个细分错误的默认文案。
 *
 * 放在 constants.js（而不是 api_auth.js）是为了避免循环依赖：
 * `scoring.js` 与 `api_checkin.js` 都需要它，而它们已经在 api_auth 的下游。
 *
 * ⚠️ 不要用 `ERR_MSG[code]` 反查文案——线码值已合并成 8 个，
 * 反查只会拿到同码值下**第一个**细分的文案，是错的。
 */
export function msgOf(name) {
  return CATALOG[name]?.message ?? CATALOG.SERVER_ERROR.message;
}

/** 活动状态。 */
export const ACTIVITY_STATUS = {
  DRAFT: 'draft',
  PUBLISHED: 'published',
  ONGOING: 'ongoing',
  FINISHED: 'finished',
  CANCELLED: 'cancelled',
};

/**
 * 分页字段与默认值（《网页开发方案》§6.1）。
 *
 * > 分页 `page` 从 1 起，`size` 默认 20、上限 100
 *
 * ⚠️ 是 **`size`**，不是 `pageSize`。`pageSize` 仅作为早期客户端的兼容输入。
 */
export const PagingFields = {
  page: 'page',
  size: 'size',
  total: 'total',
  hasMore: 'hasMore',
  items: 'items',
  stats: 'stats',
  defaultSize: 20,
  maxSize: 100,
};

/** 终态。终态时间 + 7 天为数据销毁点（§14.1-6）。 */
export const TERMINAL_STATUSES = [ACTIVITY_STATUS.FINISHED, ACTIVITY_STATUS.CANCELLED];

/** 可签到状态（§6.1 门槛之一）。 */
export const CHECKIN_ALLOWED_STATUSES = [ACTIVITY_STATUS.PUBLISHED, ACTIVITY_STATUS.ONGOING];

/** 报名状态。 */
export const SIGNUP_STATUS = {
  SIGNED: 'signed',
  PENDING_CONFIRM: 'pending_confirm',
  CANCELLED: 'cancelled',
};

/**
 * 签到方式。
 *
 * 契约值来自《网页开发方案》§4.4：`geo`（默认）/ `qrcode` / `manual`。
 *
 * ⚠️ 本平台**不启用动态签到码**（决策 D-2），因此 `qrcode` 不被接受。
 * `gps` 作为早期写法保留为别名 —— 联调期两版客户端可能同时存在。
 */
export const CHECKIN_METHOD = {
  /** 定位签到。**契约规定的默认方式**。 */
  GEO: 'geo',
  /** 早期写法，等价于 `geo`。 */
  GPS: 'gps',
  /** 人工补录：设备故障、发布者现场核实等。仅管理端可发起。 */
  MANUAL: 'manual',
};

/** 签到结果。 */
export const CHECKIN_STATUS = {
  SUCCESS: 'success',
  PENDING_REVIEW: 'pending_review',
  REJECTED: 'rejected',
};

/** 名单报名状态（网页方案 §4.3）。 */
export const SIGNUP_STATUS_CONTRACT = {
  REGISTERED: 'registered',
  CANCELLED: 'cancelled',
};

/** 在岗任务状态。 */
export const TASK_STATUS = {
  PENDING: 'pending',
  DONE: 'done',
  MISSED: 'missed',
  EXCUSED: 'excused',
};

/** 考勤汇总等级（§4.8，**参考信息**，不自动扣减）。 */
export const SUMMARY = {
  FULL: 'full',
  PARTIAL: 'partial',
  INSUFFICIENT: 'insufficient',
  ABSENT: 'absent',
};

/**
 * 发布后「关键字段」——默认禁改，确需修改要填原因并记录前后值（§4.5）。
 * 非关键字段（简介、详情、联系方式、备注）可自由修改。
 */
export const FROZEN_FIELDS = [
  'startTime',
  'endTime',
  'durationHours',
  'checkinRadius',
  'checkinWindowBefore',
  'checkinWindowAfter',
  'attendanceFirstDelay',
  'attendanceInterval',
  'attendanceResponseWindow',
  'signupDeadline',
];
