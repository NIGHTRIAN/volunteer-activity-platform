import 'package:shared_core/shared_core.dart';

/// 定位采集结果。
///
/// 除了坐标本身，还带上**服务端评分需要的辅证**：
/// 精度、是否模拟定位、采样一致性（由调用方用 [samples] 判断）。
/// 方案 §6.1 的评分表用到的量必须一并采集，否则补传时服务端无法重新判定。
class PositionFix {
  const PositionFix({
    required this.point,
    required this.accuracy,
    required this.capturedAt,
    this.altitude,
    this.speed,
    this.isMock = false,
    this.provider,
  });

  /// WGS-84 坐标。**已确认来源坐标系为 WGS-84**（见 [wgs84Confirmed]）。
  final GeoPoint point;

  /// 水平精度（米）。>100m 该证据不计分（方案 §6.1）。
  final double accuracy;

  /// 采集时刻（设备本地时间）。
  final DateTime capturedAt;

  /// 海拔（米）。
  final double? altitude;

  /// 速度（米/秒）。异常速度可触发轨迹异常判定（−40 分）。
  final double? speed;

  /// 是否被系统标记为模拟定位。
  ///
  /// ⚠️ 这只是**一条线索**，不是可靠防线：Android 的
  /// `isFromMockProvider` 可以被绕过，iOS 根本没有等价 API。
  /// 服务端会做交叉验证（坐标/精度/时间戳是否自洽），命中即强制转人工
  /// （方案 §6.1、§13-A2）。客户端**不得**因为"没检测到"就当作可信。
  final bool isMock;

  /// 定位来源：`gps` / `network` / `fused`。
  final String? provider;

  /// 该次采样的坐标系。恒为 WGS-84 —— 由 [LocationService] 保证：
  /// 它是用平台原生定位 API 采集的，没有经过任何地图 SDK 的加密转换。
  GeoCoordSystem get coordinateSystem => GeoCoordSystem.wgs84;

  /// 坐标是否可用于计分（方案 §6.1 的 100m 精度门槛）。
  bool get isAccurateEnough => accuracy > 0 && accuracy <= 100;

  /// 转为契约层的采样模型。
  CheckinSample toSample() => CheckinSample(
        point: point,
        accuracy: accuracy,
        capturedAt: capturedAt,
        altitude: altitude,
        speed: speed,
        isMock: isMock,
        provider: provider,
      );

  @override
  String toString() =>
      'PositionFix($point, ±${accuracy.toStringAsFixed(1)}m'
      '${isMock ? ', 模拟定位!' : ''})';
}

/// 定位权限状态。
///
/// 方案 §7 明确规定：**只申请「使用时」权限，不申请 Always**，
/// 因此这个枚举里**没有** `whileInUse` 之外的后台态。
enum LocationPermissionState {
  /// 尚未询问。
  notDetermined('未询问'),

  /// 用户拒绝。**必须有降级路径，不得出现死路**（方案 §7、验收 A16）。
  denied('已拒绝'),

  /// 已被系统策略禁止（例如家长控制、企业策略）。
  deniedForever('已被系统禁止'),

  /// 定位服务本身被关闭（不是权限问题）。
  serviceDisabled('定位服务已关闭'),

  /// 已授权「使用时」定位。
  granted('已授权');

  const LocationPermissionState(this.label);

  final String label;

  /// 是否可以直接采集。
  bool get canCollect => this == LocationPermissionState.granted;

  /// 是否需要引导用户去系统设置（而不是再次弹窗）。
  bool get needsAppSettings =>
      this == LocationPermissionState.deniedForever ||
      this == LocationPermissionState.serviceDisabled;
}

/// 定位采集失败的原因。
///
/// 拆得这么细是因为**每一种都要给不同的用户指引**：
/// 「权限没给」要去设置页，「服务没开」要去下拉菜单开定位，
/// 「超时」只要重试。统一报「定位失败」等于把用户堵死在那里。
enum LocationFailureReason {
  /// 权限未授予。
  permissionDenied('未获得定位权限'),

  /// 定位服务未开启。
  serviceDisabled('定位服务未开启'),

  /// 超时未取到定位（室内常见的冷启动问题）。
  timeout('定位超时'),

  /// 取到的坐标无效（例如 (0,0)）。
  invalidFix('未能获取有效位置'),

  /// 精度长期不达标。
  poorAccuracy('定位精度不足'),

  /// 其他平台错误。
  unknown('定位失败');

  const LocationFailureReason(this.label);

  final String label;
}

/// 定位采集异常。
class LocationException implements Exception {
  const LocationException(this.reason, {this.detail});

  final LocationFailureReason reason;

  /// 平台返回的原始信息，仅用于日志（会脱敏）。
  final String? detail;

  /// 面向用户的提示。
  ///
  /// **必须给出下一步动作**，而不是只报错。本平台不启用动态签到码
  /// （决策 D-2），因此提示里指向的都是真正可行的路径：
  /// 去系统设置开权限、打开定位服务、换个位置重试，或找发布者现场核实。
  String get userMessage {
    switch (reason) {
      case LocationFailureReason.permissionDenied:
        return '需要定位权限才能签到。你可以到系统设置里打开「位置信息」'
            '（选「仅在使用时允许」），或当面找活动发布者现场核实。';
      case LocationFailureReason.serviceDisabled:
        return '手机的定位服务没有打开。请下拉通知栏打开定位后重试，'
            '或找活动发布者现场核实。';
      case LocationFailureReason.timeout:
        return '暂时无法获取位置，请到空旷处或靠窗的位置再试一次。';
      case LocationFailureReason.invalidFix:
        return '暂时无法获取位置，请稍后重试。';
      case LocationFailureReason.poorAccuracy:
        return '当前位置信号较弱（室内常见），请靠近窗户或到室外重试；'
            '也可以找活动发布者现场核实。';
      case LocationFailureReason.unknown:
        return '定位失败，请稍后重试。';
    }
  }

  @override
  String toString() => 'LocationException(${reason.name}${detail == null ? '' : ': $detail'})';
}

/// 网络连通状态。
enum ConnectivityState {
  /// 有网络（Wi-Fi 或蜂窝）。
  online('已联网'),

  /// 无网络。此时证据应入本地队列（方案 §9）。
  offline('离线');

  const ConnectivityState(this.label);

  final String label;

  /// 是否可联网。
  ///
  /// 提供这个 getter 而不是让调用方写 `== ConnectivityState.online`：
  /// 判断散在界面代码里时，很容易写成 `!= offline`，
  /// 将来一旦增加 `unknown`/`limited` 之类的状态就会静默出错。
  bool get isOnline => this == ConnectivityState.online;

  /// 是否离线。
  bool get isOffline => this == ConnectivityState.offline;
}

/// 设备指纹。
///
/// 用途（方案 §2）：把管理端令牌绑到设备上，把「默认邀请码被谁拿到」
/// 的影响面压到最小；同时用于识别「同设备多账号」（§6.1 的 −30 分）。
///
/// ⚠️ 必须声明这不是硬件级唯一标识：Android 10+ 与 iOS 都限制了长期标识符，
/// 卸载重装或恢复出厂会变化。因此它只能用于"提高门槛"，不能作为身份依据。
class DeviceFingerprint {
  const DeviceFingerprint({
    required this.deviceId,
    required this.platform,
    this.model,
    this.osVersion,
    this.appVersion,
  });

  /// 组装后的设备标识：平台前缀 + 平台标识符。
  ///
  /// 形如 `android-a1b2c3d4e5f6`。**不含任何个人信息**。
  final String deviceId;

  /// `android` / `ios`。
  final String platform;

  /// 设备型号，仅用于排查现场问题。
  final String? model;

  /// 系统版本。
  final String? osVersion;

  /// App 版本。
  final String? appVersion;

  /// 供日志/崩溃上报展示的脱敏形式：只保留平台与后 4 位。
  String get maskedForLog {
    if (deviceId.length <= 4) {
      return '$platform-****';
    }
    return '$platform-****${deviceId.substring(deviceId.length - 4)}';
  }

  @override
  String toString() => 'DeviceFingerprint($maskedForLog)';
}

/// 令牌类型。
enum TokenKind {
  /// 管理端令牌。有效期 = 名下活动存续期（方案 §2）。
  admin('admin_token'),

  /// 志愿者设备令牌 + 活动级授权（方案 §5.2）。
  volunteer('volunteer_token');

  const TokenKind(this.storageKey);

  final String storageKey;
}
