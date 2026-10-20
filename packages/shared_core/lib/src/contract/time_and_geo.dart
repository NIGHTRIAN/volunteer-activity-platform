/// 时间与坐标：跨端统一口径。
///
/// 三个硬性约定，违反任何一个都会造成现场事故：
///   1. **时间一律 `yyyy-MM-dd HH:mm` 展示、ISO-8601 带偏移传输**（方案 §8）。
///   2. **坐标一律 WGS-84**（方案 §6.1）。混用 GCJ-02 / BD-09 会让围栏整体偏移
///      50～500m，直接导致签到误判（方案 §13-A7、验收用例 A14）。
///   3. 客户端**不判定**签到（方案 §2），本文件只提供坐标系转换与预校验，
///      最终判定权在服务端。
library;

import 'dart:math' as math;

/// 时间格式化与解析。
abstract final class TimeFormat {
  /// 展示格式：`yyyy-MM-dd HH:mm`（方案 §8）。
  static const String display = 'yyyy-MM-dd HH:mm';

  /// 展示格式（含秒）：复核证据、审计留痕需要精确到秒。
  static const String displaySeconds = 'yyyy-MM-dd HH:mm:ss';

  /// 传输格式：ISO-8601 到秒 + 时区偏移。
  static const String transport = "yyyy-MM-dd'T'HH:mm:ssXXX";

  /// 仅日期。
  static const String dateOnly = 'yyyy-MM-dd';

  /// 按【展示格式】输出到界面。
  ///
  /// 不引入 `intl` 的 `DateFormat`：格式固定且不含本地化月份名，手写便于单测，
  /// 也让 shared_core 保持零 Flutter 依赖。
  static String format(DateTime time, {bool withSeconds = false, bool useLocal = true}) {
    final DateTime t = useLocal ? time.toLocal() : time.toUtc();
    final String y = _p4(t.year);
    final String mo = _p2(t.month);
    final String d = _p2(t.day);
    final String h = _p2(t.hour);
    final String mi = _p2(t.minute);
    final String base = '$y-$mo-$d $h:$mi';
    return withSeconds ? '$base:${_p2(t.second)}' : base;
  }

  /// 仅日期部分 `yyyy-MM-dd`。
  static String formatDate(DateTime time) {
    final DateTime t = time.toLocal();
    return '${_p4(t.year)}-${_p2(t.month)}-${_p2(t.day)}';
  }

  /// 输出 ISO-8601（带本地时区偏移），用于上报与幂等键计算。
  static String toIso8601(DateTime time) {
    final DateTime t = time.toLocal();
    return '${_p4(t.year)}-${_p2(t.month)}-${_p2(t.day)}T'
        '${_p2(t.hour)}:${_p2(t.minute)}:${_p2(t.second)}'
        '${_formatOffset(t.timeZoneOffset)}';
  }

  /// 解析服务端时间。
  ///
  /// 兼容 ISO-8601 字符串、[DateTime]、以及 10 位/13 位时间戳。
  /// 服务端**必须**下发带偏移的时间；缺失偏移的裸串由 `DateTime.parse`
  /// 按本地时区解释，这在 +08:00 环境下属正确行为。
  static DateTime? tryParse(Object? raw) {
    if (raw is DateTime) {
      return raw;
    }
    if (raw is int) {
      return raw > 1000000000000
          ? DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(raw * 1000, isUtc: true);
    }
    if (raw is num) {
      final int v = raw.toInt();
      return v > 1000000000000
          ? DateTime.fromMillisecondsSinceEpoch(v, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(v * 1000, isUtc: true);
    }
    if (raw is! String || raw.trim().isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw.trim());
  }

  /// 解析活动录入表单中的 `yyyy-MM-dd HH:mm` 或 `yyyy-MM-ddTHH:mm`。
  static DateTime? tryParseDisplay(String input) {
    final RegExpMatch? m =
        RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{2})').firstMatch(input.trim());
    if (m == null) {
      return null;
    }
    final int month = int.parse(m.group(2)!);
    final int day = int.parse(m.group(3)!);
    final int hour = int.parse(m.group(4)!);
    final int minute = int.parse(m.group(5)!);
    if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59) {
      return null;
    }
    final DateTime parsed = DateTime(
      int.parse(m.group(1)!),
      month,
      day,
      hour,
      minute,
    );
    // 拒绝 2026-02-31 这类溢出后被 DateTime 静默归一化的输入。
    if (parsed.month != month || parsed.day != day) {
      return null;
    }
    return parsed;
  }

  /// 倒计时显示 `mm:ss` / `hh:mm:ss`，用于在岗抽查的响应窗口倒计时。
  static String formatCountdown(Duration remaining) {
    if (remaining.isNegative || remaining == Duration.zero) {
      return '00:00';
    }
    final int total = remaining.inSeconds;
    final int h = total ~/ 3600;
    final int m = (total % 3600) ~/ 60;
    final String mm = _p2(m);
    final String ss = _p2(total % 60);
    return h > 0 ? '${_p2(h)}:$mm:$ss' : '$mm:$ss';
  }

  /// 相对时长描述：「3 小时 30 分钟」。
  static String formatDuration(Duration d) {
    final int minutes = d.inMinutes.abs();
    final int h = minutes ~/ 60;
    final int m = minutes % 60;
    if (h == 0) {
      return '$m 分钟';
    }
    return m == 0 ? '$h 小时' : '$h 小时 $m 分钟';
  }

  static String _p2(int v) => v.toString().padLeft(2, '0');

  static String _p4(int v) => v.toString().padLeft(4, '0');

  static String _formatOffset(Duration offset) {
    final int totalMinutes = offset.inMinutes;
    final String sign = totalMinutes < 0 ? '-' : '+';
    final int abs = totalMinutes.abs();
    return '$sign${_p2(abs ~/ 60)}:${_p2(abs % 60)}';
  }
}

/// 坐标系枚举。
enum GeoCoordSystem {
  /// 国际标准，服务端判定**唯一**接受的坐标系（方案 §6.1）。
  wgs84('WGS-84'),

  /// 国测局加密坐标，高德 / 腾讯地图 SDK 输出。
  gcj02('GCJ-02'),

  /// 百度坐标。
  bd09('BD-09');

  const GeoCoordSystem(this.label);

  final String label;
}

/// 坐标点。**始终以 WGS-84 语义承载数值**。
///
/// 构造时即声明来源坐标系，避免「拿高德坐标直接算距离」这类混用（验收 A14）。
class GeoPoint {
  const GeoPoint({required this.lat, required this.lng});

  /// 纬度。
  final double lat;

  /// 经度。
  final double lng;

  /// 由指定坐标系的坐标构造，内部立即转换为 WGS-84。
  factory GeoPoint.fromSystem({
    required double lat,
    required double lng,
    GeoCoordSystem system = GeoCoordSystem.wgs84,
  }) {
    switch (system) {
      case GeoCoordSystem.wgs84:
        return GeoPoint(lat: lat, lng: lng);
      case GeoCoordSystem.gcj02:
        return GeoTransform.gcj02ToWgs84(GeoPoint(lat: lat, lng: lng));
      case GeoCoordSystem.bd09:
        return GeoTransform.gcj02ToWgs84(GeoTransform.bd09ToGcj02(GeoPoint(lat: lat, lng: lng)));
    }
  }

  /// 地球平均半径（米），Haversine 用。
  static const double earthRadiusMeters = 6371008.8;

  /// 到另一点的球面距离（米）。两点均须为 WGS-84。
  double distanceTo(GeoPoint other) {
    const double d2r = math.pi / 180;
    final double lat1 = lat * d2r;
    final double lat2 = other.lat * d2r;
    final double dLat = (other.lat - lat) * d2r;
    final double dLng = (other.lng - lng) * d2r;
    final double sinHalfLat = math.sin(dLat / 2);
    final double sinHalfLng = math.sin(dLng / 2);
    final double a = sinHalfLat * sinHalfLat +
        math.cos(lat1) * math.cos(lat2) * sinHalfLng * sinHalfLng;
    return earthRadiusMeters * 2 * math.asin(math.min(1, math.sqrt(a)));
  }

  /// 是否落在以 [center] 为圆心、[radiusMeters] 为半径的围栏内。
  bool isInsideFence({required GeoPoint center, required double radiusMeters}) =>
      distanceTo(center) <= radiusMeters;

  /// 坐标是否在地球合法范围内。
  bool get isPlausible =>
      lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180 && !(lat == 0 && lng == 0);

  /// 两点是否近似相等（默认 1m 容差），用于「采样一致」加分与模拟定位识别。
  bool approximatelyEquals(GeoPoint other, {double toleranceMeters = 1.0}) =>
      distanceTo(other) <= toleranceMeters;

  Map<String, dynamic> toJson() => <String, dynamic>{'lat': lat, 'lng': lng};

  @override
  String toString() => '(${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)})';

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);
}

/// 坐标系转换。
///
/// 为什么必须转换：GCJ-02 相对 WGS-84 在中国境内有 50～500m 的非线性偏移，
/// 直接用高德 SDK 的坐标去比对 WGS-84 围栏，会让围栏整体漂移（方案 §13-A7）。
abstract final class GeoTransform {
  /// GCJ-02 偏移量经验系数。
  static const double _a = 6378245.0;
  static const double _ee = 0.00669342162296594323;

  /// 是否在中国境外。境外不做偏移，否则会引入反向误差。
  static bool isOutOfChina(GeoPoint p) =>
      p.lng < 72.004 || p.lng > 137.8347 || p.lat < 0.8293 || p.lat > 55.8271;

  /// GCJ-02 → WGS-84：用一次正向偏移求残差，再迭代逼近（3 次迭代约 1e-7 度精度）。
  static GeoPoint gcj02ToWgs84(GeoPoint gcj) {
    if (isOutOfChina(gcj)) {
      return gcj;
    }
    GeoPoint wgs = gcj;
    for (int i = 0; i < 3; i++) {
      final GeoPoint forward = wgs84ToGcj02(wgs);
      wgs = GeoPoint(
        lat: gcj.lat - (forward.lat - wgs.lat),
        lng: gcj.lng - (forward.lng - wgs.lng),
      );
    }
    return wgs;
  }

  /// WGS-84 → GCJ-02（正向加密）。地图 SDK 需要在 GCJ-02 上打点时使用。
  static GeoPoint wgs84ToGcj02(GeoPoint wgs) {
    if (isOutOfChina(wgs)) {
      return wgs;
    }
    final double dLat = _transformLat(wgs.lng - 105.0, wgs.lat - 35.0);
    final double dLng = _transformLng(wgs.lng - 105.0, wgs.lat - 35.0);
    final double radLat = wgs.lat / 180.0 * math.pi;
    double magic = math.sin(radLat);
    magic = 1 - _ee * magic * magic;
    final double sqrtMagic = math.sqrt(magic);
    return GeoPoint(
      lat: wgs.lat + (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi),
      lng: wgs.lng + (dLng * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi),
    );
  }

  /// BD-09 → GCJ-02。
  ///
  /// 用的是业界通用的近似反解（不是严格逆运算，BD-09 与 GCJ-02 之间本身
  /// 就是有损的近似关系）。注意最后一步：`bdlat/bdlng` 得到的是**纬度/经度**，
  /// 不能拿它去当直角坐标的 x/y 继续算——这是这个公式最常见的写错方式。
  static GeoPoint bd09ToGcj02(GeoPoint bd) {
    const double xPi = math.pi * 3000.0 / 180.0;
    final double x = bd.lng - 0.0065;
    final double y = bd.lat - 0.006;
    final double z = math.sqrt(x * x + y * y) - 0.00002 * math.sin(y * xPi);
    final double theta = math.atan2(y, x) - 0.000003 * math.cos(x * xPi);
    return GeoPoint(
      lat: z * math.sin(theta),
      lng: z * math.cos(theta),
    );
  }

  /// GCJ-02 → BD-09。
  static GeoPoint gcj02ToBd09(GeoPoint gcj) {
    const double xPi = math.pi * 3000.0 / 180.0;
    final double z = math.sqrt(gcj.lng * gcj.lng + gcj.lat * gcj.lat) +
        0.00002 * math.sin(gcj.lat * xPi);
    final double theta = math.atan2(gcj.lat, gcj.lng) + 0.000003 * math.cos(gcj.lng * xPi);
    return GeoPoint(
      lat: z * math.sin(theta) + 0.006,
      lng: z * math.cos(theta) + 0.0065,
    );
  }

  static double _transformLat(double x, double y) {
    double ret = -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0;
    ret += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) * 2.0 / 3.0;
    ret += (160.0 * math.sin(y / 12.0 * math.pi) + 320 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0;
    return ret;
  }

  static double _transformLng(double x, double y) {
    double ret = 300.0 +
        x +
        2.0 * y +
        0.1 * x * x +
        0.1 * x * y +
        0.1 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0;
    ret += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) * 2.0 / 3.0;
    ret += (150.0 * math.sin(x / 12.0 * math.pi) + 300.0 * math.sin(x / 30.0 * math.pi)) * 2.0 / 3.0;
    return ret;
  }
}

/// 坐标系偏移异常检测（验收用例 A14）。
///
/// 判据：上报点到围栏中心的距离，若落在「GCJ-02 典型偏移区间」且明显在围栏外，
/// 提示存在坐标系未转换的可能。这只是**提示**，不是拒绝理由——服务端仍按
/// 实际距离评分，避免误伤真实迟到/跑错场地的志愿者。
enum CoordinateShiftVerdict {
  /// 距离在围栏内，无异常。
  normal('正常'),

  /// 落在围栏外，且偏移量与 GCJ-02 混用的特征相符，提示坐标系问题。
  suspectedUnconverted('疑似坐标系未转换'),

  /// 落在围栏外，偏移量不符合 GCJ-02 特征，更可能是真的不在现场。
  outsideFence('不在签到范围内');

  const CoordinateShiftVerdict(this.label);

  final String label;
}

/// 偏移异常检测器。
abstract final class CoordinateShiftDetector {
  /// GCJ-02 在中国境内的偏移量下限（米）。
  static const double minGcjOffsetMeters = 30.0;

  /// GCJ-02 在中国境内的偏移量上限（米）。留出裕量。
  static const double maxGcjOffsetMeters = 700.0;

  /// 偏移方向特征：GCJ-02 偏移总体指向东北（dLat>0、dLng>0）。
  static CoordinateShiftVerdict inspect({
    required GeoPoint reported,
    required GeoPoint fenceCenter,
    required double radiusMeters,
  }) {
    final double distance = reported.distanceTo(fenceCenter);
    if (distance <= radiusMeters) {
      return CoordinateShiftVerdict.normal;
    }
    final bool inGcjBand =
        distance >= minGcjOffsetMeters && distance <= maxGcjOffsetMeters + radiusMeters;
    // 偏移方向：上报点相对围栏中心偏东北，与 GCJ-02 加密方向一致。
    final bool northeast = reported.lat >= fenceCenter.lat && reported.lng >= fenceCenter.lng;
    if (inGcjBand && northeast) {
      return CoordinateShiftVerdict.suspectedUnconverted;
    }
    return CoordinateShiftVerdict.outsideFence;
  }
}
