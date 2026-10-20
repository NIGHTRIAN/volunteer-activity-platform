import '../contract/api_envelope.dart';
import '../contract/time_and_geo.dart';
import 'attendance.dart';
import 'enums.dart';

/// 字段级校验结果。
///
/// 方案 §4.2 要求「录入即时校验」，§8 要求「表单分区录入与字段级错误定位」。
/// 因此校验结果以**字段 → 原因**的形式返回，界面可以直接把错误挂到对应输入框。
class ValidationResult {
  const ValidationResult(this.errors);

  /// 空结果。
  const ValidationResult.valid() : errors = const <FieldError>[];

  /// 字段级错误列表。
  final List<FieldError> errors;

  /// 是否通过。
  bool get isValid => errors.isEmpty;

  /// 是否失败。
  bool get hasErrors => errors.isNotEmpty;

  /// 指定字段的首条错误文案，供输入框 `errorText` 使用。
  String? errorFor(String field) {
    for (final FieldError e in errors) {
      if (e.field == field) {
        return e.message;
      }
    }
    return null;
  }

  /// 合并两组结果。
  ValidationResult merge(ValidationResult other) =>
      ValidationResult(<FieldError>[...errors, ...other.errors]);

  /// 首条错误（用于 SnackBar / 顶部提示）。
  FieldError? get first => errors.isEmpty ? null : errors.first;

  @override
  String toString() => isValid ? '通过' : errors.map((FieldError e) => e.toString()).join('；');
}

/// 活动录入表单的原始输入。
///
/// 用原始字符串而不是强类型，是为了让校验器能报出「格式错误」而不是在
/// 解析阶段就抛异常丢掉用户输入。
class ActivityFormInput {
  const ActivityFormInput({
    required this.title,
    required this.organizer,
    required this.startTimeText,
    required this.endTimeText,
    required this.durationHoursText,
    required this.location,
    required this.geoLatText,
    required this.geoLngText,
    this.checkinRadiusText,
    this.checkinWindowBeforeText,
    this.checkinWindowAfterText,
    this.attendanceFirstDelayText,
    this.attendanceIntervalText,
    this.attendanceResponseWindowText,
    this.quotaText,
    this.signupDeadlineText,
    this.summary = '',
    this.description = '',
    this.contact = '',
    this.tags = const <String>[],
  });

  final String title;
  final String organizer;
  final String startTimeText;
  final String endTimeText;
  final String durationHoursText;
  final String location;
  final String geoLatText;
  final String geoLngText;
  final String? checkinRadiusText;
  final String? checkinWindowBeforeText;
  final String? checkinWindowAfterText;
  final String? attendanceFirstDelayText;
  final String? attendanceIntervalText;
  final String? attendanceResponseWindowText;
  final String? quotaText;
  final String? signupDeadlineText;
  final String summary;
  final String description;
  final String contact;
  final List<String> tags;
}

/// 活动发布/编辑校验器。
///
/// 覆盖方案 §4.2 列出的全部预设校验项：
///   必填缺失、`endTime ≤ startTime`、时长越界、报名截止晚于开始、
///   签到半径为 0 或 >1000m、定位与设备时间偏差过大。
abstract final class ActivityValidator {
  /// 站点坐标允许的最大偏差（米）。
  ///
  /// 用途：识别「坐标系未转换」或「选错城市」。100km 足以覆盖同城选点，
  /// 又能在坐标明显异常时拦住（验收用例 A14 的录入侧防线）。
  static const double maxSiteDriftMeters = 100000.0;

  /// 时长上限（小时）。一次志愿活动超过 24 小时几乎必然是录入错误。
  static const double maxDurationHours = 24.0;

  /// 时长下限（小时）。
  static const double minDurationHours = 0.5;

  /// 签到半径下限（米）。为 0 意味着无人能签上。
  static const double minCheckinRadiusMeters = 1.0;

  /// 校验活动表单。
  ///
  /// [now] 与 [deviceLocation] 可选：传入后做「设备时间偏差」与「站点漂移」校验。
  static ValidationResult validate(
    ActivityFormInput input, {
    DateTime? now,
    GeoPoint? deviceLocation,
  }) {
    final List<FieldError> errors = <FieldError>[];

    // ── 必填 ──────────────────────────────────────────────────────────
    if (input.title.trim().isEmpty) {
      errors.add(const FieldError(field: 'title', message: '请填写活动名称'));
    } else if (input.title.trim().length > 60) {
      errors.add(const FieldError(field: 'title', message: '活动名称不超过 60 字'));
    }
    if (input.organizer.trim().isEmpty) {
      errors.add(const FieldError(field: 'organizer', message: '请填写组织部门'));
    }
    if (input.location.trim().isEmpty) {
      errors.add(const FieldError(field: 'location', message: '请填写活动地点，或在地图上选点'));
    }
    if (input.summary.trim().isEmpty) {
      errors.add(const FieldError(field: 'summary', message: '请填写活动简介，列表页需要展示'));
    }

    // ── 时间 ──────────────────────────────────────────────────────────
    final DateTime? start = TimeFormat.tryParseDisplay(input.startTimeText);
    final DateTime? end = TimeFormat.tryParseDisplay(input.endTimeText);
    if (start == null) {
      errors.add(const FieldError(field: 'startTime', message: '开始时间格式应为 yyyy-MM-dd HH:mm'));
    }
    if (end == null) {
      errors.add(const FieldError(field: 'endTime', message: '结束时间格式应为 yyyy-MM-dd HH:mm'));
    }
    if (start != null && end != null && !end.isAfter(start)) {
      errors.add(const FieldError(field: 'endTime', message: '结束时间必须晚于开始时间'));
    }

    // ── 时长 ──────────────────────────────────────────────────────────
    final double? hours = double.tryParse(input.durationHoursText.trim());
    if (hours == null) {
      errors.add(const FieldError(field: 'durationHours', message: '请填写志愿时长（小时）'));
    } else if (hours < minDurationHours || hours > maxDurationHours) {
      errors.add(FieldError(
        field: 'durationHours',
        message: '时长应在 $minDurationHours～$maxDurationHours 小时之间（当前 $hours）',
      ));
    }

    // 时长与起止时间的一致性提醒：不阻断提交，但明显矛盾时给出提示性错误。
    if (start != null && end != null && hours != null && hours > 0) {
      final double actual = end.difference(start).inMinutes / 60.0;
      if ((actual - hours).abs() > 0.51) {
        errors.add(FieldError(
          field: 'durationHours',
          message: '与起止时间不一致：按起止时间应为 ${actual.toStringAsFixed(1)} 小时',
        ));
      }
    }

    // ── 报名截止 ──────────────────────────────────────────────────────
    if (input.signupDeadlineText != null && input.signupDeadlineText!.trim().isNotEmpty) {
      final DateTime? deadline = TimeFormat.tryParseDisplay(input.signupDeadlineText!);
      if (deadline == null) {
        errors.add(const FieldError(
            field: 'signupDeadline', message: '报名截止格式应为 yyyy-MM-dd HH:mm'));
      } else if (start != null && deadline.isAfter(start)) {
        errors.add(const FieldError(
            field: 'signupDeadline', message: '报名截止不得晚于活动开始时间'));
      }
    }

    // ── 坐标 ──────────────────────────────────────────────────────────
    final double? lat = double.tryParse(input.geoLatText.trim());
    final double? lng = double.tryParse(input.geoLngText.trim());
    if (lat == null || lng == null) {
      errors.add(const FieldError(field: 'geoLat', message: '请在地图上选择活动位置'));
    } else {
      final GeoPoint site = GeoPoint(lat: lat, lng: lng);
      if (!site.isPlausible) {
        errors.add(const FieldError(field: 'geoLat', message: '坐标不在有效范围内'));
      } else if (deviceLocation != null) {
        final double drift = site.distanceTo(deviceLocation);
        if (drift > maxSiteDriftMeters) {
          errors.add(FieldError(
            field: 'geoLat',
            message: '选点距当前位置 ${(drift / 1000).toStringAsFixed(0)} 公里，请确认坐标系为 WGS-84 且选点正确',
          ));
        }
      }
    }

    // ── 签到半径 ──────────────────────────────────────────────────────
    final double radius = input.checkinRadiusText == null ||
            input.checkinRadiusText!.trim().isEmpty
        ? 200
        : (double.tryParse(input.checkinRadiusText!.trim()) ?? -1);
    if (radius <= 0) {
      errors.add(const FieldError(
          field: 'checkinRadius', message: '签到半径必须大于 0，否则无人能签到'));
    } else if (radius > 1000) {
      errors.add(const FieldError(field: 'checkinRadius', message: '签到半径不得超过 1000 米'));
    }

    // ── 时间窗与抽查参数 ──────────────────────────────────────────────
    errors.addAll(_durationField(
      field: 'checkinWindowBefore',
      text: input.checkinWindowBeforeText,
      label: '提前开放',
      min: 0,
      max: 180,
    ).errors);
    errors.addAll(_durationField(
      field: 'checkinWindowAfter',
      text: input.checkinWindowAfterText,
      label: '延后关闭',
      min: 0,
      max: 180,
    ).errors);
    errors.addAll(_durationField(
      field: 'attendanceFirstDelay',
      text: input.attendanceFirstDelayText,
      label: '首次抽查延迟',
      min: 1,
      max: 480,
    ).errors);
    errors.addAll(_durationField(
      field: 'attendanceInterval',
      text: input.attendanceIntervalText,
      label: '抽查间隔',
      min: 1,
      max: 480,
    ).errors);
    errors.addAll(_durationField(
      field: 'attendanceResponseWindow',
      text: input.attendanceResponseWindowText,
      label: '抽查响应窗口',
      min: 1,
      max: 120,
    ).errors);

    // ── 名额 ──────────────────────────────────────────────────────────
    if (input.quotaText != null && input.quotaText!.trim().isNotEmpty) {
      final int? quota = int.tryParse(input.quotaText!.trim());
      if (quota == null || quota <= 0) {
        errors.add(const FieldError(field: 'quota', message: '名额需为正整数，或留空表示不限'));
      }
    }

    // ── 设备时间偏差 ──────────────────────────────────────────────────
    if (now != null && start != null) {
      // 只有明显不合常理时才提示（例如设备时间被改到明年）。
      final Duration skew = now.difference(start).abs();
      if (now.isAfter(start) && skew > const Duration(days: 365)) {
        errors.add(const FieldError(
            field: 'startTime', message: '开始时间距今超过一年，或本机时间不准，请核对'));
      }
    }

    // ── 抽查参数组合的可行性 ──────────────────────────────────────────
    if (start != null && end != null && end.isAfter(start)) {
      final Duration window = end.difference(start);
      final int firstDelay = _intOr(input.attendanceFirstDelayText, 15);
      final int interval = _intOr(input.attendanceIntervalText, 30);
      if (firstDelay >= window.inMinutes) {
        errors.add(const FieldError(
            field: 'attendanceFirstDelay', message: '首次抽查延迟不得超出活动时长'));
      }
      if (interval <= 0) {
        errors.add(const FieldError(field: 'attendanceInterval', message: '抽查间隔必须大于 0'));
      }
      final int lastAllowed = window.inMinutes - 15;
      final int slots = firstDelay > lastAllowed
          ? 0
          : 1 + ((lastAllowed - firstDelay) ~/ (interval <= 0 ? 30 : interval));
      if (slots == 0) {
        errors.add(const FieldError(
            field: 'attendanceInterval', message: '按当前参数不会生成任何在岗抽查'));
      }
    }

    return ValidationResult(errors);
  }

  static ValidationResult _durationField({
    required String field,
    required String? text,
    required String label,
    required int min,
    required int max,
  }) {
    if (text == null || text.trim().isEmpty) {
      return const ValidationResult.valid();
    }
    final int? v = int.tryParse(text.trim());
    if (v == null) {
      return ValidationResult(<FieldError>[
        FieldError(field: field, message: '$label 需为整数分钟'),
      ]);
    }
    if (v < min || v > max) {
      return ValidationResult(<FieldError>[
        FieldError(field: field, message: '$label 应在 $min～$max 分钟之间'),
      ]);
    }
    return const ValidationResult.valid();
  }

  static int _intOr(String? text, int fallback) {
    if (text == null || text.trim().isEmpty) {
      return fallback;
    }
    return int.tryParse(text.trim()) ?? fallback;
  }
}

/// 名单导入校验器（方案 §4.6）。
///
/// 支持「批量粘贴（学号/姓名，支持 Excel 列）」与 CSV 导入。
/// 逐行报告结果，无法匹配的行标为「待确认」并可导出修正。
abstract final class ParticipantImportValidator {
  /// 允许的学号/工号格式：4–20 位的字母数字（不同学院编号规则不一，不做过度约束）。
  static final RegExp userNoPattern = RegExp(r'^[A-Za-z0-9]{4,20}$');

  /// 手机号（用于后四位二次校验的解析）。
  static final RegExp phonePattern = RegExp(r'^1[3-9]\d{9}$');

  /// 手机号后四位。
  static final RegExp phoneSuffixPattern = RegExp(r'^\d{4}$');

  /// 解析一行「学号[分隔]姓名[分隔]手机号」的文本。
  ///
  /// 分隔符兼容 Tab（Excel 粘贴）、逗号、中文逗号、分号、空格。
  static List<String> splitLine(String line) => line
      .split(RegExp(r'[\t,，;；|]+|\s{2,}'))
      .map((String e) => e.trim())
      .where((String e) => e.isNotEmpty)
      .toList(growable: false);

  /// 批量粘贴文本 → 原始行。
  ///
  /// 自动跳表头：若首行含「学号」「姓名」「手机」等字样则跳过。
  static List<({int row, List<String> cells})> parsePasted(String raw) {
    final List<({int row, List<String> cells})> out = <({int row, List<String> cells})>[];
    final List<String> lines = raw.split(RegExp(r'\r\n|\r|\n'));
    bool headerChecked = false;
    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i];
      if (line.trim().isEmpty) {
        continue;
      }
      final List<String> cells = splitLine(line);
      if (!headerChecked) {
        headerChecked = true;
        final String joined = cells.join();
        if (joined.contains('学号') || joined.contains('姓名') || joined.contains('手机')) {
          continue; // 跳过表头，行号仍按原文件计
        }
      }
      out.add((row: i + 1, cells: cells));
    }
    return out;
  }

  /// 校验一行。
  ///
  /// [existingUserNos] 为活动内已存在的学号集合，用于「活动内重复」校验。
  /// [knownNameSuffix] 可选：`学号 → (姓名, 手机号后四位)` 的既有名册，
  /// 用于方案 §14.1-2 要求的「姓名或手机号后四位二次校验（必做）」。
  static FieldError? validateRow({
    required int row,
    required List<String> cells,
    required Set<String> existingUserNos,
  }) {
    if (cells.isEmpty) {
      return FieldError(field: 'row', message: '整行为空', row: row);
    }
    if (cells.length < 2) {
      return FieldError(
        field: 'row',
        message: '至少需要「学号」与「姓名」两列，可用 Tab 或逗号分隔',
        row: row,
      );
    }
    final String userNo = cells[0];
    final String name = cells[1];
    final String? phone = cells.length >= 3 ? cells[2] : null;

    if (!userNoPattern.hasMatch(userNo)) {
      return FieldError(
        field: 'userNo',
        message: '学号格式不正确（应为 4–20 位字母或数字）',
        row: row,
      );
    }
    if (name.trim().isEmpty) {
      return FieldError(field: 'name', message: '缺少姓名', row: row);
    }
    if (name.trim().length > 20) {
      return FieldError(field: 'name', message: '姓名过长', row: row);
    }
    if (phone != null && phone.isNotEmpty) {
      // 允许直接给完整手机号，也允许只给后四位。
      final bool ok = phonePattern.hasMatch(phone) || phoneSuffixPattern.hasMatch(phone);
      if (!ok) {
        return FieldError(
          field: 'phone',
          message: '手机号应为 11 位，或仅填后四位',
          row: row,
        );
      }
    }
    if (existingUserNos.contains(userNo)) {
      return FieldError(field: 'userNo', message: '名单中已存在该学号', row: row);
    }
    return null;
  }

  /// 二次校验：姓名或手机号后四位是否与既有名册匹配（方案 §14.1-2，**必做**）。
  ///
  /// 返回 `null` 表示匹配通过；否则返回不匹配的原因。
  /// 匹配失败的行应标为「待确认」而不是直接丢弃——发布者最清楚实际情况。
  static String? crossCheck({
    required String userNo,
    required String name,
    String? phone,
    required Map<String, ({String name, String? phoneSuffix})> knownRoster,
  }) {
    final ({String name, String? phoneSuffix})? known = knownRoster[userNo];
    if (known == null) {
      // 名册里没有这个人：不是错误，只是无法二次校验，交由发布者确认。
      return null;
    }
    final bool nameMatches = known.name.trim() == name.trim();
    final String? suffix = _suffixOf(phone);
    final bool phoneMatches = suffix != null &&
        known.phoneSuffix != null &&
        known.phoneSuffix == suffix;
    if (nameMatches || phoneMatches) {
      return null;
    }
    return '姓名或手机号后四位与名册不一致';
  }

  static String? _suffixOf(String? phone) {
    if (phone == null) {
      return null;
    }
    final String p = phone.trim();
    if (phoneSuffixPattern.hasMatch(p)) {
      return p;
    }
    if (phonePattern.hasMatch(p)) {
      return p.substring(p.length - 4);
    }
    return null;
  }

  /// 脱敏手机号，形如 `138****5678`。
  ///
  /// README §3.3 底线②：**日志与崩溃上报不含完整手机号/学号**。
  static String maskPhone(String phone) {
    final String p = phone.trim();
    if (p.length < 7) {
      return p.isEmpty ? '' : '${p[0]}****';
    }
    return '${p.substring(0, 3)}****${p.substring(p.length - 4)}';
  }

  /// 脱敏学号：保留前 2 后 2。
  static String maskUserNo(String userNo) {
    final String u = userNo.trim();
    if (u.length <= 4) {
      return u;
    }
    return '${u.substring(0, 2)}****${u.substring(u.length - 2)}';
  }
}

/// 签到前置条件检查（**仅用于界面提示**）。
///
/// ⚠️ 这里不做任何「通过/不通过」的结论。方案 §2 明确「签到判定权一律在服务端，
/// 客户端只上报证据」。本类只回答「现在点了会不会白点」，把明显的时间/名单/
/// 授权问题提前告诉志愿者，减少现场无效操作。
final class CheckinPreflight {
  /// 检查结果。
  const CheckinPreflight({
    required this.canSubmit,
    required this.message,
    this.isWarningOnly = false,
    this.fallbackSteps = const <String>[],
  });

  /// 是否允许发起签到请求。
  final bool canSubmit;

  /// 提示文案。
  final String message;

  /// 为 `true` 时表示「可以提交，但有风险，服务端可能转人工」。
  final bool isWarningOnly;

  /// 走不通时的**具体下一步动作**。
  ///
  /// 方案 §7 明确要求「不得出现死路」。因为本平台**不启用动态签到码**
  /// （见 docs/decisions.md D-2），拒定位权限时只剩两条路，必须逐条告诉用户
  /// 该怎么做，而不是只丢一句"签到失败"。
  final List<String> fallbackSteps;

  /// 是否存在降级路径。
  bool get hasFallback => fallbackSteps.isNotEmpty;

  /// 拒定位权限时的降级指引。
  ///
  /// 这是验收用例 A16「拒绝定位权限 → 提供降级路径，不得出现死路」的实现。
  /// 本平台不提供动态签到码，因此给出的是**可执行的两条路**：
  ///   1. 去系统设置开权限（引导到具体开关，而不是笼统说"开启权限"）；
  ///   2. 找发布者现场核实——发布者在管理端看板上就能替你标记到场。
  static const CheckinPreflight locationDenied = CheckinPreflight(
    canSubmit: false,
    message: '没有定位权限，无法通过定位签到。',
    fallbackSteps: <String>[
      '到「系统设置 → 应用 → 本应用 → 权限」中打开「位置信息」，'
          '选择「仅在使用时允许」，然后回到本页重试；',
      '如果暂时无法开启，请当面找活动发布者，'
          '他在管理端看板上可以现场为你标记到场（会记录为「管理端核实」）。',
    ],
  );

  /// 定位服务未开启时的指引。
  static const CheckinPreflight serviceDisabled = CheckinPreflight(
    canSubmit: false,
    message: '手机的定位服务没有打开。',
    fallbackSteps: <String>[
      '下拉通知栏，打开「位置信息」开关后重试；',
      '或当面找活动发布者现场核实。',
    ],
  );

  /// 定位超时/精度不足时的指引。
  static const CheckinPreflight poorSignal = CheckinPreflight(
    canSubmit: false,
    message: '当前定位信号较弱，暂时无法获得可靠位置。',
    fallbackSteps: <String>[
      '走到室外或靠窗的位置，稍等几秒后重试；',
      '或当面找活动发布者现场核实。',
    ],
  );

  /// 允许且无警告。
  static const CheckinPreflight ok =
      CheckinPreflight(canSubmit: true, message: '正在获取定位…');

  /// 检查能否签到。
  ///
  /// [grantExpiresAt] 为活动级授权到期时间；[myCheckinStatus] 为服务端已知的
  /// 本人签到状态（避免重复签到）。
  static CheckinPreflight inspect({
    required DateTime now,
    required DateTime checkinOpensAt,
    required DateTime checkinClosesAt,
    required ActivityStatus status,
    CheckinStatus? myCheckinStatus,
    DateTime? grantExpiresAt,
    AttendanceTask? activeTask,
  }) {
    if (grantExpiresAt != null && now.isAfter(grantExpiresAt)) {
      return const CheckinPreflight(
        canSubmit: false,
        message: '本次活动授权已过期，如需查询请联系发布者',
      );
    }
    if (myCheckinStatus != null && myCheckinStatus.countsAsPresent) {
      return const CheckinPreflight(
        canSubmit: false,
        message: '你已完成签到',
      );
    }
    if (!status.allowsCheckin) {
      return CheckinPreflight(
        canSubmit: false,
        message: status == ActivityStatus.finished || status == ActivityStatus.cancelled
            ? '活动${status.label}，签到已关闭'
            : '活动尚未开放签到',
      );
    }
    if (now.isBefore(checkinOpensAt)) {
      return CheckinPreflight(
        canSubmit: false,
        message: '签到将于 ${TimeFormat.format(checkinOpensAt)} 开放',
      );
    }
    if (now.isAfter(checkinClosesAt)) {
      return const CheckinPreflight(
        canSubmit: false,
        message: '签到时段已结束，请联系发布者人工补录',
      );
    }
    // 在岗抽查进行中：优先完成抽查，两者可能同时需要。
    if (activeTask != null) {
      return CheckinPreflight(
        canSubmit: true,
        isWarningOnly: true,
        message: '你还有 ${activeTask.seqLabel(3)} 在岗确认待响应，'
            '剩余 ${TimeFormat.formatCountdown(activeTask.remaining(now))}',
      );
    }
    return ok;
  }
}
