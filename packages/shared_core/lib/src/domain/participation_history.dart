/// 本机保存的「我参与过的活动」记录。
///
/// ## 为什么需要这个
///
/// 用户端登录方式是**输入活动编码 + 邀请码**，一次只能绑定一个活动。
/// 真机反馈：
///
/// > 参加完一个活动，还有另一个活动要参加，就得重新登录输入活动编码；
/// > 重新登录后，**之前那个活动的记录就看不到了**。
///
/// 记录本身没丢（服务端还在），但用户端拿到的新邀请码只覆盖新活动，
/// 旧活动的接口再也调不到 —— 在用户眼里就是"我的记录没了"。
///
/// 所以把「每次看到过的参与记录」存一份在本机：
///   * 切换活动、解除绑定都**不清除**；
///   * 记录页除了当前活动的实时数据，还能看到历史活动；
///   * 没有网络、没有绑定任何活动时也能看（离线可查）。
///
/// ## 为什么放在 shared_core
///
/// 这是**纯数据 + 纯函数**（合并、排序、JSON），不碰文件、不碰 Flutter，
/// 因此可以在纯 Dart 测试里覆盖边界情况；真正的落盘在
/// `shared_platform` 的 `ParticipationStore`。
library;

/// 一条参与记录（一个活动一条）。
class ParticipationRecord {
  const ParticipationRecord({
    required this.activityId,
    required this.activityTitle,
    required this.userNo,
    required this.name,
    required this.savedAt,
    this.checkinStatus,
    this.score,
    this.checkinAt,
    this.attendanceDone = 0,
    this.attendanceMissed = 0,
  });

  /// 活动编号（服务端 id 或外部编号）。
  final String activityId;

  /// 活动名称（保存时快照，便于离线显示）。
  final String activityTitle;

  /// 学号 / 工号。
  final String userNo;

  /// 姓名。
  final String name;

  /// 签到状态（服务端词表原样保留：success / pending_review / rejected …）。
  final String? checkinStatus;

  /// 证据评分（服务端计算）。
  final int? score;

  /// 签到时间。
  final DateTime? checkinAt;

  /// 在岗抽查完成 / 超时次数。
  final int attendanceDone;
  final int attendanceMissed;

  /// 最后一次在本机更新的时间（用于排序与"新不新"判断）。
  final DateTime savedAt;

  /// 状态的中文说明。**不认识的值原样显示** —— 旧版本存下的记录
  /// 不能因为词表变了就显示成空白。
  String get checkinStatusLabel {
    switch (checkinStatus) {
      case 'success':
        return '已签到';
      case 'pending_review':
        return '待确认';
      case 'rejected':
        return '已驳回';
      case 'invalid':
        return '无效';
      case 'absent':
        return '未签到';
      case null:
        return '尚无签到记录';
      default:
        return checkinStatus!;
    }
  }

  /// 是否已有签到结论（决定界面上要不要显示评分）。
  bool get hasCheckin => checkinStatus != null;

  ParticipationRecord copyWith({
    String? activityTitle,
    String? userNo,
    String? name,
    String? checkinStatus,
    int? score,
    DateTime? checkinAt,
    int? attendanceDone,
    int? attendanceMissed,
    DateTime? savedAt,
  }) =>
      ParticipationRecord(
        activityId: activityId,
        activityTitle: activityTitle ?? this.activityTitle,
        userNo: userNo ?? this.userNo,
        name: name ?? this.name,
        checkinStatus: checkinStatus ?? this.checkinStatus,
        score: score ?? this.score,
        checkinAt: checkinAt ?? this.checkinAt,
        attendanceDone: attendanceDone ?? this.attendanceDone,
        attendanceMissed: attendanceMissed ?? this.attendanceMissed,
        savedAt: savedAt ?? this.savedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'activityId': activityId,
        'activityTitle': activityTitle,
        'userNo': userNo,
        'name': name,
        if (checkinStatus != null) 'checkinStatus': checkinStatus,
        if (score != null) 'score': score,
        if (checkinAt != null) 'checkinAt': checkinAt!.toUtc().toIso8601String(),
        'attendanceDone': attendanceDone,
        'attendanceMissed': attendanceMissed,
        'savedAt': savedAt.toUtc().toIso8601String(),
      };

  /// 宽容解析：字段缺失或类型不对时用默认值，**绝不抛异常**。
  ///
  /// 理由：这份数据是"本机缓存"，属于尽力而为的信息。
  /// 因为一条缓存坏了就让整个记录页打不开，比丢一条缓存严重得多。
  static ParticipationRecord? tryFromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Map<String, dynamic> m = raw.cast<String, dynamic>();
    final String activityId = _str(m['activityId']);
    if (activityId.isEmpty) {
      return null;
    }
    return ParticipationRecord(
      activityId: activityId,
      activityTitle: _str(m['activityTitle']),
      userNo: _str(m['userNo']),
      name: _str(m['name']),
      checkinStatus: m['checkinStatus'] == null ? null : _str(m['checkinStatus']),
      score: m['score'] is int
          ? m['score'] as int
          : int.tryParse(_str(m['score'])),
      checkinAt: _time(m['checkinAt']),
      attendanceDone: _int(m['attendanceDone']),
      attendanceMissed: _int(m['attendanceMissed']),
      savedAt: _time(m['savedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  static String _str(Object? v) => v == null ? '' : v.toString().trim();

  static int _int(Object? v) {
    if (v is int) {
      return v;
    }
    return int.tryParse(_str(v)) ?? 0;
  }

  static DateTime? _time(Object? v) {
    if (v == null) {
      return null;
    }
    return DateTime.tryParse(v.toString());
  }

  @override
  String toString() =>
      'ParticipationRecord($activityId, $activityTitle, $userNo, $checkinStatus)';
}

/// 本机参与记录集合。
///
/// 用不可变集合 + `upsert` 返回新实例：界面拿到的永远是稳定快照，
/// 不会出现"列表读到一半被改"的问题。
class ParticipationHistory {
  const ParticipationHistory(this.records);

  const ParticipationHistory.empty() : records = const <ParticipationRecord>[];

  /// 最多保留多少条。
  ///
  /// 一个志愿者一学期参加几十次活动是合理的，但**不能无限增长**：
  /// 这份数据要整份读写 JSON，几十条是几 KB，几千条就会拖慢启动、
  /// 也让"最新参加的"难以找到。50 条足够覆盖一学期，超出丢最旧的。
  static const int maxRecords = 50;

  final List<ParticipationRecord> records;

  bool get isEmpty => records.isEmpty;

  int get length => records.length;

  /// 按最后更新时间倒序（最近参加的在前）。
  List<ParticipationRecord> get sortedByRecent {
    final List<ParticipationRecord> copy = List<ParticipationRecord>.of(records)
      ..sort((ParticipationRecord a, ParticipationRecord b) =>
          b.savedAt.compareTo(a.savedAt));
    return copy;
  }

  ParticipationRecord? forActivity(String activityId) {
    for (final ParticipationRecord r in records) {
      if (r.activityId == activityId) {
        return r;
      }
    }
    return null;
  }

  /// 新增或更新一条（按 activityId 去重），并裁剪到 [maxRecords]。
  ///
  /// "更新"而不是"追加"很重要：同一活动会多次刷新记录，
  /// 每次追加会让同一个活动在列表里出现十几遍。
  ParticipationHistory upsert(ParticipationRecord record) {
    final List<ParticipationRecord> next = <ParticipationRecord>[];
    bool replaced = false;
    for (final ParticipationRecord r in records) {
      if (r.activityId == record.activityId) {
        // 旧记录里有、新记录没带的字段（例如标题）保留下来，
        // 避免一次只更新签到状态就把标题刷成空。
        next.add(record.copyWith(
          activityTitle: record.activityTitle.isEmpty
              ? r.activityTitle
              : record.activityTitle,
          userNo: record.userNo.isEmpty ? r.userNo : record.userNo,
          name: record.name.isEmpty ? r.name : record.name,
          checkinStatus: record.checkinStatus ?? r.checkinStatus,
          score: record.score ?? r.score,
          checkinAt: record.checkinAt ?? r.checkinAt,
        ));
        replaced = true;
      } else {
        next.add(r);
      }
    }
    if (!replaced) {
      next.add(record);
    }
    next.sort((ParticipationRecord a, ParticipationRecord b) =>
        b.savedAt.compareTo(a.savedAt));
    return ParticipationHistory(
      next.length > maxRecords ? next.sublist(0, maxRecords) : next,
    );
  }

  ParticipationHistory removeActivity(String activityId) => ParticipationHistory(
        records
            .where((ParticipationRecord r) => r.activityId != activityId)
            .toList(),
      );

  ParticipationHistory clear() => const ParticipationHistory.empty();

  List<Object?> toJsonList() =>
      records.map((ParticipationRecord r) => r.toJson()).toList();

  /// 宽容解析：坏掉的单条被跳过，不影响其余记录。
  static ParticipationHistory fromJson(Object? raw) {
    if (raw is! List) {
      return const ParticipationHistory.empty();
    }
    final List<ParticipationRecord> parsed = <ParticipationRecord>[];
    for (final Object? item in raw) {
      final ParticipationRecord? r = ParticipationRecord.tryFromJson(item);
      if (r != null) {
        parsed.add(r);
      }
    }
    parsed.sort((ParticipationRecord a, ParticipationRecord b) =>
        b.savedAt.compareTo(a.savedAt));
    return ParticipationHistory(
      parsed.length > maxRecords ? parsed.sublist(0, maxRecords) : parsed,
    );
  }
}
