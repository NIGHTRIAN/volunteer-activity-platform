/// JSON 取值helper。
///
/// 客户端解析服务端数据的原则：**对缺失/类型不符的字段宽松兜底，不抛异常**。
/// 理由：老客户端遇到服务端新增或调整字段时必须继续可用（方案 §13-A8），
/// 宁可少显示一个字段，也不能整页崩掉让志愿者在现场无法签到。
///
/// 同时**不做静默的语义纠正**：兜底值只用于渲染，业务判定一律以服务端返回为准。
library;

/// 取字符串。非字符串且非空时用 `toString()` 兜底（服务端可能下发数字型编码）。
String? jsonString(Object? v) {
  if (v == null) {
    return null;
  }
  if (v is String) {
    return v;
  }
  return v.toString();
}

/// 取字符串，缺失时返回 [fallback]。
String jsonStringOr(Object? v, String fallback) => jsonString(v) ?? fallback;

/// 取整数。
int? jsonInt(Object? v) {
  if (v is int) {
    return v;
  }
  if (v is num) {
    return v.toInt();
  }
  if (v is String) {
    return int.tryParse(v.trim());
  }
  return null;
}

/// 取整数，缺失时返回 [fallback]。
int jsonIntOr(Object? v, int fallback) => jsonInt(v) ?? fallback;

/// 取浮点数。
double? jsonDouble(Object? v) {
  if (v is double) {
    return v;
  }
  if (v is num) {
    return v.toDouble();
  }
  if (v is String) {
    return double.tryParse(v.trim());
  }
  return null;
}

/// 取浮点数，缺失时返回 [fallback]。
double jsonDoubleOr(Object? v, double fallback) => jsonDouble(v) ?? fallback;

/// 取布尔值。兼容 `0/1` 与 `"true"/"false"` 这类弱类型下发。
bool jsonBoolOr(Object? v, bool fallback) {
  if (v is bool) {
    return v;
  }
  if (v is num) {
    return v != 0;
  }
  if (v is String) {
    final String s = v.trim().toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') {
      return true;
    }
    if (s == 'false' || s == '0' || s == 'no') {
      return false;
    }
  }
  return fallback;
}

/// 取字符串列表。
List<String> jsonStringList(Object? v) {
  if (v is! List) {
    return const <String>[];
  }
  return v.where((Object? e) => e != null).map((Object? e) => e.toString()).toList(growable: false);
}

/// 取对象列表并逐个转换。过滤掉无法转换的元素而不是整体失败。
List<T> jsonObjectList<T>(Object? v, T Function(Map<String, dynamic> json) convert) {
  if (v is! List) {
    // 不能用 `const <T>[]`：const 字面量不允许带类型参数。
    return <T>[];
  }
  final List<T> out = <T>[];
  for (final Object? e in v) {
    if (e is Map<Object?, Object?>) {
      out.add(convert(e.cast<String, dynamic>()));
    }
  }
  return out;
}

/// 取嵌套对象并转换。
T? jsonObject<T>(Object? v, T Function(Map<String, dynamic> json) convert) {
  if (v is Map<Object?, Object?>) {
    return convert(v.cast<String, dynamic>());
  }
  return null;
}

/// 取嵌套 Map（不转换）。
Map<String, dynamic>? jsonMap(Object? v) {
  if (v is Map<Object?, Object?>) {
    return v.cast<String, dynamic>();
  }
  return null;
}

/// 解析以「分钟数」下发的时长字段。
///
/// 契约约定：`checkinWindowBefore` / `attendanceInterval` 等一律以**分钟整数**传输，
/// 避免 `"PT15M"` 这类需要额外解析的表示。
Duration? jsonDurationMinutes(Object? v) {
  final num? n = v is num ? v : (v is String ? num.tryParse(v.trim()) : null);
  return n == null ? null : Duration(minutes: n.toInt());
}

/// 解析以「秒数」下发的时长字段（例如导出件下载地址的有效期）。
Duration? jsonDurationSeconds(Object? v) {
  final num? n = v is num ? v : (v is String ? num.tryParse(v.trim()) : null);
  return n == null ? null : Duration(seconds: n.toInt());
}
