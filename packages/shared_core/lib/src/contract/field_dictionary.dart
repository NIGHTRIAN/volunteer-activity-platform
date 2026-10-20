/// 契约常量：跨端字段字典与默认值。
///
/// 来源：《移动端应用开发方案》§3 数据模型、§4.2 录入校验、§6.1 判定门槛、§6.2 抽查参数。
///
/// 这些常量必须与服务端字段字典逐字一致；任何改动都要走《接口契约》的变更规则
/// （方案 §13-A8「契约变更不同步导致双端返工」）。
library;

/// 活动（`activity`）字段名。
///
/// 与后端 JSON key 一一对应，禁止在业务代码里散落字符串字面量。
abstract final class ActivityFields {
  static const String id = 'id';
  static const String title = 'title';
  static const String organizer = 'organizer';
  static const String durationHours = 'durationHours';
  static const String startTime = 'startTime';
  static const String endTime = 'endTime';
  static const String signupDeadline = 'signupDeadline';
  static const String location = 'location';
  static const String geoLat = 'geoLat';
  static const String geoLng = 'geoLng';
  static const String checkinRadius = 'checkinRadius';
  static const String checkinWindowBefore = 'checkinWindowBefore';
  static const String checkinWindowAfter = 'checkinWindowAfter';
  static const String attendanceFirstDelay = 'attendanceFirstDelay';
  static const String attendanceInterval = 'attendanceInterval';
  static const String attendanceResponseWindow = 'attendanceResponseWindow';
  static const String quota = 'quota';
  static const String enrolled = 'enrolled';
  static const String status = 'status';
  static const String tags = 'tags';
  static const String summary = 'summary';
  static const String description = 'description';
  static const String contact = 'contact';
  static const String ownerId = 'ownerId';
  static const String version = 'version';
  static const String ruleSnapshot = 'ruleSnapshot';
  static const String createdAt = 'createdAt';
  static const String updatedAt = 'updatedAt';
}

/// 参与者（`participant`）字段名。
abstract final class ParticipantFields {
  static const String userNo = 'userNo';
  static const String name = 'name';
  static const String phone = 'phone';
  static const String signupStatus = 'signupStatus';
  static const String checkinStatus = 'checkinStatus';
  static const String removedAt = 'removedAt';
}

/// 签到（`checkin`）字段名。
abstract final class CheckinFields {
  static const String id = 'id';
  static const String method = 'method';
  static const String status = 'status';
  static const String reason = 'reason';
  static const String geoLat = 'geoLat';
  static const String geoLng = 'geoLng';
  static const String accuracy = 'accuracy';
  static const String score = 'score';
  static const String scoreBreakdown = 'scoreBreakdown';
  static const String distanceMeters = 'distanceMeters';
  static const String mockLocationDetected = 'mockLocationDetected';
  static const String clientTime = 'clientTime';
  static const String serverTime = 'serverTime';
  static const String idempotencyKey = 'idempotencyKey';
  static const String samples = 'samples';
  static const String deviceId = 'deviceId';
  static const String appVersion = 'appVersion';
}

/// 在岗任务（`attendance_task`）字段名。
abstract final class AttendanceTaskFields {
  static const String id = 'id';
  static const String seq = 'seq';
  static const String scheduledAt = 'scheduledAt';
  static const String deadlineAt = 'deadlineAt';
  static const String status = 'status';
  static const String notifiedAt = 'notifiedAt';
}

/// 邀请码 / 授权字段名。
abstract final class InviteFields {
  static const String inviteCode = 'inviteCode';
  static const String userNo = 'userNo';
  static const String expiresAt = 'expiresAt';
  static const String usedAt = 'usedAt';
}

/// 分页与统计字段名。
///
/// 来源：《网页开发方案》§6.1 ——「分页 `page` 从 1 起，`size` 默认 20、上限 100」。
///
/// ⚠️ 是 **`size`**，不是 `pageSize`。（早期版本我推断成 `pageSize`，已按方案改正。）
abstract final class PagingFields {
  static const String page = 'page';
  static const String size = 'size';
  static const String total = 'total';
  static const String hasMore = 'hasMore';
  static const String items = 'items';
  static const String stats = 'stats';

  /// 每页条数默认值与上限（方案 §6.1）。
  static const int defaultSize = 20;
  static const int maxSize = 100;
}

/// 请求头字段名。
///
/// 来源：《网页开发方案》§6.1 ——「写接口必须携带 `X-Idempotency-Key`（24h 去重）」。
///
/// ⚠️ 幂等键头是 **`X-Idempotency-Key`**，不是 `Idempotency-Key`。
abstract final class HeaderFields {
  static const String authorization = 'Authorization';

  /// 幂等键。**写接口必须携带**，服务端按 24 小时窗口去重。
  static const String idempotencyKey = 'X-Idempotency-Key';

  /// 服务端↔服务端密钥。**客户端不得内置**（方案 §6.1 明确要求）。
  static const String apiKey = 'X-Api-Key';

  static const String clientVersion = 'X-Client-Version';
  static const String apiVersion = 'X-Api-Version';
  static const String deviceId = 'X-Device-Id';
  static const String platform = 'X-Client-Platform';
  static const String requestId = 'X-Request-Id';
}

/// 契约默认值与硬性门槛。
///
/// * 数值来自方案 §6.1 评分表、§6.2 抽查参数；改动会直接影响签到判定，
///   必须同步服务端。
abstract final class ContractDefaults {
  // ── 定位精度 ────────────────────────────────────────────────────────
  /// 精度必须 ≤100m，>100m 该证据不计分（方案 §6.1）。
  static const double maxUsableAccuracyMeters = 100.0;

  /// 围栏内 ≤50m 记 +40；50–100m 记 +25（方案 §6.1）。
  static const double tightAccuracyMeters = 50.0;

  /// 高精度采样次数与总时长：3 次约 3 秒（方案 §5.3）。
  static const int checkinSampleCount = 3;
  static const Duration checkinSampleDuration = Duration(seconds: 3);

  // ── 风险评分（方案 §6.1）────────────────────────────────────────────
  static const int scoreInsideFenceTight = 40;
  static const int scoreInsideFenceLoose = 25;
  static const int scoreRecentInsideFence = 15;
  static const int scoreWifiBssidMatched = 20;
  static const int scoreCampusIpMatched = 10;
  static const int scoreDwellVerified = 15;
  static const int scoreSamplesConsistent = 10;
  static const int penaltyMockLocation = -60;
  static const int penaltyMultiAccountSameDevice = -30;
  static const int penaltyTrajectoryAnomaly = -40;

  /// 判定门槛：≥60 `success`；30–59 转人工（方案 §6.1）。
  static const int scoreSuccessThreshold = 60;
  static const int scorePendingReviewThreshold = 30;

  /// 签到前 60 秒内已有围栏内定位，记 +15。
  static const Duration recentInsideFenceWindow = Duration(seconds: 60);

  // ── 防脱岗抽查（方案 §6.2）─────────────────────────────────────────
  /// 首次抽查：`startTime + 15min`。
  static const Duration attendanceFirstDelay = Duration(minutes: 15);

  /// 默认间隔 30 分钟。
  static const Duration attendanceInterval = Duration(minutes: 30);

  /// 响应窗口 5 分钟。
  static const Duration attendanceResponseWindow = Duration(minutes: 5);

  /// 超时判定在 `deadline + 2min` 生效，以区分「人不在」与「通知没到」。
  static const Duration attendanceMissGrace = Duration(minutes: 2);

  /// 末次抽查距活动结束的最小留白。
  ///
  /// ⚠️ 这个值是**被验收用例 A20 反推出来的**，不是随手取的。
  /// 方案 §6.2 同时给了两条约束：
  ///   (a)「末次不晚于 `endTime − 15min`」
  ///   (b)「2 小时活动 3 次（T+15 / T+45 / T+75）」
  /// 若留白取 15 分钟，2 小时活动的可用区间是 [15, 105]，30 分钟间隔会产出
  /// **4 次**（T+15/45/75/105），与 (b) 矛盾；取 30 分钟则恰好 3 次。
  /// 因此以 (b) 为准。**此项待后端确认**（见 docs/contract-assumptions.md）。
  static const Duration attendanceLastTaskMargin = Duration(minutes: 30);

  // ── 签到时间窗（网页方案 §4.1 字段字典，冻结版）──────────────────
  //
  // ⚠️ 两方案冲突：移动端方案 §4.2 写 15/15，网页方案 §4.1 写 30/60。
  // 已决定采用**网页方案**（决策见 docs/decisions.md D-5）：
  //   * §4.1 是标注"冻结版"的字段字典，权威性更高；
  //   * 移动端方案未为 15/15 给出理由；
  //   * 宽容窗口对现场更友好 —— 志愿者迟到 20 分钟仍能签到。
  /// 默认签到提前量：活动开始前 30 分钟开放。
  static const Duration defaultCheckinWindowBefore = Duration(minutes: 30);

  /// 默认签到延后量：活动结束后 60 分钟关闭。
  static const Duration defaultCheckinWindowAfter = Duration(minutes: 60);

  // ── 签到半径（网页方案 §4.1）──────────────────────────────────────
  /// 范围下限（米）。低于 10 米时 GPS 精度本身就不可靠。
  static const double minCheckinRadiusMeters = 10.0;

  /// 范围上限（米）。
  static const double maxCheckinRadiusMeters = 1000.0;

  /// 室外默认（米）。
  static const double defaultCheckinRadiusOutdoorMeters = 300.0;

  /// 室内默认（米）。室内精度差，默认更小以免把围栏外的定位算成"在范围内"。
  static const double defaultCheckinRadiusIndoorMeters = 150.0;

  /// 未指定场地类型时的默认值（取室外值）。
  static const double defaultCheckinRadiusMeters = 300.0;

  // ── 活动字段长度与取值约束（网页方案 §4.1）────────────────────────
  static const int titleMaxChars = 60;
  static const int organizerMaxChars = 50;
  static const int summaryMaxChars = 120;
  static const int locationMaxChars = 100;
  static const int contactMaxChars = 50;

  /// 时长上限（小时）。
  static const double durationMaxHours = 999.9;

  /// 时长步长（小时）。
  static const double durationStepHours = 0.5;

  /// 活动简介在列表页的展开上限。
  static const int listSummaryMaxChars = 60;

  // ── 降级手段：不启用动态签到码 ─────────────────────────────────────
  //
  // 方案 §6.3 设计了动态签到码（签到码 5 分钟、在岗码 60 秒轮换、管理端
  // 全屏展示、预取续播）。本项目决定**不实现**该功能，理由见 docs/decisions.md D-2：
  //   1. 动态码本身证明不了"人在现场"—— 码可以被转发，防不住脱岗，
  //      与 §1.1「数据准确性必须保证」的目标不一致；
  //   2. 它引入一套额外的轮换 / 预取 / 断网续播 / 时钟基准逻辑，
  //      每一环都可能成为现场故障点，而本阶段的价值增量很小；
  //   3. 拒定位权限时仍有**两级**兜底，不会出现死路（方案 §7 的硬性要求）：
  //      管理端现场核实（`checkin.method = admin_scan`）与人工补录（`manual`）。
  //
  // ⚠️ 这会影响验收用例 A16 的预期：原方案要求"提供降级路径（动态码 /
  // 管理端反向扫码 / 人工补录）"，现缩为后两条。

  // ── 身份与留存（方案 §2、§14.1）────────────────────────────────────
  /// 管理端邀请码默认值（服务端可配置；方案 §2 已接受该风险）。
  ///
  /// ⚠️ 方案 §7「三条零成本底线」写作「管理端不使用固定默认邀请码」，
  /// 与 §2 / §14.1 / 验收 A2 冲突。当前按 §2/§14.1/A2 实现，见
  /// docs/open-issues-app.md 的 O-1。
  static const String defaultAdminInviteCode = '1111';

  /// 连续 5 次失败锁定 10 分钟。
  static const int adminCodeMaxAttempts = 5;
  static const Duration adminCodeLockDuration = Duration(minutes: 10);

  /// 管理端令牌：名下活动全部进入终态后 24 小时失效。
  static const Duration adminTokenIdleExpiry = Duration(hours: 24);

  /// 统一留存期：活动终态 + 7 天。
  static const Duration retentionPeriod = Duration(days: 7);

  /// 到期前 48 小时提醒发布者导出。
  static const Duration exportReminderLead = Duration(hours: 48);

  // ── 弱网与重试（方案 §9）───────────────────────────────────────────
  /// 指数退避：1s / 2s / 4s / 8s / 16s，上限 5 次。
  static const List<Duration> retryBackoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
  ];

  /// 单次请求超时。
  static const Duration requestTimeout = Duration(seconds: 15);

  /// 端到端数据同步目标 ≤60 秒（README §3.4），前台轮询周期取 20 秒。
  static const Duration foregroundPollInterval = Duration(seconds: 20);

  /// 设备与服务端时间偏差上限，超过则提示校准（方案 §9）。
  static const Duration maxClockSkew = Duration(minutes: 3);

  // ── 取消活动（方案 §4.4）───────────────────────────────────────────
  /// 取消原因至少 5 字。
  static const int cancelReasonMinLength = 5;

  // ── 接口版本协商（方案 §1.4）────────────────────────────────────────
  static const String apiVersion = 'v1';
}
