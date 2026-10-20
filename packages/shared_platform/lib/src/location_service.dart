import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:shared_core/shared_core.dart';

import 'models.dart';

/// 定位服务。
///
/// ## 隐私约束（方案 §7，不可协商）
///
/// > 位置**仅在签到与抽查时刻按需采集，不采集轨迹、不做后台持续定位**。
///
/// 落实到实现上：
///   * **只申请「使用时」权限**，代码里没有任何 `LocationPermission.always` 的引用；
///   * 没有任何 stream / 订阅式定位，只有单次 `getCurrentPosition`；
///   * 不写任何定位历史到本地存储（`recentInsideFence` 只在**内存**里保留一个短窗口，
///     进程结束即消失）；
///   * [collectSamples] 只采 [ContractDefaults.checkinSampleCount] 次（3 次约 3 秒）。
///
/// ## 坐标系
///
/// 平台原生定位返回的就是 **WGS-84**。这里**不做任何** GCJ-02 / BD-09 转换——
/// 如果用高德/腾讯 SDK 取点，必须先用 `GeoTransform` 转回 WGS-84
/// （方案 §6.1、§13-A7、验收 A14）。
class LocationService {
  LocationService({GeolocatorPlatform? geolocator})
      : _geolocator = geolocator ?? GeolocatorPlatform.instance;

  final GeolocatorPlatform _geolocator;

  /// 内存中的「最近一次围栏内定位」。
  ///
  /// 只用于给服务端提供**停留验证**线索（方案 §6.1 的 +15 分）。
  /// **刻意不持久化**：一旦落盘就变成了"轨迹采集"，违反方案 §7。
  PositionFix? _lastFix;
  DateTime? _lastFixAt;

  /// 检查并（必要时）申请定位权限。
  ///
  /// 返回细化后的状态，让界面能决定"再弹一次"还是"引导去系统设置"。
  Future<LocationPermissionState> ensurePermission() async {
    final bool serviceEnabled = await _geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return LocationPermissionState.serviceDisabled;
    }

    LocationPermission permission = await _geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await _geolocator.requestPermission();
    }

    switch (permission) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        return LocationPermissionState.granted;
      case LocationPermission.deniedForever:
        return LocationPermissionState.deniedForever;
      case LocationPermission.denied:
      case LocationPermission.unableToDetermine:
        return LocationPermissionState.denied;
    }
  }

  /// 采集单次高精度定位。
  ///
  /// [timeout] 默认 12 秒：室内冷启动经常要 5～10 秒，给太短会误报超时，
  /// 给太长又让志愿者在场地里干等。
  Future<PositionFix> getCurrentFix({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final LocationPermissionState state = await ensurePermission();
    if (state == LocationPermissionState.serviceDisabled) {
      throw const LocationException(LocationFailureReason.serviceDisabled);
    }
    if (!state.canCollect) {
      throw const LocationException(LocationFailureReason.permissionDenied);
    }

    try {
      final Position pos = await _geolocator
          .getCurrentPosition(
            locationSettings: LocationSettings(
              // high：方案 §5.3 要求"高精度采样"。
              accuracy: LocationAccuracy.high,
              timeLimit: timeout,
            ),
          )
          .timeout(timeout + const Duration(seconds: 2));

      final PositionFix fix = _toFix(pos);
      if (!fix.point.isPlausible) {
        throw const LocationException(LocationFailureReason.invalidFix);
      }
      _rememberIfRelevant(fix);
      return fix;
    } on LocationException {
      rethrow;
    } on TimeoutException {
      throw const LocationException(LocationFailureReason.timeout);
    } catch (e) {
      // 平台异常信息可能含坐标，日志层会脱敏（见 TelemetryLogger）。
      throw LocationException(LocationFailureReason.unknown, detail: e.toString());
    }
  }

  /// 连续采样 [count] 次，间隔约 [interval]。
  ///
  /// 方案 §5.3：「高精度采样 3 次（约 3 秒）」。多次采样有两个作用：
  ///   1. 给服务端"采样一致"（+10）与"模拟定位"交叉验证提供依据；
  ///   2. 丢掉明显跳变的那一次，提高有效精度。
  ///
  /// **有意义的失败处理**：如果第一次就失败，直接抛出（没必要重试 3 次让用户等）；
  /// 后续失败则忽略，用已有的采样继续——能采到 1 次总比一次都没有好。
  Future<List<PositionFix>> collectSamples({
    int count = ContractDefaults.checkinSampleCount,
    Duration interval = const Duration(milliseconds: 1200),
  }) async {
    final List<PositionFix> samples = <PositionFix>[];

    for (int i = 0; i < count; i++) {
      try {
        samples.add(await getCurrentFix());
      } on LocationException {
        if (samples.isEmpty) {
          rethrow;
        }
        // 已有采样，继续尝试下一次。
      }
      if (i < count - 1) {
        await Future<void>.delayed(interval);
      }
    }

    if (samples.isEmpty) {
      throw const LocationException(LocationFailureReason.invalidFix);
    }
    return samples;
  }

  /// 把采样序列归并成一个[PositionFix]：取**精度最好的**那一次。
  ///
  /// 为什么取最好而不是平均：平均会造出一个"谁都没到过的点"，
  /// 在围栏边界上可能把一次合法签到算到围栏外。
  static PositionFix bestOf(List<PositionFix> samples) {
    assert(samples.isNotEmpty, '采样序列不能为空');
    PositionFix best = samples.first;
    for (final PositionFix s in samples.skip(1)) {
      // 精度数值越小越好；精度无效（<=0）的排在最后。
      if (_accuracyRank(s.accuracy) < _accuracyRank(best.accuracy)) {
        best = s;
      }
    }
    return best;
  }

  static double _accuracyRank(double accuracy) => accuracy > 0 ? accuracy : 1e9;

  /// 采样序列内是否出现模拟定位标记。
  ///
  /// **只要有一次被标记就上报为 true**：方案 §6.1 是"命中即强制转人工"，
  /// 宁可多转一次人工，也不要放过一次伪造。
  static bool anyMockDetected(List<PositionFix> samples) =>
      samples.any((PositionFix s) => s.isMock);

  /// 判断签到前 60 秒内是否已有围栏内定位（方案 §6.1 的 +15 分线索）。
  ///
  /// ⚠️ 这是**客户端提供的线索**，服务端仍会独立判断。而且因为内存里只有一个点，
  /// 它最多只能证明"刚才也在这个围栏附近"，不能证明"一直在"。
  bool recentlyInsideFence({
    required GeoPoint fenceCenter,
    required double radiusMeters,
    DateTime? now,
  }) {
    final PositionFix? fix = _lastFix;
    final DateTime? at = _lastFixAt;
    if (fix == null || at == null) {
      return false;
    }
    final DateTime reference = now ?? DateTime.now();
    if (reference.difference(at) > ContractDefaults.recentInsideFenceWindow) {
      return false;
    }
    return fix.point.isInsideFence(center: fenceCenter, radiusMeters: radiusMeters);
  }

  /// 清空内存线索（例如切换活动、退出登录）。
  void clearRecentHint() {
    _lastFix = null;
    _lastFixAt = null;
  }

  /// 打开系统设置页（权限被永久拒绝时唯一的出路）。
  Future<bool> openAppSettings() => _geolocator.openAppSettings();

  /// 打开系统定位设置页（定位服务关闭时）。
  Future<bool> openLocationSettings() => _geolocator.openLocationSettings();

  void _rememberIfRelevant(PositionFix fix) {
    _lastFix = fix;
    _lastFixAt = fix.capturedAt;
  }

  PositionFix _toFix(Position pos) => PositionFix(
        // 平台原生定位已是 WGS-84，直接采用，不做坐标转换。
        point: GeoPoint(lat: pos.latitude, lng: pos.longitude),
        accuracy: pos.accuracy,
        capturedAt: pos.timestamp,
        altitude: pos.altitude,
        speed: pos.speed,
        // Android 的模拟定位标记由 geolocator 透传；iOS 上恒为 false。
        // 因此这**不是**可靠防线，服务端必须做交叉验证（方案 §13-A2）。
        isMock: pos.isMocked,
        // geolocator 的 Position 不暴露 provider 名称，因此这里不下发。
        // 服务端评分表里没有依赖 provider 的条目，所以不影响判定。
        provider: null,
      );
}
