import '../contract/time_and_geo.dart';

/// 日志与出站文本的脱敏工具。
///
/// README §3.3 底线②：「**日志与崩溃上报不含完整手机号/学号**」。
///
/// 为什么把它放在 `shared_core` 而不是各端各自实现：
/// 脱敏必须是一条**唯一的出口**。如果让每处自己 `mask`，迟早会有人漏掉，
/// 而漏掉的那一次往往正好是排查现场问题、把日志发给别人的时候——
/// 也就是唯一会真正泄露的时刻。
///
/// 因此网络层的请求日志、异常信息包装、崩溃上报都**必须**经过本类。
abstract final class TelemetrySanitizer {
  /// 手机号 → `138****5678`。
  static String maskPhone(String phone) {
    final String p = phone.trim();
    if (p.length < 7) {
      return p.isEmpty ? '' : '${p[0]}****';
    }
    return '${p.substring(0, 3)}****${p.substring(p.length - 4)}';
  }

  /// 学号/工号 → `20****01`。
  static String maskUserNo(String userNo) {
    final String u = userNo.trim();
    if (u.length <= 4) {
      return u;
    }
    return '${u.substring(0, 2)}****${u.substring(u.length - 2)}';
  }

  /// 令牌 → `abcd****`。
  ///
  /// **令牌绝不能进日志**：它等价于密码，拿到就能冒充身份。
  static String maskToken(String token) {
    if (token.length <= 4) {
      return '****';
    }
    return '${token.substring(0, 4)}****';
  }

  /// 坐标降精度到约 1km。
  ///
  /// 日志里不需要精确位置，但需要能判断"在不在同一个城市"——
  /// 这是排查围栏问题的关键信息，而 1km 精度不足以定位到具体的人。
  static GeoPoint coarsen(GeoPoint point) => GeoPoint(
        lat: (point.lat * 100).roundToDouble() / 100,
        lng: (point.lng * 100).roundToDouble() / 100,
      );

  /// 对一段自由文本做兜底脱敏。
  ///
  /// 用在**不受我们控制的内容**上：异常信息、平台返回的原始字符串、
  /// 第三方 SDK 的错误描述。
  ///
  /// ## 设计原则：宁可少脱敏，不可多脱敏
  ///
  /// 这是经过一次实测修正的结论。最初我按"7～12 位纯数字就是学号"来做，
  /// 结果发现**裸数字无法区分学号与时间戳**：
  ///   * 13 位毫秒时间戳会被匹配掉前 12 位，产出 `179****000000`——
  ///     看起来脱敏了、其实还露着 6 位，**比完全不脱敏更有欺骗性**；
  ///   * 10 位秒级时间戳 `1792000000` 又恰好符合手机号 `1[3-9]` 号段，
  ///     会被脱敏成 `17****00`，把排查最需要的时间线索打残。
  ///
  /// 因此这里的策略是：
  ///   1. **手机号**：11 位、带数字边界 → 总是脱敏（手机号几乎不会与时间戳混淆）；
  ///   2. **带标签的学号**（`学号 2021001234`）→ 连标签一起换成掩码。例外信息里
  ///      学号基本都带标签，带标签就足以确认语义；
  ///   3. **裸数字** → **不处理**。
  ///
  /// 那"裸学号泄露"怎么办？靠另一条路径兜住：[sanitizeJson] 按**字段名**
  /// 精确处理（`userNo` / `phone` / `token` ...），而结构化的日志和上报
  /// 都走那条路径。自由文本兜底只负责明确可判定的情况。
  static String sanitizeText(String input) {
    String out = input;

    // 1) 手机号：11 位、数字边界。
    out = out.replaceAllMapped(
      RegExp(r'(?<!\d)1[3-9]\d{9}(?!\d)'),
      (Match m) => maskPhone(m.group(0)!),
    );

    // 2) 带标签的学号/工号。连标签一起替换，避免留下"学号 ****"这种
    //    让人以为值丢了、又看不出原始长度的中间态。
    out = out.replaceAllMapped(
      RegExp(r'(?:学号|工号|学工号|userNo|user_no)[\s:：=]*([A-Za-z0-9]{4,20})'),
      (Match m) => '学号 ****',
    );

    return out;
  }

  /// 对整份 JSON 做脱敏后序列化，用于打印请求/响应体。
  ///
  /// 先按字段名精确处理敏感键，再对整体做文本脱敏兜底。
  static String sanitizeJson(Object? value) {
    if (value == null) {
      return '(空)';
    }
    final Object? cleaned = _walk(value);
    return sanitizeText(cleaned.toString());
  }

  static Object? _walk(Object? value) {
    if (value is Map<Object?, Object?>) {
      final Map<String, Object?> out = <String, Object?>{};
      value.forEach((Object? k, Object? v) {
        final String key = k.toString();
        out[key] = _sensitiveKey(key) ? '****' : _walk(v);
      });
      return out;
    }
    if (value is List<Object?>) {
      return value.map(_walk).toList(growable: false);
    }
    if (value is String) {
      return sanitizeText(value);
    }
    return value;
  }

  /// 明确敏感、必须整体替换的键。
  static bool _sensitiveKey(String key) {
    const Set<String> sensitive = <String>{
      'token',
      'authorization',
      'inviteCode',
      // 密码类：本平台没有账号密码体系，但留在这里以防将来加管理端口令。
      'password',
      'secret',
    };
    return sensitive.contains(key);
  }
}
