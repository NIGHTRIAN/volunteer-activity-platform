/// 领域枚举。
///
/// 所有枚举都以**服务端字符串**为持久化表示（如 `pending_review`），
/// 解析时对未知值做显式兜底而不是抛异常——老客户端遇到新状态必须能继续运行
/// （方案 §13-A8 契约变更风险的客户端侧防御）。
library;

/// 从服务端字符串解析枚举。
///
/// [unknown] 为兜底值。调用方应把「解析到 unknown」视为可上报的异常信号，
/// 而不是静默吞掉。
T parseEnum<T extends Enum>(
  List<T> values,
  Object? raw,
  T Function(String name) matcher,
  T unknown,
) {
  if (raw is! String || raw.isEmpty) {
    return unknown;
  }
  final String normalized = raw.trim();
  for (final T v in values) {
    if (v.name == normalized) {
      return v;
    }
  }
  try {
    return matcher(normalized);
  } on Object {
    return unknown;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 活动状态
// ─────────────────────────────────────────────────────────────────────────

/// 活动状态。对应方案 §4.4 状态流转。
///
/// 流转：`draft → published → ongoing → finished`，任意非终态可 `→ cancelled`。
/// `finished` 与 `cancelled` 都是**终态**，终态时间 +7 天为数据销毁点（方案 §14.1-6）。
enum ActivityStatus {
  /// 草稿：仅发布者可见，可自由编辑。
  draft('draft', '草稿'),

  /// 已发布：对外可见，关键字段进入受限编辑（方案 §4.5）。
  published('published', '已发布'),

  /// 进行中：签到与抽查已开启。
  ongoing('ongoing', '进行中'),

  /// 已结束：宣布结束后的终态，签到与抽查关闭。
  finished('finished', '已结束'),

  /// 已取消：不可逆终态，未发生的抽查置 `excused`（方案 §4.4）。
  cancelled('cancelled', '已取消'),

  /// 未知状态兜底：客户端应提示升级。
  unknown('unknown', '未知状态');

  const ActivityStatus(this.wire, this.label);

  /// 服务端字符串。
  final String wire;

  /// 界面中文文案。
  final String label;

  /// 是否为终态（触发 7 天留存倒计时）。
  bool get isTerminal => this == ActivityStatus.finished || this == ActivityStatus.cancelled;

  /// 是否允许签到。判定权在服务端，这里只用于界面预判（方案 §6.1 门槛之一）。
  bool get allowsCheckin => this == ActivityStatus.published || this == ActivityStatus.ongoing;

  /// 关键字段（起止时间、时长、签到窗口/半径、抽查参数、折算系数）是否已被冻结。
  ///
  /// 草稿可自由改；其余状态一律受限编辑（方案 §4.5）。
  bool get hasFrozenRules => this != ActivityStatus.draft;

  /// 静态解析。
  static ActivityStatus fromWire(Object? raw) => parseEnum<ActivityStatus>(
        ActivityStatus.values,
        raw,
        (String n) => ActivityStatus.values.firstWhere((ActivityStatus v) => v.wire == n),
        ActivityStatus.unknown,
      );
}

// ─────────────────────────────────────────────────────────────────────────
// 报名 / 名单状态
// ─────────────────────────────────────────────────────────────────────────

/// 参与者报名状态。对应 `participant.signupStatus`。
enum SignupStatus {
  /// 已报名（已入名单）。
  signed('signed', '已报名'),

  /// 待确认：批量导入时姓名/手机号后四位未能匹配的行（方案 §4.6）。
  pendingConfirm('pending_confirm', '待确认'),

  /// 已取消（软删除）。记录保留并标注「已移出（时间）」（方案 §14.1-7）。
  cancelled('cancelled', '已移出'),

  /// 未知状态兜底。
  unknown('unknown', '未知');

  const SignupStatus(this.wire, this.label);

  final String wire;
  final String label;

  /// 是否计入有效名单。
  bool get isActive => this == SignupStatus.signed || this == SignupStatus.pendingConfirm;

  static SignupStatus fromWire(Object? raw) => parseEnum<SignupStatus>(
        SignupStatus.values,
        raw,
        (String n) => SignupStatus.values.firstWhere((SignupStatus v) => v.wire == n),
        SignupStatus.unknown,
      );
}

/// 参与者签到状态。对应 `participant.checkinStatus`。
/// 名单里某个人的**签到**状态。
///
/// ## 线值取自 `checkin.status`（`success` / `pending_review` / `none`）
///
/// 这一点是实测确认的：服务端在名单行上下发的就是签到记录的原始状态，
/// 而不是另造一套词。统一词表的好处是**客户端不需要做状态翻译**——
/// 而翻译层正是 bug 的老家（早期这里写的是 `checked_in`，与
/// `checkin.status` 的 `success` 不一致，结果看板上所有已签到的参与者
/// 都解析成"未知"）。
///
/// [notCheckedIn]、[absent] 是**客户端使用的呈现档位**，不由服务端直接下发：
///   * [notCheckedIn] 对应 `none`（尚无记录）；
///   * [absent] 由考勤汇总推得（确实没到场）。
enum ParticipantCheckinStatus {
  /// 已签到（服务端判定 `success`）。
  checkedIn('success', '已签到'),

  /// 待人工确认：评分 30–59 或命中模拟定位（方案 §6.1）。
  pendingReview('pending_review', '待确认'),

  /// 尚无签到记录。
  ///
  /// 措辞刻意是"尚无记录"而不是"未签到"：活动还没开始时所有人都是这个状态，
  /// 说成"未签到"会让人以为出问题了。
  notCheckedIn('none', '尚未签到'),

  /// 未签到且判定为缺席（客户端由考勤汇总推得，服务端不直接下发）。
  absent('absent', '缺席'),

  /// 未知状态兜底。
  unknown('unknown', '未知');

  const ParticipantCheckinStatus(this.wire, this.label);

  final String wire;
  final String label;

  /// 是否为"需要发布者处理"的状态。
  bool get needsAttention => this == ParticipantCheckinStatus.pendingReview;

  /// 解析线值。
  ///
  /// 同时接受早期的 `checked_in` / `not_checked_in` 写法：
  /// 联调期可能有两版服务端在跑，把它们映射到同一档比报"未知"更有用。
  static ParticipantCheckinStatus fromWire(Object? raw) {
    final String s = raw?.toString().trim().toLowerCase() ?? '';
    return switch (s) {
      'checked_in' => ParticipantCheckinStatus.checkedIn,
      'not_checked_in' => ParticipantCheckinStatus.notCheckedIn,
      _ => parseEnum<ParticipantCheckinStatus>(
          ParticipantCheckinStatus.values,
          raw,
          (String n) => ParticipantCheckinStatus.values
              .firstWhere((ParticipantCheckinStatus v) => v.wire == n),
          ParticipantCheckinStatus.unknown,
        ),
    };
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 签到
// ─────────────────────────────────────────────────────────────────────────

/// 签到方式。对应 `checkin.method`。
///
/// 契约值来自《网页开发方案》§4.4：`geo`（默认）/ `qrcode` / `manual`。
///
/// ⚠️ **本平台不启用动态签到码**（决策：见 docs/decisions.md D-2），
/// 因此这里**没有** `qrcode`。方案 §6.3 把动态码列为降级手段，本项目决定不做：
///   * 动态码本身证明不了"人在现场"——码可以被转发，防不住脱岗；
///   * 少一套轮换/预取/断网续播逻辑，少一类现场故障；
///   * 拒定位权限时仍有两级兜底：管理端现场核实 + 人工补录。
enum CheckinMethod {
  /// 定位签到。**契约规定的默认值**，服务端只接受这一个。
  geo('geo', '定位签到'),

  /// 人工补录：设备故障、发布者现场核实等。
  ///
  /// 仅**管理端**可发起（走 `POST /activities/{id}/checkins/manual`），
  /// 志愿者端不得自行声明。
  manual('manual', '人工补录'),

  /// 未知方式兜底。
  unknown('unknown', '未知方式');

  const CheckinMethod(this.wire, this.label);

  final String wire;
  final String label;

  /// 是否属于**免发码**的常规路径。
  bool get isPrimaryPath => this == CheckinMethod.geo;

  /// 是否为人工介入的方式。管理端应把这些记录单独标出来，
  /// 因为它们不携带客观位置证据。
  bool get isManualIntervention => this == CheckinMethod.manual;

  /// 静态解析。
  ///
  /// 同时接受 `gps`（早期写法）与 `geo`（契约值），两者都映射到 [geo]。
  ///
  /// 实测确认服务端**存量数据里就是 `gps`**（种子与早期提交的记录），
  /// 而新契约要求 `geo`。两者都得认，否则历史记录会显示成"未知方式"。
  static CheckinMethod fromWire(Object? raw) {
    final String s = raw?.toString().trim().toLowerCase() ?? '';
    if (s == 'gps') {
      return CheckinMethod.geo;
    }
    // `qrcode` / `code` 属于本平台**不启用**的动态签到码（决策 D-2）。
    // 若历史数据里出现，归到"未知"而不是当作定位签到 —— 静默当成定位
    // 会让一条没有位置证据的记录看起来像有效签到。
    return parseEnum<CheckinMethod>(
      CheckinMethod.values,
      raw,
      (String n) => CheckinMethod.values.firstWhere((CheckinMethod v) => v.wire == n),
      CheckinMethod.unknown,
    );
  }
}

/// 签到结果状态。对应 `checkin.status`。
///
/// **客户端绝不自行判定**（方案 §2）：服务端返回前，界面只能显示「提交中」，
/// 不得显示「成功」（验收用例 A15）。
enum CheckinStatus {
  /// 已提交，等待服务端响应。纯客户端中间态，不出现在服务端数据里。
  submitting('submitting', '提交中'),

  /// 已通过：评分 ≥60（方案 §6.1）。
  success('success', '已签到'),

  /// 待人工确认：评分 30–59，或命中模拟定位强制转人工。
  pendingReview('pending_review', '待确认'),

  /// 已驳回：评分 <30 或明确违规。
  rejected('rejected', '未通过'),

  /// 已保存在本地队列，等待联网补传（方案 §9）。超窗补传一律转 pending_review。
  offlineQueued('offline_queued', '待同步'),

  /// 未知状态兜底。
  unknown('unknown', '未知');

  const CheckinStatus(this.wire, this.label);

  final String wire;
  final String label;

  /// 是否为服务端给出的**终态**。界面据此决定是否允许停止轮询。
  bool get isServerTerminal =>
      this == CheckinStatus.success ||
      this == CheckinStatus.pendingReview ||
      this == CheckinStatus.rejected;

  /// 是否仍需要继续等待/重试。
  bool get isPending =>
      this == CheckinStatus.submitting || this == CheckinStatus.offlineQueued;

  /// 是否算作「有效到场」。仅用于看板计数，不产生任何时长扣减（方案 §1.1）。
  bool get countsAsPresent =>
      this == CheckinStatus.success || this == CheckinStatus.pendingReview;

  static CheckinStatus fromWire(Object? raw) => parseEnum<CheckinStatus>(
        CheckinStatus.values,
        raw,
        (String n) => CheckinStatus.values.firstWhere((CheckinStatus v) => v.wire == n),
        CheckinStatus.unknown,
      );
}

// ─────────────────────────────────────────────────────────────────────────
// 在岗抽查
// ─────────────────────────────────────────────────────────────────────────

/// 在岗任务状态。对应 `attendance_task.status`。
enum AttendanceTaskStatus {
  /// 待响应：已生成，尚未到响应截止。
  pending('pending', '待确认'),

  /// 已完成：志愿者点开即自动定位上报（零输入，方案 §5.4）。
  done('done', '已完成'),

  /// 已超时：`deadline + 2min` 后置位（方案 §6.2）。
  ///
  /// 保留通知记录，以区分「人不在」与「通知没到」（方案 §13-A5）。
  missed('missed', '已超时'),

  /// 已豁免：活动取消时未发生的任务置位，**不冤枉已到场的人**（方案 §4.4）。
  excused('excused', '已豁免'),

  /// 未知状态兜底。
  unknown('unknown', '未知');

  const AttendanceTaskStatus(this.wire, this.label);

  final String wire;
  final String label;

  /// 是否仍需志愿者响应。
  bool get isActionable => this == AttendanceTaskStatus.pending;

  /// 是否为已定案状态。
  bool get isSettled =>
      this == AttendanceTaskStatus.done ||
      this == AttendanceTaskStatus.missed ||
      this == AttendanceTaskStatus.excused;

  static AttendanceTaskStatus fromWire(Object? raw) => parseEnum<AttendanceTaskStatus>(
        AttendanceTaskStatus.values,
        raw,
        (String n) => AttendanceTaskStatus.values.firstWhere((AttendanceTaskStatus v) => v.wire == n),
        AttendanceTaskStatus.unknown,
      );
}

// ─────────────────────────────────────────────────────────────────────────
// 考勤汇总
// ─────────────────────────────────────────────────────────────────────────

/// 考勤汇总等级。对应方案 §4.8。
///
/// ⚠️ 明确标注为**参考信息**，不自动产生任何时长扣减或权益影响（方案 §1.1）。
enum AttendanceSummary {
  /// 全勤。
  full('full', '全勤'),

  /// 部分完成。
  partial('partial', '部分完成'),

  /// 证据不足。
  insufficient('insufficient', '证据不足'),

  /// 缺席。
  absent('absent', '缺席'),

  /// 未知兜底。
  unknown('unknown', '未知');

  const AttendanceSummary(this.wire, this.label);

  final String wire;
  final String label;

  static AttendanceSummary fromWire(Object? raw) => parseEnum<AttendanceSummary>(
        AttendanceSummary.values,
        raw,
        (String n) => AttendanceSummary.values.firstWhere((AttendanceSummary v) => v.wire == n),
        AttendanceSummary.unknown,
      );
}

// ─────────────────────────────────────────────────────────────────────────
// 人工复核
// ─────────────────────────────────────────────────────────────────────────

/// 在岗抽查的触发方式。对应 `attendance_task` 的生成策略。
///
/// * [auto]：按"开始后 N 分钟第一次、之后每 M 分钟"自动生成。
/// * [manual]：不自动生成，由发布者在现场看板上按需触发一次。
///
/// 短活动用自动抽查会一直打断人，而发布者其实只想点一两次名 —— 所以给一个开关，
/// 而不是把间隔调成很大来"假装手动"。
enum AttendanceMode {
  auto('auto', '自动抽查', '按开始时间与间隔自动生成，发布者不用管'),
  manual('manual', '手动抽查', '不自动生成，发布者现场看板上点一下才发');

  const AttendanceMode(this.wire, this.label, this.hint);

  final String wire;
  final String label;
  final String hint;

  static AttendanceMode fromWire(Object? raw) => parseEnum<AttendanceMode>(
        AttendanceMode.values,
        raw,
        (String name) =>
            AttendanceMode.values.firstWhere((AttendanceMode v) => v.wire == name),
        AttendanceMode.auto,
      );
}
/// 人工复核决定。对应方案 §4.8「复核通过或驳回并填备注」。
enum ReviewDecision {
  /// 复核通过，计入已签到。
  approve('approve', '通过'),

  /// 复核驳回，必须填备注。
  reject('reject', '驳回');

  const ReviewDecision(this.wire, this.label);

  final String wire;
  final String label;

  static ReviewDecision fromWire(Object? raw) => parseEnum<ReviewDecision>(
        ReviewDecision.values,
        raw,
        (String n) => ReviewDecision.values.firstWhere((ReviewDecision v) => v.wire == n),
        ReviewDecision.approve,
      );
}

// ─────────────────────────────────────────────────────────────────────────
// 同步状态（本地）
// ─────────────────────────────────────────────────────────────────────────

/// 离线队列条目的同步状态。方案 §9「明确显示待同步」。
enum SyncState {
  /// 仅在本地（离线或尚未上报）。
  pending('pending', '待同步'),

  /// 上报中。
  syncing('syncing', '同步中'),

  /// 已同步，且拿到服务端终态。
  synced('synced', '已同步'),

  /// 重试已用尽，需要人工介入（保留本地数据，不丢）。
  failed('failed', '同步失败');

  const SyncState(this.wire, this.label);

  final String wire;
  final String label;

  /// 是否应显示为「未完成」。
  bool get isOutstanding => this != SyncState.synced;
}
