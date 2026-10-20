import 'error_codes.dart';

/// 统一响应信封。
///
/// ## 契约来源：《网页开发方案》§6.1（权威）
///
/// > 统一响应：`{"code":0,"msg":"ok","data":{...}}`
///
/// 因此字段名是 **`msg`**，不是 `message`。
/// （早期版本我按常见约定写成了 `message` 并标注"待确认"，
/// 网页方案已明确，故改为 `msg`。）
///
/// `errors[]` 与 `traceId` / `serverTime` 是**我方的扩展**：
/// 方案只规定了 `code`/`msg`/`data` 三个字段。这三个扩展的必要性：
///   * `errors[]` —— 满足方案 §7.2「字段级错误定位」与 §6.4.3「逐行返回结果」。
///     方案只授权了 8 个粗粒度错误码，没有字段级信息就无法把错误显示到具体输入框。
///   * `serverTime` —— 方案 §6.1「判定以服务端时间为准」+ §6.5「NTP 必须启用」。
///     客户端倒计时必须以它为基准。
///   * `traceId` —— 现场排查时把用户截图与后端日志对上。
///
/// ⚠️ 这三个字段**尚未经后端确认**，见 docs/contract-assumptions.md。
/// 服务端不下发时解析层会安全地退化为空值，不会导致失败。
class ApiResponse<T> {
  const ApiResponse({
    required this.code,
    required this.message,
    this.data,
    this.fieldErrors = const <FieldError>[],
    this.traceId,
    this.serverTime,
  });

  /// 平台错误码，见 [ApiErrorCode]。方案授权的值只有 8 个。
  final int code;

  /// 面向用户的提示文案（服务端下发，对应响应体里的 `msg`）。
  final String message;

  /// 业务数据；失败时通常为 `null`。
  final T? data;

  /// 字段级错误，供表单「字段级错误定位」使用（方案 §7.2）。
  final List<FieldError> fieldErrors;

  /// 服务端追踪号。
  final String? traceId;

  /// 服务端当前时间（ISO-8601 带时区）。
  ///
  /// 方案 §6.1：判定以服务端时间为准；§6.5：NTP 必须启用。
  final DateTime? serverTime;

  /// 反查得到的枚举码。
  ApiErrorCode get errorCode => ApiErrorCode.fromValue(code);

  /// 是否成功。
  bool get isSuccess => code == ApiErrorCode.ok.value;

  /// 从 JSON 构造。`data` 由调用方以 [fromData] 转换。
  factory ApiResponse.fromJson(
    Map<String, dynamic> json,
    T Function(Object? data)? fromData, {
    int? fallbackStatusCode,
  }) {
    final int? rawCode = _asInt(json['code']);
    final Object? rawData = json['data'];
    final List<FieldError> fieldErrors = _parseFieldErrors(json['errors']);

    final int code =
        rawCode ?? (fallbackStatusCode == null ? -99 : _statusToCode(fallbackStatusCode));

    return ApiResponse<T>(
      code: code,
      // 方案规定是 `msg`；同时兼容 `message`，这样即便后端两种都出现过也不会丢文案。
      message: _asString(json['msg']) ??
          _asString(json['message']) ??
          ApiErrorCode.fromValue(code).defaultMessage,
      data: rawData == null || fromData == null ? null : fromData(rawData),
      fieldErrors: fieldErrors,
      traceId: _asString(json['traceId']),
      serverTime: _asDateTime(json['serverTime']),
    );
  }

  static int _statusToCode(int httpStatus) => mapHttpStatusToErrorCode(httpStatus).value;

  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  static String? _asString(Object? value) => value is String ? value : null;

  static DateTime? _asDateTime(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  static List<FieldError> _parseFieldErrors(Object? raw) {
    if (raw is! List) {
      return const <FieldError>[];
    }
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> e) => FieldError.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  @override
  String toString() => 'ApiResponse(code: $code, message: $message, traceId: $traceId)';
}

/// 字段级错误，用于表单定位与逐行导入报告（方案 §4.3、§4.6）。
class FieldError {
  const FieldError({required this.field, required this.message, this.row});

  /// 字段名（与字段字典一致）或表格列名。
  final String field;

  /// 中文原因。
  final String message;

  /// 批量导入场景下的行号（从 1 开始）；非逐行场景为 `null`。
  final int? row;

  factory FieldError.fromJson(Map<String, dynamic> json) => FieldError(
        field: json['field']?.toString() ?? '',
        message: json['message']?.toString() ?? '',
        row: json['row'] is int ? json['row'] as int : int.tryParse('${json['row']}'),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'field': field,
        'message': message,
        if (row != null) 'row': row,
      };

  @override
  String toString() => row == null ? '$field: $message' : '第 $row 行 $field: $message';
}
