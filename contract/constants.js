/**
 * 契约常量 —— 三端（同步服务 / Web 前端 / 两个 App）共用的**唯一来源**。
 *
 * ## 为什么要有这个文件
 *
 * 移动端阶段的教训：契约散落在各端时，同一个概念会长出两套词表。
 * 实测踩到过「服务端下发 `success`、客户端 enum 期望 `checked_in`」，
 * 结果是**看板上所有已签到的人都显示成"未知"** —— 不报错，
 * 只是安静地显示错的东西。
 *
 * 因此这一层刻意**不含任何逻辑**，只有字面量与枚举。
 * 三端各自读取同一份定义，词表不一致在结构上就不可能发生。
 *
 * ## 权威来源
 *
 * 取值全部来自《网页开发方案》：
 *   * §6.1 通用约定（响应信封、错误码、分页、鉴权头）
 *   * §4.1 活动字段字典（冻结版）
 *   * §4.4 / §4.5 签到与在岗状态
 *   * §5.1 状态与转移
 *
 * 凡本文件与方案不符，以方案为准；修改必须同步更新 `docs/`。
 */

// ══════════════════════════════════════════════════════════════════════════
// 响应信封（方案 §6.1）
// ══════════════════════════════════════════════════════════════════════════

/**
 * 字段名是 **`msg`**，不是 `message`。
 *
 * 为减少联调摩擦，响应里会同时下发 `message`（与 `msg` 同值），
 * 但**契约字段是 `msg`**，新代码只应读它。
 */
export const ENVELOPE_FIELDS = Object.freeze({
  code: 'code',
  msg: 'msg',
  data: 'data',
  errors: 'errors',
  traceId: 'traceId',
  serverTime: 'serverTime',
});

/**
 * 方案 §6.1 授权的**8 个**线码值。
 *
 * ⚠️ 这是本项目最容易踩的坑之一：业务上有几十种细分错误，
 * 而契约只授权 8 个码值，因此**多个语义共享同一个码**。
 * 于是「按码值反查原因」是**不可逆**的 —— 客户端必须
 * 用族级谓词判断「该做什么」，用 `msg` 判断「具体为什么」，
 * 用 `errors[].field` 定位「哪个字段」。
 *
 * 绝不能写成 `if (code === 40301) return '你不在名单里'`：
 * 40301 同时代表越权 / 不在名单 / 设备不符 / 二次校验失败。
 */
export const ERROR_CODES = Object.freeze({
  OK: 0,
  /** 参数错误、业务性拒绝（签到窗口外、原因太短等）。 */
  BAD_REQUEST: 40001,
  /** 未认证：令牌缺失/无效/过期、邀请码错误、账号锁定。 */
  UNAUTHORIZED: 40101,
  /** 越权：不在名单、设备不符、角色不符、二次校验失败。 */
  FORBIDDEN: 40301,
  /** 不存在：活动、导出文件、在岗任务。 */
  NOT_FOUND: 40401,
  /** 状态冲突：非法流转、版本冲突、规则冻结、重复提交。 */
  CONFLICT: 40901,
  /** 限流。 */
  RATE_LIMITED: 42901,
  /** 服务异常。 */
  SERVER_ERROR: 50001,
});

/** 本地码（**仅客户端使用**，永不出现在线上）。 */
export const LOCAL_ERROR_CODES = Object.freeze({
  /** 离线：已入本地队列。 */
  OFFLINE: -1,
  /** 超时。 */
  TIMEOUT: -2,
  /** 未知。 */
  UNKNOWN: -99,
});

/** 族级谓词 —— 客户端应据此决定「该做什么」。 */
export const errorFamilies = Object.freeze({
  isSuccess: (code) => code === ERROR_CODES.OK,
  /** 需要重新拿令牌（**只有**这一类应清除令牌）。 */
  isAuthFailure: (code) => code === ERROR_CODES.UNAUTHORIZED,
  isForbidden: (code) => code === ERROR_CODES.FORBIDDEN,
  isNotFound: (code) => code === ERROR_CODES.NOT_FOUND,
  isConflict: (code) => code === ERROR_CODES.CONFLICT,
  isBadRequest: (code) => code === ERROR_CODES.BAD_REQUEST,
  isRateLimited: (code) => code === ERROR_CODES.RATE_LIMITED,
  isServerError: (code) => code === ERROR_CODES.SERVER_ERROR,
});

// ══════════════════════════════════════════════════════════════════════════
// 分页（方案 §6.1：`page` 从 1 起，`size` 默认 20、上限 100）
// ══════════════════════════════════════════════════════════════════════════

export const PAGING = Object.freeze({
  page: 'page',
  /** ⚠️ 是 `size`，不是 `pageSize`。后者仅作早期客户端的兼容输入。 */
  size: 'size',
  total: 'total',
  hasMore: 'hasMore',
  items: 'items',
  stats: 'stats',
  defaultSize: 20,
  maxSize: 100,
});

// ══════════════════════════════════════════════════════════════════════════
// 鉴权头（方案 §6.1）
// ══════════════════════════════════════════════════════════════════════════

export const HEADERS = Object.freeze({
  authorization: 'Authorization',
  /** 幂等键。契约名带 `X-` 前缀。 */
  idempotencyKey: 'X-Idempotency-Key',
  deviceId: 'X-Device-Id',
  apiVersion: 'X-Api-Version',
  clientVersion: 'X-Client-Version',
});

// ══════════════════════════════════════════════════════════════════════════
// 枚举
// ══════════════════════════════════════════════════════════════════════════

/** 活动状态（方案 §5.1）。 */
export const ACTIVITY_STATUS = Object.freeze({
  DRAFT: 'draft',
  PUBLISHED: 'published',
  ONGOING: 'ongoing',
  FINISHED: 'finished',
  CANCELLED: 'cancelled',
});

/** 终态：不可再流转。 */
export const TERMINAL_STATUSES = Object.freeze([
  ACTIVITY_STATUS.FINISHED,
  ACTIVITY_STATUS.CANCELLED,
]);

/**
 * 合法状态转移（方案 §5.1）。
 *
 * 放在契约层而不是服务实现里，是因为**前端也要用它来决定显示哪个按钮** ——
 * 两边各写一份必然漂移。注意：前端据此过滤只是「不让用户点到必然失败的按钮」，
 * **判定仍在服务端**。
 */
export const STATUS_TRANSITIONS = Object.freeze({
  [ACTIVITY_STATUS.DRAFT]: [ACTIVITY_STATUS.PUBLISHED, ACTIVITY_STATUS.CANCELLED],
  [ACTIVITY_STATUS.PUBLISHED]: [ACTIVITY_STATUS.ONGOING, ACTIVITY_STATUS.CANCELLED],
  [ACTIVITY_STATUS.ONGOING]: [ACTIVITY_STATUS.FINISHED, ACTIVITY_STATUS.CANCELLED],
  [ACTIVITY_STATUS.FINISHED]: [],
  [ACTIVITY_STATUS.CANCELLED]: [],
});

/** 名单报名状态（方案 §4.3）。 */
export const SIGNUP_STATUS = Object.freeze({
  /** 已入库。 */
  REGISTERED: 'registered',
  /** 已移出（软删，记录保留）。 */
  CANCELLED: 'cancelled',
});

/**
 * 名单行的**签到**状态（方案 §4.4 / §4.8 看板四态）。
 *
 * ⚠️ 线值取自 `checkin.status`，**不是另造一套词**。
 * 移动端阶段实测踩到过：这里曾用 `checked_in` / `not_checked_in`，
 * 而 `checkin.status` 用 `success` / `pending_review`，
 * 两套并存导致看板整列显示"未知"。
 */
export const PARTICIPANT_CHECKIN_STATUS = Object.freeze({
  CHECKED_IN: 'success',
  PENDING_REVIEW: 'pending_review',
  /** 尚无签到记录（**不是**"判定为未签到"）。 */
  NONE: 'none',
});

/** 签到结果（方案 §4.4）。 */
export const CHECKIN_STATUS = Object.freeze({
  SUCCESS: 'success',
  PENDING_REVIEW: 'pending_review',
  REJECTED: 'rejected',
});

/** 签到方式（方案 §4.4：`geo` 默认 / `qrcode` / `manual`）。 */
export const CHECKIN_METHOD = Object.freeze({
  /** 定位签到 —— 契约规定的默认值。 */
  GEO: 'geo',
  /**
   * 早期写法，等价于 `geo`。
   * 读取侧兼容、**写入侧只用 `geo`**（否则线上会长期并存两套词表）。
   */
  GPS_LEGACY: 'gps',
  /** 人工补录（管理端）。 */
  MANUAL: 'manual',
});

/** 在岗抽查任务状态（方案 §4.5）。 */
/**
 * 在岗抽查的触发方式。
 *
 * ## 为什么要有两种
 *
 * `auto` 按"开始后 N 分钟第一次、之后每 M 分钟"自动生成任务 ——
 * 适合人多的常规活动，发布者不必盯着。
 *
 * `manual` **不自动生成**，由发布者在现场看板上按需触发一次 ——
 * 适合短活动、或"我只想临时点个名"的场景。自动抽查在短活动里
 * 反而会让人觉得被机器盯着，而发布者其实只想抽查一两次。
 */
export const ATTENDANCE_MODE = Object.freeze({
  /** 自动：按开始时间与间隔生成（默认）。 */
  AUTO: 'auto',
  /** 手动：不自动生成，由发布者触发。 */
  MANUAL: 'manual',
});

export const ATTENDANCE_TASK_STATUS = Object.freeze({
  PENDING: 'pending',
  DONE: 'done',
  MISSED: 'missed',
  /** 已豁免：**不计入分母**。 */
  EXCUSED: 'excused',
});

/** 考勤汇总等级（方案 §6.4.7，决策 D-7：partial 阈值 = 完成率 ≥0.7）。 */
export const ATTENDANCE_SUMMARY = Object.freeze({
  FULL: 'full',
  PARTIAL: 'partial',
  /**
   * 证据不足 —— **不等于缺席**。
   * 完成率不足或无已定案任务都归到这里，不定性为没到场。
   */
  INSUFFICIENT: 'insufficient',
  ABSENT: 'absent',
});

// ══════════════════════════════════════════════════════════════════════════
// 默认值与边界（方案 §4.1 字段字典 · 冻结版）
// ══════════════════════════════════════════════════════════════════════════

export const DEFAULTS = Object.freeze({
  apiVersion: 'v1',

  /** 签到窗口：提前 30 分钟 / 延后 60 分钟。 */
  checkinWindowBeforeMinutes: 30,
  checkinWindowAfterMinutes: 60,

  /** 签到半径（米）：范围与按场地类型的默认值。 */
  checkinRadiusMin: 10,
  checkinRadiusMax: 1000,
  checkinRadiusOutdoor: 300,
  checkinRadiusIndoor: 150,

  /**
   * 判定阈值（方案 §6.1 评分表）。
   * ⚠️ 自动通过门槛是 60，而**单次采样只能拿到围栏分 40** ——
   * 因此现场会有较多签到落到「待确认」，这是设计意图（宁可疑、不误放），
   * 但真机验证时要盯住这个比例（见 docs/device-test-guide.md）。
   */
  scoreSuccessThreshold: 60,
  scorePendingReviewThreshold: 30,
  /** 超过此精度不计分。 */
  maxUsableAccuracyMeters: 100,
  /** 精度 ≤ 此值视为"紧贴围栏中心"，拿满围栏分。 */
  tightAccuracyMeters: 50,
  /** 围栏外宽容带上限（半径的倍数）：1.5 倍之外一律 0 分（验收 A12）。 */
  fenceToleranceFactor: 1.5,

  /*
    评分构成（方案 §6.1）。

    ⚠️ 这些权重**必须与 mock_server 完全一致** —— 离线演示模式（本机引擎）
    与真服务端如果算得不一样，同一个动作在两种模式下会得到不同结论，
    而用户会认为"系统不稳定"。真机测试期间就因为两边口径不同
    出现过"演示能自动通过、真服务端转人工"的怪现象。

    现在 mock 与 server 都从这里取，唯一的数字来源。
  */
  scoreInsideFenceTight: 40,
  scoreInsideFenceLoose: 25,
  scoreRecentInsideFence: 15,
  scoreWifiBssidMatched: 20,
  scoreCampusIpMatched: 10,
  scoreDwellVerified: 15,
  scoreSamplesConsistent: 10,
  penaltyMockLocation: -60,
  penaltyMultiAccountSameDevice: -30,
  penaltyTrajectoryAnomaly: -40,
  /**
   * 判定模拟定位的精度上限。
   *
   * 真机测试修正过：早期只要"多次采样完全一致"就判伪造，误杀了
   * 静止在室内的真实用户（GPS 抖动小是正常的）。现在要求
   * **坐标与精度都完全一致 且 精度 ≤5m** —— 那是模拟器才有的理想值。
   */
  mockPerfectAccuracyMeters: 5,
  /** 最小采样数：少于 2 次无法判断一致性。 */
  minSamplesForConsistency: 2,

  /** 在岗抽查：首次延迟 / 间隔 / 响应窗口 / 超时宽限（分钟）。 */
  /** 默认抽查方式：自动（保持既有行为，老活动不受影响）。 */
  attendanceMode: 'auto',
  attendanceFirstDelayMinutes: 15,
  attendanceIntervalMinutes: 30,
  attendanceResponseWindowMinutes: 5,
  attendanceMissGraceMinutes: 2,
  /** 末次抽查与结束之间至少留 30 分钟。 */
  attendanceLastTaskMarginMinutes: 30,
  /** 考勤 partial 阈值：完成率 ≥ 0.7。 */
  attendancePartialMinRate: 0.7,

  /** 数据留存期（天）：活动终态 + 7 天。 */
  retentionDays: 7,
  /** 到期前多少小时提醒导出。 */
  retentionWarnHours: 48,

  /** 取消原因最小长度。 */
  cancelReasonMinLength: 5,

  /** 时长（小时）：>0 且 ≤999.9，步长 0.5。 */
  durationMaxHours: 999.9,
  durationStepHours: 0.5,

  /** 字段长度上限（保证列表页同构呈现）。 */
  titleMaxLength: 60,
  organizerMaxLength: 50,
  locationMaxLength: 100,
  summaryMaxLength: 120,
  contactMaxLength: 50,
  externalIdMaxLength: 64,

  /** 时钟偏差容忍（秒）。 */
  maxClockSkewSeconds: 60,
  /** 请求超时（秒）。 */
  requestTimeoutSeconds: 10,
});

/** 分页默认值便于直接引用。 */
export const PAGE_DEFAULT_SIZE = PAGING.defaultSize;
export const PAGE_MAX_SIZE = PAGING.maxSize;

/**
 * 免责声明 —— **由服务端下发**，不在各端硬编码。
 *
 * 它是发布者面对「你为什么扣我时长」这类质疑时的依据，
 * 措辞必须与服务端记录的口径一致。各端自己写一份，两边就可能对不上。
 */
export const DISCLAIMER =
  '考勤结果仅作现场管理参考，不作为志愿时长认定依据，不自动产生任何扣减。';
