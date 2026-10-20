import '../contract/field_dictionary.dart';
import '../contract/time_and_geo.dart';
import 'enums.dart';
import 'json_utils.dart';

/// 活动（`activity`）领域模型。
///
/// 字段与《移动端应用开发方案》§3 的 App 侧视图一一对应。
/// 本类**不可变**；`copyWith` 只用于本地草稿编辑，服务端权威数据以
/// `version` 乐观锁为准（方案 §2）。
class Activity {
  const Activity({
    required this.id,
    required this.title,
    required this.organizer,
    required this.durationHours,
    required this.startTime,
    required this.endTime,
    required this.location,
    required this.geoLat,
    required this.geoLng,
    required this.status,
    this.externalId = '',
    this.locationType,
    this.wifiBssids = const <String>[],
    this.campusIpPrefixes = const <String>[],
    this.summary = '',
    this.description = '',
    this.tags = const <String>[],
    this.contact,
    this.ownerId,
    this.signupDeadline,
    this.checkinRadius = 200,
    this.checkinWindowBefore = const Duration(minutes: 15),
    this.checkinWindowAfter = const Duration(minutes: 15),
    this.attendanceFirstDelay = const Duration(minutes: 15),
    this.attendanceInterval = const Duration(minutes: 30),
    this.attendanceResponseWindow = const Duration(minutes: 5),
    this.attendanceMode = AttendanceMode.auto,
    this.quota,
    this.enrolled = 0,
    this.version = 1,
    this.ruleSnapshot,
    this.createdAt,
    this.updatedAt,
    this.terminalAt,
    this.myCheckinStatus,
    this.mySignupStatus,
    this.pendingAttendanceCount = 0,
  });

  /// 活动 ID（字符串，避免 JS 端精度问题）。
  final String id;

  /// 外部唯一号。**管理端的幂等键**（网页方案 §4.1，必填、≤64 字符）。
  ///
  /// 同一 `externalId` 重复上报视为**更新**（方案 §5.4），
  /// 因此管理端离线草稿重传不会产生重复活动。
  final String externalId;

  /// 场地类型：`indoor` / `outdoor`（或 `null`）。
  ///
  /// 只用于决定**默认签到半径**（室外 300m / 室内 150m），不参与判定。
  final String? locationType;

  /// Wi-Fi BSSID 白名单：命中才给「Wi-Fi 辅证」加分（评分表 +20）。
  ///
  /// ⚠️ 必须由发布者配置，而不是"客户端上报了就给分"——
  /// 否则任何人填一个 BSSID 都能拿 20 分，辅证就失去意义。
  final List<String> wifiBssids;

  /// 校园网 IP 前缀白名单：命中才给「校园网辅证」加分（评分表 +10）。
  final List<String> campusIpPrefixes;

  /// 活动名称。列表页首要展示项（方案 §8 展示层级）。
  final String title;

  /// 组织部门。
  final String organizer;

  /// 志愿时长（小时）。仅作展示与参考，**平台不作认定依据**（方案 §1.1）。
  final double durationHours;

  /// 开始时间。
  final DateTime startTime;

  /// 结束时间。
  final DateTime endTime;

  /// 活动地点文字描述。
  final String location;

  /// 围栏中心纬度（WGS-84，方案 §6.1）。
  final double geoLat;

  /// 围栏中心经度（WGS-84）。
  final double geoLng;

  /// 签到半径（米）。0 或 >1000 视为录入错误（方案 §4.2）。
  final double checkinRadius;

  /// 签到窗口：开始前提前开放量（方案 §4.2）。
  final Duration checkinWindowBefore;

  /// 签到窗口：结束后延后关闭量。
  final Duration checkinWindowAfter;

  /// 抽查首次延迟，默认 `startTime + 15min`（方案 §6.2）。
  final Duration attendanceFirstDelay;

  /// 抽查间隔，默认 30 分钟。
  final Duration attendanceInterval;

  /// 抽查响应窗口，默认 5 分钟。
  final Duration attendanceResponseWindow;

  /// 抽查触发方式：自动（按间隔）或手动（发布者现场触发）。
  final AttendanceMode attendanceMode;

  /// 名额上限；`null` 表示不限。
  final int? quota;

  /// 已报名人数。
  final int enrolled;

  /// 活动状态。
  final ActivityStatus status;

  /// 标签。
  final List<String> tags;

  /// 简介（列表页展示，超出部分折叠）。
  final String summary;

  /// 详情（详情页折叠展开全部信息，方案 §3.1）。
  final String description;

  /// 联系方式（服务端已脱敏）。
  final String? contact;

  /// 归属发布者 ID。服务端据此做越权隔离（方案 §2，验收用例 A4）。
  final String? ownerId;

  /// 报名截止时间。校验规则：不得晚于 [startTime]（方案 §4.2）。
  final DateTime? signupDeadline;

  /// 乐观锁版本号。
  final int version;

  /// 规则快照：发布时冻结，之后的判定依据（方案 §4.5）。
  final RuleSnapshot? ruleSnapshot;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// 进入终态的时刻。`+7 天` 即数据销毁点（方案 §14.1-6）。
  final DateTime? terminalAt;

  /// 当前用户在本活动的签到状态（用户端接口下发）。
  final CheckinStatus? myCheckinStatus;

  /// 当前用户在本活动的报名状态。
  final SignupStatus? mySignupStatus;

  /// 当前用户待响应的在岗抽查数量（驱动「待确认任务」入口红点，方案 §5.4）。
  final int pendingAttendanceCount;

  /// 围栏中心点（WGS-84）。
  GeoPoint get fenceCenter => GeoPoint(lat: geoLat, lng: geoLng);

  /// 活动时长。
  Duration get duration => endTime.difference(startTime);

  /// 签到窗口开启时刻。
  DateTime get checkinOpensAt => startTime.subtract(checkinWindowBefore);

  /// 签到窗口关闭时刻。
  DateTime get checkinClosesAt => endTime.add(checkinWindowAfter);

  /// 判定某时刻是否在签到时间窗内（方案 §6.1 门槛之一）。
  ///
  /// 这只是界面预判；**服务端仍会独立校验**。
  bool isWithinCheckinWindow(DateTime now) =>
      !now.isBefore(checkinOpensAt) && !now.isAfter(checkinClosesAt);

  /// 按方案 §6.2 推算应生成的抽查时刻序列。
  ///
  /// 规则：首次 `startTime + attendanceFirstDelay`，间隔 `attendanceInterval`，
  /// 末次不晚于 `endTime − 30min`。2 小时活动默认得到 3 次（T+15 / T+45 / T+75）。
  ///
  /// 为什么留白是 30 分钟而不是 15 分钟：见
  /// [ContractDefaults.attendanceLastTaskMargin] 的推导——15 分钟会让 2 小时
  /// 活动产出 4 次，与验收用例 A20 要求的 3 次矛盾。
  ///
  /// 与服务端的一致性由验收用例 A20 保证；此处用于管理端预览与倒计时。
  List<DateTime> plannedAttendanceSlots() {
    final DateTime lastAllowed = endTime.subtract(
      ContractDefaults.attendanceLastTaskMargin,
    );
    final List<DateTime> slots = <DateTime>[];
    DateTime cursor = startTime.add(attendanceFirstDelay);
    // 上限保护：异常参数（interval 为 0）不得造成死循环。
    final Duration step = attendanceInterval <= Duration.zero
        ? ContractDefaults.attendanceInterval
        : attendanceInterval;
    int guard = 0;
    while (!cursor.isAfter(lastAllowed) && guard < 500) {
      slots.add(cursor);
      cursor = cursor.add(step);
      guard++;
    }
    return slots;
  }

  /// 根据留存规则判断数据是否已过销毁点。
  bool isExpiredByRetention(DateTime now, {Duration retention = const Duration(days: 7)}) {
    final DateTime? t = terminalAt;
    if (t == null) {
      return false;
    }
    return now.isAfter(t.add(retention));
  }

  /// 距离留存销毁的剩余时间；非终态或已过期返回 `null` / 负值语义由调用方处理。
  Duration? retentionRemaining(DateTime now,
      {Duration retention = const Duration(days: 7)}) {
    final DateTime? t = terminalAt;
    if (t == null) {
      return null;
    }
    return t.add(retention).difference(now);
  }

  /// 本地草稿编辑用。**不要**用它伪造服务端数据。
  Activity copyWith({
    String? id,
    String? externalId,
    String? locationType,
    List<String>? wifiBssids,
    List<String>? campusIpPrefixes,
    String? title,
    String? organizer,
    double? durationHours,
    DateTime? startTime,
    DateTime? endTime,
    String? location,
    double? geoLat,
    double? geoLng,
    double? checkinRadius,
    Duration? checkinWindowBefore,
    Duration? checkinWindowAfter,
    Duration? attendanceFirstDelay,
    Duration? attendanceInterval,
    Duration? attendanceResponseWindow,
    AttendanceMode? attendanceMode,
    int? quota,
    int? enrolled,
    ActivityStatus? status,
    List<String>? tags,
    String? summary,
    String? description,
    String? contact,
    String? ownerId,
    DateTime? signupDeadline,
    int? version,
    RuleSnapshot? ruleSnapshot,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? terminalAt,
    CheckinStatus? myCheckinStatus,
    SignupStatus? mySignupStatus,
    int? pendingAttendanceCount,
  }) =>
      Activity(
        id: id ?? this.id,
        externalId: externalId ?? this.externalId,
        locationType: locationType ?? this.locationType,
        wifiBssids: wifiBssids ?? this.wifiBssids,
        campusIpPrefixes: campusIpPrefixes ?? this.campusIpPrefixes,
        title: title ?? this.title,
        organizer: organizer ?? this.organizer,
        durationHours: durationHours ?? this.durationHours,
        startTime: startTime ?? this.startTime,
        endTime: endTime ?? this.endTime,
        location: location ?? this.location,
        geoLat: geoLat ?? this.geoLat,
        geoLng: geoLng ?? this.geoLng,
        checkinRadius: checkinRadius ?? this.checkinRadius,
        checkinWindowBefore: checkinWindowBefore ?? this.checkinWindowBefore,
        checkinWindowAfter: checkinWindowAfter ?? this.checkinWindowAfter,
        attendanceFirstDelay: attendanceFirstDelay ?? this.attendanceFirstDelay,
        attendanceInterval: attendanceInterval ?? this.attendanceInterval,
        attendanceResponseWindow: attendanceResponseWindow ?? this.attendanceResponseWindow,
      attendanceMode: attendanceMode ?? this.attendanceMode,
        quota: quota ?? this.quota,
        enrolled: enrolled ?? this.enrolled,
        status: status ?? this.status,
        tags: tags ?? this.tags,
        summary: summary ?? this.summary,
        description: description ?? this.description,
        contact: contact ?? this.contact,
        ownerId: ownerId ?? this.ownerId,
        signupDeadline: signupDeadline ?? this.signupDeadline,
        version: version ?? this.version,
        ruleSnapshot: ruleSnapshot ?? this.ruleSnapshot,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        terminalAt: terminalAt ?? this.terminalAt,
        myCheckinStatus: myCheckinStatus ?? this.myCheckinStatus,
        mySignupStatus: mySignupStatus ?? this.mySignupStatus,
        pendingAttendanceCount: pendingAttendanceCount ?? this.pendingAttendanceCount,
      );

  /// 反序列化。对缺失字段做宽松兜底，避免服务端新增/调整字段导致整页崩溃。
  factory Activity.fromJson(Map<String, dynamic> json) {
    final DateTime? start = TimeFormat.tryParse(json['startTime']);
    return Activity(
      id: jsonStringOr(json['id'], ''),
      externalId: jsonStringOr(json['externalId'], ''),
      locationType: jsonString(json['locationType']),
      wifiBssids: jsonStringList(json['wifiBssids']),
      campusIpPrefixes: jsonStringList(json['campusIpPrefixes']),
      title: jsonStringOr(json['title'], ''),
      organizer: jsonStringOr(json['organizer'], ''),
      durationHours: jsonDoubleOr(json['durationHours'], 0),
      startTime: start ?? DateTime.fromMillisecondsSinceEpoch(0),
      endTime: TimeFormat.tryParse(json['endTime']) ??
          start ??
          DateTime.fromMillisecondsSinceEpoch(0),
      location: jsonStringOr(json['location'], ''),
      geoLat: jsonDoubleOr(json['geoLat'], 0),
      geoLng: jsonDoubleOr(json['geoLng'], 0),
      checkinRadius: jsonDoubleOr(json['checkinRadius'], 200),
      checkinWindowBefore:
          jsonDurationMinutes(json['checkinWindowBefore']) ?? const Duration(minutes: 15),
      checkinWindowAfter:
          jsonDurationMinutes(json['checkinWindowAfter']) ?? const Duration(minutes: 15),
      attendanceFirstDelay:
          jsonDurationMinutes(json['attendanceFirstDelay']) ?? const Duration(minutes: 15),
      attendanceInterval:
          jsonDurationMinutes(json['attendanceInterval']) ?? const Duration(minutes: 30),
      attendanceResponseWindow:
          jsonDurationMinutes(json['attendanceResponseWindow']) ?? const Duration(minutes: 5),
      attendanceMode: AttendanceMode.fromWire(json['attendanceMode']),
      quota: jsonInt(json['quota']),
      enrolled: jsonIntOr(json['enrolled'], 0),
      status: ActivityStatus.fromWire(json['status']),
      tags: jsonStringList(json['tags']),
      summary: jsonStringOr(json['summary'], ''),
      description: jsonStringOr(json['description'], ''),
      contact: jsonString(json['contact']),
      ownerId: jsonString(json['ownerId']),
      signupDeadline: TimeFormat.tryParse(json['signupDeadline']),
      version: jsonIntOr(json['version'], 1),
      ruleSnapshot: jsonObject(json['ruleSnapshot'], RuleSnapshot.fromJson),
      createdAt: TimeFormat.tryParse(json['createdAt']),
      updatedAt: TimeFormat.tryParse(json['updatedAt']),
      terminalAt: TimeFormat.tryParse(json['terminalAt']),
      myCheckinStatus: json['myCheckinStatus'] == null
          ? null
          : CheckinStatus.fromWire(json['myCheckinStatus']),
      mySignupStatus:
          json['mySignupStatus'] == null ? null : SignupStatus.fromWire(json['mySignupStatus']),
      pendingAttendanceCount: jsonIntOr(json['pendingAttendanceCount'], 0),
    );
  }

  /// 序列化。时间统一输出 ISO-8601（方案 §8）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'externalId': externalId,
        if (locationType != null) 'locationType': locationType,
        if (wifiBssids.isNotEmpty) 'wifiBssids': wifiBssids,
        if (campusIpPrefixes.isNotEmpty) 'campusIpPrefixes': campusIpPrefixes,
        'title': title,
        'organizer': organizer,
        'durationHours': durationHours,
        'startTime': TimeFormat.toIso8601(startTime),
        'endTime': TimeFormat.toIso8601(endTime),
        'location': location,
        'geoLat': geoLat,
        'geoLng': geoLng,
        'checkinRadius': checkinRadius,
        'checkinWindowBefore': checkinWindowBefore.inMinutes,
        'checkinWindowAfter': checkinWindowAfter.inMinutes,
        'attendanceFirstDelay': attendanceFirstDelay.inMinutes,
        'attendanceInterval': attendanceInterval.inMinutes,
        'attendanceResponseWindow': attendanceResponseWindow.inMinutes,
        'attendanceMode': attendanceMode.wire,
        if (quota != null) 'quota': quota,
        'enrolled': enrolled,
        'status': status.wire,
        'tags': tags,
        'summary': summary,
        'description': description,
        if (contact != null) 'contact': contact,
        if (ownerId != null) 'ownerId': ownerId,
        if (signupDeadline != null) 'signupDeadline': TimeFormat.toIso8601(signupDeadline!),
        'version': version,
        if (ruleSnapshot != null) 'ruleSnapshot': ruleSnapshot!.toJson(),
        if (createdAt != null) 'createdAt': TimeFormat.toIso8601(createdAt!),
        if (updatedAt != null) 'updatedAt': TimeFormat.toIso8601(updatedAt!),
        if (terminalAt != null) 'terminalAt': TimeFormat.toIso8601(terminalAt!),
        if (myCheckinStatus != null) 'myCheckinStatus': myCheckinStatus!.wire,
        if (mySignupStatus != null) 'mySignupStatus': mySignupStatus!.wire,
        'pendingAttendanceCount': pendingAttendanceCount,
      };
}

/// 规则快照：发布时冻结的判定依据（方案 §4.5、§2「发布即冻结规则」）。
///
/// 存在的意义是**保护管理者**：判定依据不被事后改写，争议时有据可依。
/// 关键字段修改后产生**新快照**，仅对未来生效。
class RuleSnapshot {
  const RuleSnapshot({
    required this.frozenAt,
    required this.startTime,
    required this.endTime,
    required this.checkinRadius,
    required this.checkinWindowBefore,
    required this.checkinWindowAfter,
    required this.attendanceFirstDelay,
    required this.attendanceInterval,
    required this.attendanceResponseWindow,
    this.attendanceMode = AttendanceMode.auto,
    this.durationHours,
    this.revision = 1,
    this.reason,
    this.changedBy,
  });

  /// 冻结时刻。
  final DateTime frozenAt;

  final DateTime startTime;
  final DateTime endTime;
  final double checkinRadius;
  final Duration checkinWindowBefore;
  final Duration checkinWindowAfter;
  final Duration attendanceFirstDelay;
  final Duration attendanceInterval;
  final Duration attendanceResponseWindow;

  /// 抽查方式（快照里冻结，事后争议时有据可依）。
  final AttendanceMode attendanceMode;

  /// 折算系数（时长折算；平台不作认定依据，仅记录）。
  final double? durationHours;

  /// 快照版本：每次受限编辑产生新快照时 +1。
  final int revision;

  /// 修改原因（受限编辑必填，方案 §4.5）。
  final String? reason;

  /// 操作人。
  final String? changedBy;

  factory RuleSnapshot.fromJson(Map<String, dynamic> json) => RuleSnapshot(
        frozenAt: TimeFormat.tryParse(json['frozenAt']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        startTime: TimeFormat.tryParse(json['startTime']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        endTime:
            TimeFormat.tryParse(json['endTime']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        checkinRadius: jsonDoubleOr(json['checkinRadius'], 200),
        checkinWindowBefore: jsonDurationMinutes(json['checkinWindowBefore']) ??
            const Duration(minutes: 15),
        checkinWindowAfter: jsonDurationMinutes(json['checkinWindowAfter']) ??
            const Duration(minutes: 15),
        attendanceFirstDelay: jsonDurationMinutes(json['attendanceFirstDelay']) ??
            const Duration(minutes: 15),
        attendanceInterval: jsonDurationMinutes(json['attendanceInterval']) ??
            const Duration(minutes: 30),
        attendanceResponseWindow:
            jsonDurationMinutes(json['attendanceResponseWindow']) ??
                const Duration(minutes: 5),
        attendanceMode: AttendanceMode.fromWire(json['attendanceMode']),
        durationHours: jsonDouble(json['durationHours']),
        revision: jsonIntOr(json['revision'], 1),
        reason: jsonString(json['reason']),
        changedBy: jsonString(json['changedBy']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'frozenAt': TimeFormat.toIso8601(frozenAt),
        'startTime': TimeFormat.toIso8601(startTime),
        'endTime': TimeFormat.toIso8601(endTime),
        'checkinRadius': checkinRadius,
        'checkinWindowBefore': checkinWindowBefore.inMinutes,
        'checkinWindowAfter': checkinWindowAfter.inMinutes,
        'attendanceFirstDelay': attendanceFirstDelay.inMinutes,
        'attendanceInterval': attendanceInterval.inMinutes,
        'attendanceResponseWindow': attendanceResponseWindow.inMinutes,
        'attendanceMode': attendanceMode.wire,
        if (durationHours != null) 'durationHours': durationHours,
        'revision': revision,
        if (reason != null) 'reason': reason,
        if (changedBy != null) 'changedBy': changedBy,
      };
}
