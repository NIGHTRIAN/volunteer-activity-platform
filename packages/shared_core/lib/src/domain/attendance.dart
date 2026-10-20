import '../contract/time_and_geo.dart';
import 'enums.dart';
import 'json_utils.dart';

/// 在岗任务（`attendance_task`）—— 防脱岗抽查。
///
/// 设计要点（方案 §5.4、§6.2）：
///   * **不启用推送**：任务由 App 前台轮询拉取，出现在「待确认任务」入口；
///   * 志愿者的**唯一动作是点一下**，App 随后自动定位并上报，零输入零扫码；
///   * 响应窗口 5 分钟，`deadline + 2min` 置 `missed`，并保留通知记录，
///     以区分「人不在」与「通知没到」（方案 §13-A5）；
///   * **App 不承担任何定时判定**，`workmanager` 仅用于离线补传。
class AttendanceTask {
  const AttendanceTask({
    required this.id,
    required this.activityId,
    required this.seq,
    required this.scheduledAt,
    required this.deadlineAt,
    required this.status,
    this.activityTitle,
    this.notifiedAt,
    this.respondedAt,
    this.point,
    this.accuracy,
    this.manualFill = false,
    this.excusedAt,
    this.excusedReason,
    this.filledBy,
    this.syncState,
  });

  /// 任务 ID。
  final String id;

  /// 活动 ID。
  final String activityId;

  /// 序号，从 1 开始。2 小时活动默认 3 次（T+15 / T+45 / T+75）。
  ///
  /// 幂等键的一部分：`(activityId, userId, seq)` 保证重算不重复生成（方案 §14.1-3）。
  final int seq;

  /// 计划抽查时刻。
  final DateTime scheduledAt;

  /// 响应截止时刻 = `scheduledAt + 响应窗口`（默认 5 分钟）。
  final DateTime deadlineAt;

  /// 任务状态。
  final AttendanceTaskStatus status;

  /// 豁免时刻（活动取消/结束时，未响应的抽查会被豁免）。
  final DateTime? excusedAt;

  /// 豁免原因（给用户看的说明）。
  final String? excusedReason;

  /// 活动名称，用于「待确认任务」列表展示（避免再查一次活动）。
  final String? activityTitle;

  /// 通知下发时刻。**保留该字段是「区分人不在与通知没到」的关键**。
  final DateTime? notifiedAt;

  /// 志愿者响应时刻。
  final DateTime? respondedAt;

  /// 响应时的坐标（WGS-84）。
  final GeoPoint? point;

  /// 响应时的精度（米）。
  final double? accuracy;

  /// 是否为**现场点名人工补录**（方案 §4.8 兜底手段）。
  final bool manualFill;

  /// 补录操作人。
  final String? filledBy;

  /// 仅本地：离线队列同步状态。
  final SyncState? syncState;

  /// 距截止的剩余时间。
  Duration remaining(DateTime now) => deadlineAt.difference(now);

  /// 是否已超时（未响应且已过截止）。
  ///
  /// 注意：**真正的 `missed` 由服务端在 `deadline + 2min` 时置位**，
  /// 这里只用于界面把倒计时变成「已超时」提示，不改变任何数据。
  bool isOverdue(DateTime now) =>
      status == AttendanceTaskStatus.pending && now.isAfter(deadlineAt);

  /// 是否可以响应（仍需动作且未过截止）。
  bool canRespond(DateTime now) =>
      status == AttendanceTaskStatus.pending && !now.isAfter(deadlineAt);

  /// 是否处于「忘了点，还能补」的宽限期内（`deadline` 到 `deadline+2min`）。
  ///
  /// 界面在这个区间应提示「已超时，正在等待服务端判定」，
  /// 而不是自行显示为超时失败。
  bool isInGracePeriod(DateTime now, {Duration grace = const Duration(minutes: 2)}) =>
      status == AttendanceTaskStatus.pending &&
      now.isAfter(deadlineAt) &&
      now.isBefore(deadlineAt.add(grace));

  /// 进度文案：`第 2/3 次`。
  String seqLabel(int total) => '第 $seq/$total 次';

  factory AttendanceTask.fromJson(Map<String, dynamic> json) => AttendanceTask(
        id: jsonStringOr(json['id'], ''),
        activityId: jsonStringOr(json['activityId'], ''),
        seq: jsonIntOr(json['seq'], 0),
        scheduledAt: TimeFormat.tryParse(json['scheduledAt']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        deadlineAt: TimeFormat.tryParse(json['deadlineAt']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        status: AttendanceTaskStatus.fromWire(json['status']),
        activityTitle: jsonString(json['activityTitle']),
        notifiedAt: TimeFormat.tryParse(json['notifiedAt']),
        respondedAt: TimeFormat.tryParse(json['respondedAt']),
        point: json['geoLat'] == null && json['geoLng'] == null
            ? null
            : GeoPoint(
                lat: jsonDoubleOr(json['geoLat'], 0),
                lng: jsonDoubleOr(json['geoLng'], 0),
              ),
        accuracy: jsonDouble(json['accuracy']),
        manualFill: jsonBoolOr(json['manualFill'], false),
        excusedAt: TimeFormat.tryParse(json['excusedAt']),
        excusedReason: jsonString(json['excusedReason']),
        filledBy: jsonString(json['filledBy']),
        syncState: json['syncState'] == null
            ? null
            : parseEnum<SyncState>(
                SyncState.values,
                json['syncState'],
                (String n) => SyncState.values.firstWhere((SyncState v) => v.wire == n),
                SyncState.pending,
              ),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'activityId': activityId,
        'seq': seq,
        'scheduledAt': TimeFormat.toIso8601(scheduledAt),
        'deadlineAt': TimeFormat.toIso8601(deadlineAt),
        'status': status.wire,
        if (activityTitle != null) 'activityTitle': activityTitle,
        if (notifiedAt != null) 'notifiedAt': TimeFormat.toIso8601(notifiedAt!),
        if (respondedAt != null) 'respondedAt': TimeFormat.toIso8601(respondedAt!),
        if (point != null) ...<String, dynamic>{
          'geoLat': point!.lat,
          'geoLng': point!.lng,
        },
        if (accuracy != null) 'accuracy': accuracy,
        'manualFill': manualFill,
        if (filledBy != null) 'filledBy': filledBy,
        if (syncState != null) 'syncState': syncState!.wire,
      };

  AttendanceTask copyWith({
    AttendanceTaskStatus? status,
    DateTime? respondedAt,
    GeoPoint? point,
    double? accuracy,
    SyncState? syncState,
  }) =>
      AttendanceTask(
        id: id,
        activityId: activityId,
        seq: seq,
        scheduledAt: scheduledAt,
        deadlineAt: deadlineAt,
        status: status ?? this.status,
        activityTitle: activityTitle,
        notifiedAt: notifiedAt,
        respondedAt: respondedAt ?? this.respondedAt,
        point: point ?? this.point,
        accuracy: accuracy ?? this.accuracy,
        manualFill: manualFill,
        filledBy: filledBy,
        syncState: syncState ?? this.syncState,
      );
}

/// 一次性邀请码（`invite_code`）。方案 §4.7、§14.1-2。
///
/// 安全约定：
///   * **仅显示一次**——服务端只在生成响应中回传明文，之后不再提供；
///   * 必须**一对一私发**，不得公开张贴；
///   * 志愿者侧 `学号 + 邀请码` 绑定一次，活动期间长期有效。
class InviteCode {
  const InviteCode({
    required this.userNo,
    required this.name,
    required this.code,
    this.expiresAt,
    this.usedAt,
  });

  /// 学号 / 工号。
  final String userNo;

  /// 姓名（便于发布者一对一私发时核对）。
  final String name;

  /// 邀请码明文。**仅生成时可得**。
  final String code;

  /// 失效时刻；`null` 表示随活动存续。
  final DateTime? expiresAt;

  /// 被使用的时刻；非空即已绑定，不可再用。
  final DateTime? usedAt;

  /// 是否已被使用。
  bool get isUsed => usedAt != null;

  /// 是否已过期。
  bool isExpired(DateTime now) => expiresAt != null && now.isAfter(expiresAt!);

  /// 是否仍可用。
  bool isUsable(DateTime now) => !isUsed && !isExpired(now);

  factory InviteCode.fromJson(Map<String, dynamic> json) => InviteCode(
        userNo: jsonStringOr(json['userNo'], ''),
        name: jsonStringOr(json['name'], ''),
        code: jsonStringOr(json['inviteCode'], ''),
        expiresAt: TimeFormat.tryParse(json['expiresAt']),
        usedAt: TimeFormat.tryParse(json['usedAt']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'userNo': userNo,
        'name': name,
        'inviteCode': code,
        if (expiresAt != null) 'expiresAt': TimeFormat.toIso8601(expiresAt!),
        if (usedAt != null) 'usedAt': TimeFormat.toIso8601(usedAt!),
      };
}

/// 管理员会话（管理端登录结果）。方案 §4.1。
class AdminSession {
  const AdminSession({
    required this.token,
    required this.deviceId,
    this.ownerId,
    this.expiresAt,
    this.serverTime,
    this.activeActivityCount = 0,
  });

  /// 管理端令牌。有效期 = 名下活动存续期；全部活动终态后 24 小时失效（方案 §2）。
  final String token;

  /// 绑定的设备指纹。
  final String deviceId;

  /// 归属发布者 ID，用于服务端越权隔离。
  final String? ownerId;

  /// 令牌失效时刻。
  final DateTime? expiresAt;

  /// 服务端时间，用于校正客户端时钟。
  final DateTime? serverTime;

  /// 当前名下未进入终态的活动数量。为 0 时令牌将在 24 小时后失效。
  final int activeActivityCount;

  factory AdminSession.fromJson(Map<String, dynamic> json) => AdminSession(
        token: jsonStringOr(json['token'], ''),
        deviceId: jsonStringOr(json['deviceId'], ''),
        ownerId: jsonString(json['ownerId']),
        expiresAt: TimeFormat.tryParse(json['expiresAt']),
        serverTime: TimeFormat.tryParse(json['serverTime']),
        activeActivityCount: jsonIntOr(json['activeActivityCount'], 0),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'token': token,
        'deviceId': deviceId,
        if (ownerId != null) 'ownerId': ownerId,
        if (expiresAt != null) 'expiresAt': TimeFormat.toIso8601(expiresAt!),
        if (serverTime != null) 'serverTime': TimeFormat.toIso8601(serverTime!),
        'activeActivityCount': activeActivityCount,
      };
}

/// 志愿者绑定结果（用户端身份绑定）。方案 §5.2。
class VolunteerGrant {
  const VolunteerGrant({
    required this.token,
    required this.activityId,
    required this.userNo,
    required this.name,
    required this.expiresAt,
    this.deviceId,
    this.serverTime,
  });

  /// 设备令牌。存入 Keystore / Keychain，**不落明文**（方案 §3）。
  final String token;

  /// 绑定的活动 ID。
  final String activityId;

  /// 学号 / 工号。
  final String userNo;

  /// 姓名。
  final String name;

  /// 授权到期时间 = 活动终态 + 7 天（方案 §5.2）。到期后回到绑定页。
  final DateTime expiresAt;

  /// 绑定设备指纹。
  final String? deviceId;

  /// 服务端时间。
  final DateTime? serverTime;

  /// 授权是否仍有效。
  bool isValid(DateTime now) => now.isBefore(expiresAt);

  /// 距授权到期的剩余时间。
  Duration remaining(DateTime now) => expiresAt.difference(now);

  factory VolunteerGrant.fromJson(Map<String, dynamic> json) => VolunteerGrant(
        token: jsonStringOr(json['token'], ''),
        activityId: jsonStringOr(json['activityId'], ''),
        userNo: jsonStringOr(json['userNo'], ''),
        name: jsonStringOr(json['name'], ''),
        expiresAt: TimeFormat.tryParse(json['expiresAt']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        deviceId: jsonString(json['deviceId']),
        serverTime: TimeFormat.tryParse(json['serverTime']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'token': token,
        'activityId': activityId,
        'userNo': userNo,
        'name': name,
        'expiresAt': TimeFormat.toIso8601(expiresAt),
        if (deviceId != null) 'deviceId': deviceId,
        if (serverTime != null) 'serverTime': TimeFormat.toIso8601(serverTime!),
      };
}

/// 导出任务（`export_job`）。
///
/// 方案 §2「导出统一调用服务端导出接口，两端不自建」，
/// 因此这里只是一个句柄，客户端**不生成**任何导出文件内容。
class ExportJob {
  const ExportJob({
    required this.id,
    required this.status,
    this.downloadUrl,
    this.fileName,
    this.expiresAt,
    this.rowCount,
    this.readyAt,
  });

  /// 导出任务 ID。
  final String id;

  /// 状态：`pending` / `ready` / `failed`。
  final String status;

  /// 下载地址（服务端签发，通常带时效签名）。
  final String? downloadUrl;

  /// 建议文件名。
  final String? fileName;

  /// 下载地址失效时刻。
  final DateTime? expiresAt;

  /// 行数。
  final int? rowCount;

  /// 就绪时刻。
  final DateTime? readyAt;

  /// 是否已就绪可下载。
  bool get isReady => status == 'ready' && downloadUrl != null && downloadUrl!.isNotEmpty;

  /// 是否仍在生成中（对应 `50002`）。
  bool get isPending => status == 'pending';

  factory ExportJob.fromJson(Map<String, dynamic> json) => ExportJob(
        id: jsonStringOr(json['id'], ''),
        status: jsonStringOr(json['status'], 'pending'),
        downloadUrl: jsonString(json['downloadUrl']),
        fileName: jsonString(json['fileName']),
        expiresAt: TimeFormat.tryParse(json['expiresAt']),
        rowCount: jsonInt(json['rowCount']),
        readyAt: TimeFormat.tryParse(json['readyAt']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'status': status,
        if (downloadUrl != null) 'downloadUrl': downloadUrl,
        if (fileName != null) 'fileName': fileName,
        if (expiresAt != null) 'expiresAt': TimeFormat.toIso8601(expiresAt!),
        if (rowCount != null) 'rowCount': rowCount,
        if (readyAt != null) 'readyAt': TimeFormat.toIso8601(readyAt!),
      };
}
