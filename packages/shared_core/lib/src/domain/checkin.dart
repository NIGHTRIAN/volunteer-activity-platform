import '../contract/time_and_geo.dart';
import 'enums.dart';
import 'json_utils.dart';

/// 参与者 / 名单条目（`participant`）。
///
/// ⚠️ 隐私：`phone` 服务端已脱敏（形如 `138****5678`），
/// 客户端**不得**自行拼接或缓存完整手机号（README §3.3「日志不打完整手机号」）。
class Participant {
  const Participant({
    required this.userNo,
    required this.name,
    required this.signupStatus,
    required this.checkinStatus,
    this.college,
    this.phoneMasked,
    this.removedAt,
    this.removedBy,
    this.grantExpiresAt,
    this.inviteCodeIssued = false,
    this.inviteCodeUsedAt,
    this.attendanceDone = 0,
    this.attendanceMissed = 0,
    this.attendanceExcused = 0,
    this.attendanceSummary,
    this.checkinAt,
    this.boundDeviceId,
  });

  /// 学号 / 工号。活动内唯一（方案 §4.6「活动内重复」校验）。
  final String userNo;

  /// 姓名。
  final String name;

  /// 学院 / 院系（可选，来自名单导入）。
  final String? college;

  /// 手机号（已脱敏）。
  final String? phoneMasked;

  /// 报名状态。
  final SignupStatus signupStatus;

  /// 签到状态。
  final ParticipantCheckinStatus checkinStatus;

  /// 移出名单的时刻。记录保留并标注「已移出（时间）」（方案 §14.1-7）。
  final DateTime? removedAt;

  /// 执行移出的操作人。
  final String? removedBy;

  /// 活动级授权到期时间 = 活动终态 + 7 天（方案 §5.2）。
  final DateTime? grantExpiresAt;

  /// 是否已生成一次性邀请码（方案 §4.7）。
  final bool inviteCodeIssued;

  /// 邀请码被使用的时刻；`null` 表示尚未绑定。
  final DateTime? inviteCodeUsedAt;

  /// 在岗抽查完成次数。
  final int attendanceDone;

  /// 在岗抽查超时次数。
  final int attendanceMissed;

  /// 被豁免的抽查次数（活动取消时未发生的任务）。
  final int attendanceExcused;

  /// 考勤汇总等级。**参考信息**，不自动扣减（方案 §1.1）。
  final AttendanceSummary? attendanceSummary;

  /// 本人签到时刻。
  final DateTime? checkinAt;

  /// 绑定设备指纹（用于识别「同设备多账号」风险，方案 §6.1）。
  final String? boundDeviceId;

  /// 该条目是否仍在有效名单内。
  bool get isActive => signupStatus.isActive && removedAt == null;

  /// 「已移出（时间）」标注文案（方案 §14.1-7）。
  String? get removedLabel => removedAt == null ? null : '已移出（${TimeFormat.format(removedAt!)}）';

  /// 在岗应响应总次数。
  int get attendanceTotal => attendanceDone + attendanceMissed + attendanceExcused;

  factory Participant.fromJson(Map<String, dynamic> json) => Participant(
        userNo: jsonStringOr(json['userNo'], ''),
        name: jsonStringOr(json['name'], ''),
        college: jsonString(json['college']),
        phoneMasked: jsonString(json['phone']),
        signupStatus: SignupStatus.fromWire(json['signupStatus']),
        checkinStatus: ParticipantCheckinStatus.fromWire(json['checkinStatus']),
        removedAt: TimeFormat.tryParse(json['removedAt']),
        removedBy: jsonString(json['removedBy']),
        grantExpiresAt: TimeFormat.tryParse(json['grantExpiresAt']),
        inviteCodeIssued: jsonBoolOr(json['inviteCodeIssued'], false),
        inviteCodeUsedAt: TimeFormat.tryParse(json['inviteCodeUsedAt']),
        attendanceDone: jsonIntOr(json['attendanceDone'], 0),
        attendanceMissed: jsonIntOr(json['attendanceMissed'], 0),
        attendanceExcused: jsonIntOr(json['attendanceExcused'], 0),
        attendanceSummary: json['attendanceSummary'] == null
            ? null
            : AttendanceSummary.fromWire(json['attendanceSummary']),
        checkinAt: TimeFormat.tryParse(json['checkinAt']),
        boundDeviceId: jsonString(json['boundDeviceId']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'userNo': userNo,
        'name': name,
        if (college != null) 'college': college,
        if (phoneMasked != null) 'phone': phoneMasked,
        'signupStatus': signupStatus.wire,
        'checkinStatus': checkinStatus.wire,
        if (removedAt != null) 'removedAt': TimeFormat.toIso8601(removedAt!),
        if (removedBy != null) 'removedBy': removedBy,
        if (grantExpiresAt != null) 'grantExpiresAt': TimeFormat.toIso8601(grantExpiresAt!),
        'inviteCodeIssued': inviteCodeIssued,
        if (inviteCodeUsedAt != null) 'inviteCodeUsedAt': TimeFormat.toIso8601(inviteCodeUsedAt!),
        'attendanceDone': attendanceDone,
        'attendanceMissed': attendanceMissed,
        'attendanceExcused': attendanceExcused,
        if (attendanceSummary != null) 'attendanceSummary': attendanceSummary!.wire,
        if (checkinAt != null) 'checkinAt': TimeFormat.toIso8601(checkinAt!),
        if (boundDeviceId != null) 'boundDeviceId': boundDeviceId,
      };
}

/// 单次定位采样。方案 §5.3 要求高精度采样 3 次（约 3 秒）。
class CheckinSample {
  const CheckinSample({
    required this.point,
    required this.accuracy,
    required this.capturedAt,
    this.altitude,
    this.speed,
    this.isMock,
    this.provider,
  });

  /// WGS-84 坐标点。
  final GeoPoint point;

  /// 水平精度（米）。>100m 该证据不计分（方案 §6.1）。
  final double accuracy;

  /// 采集时刻。
  final DateTime capturedAt;

  /// 海拔（米）。
  final double? altitude;

  /// 速度（米/秒）。异常速度可用于轨迹异常判定（方案 §6.1 `−40`）。
  final double? speed;

  /// 该次采样是否被系统标记为模拟定位。
  final bool? isMock;

  /// 定位来源：`gps` / `network` / `fused`。
  final String? provider;

  /// 精度是否可用于计分。
  bool get isAccurateEnough => accuracy > 0 && accuracy <= 100;

  factory CheckinSample.fromJson(Map<String, dynamic> json) => CheckinSample(
        point: GeoPoint(
          lat: jsonDoubleOr(json['geoLat'], 0),
          lng: jsonDoubleOr(json['geoLng'], 0),
        ),
        accuracy: jsonDoubleOr(json['accuracy'], 0),
        capturedAt: TimeFormat.tryParse(json['capturedAt']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        altitude: jsonDouble(json['altitude']),
        speed: jsonDouble(json['speed']),
        isMock: json['isMock'] == null ? null : jsonBoolOr(json['isMock'], false),
        provider: jsonString(json['provider']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'geoLat': point.lat,
        'geoLng': point.lng,
        'accuracy': accuracy,
        'capturedAt': TimeFormat.toIso8601(capturedAt),
        if (altitude != null) 'altitude': altitude,
        if (speed != null) 'speed': speed,
        if (isMock != null) 'isMock': isMock,
        if (provider != null) 'provider': provider,
      };
}

/// 评分明细项。**这不是客户端判定**，只是服务端返回结果的展示载体。
///
/// 管理端「待人工确认列表」需要展示评分构成，让复核有据可依（方案 §4.8）。
class ScoreItem {
  const ScoreItem({required this.reason, required this.points});

  /// 中文原因，与方案 §6.1 评分表逐条对应。
  final String reason;

  /// 该条目的加减分。
  final int points;

  factory ScoreItem.fromJson(Map<String, dynamic> json) => ScoreItem(
        reason: jsonStringOr(json['reason'], ''),
        points: jsonIntOr(json['points'], 0),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{'reason': reason, 'points': points};

  /// 展示用文案：`围栏内（≤50m） +40`。
  String get label => points >= 0 ? '$reason +$points' : '$reason $points';
}

/// 签到记录（`checkin`）。
class Checkin {
  const Checkin({
    required this.id,
    required this.activityId,
    required this.method,
    required this.status,
    this.userNo,
    this.name,
    this.reason,
    this.point,
    this.accuracy,
    this.score,
    this.scoreItems = const <ScoreItem>[],
    this.distanceMeters,
    this.mockLocationDetected = false,
    this.clientTime,
    this.serverTime,
    this.reviewedAt,
    this.reviewedBy,
    this.reviewNote,
    this.deviceId,
    this.appVersion,
    this.wifiMatched = false,
    this.campusIpMatched = false,
    this.dwellVerified = false,
    this.offlineBackfill = false,
    this.syncState,
  });

  /// 签到记录 ID。
  final String id;

  /// 所属活动 ID。
  final String activityId;

  /// 签到方式。
  final CheckinMethod method;

  /// 服务端判定结果。
  final CheckinStatus status;

  /// 学号（管理端看板展示用；用户端查询本人记录时为本人学号）。
  final String? userNo;

  /// 姓名（管理端看板展示用）。
  final String? name;

  /// 判定原因。驳回时**必须**给出具体原因（方案 §4.3、验收 A12）。
  final String? reason;

  /// 上报坐标（WGS-84）。
  final GeoPoint? point;

  /// 上报精度（米）。
  final double? accuracy;

  /// 风险评分。≥60 `success`；30–59 `pending_review`（方案 §6.1）。
  final int? score;

  /// 评分明细。
  final List<ScoreItem> scoreItems;

  /// 到围栏中心的距离（米），由服务端计算。
  final double? distanceMeters;

  /// 是否命中模拟定位。**命中即强制转人工，不自动通过**（方案 §6.1）。
  final bool mockLocationDetected;

  /// 客户端时间戳。与服务端时间同时保存（方案 §6.4）。
  final DateTime? clientTime;

  /// 服务端时间戳。
  final DateTime? serverTime;

  /// 人工复核时刻。
  final DateTime? reviewedAt;

  /// 复核人。
  final String? reviewedBy;

  /// 复核备注。驳回时必填（方案 §4.8）。
  final String? reviewNote;

  /// 设备指纹。
  final String? deviceId;

  /// 客户端版本，便于定位现场问题。
  final String? appVersion;

  /// Wi-Fi BSSID 命中（`+20`）。
  final bool wifiMatched;

  /// 校园网 IP 命中（`+10`）。
  final bool campusIpMatched;

  /// 停留验证通过（`+15`）。
  final bool dwellVerified;

  /// 是否为超窗离线补传。**超窗补传一律转待人工确认**（方案 §6.4）。
  final bool offlineBackfill;

  /// 仅本地：同步状态。服务端下发时为 `null`。
  final SyncState? syncState;

  /// 是否为离线补传且尚未拿到终态。
  bool get isAwaitingSync => syncState != null && syncState!.isOutstanding;

  /// 精度是否达标（方案 §6.1）。
  bool get accuracyOk => accuracy != null && accuracy! > 0 && accuracy! <= 100;

  /// 能否人工复核（仅 `pending_review` 可复核）。
  bool get isReviewable => status == CheckinStatus.pendingReview;

  factory Checkin.fromJson(Map<String, dynamic> json) => Checkin(
        id: jsonStringOr(json['id'], ''),
        activityId: jsonStringOr(json['activityId'], ''),
        method: CheckinMethod.fromWire(json['method']),
        status: CheckinStatus.fromWire(json['status']),
        userNo: jsonString(json['userNo']),
        name: jsonString(json['name']),
        reason: jsonString(json['reason']),
        point: json['geoLat'] == null && json['geoLng'] == null
            ? null
            : GeoPoint(
                lat: jsonDoubleOr(json['geoLat'], 0),
                lng: jsonDoubleOr(json['geoLng'], 0),
              ),
        accuracy: jsonDouble(json['accuracy']),
        score: jsonInt(json['score']),
        scoreItems: jsonObjectList(json['scoreBreakdown'], ScoreItem.fromJson),
        distanceMeters: jsonDouble(json['distanceMeters']),
        mockLocationDetected: jsonBoolOr(json['mockLocationDetected'], false),
        clientTime: TimeFormat.tryParse(json['clientTime']),
        serverTime: TimeFormat.tryParse(json['serverTime']),
        reviewedAt: TimeFormat.tryParse(json['reviewedAt']),
        reviewedBy: jsonString(json['reviewedBy']),
        reviewNote: jsonString(json['reviewNote']),
        deviceId: jsonString(json['deviceId']),
        appVersion: jsonString(json['appVersion']),
        wifiMatched: jsonBoolOr(json['wifiMatched'], false),
        campusIpMatched: jsonBoolOr(json['campusIpMatched'], false),
        dwellVerified: jsonBoolOr(json['dwellVerified'], false),
        offlineBackfill: jsonBoolOr(json['offlineBackfill'], false),
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
        'method': method.wire,
        'status': status.wire,
        if (userNo != null) 'userNo': userNo,
        if (name != null) 'name': name,
        if (reason != null) 'reason': reason,
        if (point != null) ...<String, dynamic>{
          'geoLat': point!.lat,
          'geoLng': point!.lng,
        },
        if (accuracy != null) 'accuracy': accuracy,
        if (score != null) 'score': score,
        if (scoreItems.isNotEmpty)
          'scoreBreakdown':
              scoreItems.map((ScoreItem e) => e.toJson()).toList(growable: false),
        if (distanceMeters != null) 'distanceMeters': distanceMeters,
        'mockLocationDetected': mockLocationDetected,
        if (clientTime != null) 'clientTime': TimeFormat.toIso8601(clientTime!),
        if (serverTime != null) 'serverTime': TimeFormat.toIso8601(serverTime!),
        if (reviewedAt != null) 'reviewedAt': TimeFormat.toIso8601(reviewedAt!),
        if (reviewedBy != null) 'reviewedBy': reviewedBy,
        if (reviewNote != null) 'reviewNote': reviewNote,
        if (deviceId != null) 'deviceId': deviceId,
        if (appVersion != null) 'appVersion': appVersion,
        'wifiMatched': wifiMatched,
        'campusIpMatched': campusIpMatched,
        'dwellVerified': dwellVerified,
        'offlineBackfill': offlineBackfill,
        if (syncState != null) 'syncState': syncState!.wire,
      };
}

/// 签到提交载荷（本地队列也用它持久化原始证据，方案 §6.4）。
///
/// 关键点：
///   * [idempotencyKey] 保证重传不产生重复记录（方案 §9、验收 A23）；
///   * [clientTime] 与 [serverTime] 由服务端分别保存；
///   * 原始证据（坐标、精度、时间戳、模拟定位检测结果）**全部**入队，
///     而不是只存最终结论——补传时要让服务端重新判定。
class CheckinDraft {
  const CheckinDraft({
    required this.activityId,
    required this.idempotencyKey,
    required this.samples,
    required this.clientTime,
    required this.method,
    this.mockLocationDetected = false,
    this.wifiBssid,
    this.localIp,
    this.deviceId,
    this.appVersion,
    this.recentInsideFence = false,
    this.enqueuedAt,
    this.isBackfill = false,
  });

  /// 活动 ID。
  final String activityId;

  /// 幂等键。同一份证据重传必须复用同一个键（方案 §9）。
  final String idempotencyKey;

  /// 定位采样序列（通常 3 次）。
  final List<CheckinSample> samples;

  /// 客户端时间戳。
  final DateTime clientTime;

  /// 签到方式。
  final CheckinMethod method;

  /// 模拟定位检测结果。**必须一并上报**，而不是本地丢弃——
  /// 服务端需要据此做「命中即强制转人工」判定（方案 §6.1）。
  final bool mockLocationDetected;

  /// 当前 Wi-Fi BSSID，用于辅证（`+20`）。
  final String? wifiBssid;

  /// 当前 IP，用于校园网辅证（`+10`）。
  final String? localIp;

  /// 设备指纹。
  final String? deviceId;

  /// 客户端版本。
  final String? appVersion;

  /// 签到前 60 秒内是否已有围栏内定位（`+15`）。由客户端缓存提供线索。
  final bool recentInsideFence;

  /// 入队时刻。
  final DateTime? enqueuedAt;

  /// 是否为超窗补传。服务端据此**一律转 `pending_review`**（方案 §6.4）。
  final bool isBackfill;

  /// 主采样点（取第一次采样）。
  CheckinSample? get primarySample => samples.isEmpty ? null : samples.first;

  /// 采样是否全部一致（用于 `+10` 加分与模拟定位识别）。
  bool get samplesConsistent {
    if (samples.length < 2) {
      return false;
    }
    final GeoPoint first = samples.first.point;
    for (final CheckinSample s in samples.skip(1)) {
      if (!first.approximatelyEquals(s.point, toleranceMeters: 30)) {
        return false;
      }
    }
    return true;
  }

  /// 所有采样中出现的最小精度（越小越好）。
  double? get bestAccuracy {
    double? best;
    for (final CheckinSample s in samples) {
      if (best == null || s.accuracy < best) {
        best = s.accuracy;
      }
    }
    return best;
  }

  /// 上报体。字段名与**网页方案 §6.4.5 的嵌套报文**严格一致。
  ///
  /// ```jsonc
  /// { "method":"geo",
  ///   "location":{ "lat":…, "lng":…, "accuracy":…, "provider":"…",
  ///                "samples":[…], "sampledAt":"…" },
  ///   "network":{ "wifiBssids":[…], "sourceIp":"…" },
  ///   "device":{ "deviceId":"…", "mockLocationDetected":false, "appVersion":"…" },
  ///   "clientTime":"…" }
  /// ```
  ///
  /// ⚠️ 两处刻意偏离契约原文，都有理由：
  ///
  /// 1. **`samples` 发数组而不是数量**。契约写的是 `samples`（数量），
  ///    但服务端的反作弊要看**每次采样是否一致**（`+10` 评分项，
  ///    也是识别"坐标与精度完全一致"这类伪造的依据）。只报数量等于
  ///    把这条判据废掉。因此这里发完整采样数组；
  ///    服务端两种都接受（见 `normalizeCheckinPayload`）。
  ///    此项已列入 `docs/contract-alignment-web-plan.md` §3.2 待后端确认。
  ///
  /// 2. **额外带 `idempotencyKey` 与 `offlineBackfill`**。前者是为了让
  ///    请求体与 `X-Idempotency-Key` 头一致（服务端两者都读）；
  ///    后者标记超窗补传，服务端据此转人工（移动端方案 §6.4）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'method': method.wire,
        'location': <String, dynamic>{
          if (primarySample != null) ...<String, dynamic>{
            'lat': primarySample!.point.lat,
            'lng': primarySample!.point.lng,
            'accuracy': primarySample!.accuracy,
            if (primarySample!.altitude != null) 'altitude': primarySample!.altitude,
            if (primarySample!.speed != null) 'speed': primarySample!.speed,
            if (primarySample!.provider != null) 'provider': primarySample!.provider,
          },
          // 完整采样序列（见上面第 1 点的说明）。
          'samples': samples.map((CheckinSample e) => e.toJson()).toList(growable: false),
          'sampledAt': TimeFormat.toIso8601(clientTime),
        },
        'network': <String, dynamic>{
          if (wifiBssid != null) 'wifiBssids': <String>[wifiBssid!],
          if (localIp != null) 'sourceIp': localIp,
        },
        'device': <String, dynamic>{
          if (deviceId != null) 'deviceId': deviceId,
          'mockLocationDetected': mockLocationDetected,
          if (appVersion != null) 'appVersion': appVersion,
        },
        'clientTime': TimeFormat.toIso8601(clientTime),
        // 服务端也读请求体里的幂等键（与请求头二者取一）。
        if (idempotencyKey.isNotEmpty) 'idempotencyKey': idempotencyKey,
        'offlineBackfill': isBackfill,
        'recentInsideFence': recentInsideFence,
      };

  /// 反序列化。**同时兼容嵌套（契约）与扁平（早期队列数据）两种形态**。
  ///
  /// ⚠️ 兼容扁平形态不是可选项：本地离线队列里可能还躺着按旧格式
  /// （`geoLat`/`samples` 在顶层）序列化的证据。只认新格式会让这些
  /// **尚未补传的签到证据直接丢失**——而那正是最不该丢的数据。
  factory CheckinDraft.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? loc = jsonMap(json['location']);
    final Map<String, dynamic>? net = jsonMap(json['network']);
    final Map<String, dynamic>? dev = jsonMap(json['device']);

    // 采样：优先嵌套的 location.samples，退回顶层的 samples。
    final Object? rawSamples = loc?['samples'] ?? json['samples'];
    // Wi-Fi：契约是数组 wifiBssids，退回单个 wifiBssid。
    final List<String> bssids = loc == null && net == null
        ? <String>[]
        : jsonStringList(net?['wifiBssids']);

    return CheckinDraft(
      activityId: jsonStringOr(json['activityId'], ''),
      idempotencyKey: jsonStringOr(json['idempotencyKey'], ''),
      samples: jsonObjectList(rawSamples, CheckinSample.fromJson),
      clientTime: TimeFormat.tryParse(json['clientTime']) ?? DateTime.now(),
      method: CheckinMethod.fromWire(json['method']),
      // 模拟定位：优先 device 节点，退回顶层。
      mockLocationDetected: jsonBoolOr(
        dev?['mockLocationDetected'] ?? json['mockLocationDetected'],
        false,
      ),
      wifiBssid: bssids.isNotEmpty
          ? bssids.first
          : (jsonString(net?['wifiBssid']) ?? jsonString(json['wifiBssid'])),
      localIp: jsonString(net?['sourceIp']) ?? jsonString(json['localIp']),
      deviceId: jsonString(dev?['deviceId']) ?? jsonString(json['deviceId']),
      appVersion: jsonString(dev?['appVersion']) ?? jsonString(json['appVersion']),
      recentInsideFence: jsonBoolOr(json['recentInsideFence'], false),
      enqueuedAt: TimeFormat.tryParse(json['enqueuedAt']),
      isBackfill: jsonBoolOr(json['offlineBackfill'], false),
    );
  }

  CheckinDraft copyWith({
    String? activityId,
    String? idempotencyKey,
    List<CheckinSample>? samples,
    DateTime? clientTime,
    CheckinMethod? method,
    bool? mockLocationDetected,
    String? wifiBssid,
    String? localIp,
    String? deviceId,
    String? appVersion,
    bool? recentInsideFence,
    DateTime? enqueuedAt,
    bool? isBackfill,
  }) =>
      CheckinDraft(
        activityId: activityId ?? this.activityId,
        idempotencyKey: idempotencyKey ?? this.idempotencyKey,
        samples: samples ?? this.samples,
        clientTime: clientTime ?? this.clientTime,
        method: method ?? this.method,
        mockLocationDetected: mockLocationDetected ?? this.mockLocationDetected,
        wifiBssid: wifiBssid ?? this.wifiBssid,
        localIp: localIp ?? this.localIp,
        deviceId: deviceId ?? this.deviceId,
        appVersion: appVersion ?? this.appVersion,
        recentInsideFence: recentInsideFence ?? this.recentInsideFence,
        enqueuedAt: enqueuedAt ?? this.enqueuedAt,
        isBackfill: isBackfill ?? this.isBackfill,
      );
}
