import '../contract/field_dictionary.dart';
import '../contract/time_and_geo.dart';
import 'activity.dart';
import 'checkin.dart';
import 'enums.dart';
import 'json_utils.dart';

/// 分页结果。用户端列表使用无限滚动分页（方案 §5.1）。
class Paged<T> {
  const Paged({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    this.hasMore,
  });

  /// 当前页数据。
  final List<T> items;

  /// 满足条件的总条数。
  final int total;

  /// 序号。从 1 开始。
  final int page;

  /// 每页条数。**下发时的键是 `size`**（方案 §6.1），上限 100。
  final int pageSize;

  /// 是否还有下一页。服务端未下发时按 [total] 与已加载数量推导。
  final bool? hasMore;

  /// 是否还有更多。
  bool get more => hasMore ?? (page * pageSize < total);

  /// 空结果。
  static Paged<T> empty<T>() => Paged<T>(
        // 不能用 `const <Never>[] as List<T>`：const 字面量不允许带类型参数。
        items: List<T>.empty(),
        total: 0,
        page: 1,
        pageSize: 20,
        hasMore: false,
      );

  /// 追加下一页，用于无限滚动。
  Paged<T> append(Paged<T> next) => Paged<T>(
        items: <T>[...items, ...next.items],
        total: next.total,
        page: next.page,
        pageSize: next.pageSize,
        hasMore: next.hasMore,
      );

  /// 反序列化。`items` 由调用方转换。
  factory Paged.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic> json) convert,
  ) =>
      Paged<T>(
        items: jsonObjectList<T>(json[PagingFields.items], convert),
        total: jsonIntOr(json[PagingFields.total], 0),
        page: jsonIntOr(json[PagingFields.page], 1),
        // 兼容 `size`（方案规定）与 `pageSize`（早期推断），避免后端下发不一致时丢分页信息。
        pageSize: jsonIntOr(
          json[PagingFields.size] ?? json['pageSize'],
          PagingFields.defaultSize,
        ),
        hasMore: json[PagingFields.hasMore] == null
            ? null
            : jsonBoolOr(json[PagingFields.hasMore], false),
      );
}

/// 分页读取的重试与加载更多策略。
abstract final class PagingPolicy {
  /// 首屏每页条数。移动端列表首屏不宜过大：弱网下等待时间会被放大。
  static const int firstPageSize = 20;

  /// 加载更多的每页条数。
  static const int nextPageSize = 20;

  /// 触发「加载更多」的剩余条数阈值：列表滚到还剩这么多时就开始预取。
  static const int prefetchThreshold = 5;
}

/// 活动列表统计（用户端筛选栏上方的统计图，方案 §5.1）。
class ActivityStats {
  const ActivityStats({
    this.total = 0,
    this.published = 0,
    this.ongoing = 0,
    this.finished = 0,
    this.cancelled = 0,
    this.totalDurationHours = 0,
  });

  final int total;
  final int published;
  final int ongoing;
  final int finished;
  final int cancelled;

  /// 时长合计，用于统计图。仅作展示参考。
  final double totalDurationHours;

  factory ActivityStats.fromJson(Map<String, dynamic> json) => ActivityStats(
        total: jsonIntOr(json['total'], 0),
        published: jsonIntOr(json['published'], 0),
        ongoing: jsonIntOr(json['ongoing'], 0),
        finished: jsonIntOr(json['finished'], 0),
        cancelled: jsonIntOr(json['cancelled'], 0),
        totalDurationHours: jsonDoubleOr(json['totalDurationHours'], 0),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'total': total,
        'published': published,
        'ongoing': ongoing,
        'finished': finished,
        'cancelled': cancelled,
        'totalDurationHours': totalDurationHours,
      };

  /// 用于绘制分布图的（标签，数值）序列。
  List<(String, int)> get distribution => <(String, int)>[
        ('已发布', published),
        ('进行中', ongoing),
        ('已结束', finished),
        ('已取消', cancelled),
      ];
}

/// 活动列表查询条件。
///
/// 与《移动端应用开发方案》§5.1 的筛选栏一一对应：
/// 组织部门 / 状态 / 时间范围 / 关键词。
///
/// 分页参数按《网页开发方案》§6.1：`page` 从 1 起，`size` 默认 20、上限 100。
/// Dart 侧属性名保留 `pageSize`（可读性更好），但**下发的查询键是 `size`**。
class ActivityQuery {
  const ActivityQuery({
    this.keyword,
    this.organizer,
    this.statuses = const <ActivityStatus>[],
    this.startFrom,
    this.startTo,
    this.page = 1,
    this.pageSize = PagingFields.defaultSize,
    this.sortBy = 'startTime',
    this.sortDesc = true,
    this.onlyMine = false,
  });

  /// 关键词（匹配名称 / 地点 / 标签）。
  final String? keyword;

  /// 组织部门。
  final String? organizer;

  /// 状态多选。
  final List<ActivityStatus> statuses;

  /// 时间范围起。
  final DateTime? startFrom;

  /// 时间范围止。
  final DateTime? startTo;

  /// 页码。
  final int page;

  /// 每页条数。
  final int pageSize;

  /// 排序字段。默认 `startTime desc`（方案 §5.1）。
  final String sortBy;

  /// 是否倒序。
  final bool sortDesc;

  /// 仅看本人名下（管理端用）。
  final bool onlyMine;

  /// 转查询串。空值不下发，避免服务端把空串当过滤条件。
  Map<String, String> toQueryParameters() => <String, String>{
        if (keyword != null && keyword!.trim().isNotEmpty) 'keyword': keyword!.trim(),
        if (organizer != null && organizer!.trim().isNotEmpty) 'organizer': organizer!.trim(),
        if (statuses.isNotEmpty)
          'status': statuses.map((ActivityStatus e) => e.wire).join(','),
        if (startFrom != null) 'startFrom': TimeFormat.toIso8601(startFrom!),
        if (startTo != null) 'startTo': TimeFormat.toIso8601(startTo!),
        'page': '$page',
        'size': '$pageSize',
        'sortBy': sortBy,
        'sortDesc': sortDesc ? 'true' : 'false',
        if (onlyMine) 'onlyMine': 'true',
      };

  /// 复制并翻页。
  ActivityQuery nextPage() => ActivityQuery(
        keyword: keyword,
        organizer: organizer,
        statuses: statuses,
        startFrom: startFrom,
        startTo: startTo,
        page: page + 1,
        pageSize: pageSize,
        sortBy: sortBy,
        sortDesc: sortDesc,
        onlyMine: onlyMine,
      );

  /// 回到第一页（改筛选条件时调用）。
  ActivityQuery resetPage() => ActivityQuery(
        keyword: keyword,
        organizer: organizer,
        statuses: statuses,
        startFrom: startFrom,
        startTo: startTo,
        page: 1,
        pageSize: pageSize,
        sortBy: sortBy,
        sortDesc: sortDesc,
        onlyMine: onlyMine,
      );

  ActivityQuery copyWith({
    String? keyword,
    String? organizer,
    List<ActivityStatus>? statuses,
    DateTime? startFrom,
    DateTime? startTo,
    int? page,
    int? pageSize,
    String? sortBy,
    bool? sortDesc,
    bool? onlyMine,
    bool clearKeyword = false,
    bool clearOrganizer = false,
    bool clearStartFrom = false,
    bool clearStartTo = false,
  }) =>
      ActivityQuery(
        keyword: clearKeyword ? null : (keyword ?? this.keyword),
        organizer: clearOrganizer ? null : (organizer ?? this.organizer),
        statuses: statuses ?? this.statuses,
        startFrom: clearStartFrom ? null : (startFrom ?? this.startFrom),
        startTo: clearStartTo ? null : (startTo ?? this.startTo),
        page: page ?? this.page,
        pageSize: pageSize ?? this.pageSize,
        sortBy: sortBy ?? this.sortBy,
        sortDesc: sortDesc ?? this.sortDesc,
        onlyMine: onlyMine ?? this.onlyMine,
      );

  /// 是否存在任何筛选条件（决定是否显示「清空筛选」）。
  bool get hasFilters =>
      (keyword != null && keyword!.trim().isNotEmpty) ||
      (organizer != null && organizer!.trim().isNotEmpty) ||
      statuses.isNotEmpty ||
      startFrom != null ||
      startTo != null;
}

/// 管理端签到与在岗看板的聚合结果（方案 §4.8）。
///
/// 四态计数：已签到 / 待人工确认 / 未签到 / 在岗抽查完成情况。
class ActivityBoard {
  const ActivityBoard({
    required this.activityId,
    this.checkedIn = 0,
    this.pendingReview = 0,
    this.notCheckedIn = 0,
    this.removed = 0,
    this.attendancePending = 0,
    this.attendanceDone = 0,
    this.attendanceMissed = 0,
    this.attendanceExcused = 0,
    this.servingNow = 0,
    this.serverTime,
    this.participants = const <Participant>[],
    this.disclaimer = '',
    this.dataDestroyAt,
  });

  /// 活动 ID。
  final String activityId;

  /// 已签到人数。
  final int checkedIn;

  /// 待人工确认人数。
  final int pendingReview;

  /// 未签到人数。
  final int notCheckedIn;

  /// 已移出名单人数（记录保留，方案 §14.1-7）。
  final int removed;

  /// 在岗抽查：待确认。
  final int attendancePending;

  /// 在岗抽查：已完成。
  final int attendanceDone;

  /// 在岗抽查：已超时。
  final int attendanceMissed;

  /// 在岗抽查：已豁免（活动取消）。
  final int attendanceExcused;

  /// 当前仍在岗（已响应且未超时）人数。
  final int servingNow;

  /// 服务端时间，用于校正看板的倒计时。
  final DateTime? serverTime;

  /// 名单明细（可选，按需下发以免看板接口过重）。
  final List<Participant> participants;

  /// 免责声明。
  ///
  /// **由服务端下发，不在客户端硬编码**：这句话是发布者面对
  /// "你为什么扣我时长"这类质疑时的依据，它的措辞必须与服务端
  /// 记录的口径一致。客户端自己写一份，两边就可能对不上。
  final String disclaimer;

  /// 数据不可访问的时刻（活动终态 + 7 天留存期）。
  ///
  /// 为 `null` 表示活动尚未进入终态，留存期还没开始计算。
  /// 看板据此显示"请在此之前完成导出与对账"——这句话必须在
  /// **数据还在的时候**说，而不是等销毁之后。
  final DateTime? dataDestroyAt;

  /// 有效名单人数（不含已移出）。
  int get activeTotal => checkedIn + pendingReview + notCheckedIn;

  /// 到场率。仅供参考。
  double get presentRate {
    final int t = activeTotal;
    return t == 0 ? 0 : (checkedIn + pendingReview) / t;
  }

  /// 在岗抽查应完成总次数。
  int get attendanceTotal =>
      attendancePending + attendanceDone + attendanceMissed + attendanceExcused;

  factory ActivityBoard.fromJson(Map<String, dynamic> json) => ActivityBoard(
        activityId: jsonStringOr(json['activityId'], ''),
        checkedIn: jsonIntOr(json['checkedIn'], 0),
        pendingReview: jsonIntOr(json['pendingReview'], 0),
        notCheckedIn: jsonIntOr(json['notCheckedIn'], 0),
        removed: jsonIntOr(json['removed'], 0),
        attendancePending: jsonIntOr(json['attendancePending'], 0),
        attendanceDone: jsonIntOr(json['attendanceDone'], 0),
        attendanceMissed: jsonIntOr(json['attendanceMissed'], 0),
        attendanceExcused: jsonIntOr(json['attendanceExcused'], 0),
        servingNow: jsonIntOr(json['servingNow'], 0),
        serverTime: TimeFormat.tryParse(json['serverTime']),
        participants: jsonObjectList(json['participants'], Participant.fromJson),
        disclaimer: jsonStringOr(json['disclaimer'], ''),
        dataDestroyAt: TimeFormat.tryParse(json['dataDestroyAt']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'activityId': activityId,
        'checkedIn': checkedIn,
        'pendingReview': pendingReview,
        'notCheckedIn': notCheckedIn,
        'removed': removed,
        'attendancePending': attendancePending,
        'attendanceDone': attendanceDone,
        'attendanceMissed': attendanceMissed,
        'attendanceExcused': attendanceExcused,
        'servingNow': servingNow,
        if (serverTime != null) 'serverTime': TimeFormat.toIso8601(serverTime!),
        if (participants.isNotEmpty)
          'participants': participants.map((Participant e) => e.toJson()).toList(growable: false),
      };
}

/// 逐行导入结果（方案 §4.6「逐行报告结果」、验收用例 A8）。
class ImportRowResult {
  const ImportRowResult({
    required this.row,
    required this.accepted,
    this.userNo,
    this.name,
    this.reason,
    this.status,
  });

  /// 源文件行号（从 1 开始，含表头，便于用户回到 Excel 定位）。
  final int row;

  /// 是否接收。
  final bool accepted;

  /// 解析出的学号。
  final String? userNo;

  /// 解析出的姓名。
  final String? name;

  /// 拒绝原因；接收时为 `null`。
  final String? reason;

  /// 入库后的状态：`signed` 或 `pending_confirm`（无法匹配姓名/手机号后四位）。
  final SignupStatus? status;

  /// 是否落入「待确认」。
  bool get needsConfirmation => status == SignupStatus.pendingConfirm;

  factory ImportRowResult.fromJson(Map<String, dynamic> json) => ImportRowResult(
        row: jsonIntOr(json['row'], 0),
        accepted: jsonBoolOr(json['accepted'], false),
        userNo: jsonString(json['userNo']),
        name: jsonString(json['name']),
        reason: jsonString(json['reason']),
        status: json['status'] == null ? null : SignupStatus.fromWire(json['status']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'row': row,
        'accepted': accepted,
        if (userNo != null) 'userNo': userNo,
        if (name != null) 'name': name,
        if (reason != null) 'reason': reason,
        if (status != null) 'status': status!.wire,
      };
}

/// 批量导入汇总。
class ImportReport {
  const ImportReport({
    required this.total,
    required this.accepted,
    required this.rejected,
    required this.pendingConfirm,
    this.rows = const <ImportRowResult>[],
  });

  final int total;
  final int accepted;
  final int rejected;
  final int pendingConfirm;
  final List<ImportRowResult> rows;

  /// 是否存在需要发布者处理的错误行。
  bool get hasErrors => rejected > 0;

  /// 是否存在需要二次校验的行。
  bool get hasPendingConfirm => pendingConfirm > 0;

  /// 一句话汇总，用于结果页顶部。
  String get summary => '共 $total 行：成功 $accepted，待确认 $pendingConfirm，失败 $rejected';

  factory ImportReport.fromJson(Map<String, dynamic> json) => ImportReport(
        total: jsonIntOr(json['total'], 0),
        accepted: jsonIntOr(json['accepted'], 0),
        rejected: jsonIntOr(json['rejected'], 0),
        pendingConfirm: jsonIntOr(json['pendingConfirm'], 0),
        rows: jsonObjectList(json['rows'], ImportRowResult.fromJson),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'total': total,
        'accepted': accepted,
        'rejected': rejected,
        'pendingConfirm': pendingConfirm,
        'rows': rows.map((ImportRowResult e) => e.toJson()).toList(growable: false),
      };
}

/// 规则变更记录（方案 §4.5「记录前后值 + 通知志愿者」）。
///
/// 这是管理者的**证据**，而不是对他的审查（README §3.2）。
class RuleChangeLog {
  const RuleChangeLog({
    required this.field,
    required this.before,
    required this.after,
    required this.reason,
    required this.changedAt,
    required this.changedBy,
    this.revision = 1,
    this.notifiedCount = 0,
  });

  /// 字段名（与字段字典一致）。
  final String field;

  /// 变更前值（字符串化）。
  final String before;

  /// 变更后值。
  final String after;

  /// 变更原因（必填）。
  final String reason;

  final DateTime changedAt;
  final String changedBy;

  /// 新快照版本号。**仅对未来生效**。
  final int revision;

  /// 已通知的志愿者数量。
  final int notifiedCount;

  factory RuleChangeLog.fromJson(Map<String, dynamic> json) => RuleChangeLog(
        field: jsonStringOr(json['field'], ''),
        before: jsonStringOr(json['before'], ''),
        after: jsonStringOr(json['after'], ''),
        reason: jsonStringOr(json['reason'], ''),
        changedAt: TimeFormat.tryParse(json['changedAt']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        changedBy: jsonStringOr(json['changedBy'], ''),
        revision: jsonIntOr(json['revision'], 1),
        notifiedCount: jsonIntOr(json['notifiedCount'], 0),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'field': field,
        'before': before,
        'after': after,
        'reason': reason,
        'changedAt': TimeFormat.toIso8601(changedAt),
        'changedBy': changedBy,
        'revision': revision,
        'notifiedCount': notifiedCount,
      };
}

/// 管理员登录审计条目（方案 §2 风险缓解③）。
class LoginAuditEntry {
  const LoginAuditEntry({
    required this.at,
    required this.deviceId,
    this.ip,
    this.success = true,
    this.failureReason,
  });

  final DateTime at;
  final String deviceId;

  /// IP。**日志不打完整手机号**，IP 属必要审计信息（README §3.3）。
  final String? ip;

  final bool success;
  final String? failureReason;

  factory LoginAuditEntry.fromJson(Map<String, dynamic> json) => LoginAuditEntry(
        at: TimeFormat.tryParse(json['at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        deviceId: jsonStringOr(json['deviceId'], ''),
        ip: jsonString(json['ip']),
        success: jsonBoolOr(json['success'], true),
        failureReason: jsonString(json['failureReason']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'at': TimeFormat.toIso8601(at),
        'deviceId': deviceId,
        if (ip != null) 'ip': ip,
        'success': success,
        if (failureReason != null) 'failureReason': failureReason,
      };
}

/// 用于展示的活动统计卡片数据。
///
/// 从列表结果聚合得到，避免为一个图表再打一次接口。
abstract final class ActivityStatsAggregator {
  /// 由活动列表推导统计。服务端下发 [ActivityStats] 时以服务端为准。
  static ActivityStats fromActivities(List<Activity> activities) {
    int published = 0;
    int ongoing = 0;
    int finished = 0;
    int cancelled = 0;
    double hours = 0;
    for (final Activity a in activities) {
      switch (a.status) {
        case ActivityStatus.published:
          published++;
        case ActivityStatus.ongoing:
          ongoing++;
        case ActivityStatus.finished:
          finished++;
        case ActivityStatus.cancelled:
          cancelled++;
        case ActivityStatus.draft:
        case ActivityStatus.unknown:
          break;
      }
      hours += a.durationHours;
    }
    return ActivityStats(
      total: activities.length,
      published: published,
      ongoing: ongoing,
      finished: finished,
      cancelled: cancelled,
      totalDurationHours: hours,
    );
  }
}
