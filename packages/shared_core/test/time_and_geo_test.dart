import 'package:shared_core/shared_core.dart';
import 'package:test/test.dart';

/// 坐标系与时间口径的回归测试。
///
/// 这两件事出错不会崩，但会造成**现场事故**：
///   * 坐标系混用 → 围栏整体偏移 50～500m → 签到误判（方案 §13-A7、验收 A14）
///   * 时间格式不统一 → 展示错乱、跨端对不上
void main() {
  group('GeoPoint 距离计算', () {
    // 中国矿业大学南湖校区附近的一个基准点
    const GeoPoint base = GeoPoint(lat: 34.2175, lng: 117.1425);
    const double mPerDegLat = 111320;

    GeoPoint north(double meters) =>
        GeoPoint(lat: base.lat + meters / mPerDegLat, lng: base.lng);

    test('正北 100m 的距离误差在 1m 内', () {
      expect(base.distanceTo(north(100)), closeTo(100, 1));
    });

    test('正北 1000m 的距离误差在 5m 内', () {
      expect(base.distanceTo(north(1000)), closeTo(1000, 5));
    });

    test('同一点距离为 0', () {
      expect(base.distanceTo(base), 0);
    });

    test('距离是对称的', () {
      final GeoPoint other = north(500);
      expect(base.distanceTo(other), closeTo(other.distanceTo(base), 0.001));
    });

    test('围栏判定：边界内外', () {
      const double radius = 200;
      expect(
        GeoPoint(lat: base.lat, lng: base.lng).isInsideFence(center: base, radiusMeters: radius),
        isTrue,
      );
      expect(
        north(199).isInsideFence(center: base, radiusMeters: radius),
        isTrue,
        reason: '199m 应在 200m 围栏内',
      );
      expect(
        north(201).isInsideFence(center: base, radiusMeters: radius),
        isFalse,
        reason: '201m 应在 200m 围栏外',
      );
    });

    test('isPlausible 拒绝越界坐标与 (0,0)', () {
      expect(const GeoPoint(lat: 34.2, lng: 117.1).isPlausible, isTrue);
      expect(const GeoPoint(lat: 0, lng: 0).isPlausible, isFalse, reason: '(0,0) 是"没拿到定位"');
      expect(const GeoPoint(lat: 91, lng: 117).isPlausible, isFalse);
      expect(const GeoPoint(lat: 34, lng: 181).isPlausible, isFalse);
      expect(const GeoPoint(lat: -91, lng: 117).isPlausible, isFalse);
    });
  });

  group('GeoTransform 坐标转换（验收 A14 的基础）', () {
    const GeoPoint wgs = GeoPoint(lat: 34.2175, lng: 117.1425);

    test('WGS-84 → GCJ-02 产生 30～800m 的偏移（这是问题的根源）', () {
      final GeoPoint gcj = GeoTransform.wgs84ToGcj02(wgs);
      final double offset = wgs.distanceTo(gcj);
      expect(
        offset,
        greaterThan(30),
        reason: '境内 GCJ-02 偏移不应小于 30m，否则说明转换没生效',
      );
      expect(offset, lessThan(800), reason: '偏移量不应超过 800m');
      expect(gcj, isNot(equals(wgs)));
    });

    test('GCJ-02 → WGS-84 能还原回原坐标（误差 < 1m）', () {
      final GeoPoint gcj = GeoTransform.wgs84ToGcj02(wgs);
      final GeoPoint back = GeoTransform.gcj02ToWgs84(gcj);
      expect(
        back.distanceTo(wgs),
        lessThan(1.0),
        reason: '迭代逼近应能还原到 1m 内，实际 ${back.distanceTo(wgs)}m',
      );
    });

    test('BD-09 → GCJ-02 → WGS-84 往返误差 < 2m', () {
      final GeoPoint bd = GeoTransform.gcj02ToBd09(GeoTransform.wgs84ToGcj02(wgs));
      final GeoPoint back = GeoTransform.gcj02ToWgs84(GeoTransform.bd09ToGcj02(bd));
      expect(back.distanceTo(wgs), lessThan(2.0));
    });

    test('境外坐标不做偏移（否则会引入反向误差）', () {
      // 伦敦
      const GeoPoint london = GeoPoint(lat: 51.5074, lng: -0.1278);
      expect(GeoTransform.isOutOfChina(london), isTrue);
      expect(GeoTransform.wgs84ToGcj02(london), equals(london));
      expect(GeoTransform.gcj02ToWgs84(london), equals(london));
    });

    test('GeoPoint.fromSystem 声明坐标来源即自动转换', () {
      final GeoPoint gcj = GeoTransform.wgs84ToGcj02(wgs);
      final GeoPoint converted = GeoPoint.fromSystem(
        lat: gcj.lat,
        lng: gcj.lng,
        system: GeoCoordSystem.gcj02,
      );
      expect(converted.distanceTo(wgs), lessThan(1.0));
    });

    test('GeoPoint.fromSystem 默认按 WGS-84 处理，不做转换', () {
      final GeoPoint asIs = GeoPoint.fromSystem(lat: wgs.lat, lng: wgs.lng);
      expect(asIs, equals(wgs));
    });
  });

  group('CoordinateShiftDetector 偏移异常识别（验收 A14）', () {
    const GeoPoint fence = GeoPoint(lat: 34.2175, lng: 117.1425);
    const double radius = 200;

    test('围栏内 → normal', () {
      const GeoPoint inside = GeoPoint(lat: 34.21755, lng: 117.14255);
      expect(
        CoordinateShiftDetector.inspect(
          reported: inside,
          fenceCenter: fence,
          radiusMeters: radius,
        ),
        CoordinateShiftVerdict.normal,
      );
    });

    test('东北向偏移约 500m → 疑似坐标系未转换', () {
      // GCJ-02 在中国境内总体偏东北
      const GeoPoint shifted = GeoPoint(lat: 34.22126, lng: 117.14757);
      final CoordinateShiftVerdict v = CoordinateShiftDetector.inspect(
        reported: shifted,
        fenceCenter: fence,
        radiusMeters: radius,
      );
      expect(v, CoordinateShiftVerdict.suspectedUnconverted);
    });

    test('西南向偏移 → 判为不在范围内，而不是坐标系问题', () {
      const GeoPoint southwest = GeoPoint(lat: 34.21374, lng: 117.13743);
      final CoordinateShiftVerdict v = CoordinateShiftDetector.inspect(
        reported: southwest,
        fenceCenter: fence,
        radiusMeters: radius,
      );
      expect(
        v,
        CoordinateShiftVerdict.outsideFence,
        reason: 'GCJ-02 偏东北；西南向偏移不符合其特征，不应误导用户去查坐标系',
      );
    });

    test('极远处（另一个城市）→ outsideFence', () {
      const GeoPoint far = GeoPoint(lat: 35.0, lng: 118.0);
      expect(
        CoordinateShiftDetector.inspect(
          reported: far,
          fenceCenter: fence,
          radiusMeters: radius,
        ),
        CoordinateShiftVerdict.outsideFence,
      );
    });
  });

  group('TimeFormat 展示与传输格式（方案 §8）', () {
    test('展示格式为 yyyy-MM-dd HH:mm', () {
      final DateTime t = DateTime(2026, 10, 16, 9, 5);
      expect(TimeFormat.format(t), '2026-10-16 09:05');
      expect(TimeFormat.format(t, withSeconds: true), '2026-10-16 09:05:00');
    });

    test('毫秒不参与展示（避免界面抖动）', () {
      final DateTime t = DateTime(2026, 10, 16, 9, 5, 30, 789);
      expect(TimeFormat.format(t), '2026-10-16 09:05');
      expect(TimeFormat.format(t, withSeconds: true), '2026-10-16 09:05:30');
    });

    test('formatDate 只输出日期', () {
      expect(TimeFormat.formatDate(DateTime(2026, 1, 5, 23, 59)), '2026-01-05');
    });

    test('toIso8601 带时区偏移', () {
      final DateTime t = DateTime(2026, 10, 16, 15, 30, 0);
      final String iso = TimeFormat.toIso8601(t);
      expect(iso, startsWith('2026-10-16T15:30:00'));
      expect(
        RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(iso),
        isTrue,
        reason: '必须带偏移，否则跨端解析会歧义：$iso',
      );
    });

    test('toIso8601 与 tryParse 往返一致', () {
      final DateTime t = DateTime(2026, 10, 16, 15, 30, 45);
      final DateTime? back = TimeFormat.tryParse(TimeFormat.toIso8601(t));
      expect(back, isNotNull);
      expect(back!.isAtSameMomentAs(t), isTrue);
    });

    test('tryParse 兼容 10 位秒级与 13 位毫秒级时间戳', () {
      final DateTime t = DateTime.fromMillisecondsSinceEpoch(1792000000000, isUtc: true);
      expect(TimeFormat.tryParse(1792000000)!.isAtSameMomentAs(t), isTrue);
      expect(TimeFormat.tryParse(1792000000000)!.isAtSameMomentAs(t), isTrue);
    });

    test('tryParse 对无效输入返回 null 而不是抛异常', () {
      expect(TimeFormat.tryParse(null), isNull);
      expect(TimeFormat.tryParse(''), isNull);
      expect(TimeFormat.tryParse('不是一个时间'), isNull);
      expect(TimeFormat.tryParse(<String, dynamic>{}), isNull);
    });

    test('tryParseDisplay 解析表单输入', () {
      expect(TimeFormat.tryParseDisplay('2026-10-16 09:05'), DateTime(2026, 10, 16, 9, 5));
      expect(TimeFormat.tryParseDisplay('2026-10-16T09:05'), DateTime(2026, 10, 16, 9, 5));
      expect(TimeFormat.tryParseDisplay('2026-1-5 9:05'), DateTime(2026, 1, 5, 9, 5));
    });

    test('tryParseDisplay 拒绝溢出日期（2 月 31 日）', () {
      expect(
        TimeFormat.tryParseDisplay('2026-02-31 10:00'),
        isNull,
        reason: 'DateTime 会把 2/31 静默归一化成 3/3，必须显式拒绝',
      );
    });

    test('tryParseDisplay 拒绝非法月/日/时', () {
      expect(TimeFormat.tryParseDisplay('2026-13-01 10:00'), isNull);
      expect(TimeFormat.tryParseDisplay('2026-10-16 25:00'), isNull);
      expect(TimeFormat.tryParseDisplay('2026-10-16 10:70'), isNull);
      expect(TimeFormat.tryParseDisplay('随便什么'), isNull);
    });

    test('formatCountdown 输出 mm:ss 与 hh:mm:ss', () {
      expect(TimeFormat.formatCountdown(const Duration(minutes: 4, seconds: 30)), '04:30');
      expect(TimeFormat.formatCountdown(const Duration(seconds: 59)), '00:59');
      expect(TimeFormat.formatCountdown(const Duration(hours: 1, minutes: 2, seconds: 3)), '01:02:03');
    });

    test('formatCountdown 对零与负数统一显示 00:00（不显示负倒计时）', () {
      expect(TimeFormat.formatCountdown(Duration.zero), '00:00');
      expect(TimeFormat.formatCountdown(const Duration(seconds: -5)), '00:00');
    });

    test('formatDuration 输出中文时长', () {
      expect(TimeFormat.formatDuration(const Duration(minutes: 45)), '45 分钟');
      expect(TimeFormat.formatDuration(const Duration(hours: 2)), '2 小时');
      expect(TimeFormat.formatDuration(const Duration(hours: 2, minutes: 30)), '2 小时 30 分钟');
    });
  });
}
