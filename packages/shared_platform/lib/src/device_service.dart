// `prefer_initializing_formals` 在本文件不适用：这里的字段都是**私有**的
// （`_packageInfo` / `_connectivity` / `_deviceIdentity`），而 Dart 不允许
// 具名参数以 `_` 开头，所以只能保留同名的公开参数再显式赋值。
// 这不是可以简化的写法，是语言限制。
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'models.dart';
import 'token_store.dart';

/// 设备指纹服务。
///
/// 用途（方案 §2）：把管理端令牌绑到设备、把「默认邀请码被谁拿到」的影响面
/// 压到最小；也用于识别「同设备多账号」（§6.1 的 −30 分）。
///
/// ## ⚠️ 诚实说明它的强度
///
/// **这不是硬件级唯一标识。**
///   * Android 10+ 起，应用拿不到不可重置的硬件 ID；`androidId` 在恢复出厂后变化，
///     同一用户的不同应用签名拿到的值也不同；
///   * iOS 的 `identifierForVendor` 在**卸载全部同厂商应用后**会重置。
///
/// 所以它能做到的是"提高冒用门槛"，**不能**作为身份依据。方案 §2 把
/// 设备绑定列为**缓解**措施之一，而不是身份认证手段，正是这个原因。
///
/// 组装方式：`<platform>-<平台标识符>`，例如 `android-a1b2c3d4e5f6`。
/// 结果会持久化到安全存储，保证同一安装实例标识稳定。
class DeviceIdentityService {
  DeviceIdentityService({
    DeviceInfoPlugin? deviceInfo,
    PackageInfo? packageInfo,
    TokenStore? tokenStore,
  })  : _deviceInfo = deviceInfo ?? DeviceInfoPlugin(),
        _packageInfo = packageInfo,
        _tokenStore = tokenStore ?? TokenStore();

  final DeviceInfoPlugin _deviceInfo;

  /// 包信息。可注入（测试用），未注入时首次 [get] 时懒加载。
  PackageInfo? _packageInfo;
  final TokenStore _tokenStore;

  DeviceFingerprint? _cached;

  /// 获取设备指纹。结果会缓存，避免每次请求都读一遍平台信息。
  Future<DeviceFingerprint> get() async {
    final DeviceFingerprint? cached = _cached;
    if (cached != null) {
      return cached;
    }

    final PackageInfo pkg = _packageInfo ??= await PackageInfo.fromPlatform();
    final String appVersion = '${pkg.version}+${pkg.buildNumber}';

    late final String platform;
    String? model;
    String? osVersion;
    String? rawId;

    if (Platform.isAndroid) {
      platform = 'android';
      final AndroidDeviceInfo info = await _deviceInfo.androidInfo;
      model = '${info.manufacturer} ${info.model}';
      osVersion = 'Android ${info.version.release} (SDK ${info.version.sdkInt})';
      // androidId：恢复出厂会变，因此只作为"提高门槛"的线索。
      rawId = info.id;
    } else if (Platform.isIOS) {
      platform = 'ios';
      final IosDeviceInfo info = await _deviceInfo.iosInfo;
      model = info.utsname.machine;
      osVersion = '${info.systemName} ${info.systemVersion}';
      rawId = info.identifierForVendor;
    } else {
      // 桌面/Web 只在开发期用到（本机跑 Flutter 调试）。
      platform = Platform.operatingSystem;
      rawId = null;
    }

    // 平台标识符不可用时，退回到一个随机生成并持久化的 UUID。
    // 这样"同一安装实例稳定"这个性质仍然成立。
    final String deviceId;
    if (rawId != null && rawId.isNotEmpty) {
      final String stored = await _tokenStore.readDeviceId() ?? '';
      // 若之前存过且平台标识符变了（恢复出厂），以**旧的为准**：
      // 否则服务端会认为换了设备，触发不必要的重新绑定。
      if (stored.isNotEmpty && stored.startsWith('$platform-')) {
        deviceId = stored;
      } else {
        deviceId = '$platform-${_shortHash(rawId)}';
        await _tokenStore.saveDeviceId(deviceId);
      }
    } else {
      final String stored = await _tokenStore.readDeviceId() ?? '';
      if (stored.isNotEmpty) {
        deviceId = stored;
      } else {
        deviceId = '$platform-${_randomToken()}';
        await _tokenStore.saveDeviceId(deviceId);
      }
    }

    final DeviceFingerprint fp = DeviceFingerprint(
      deviceId: deviceId,
      platform: platform,
      model: model,
      osVersion: osVersion,
      appVersion: appVersion,
    );
    _cached = fp;
    return fp;
  }

  /// 取设备指纹字符串（请求头 `X-Device-Id` 用）。
  Future<String> deviceId() async => (await get()).deviceId;

  /// FNV-1a 32 位散列，8 位十六进制。
  ///
  /// 用散列而不是原值：平台标识符在部分机型上较长，且原值没有任何业务用途；
  /// 散列后固定长度、便于日志展示，也避免把平台原始标识直接发给服务端。
  static String _shortHash(String input) {
    const int fnvOffset = 0x811c9dc5;
    const int fnvPrime = 0x01000193;
    int hash = fnvOffset;
    for (final int unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * fnvPrime) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static String _randomToken() {
    // 不引入 uuid 依赖：用时间戳 + 随机数的组合已足够避免碰撞，
    // 且这个值本身不需要不可预测（它不是凭证，只是区分安装实例）。
    final int ms = DateTime.now().microsecondsSinceEpoch;
    final int rnd = DateTime.now().hashCode ^ identityHashCode(Object());
    return '${ms.toRadixString(16)}${rnd.abs().toRadixString(16)}';
  }
}

/// 网络状态监听。
///
/// 用途（方案 §9）：完全离线时把证据写入本地队列，并在恢复联网后触发补传。
///
/// 同时提供**网络辅证采集**：
///   * Wi-Fi BSSID —— 命中活动场地记 +20；
///   * 本机 IP —— 命中校园网记 +10。
///
/// ⚠️ 这两项在 Android 10+ 需要定位权限才能读到 BSSID（系统把它当位置信息）。
/// 读不到时**返回 null 而不是伪造**：伪造辅证等于帮用户作弊。
class ConnectivityService {
  ConnectivityService({
    Connectivity? connectivity,
    NetworkInfo? networkInfo,
  })  : _connectivity = connectivity ?? Connectivity(),
        _networkInfo = networkInfo ?? NetworkInfo();

  final Connectivity _connectivity;
  final NetworkInfo _networkInfo;
  /// 当前是否在线。
  Future<ConnectivityState> state() async {
    final List<ConnectivityResult> results = await _connectivity.checkConnectivity();
    return _isOnline(results) ? ConnectivityState.online : ConnectivityState.offline;
  }

  /// 在线状态变化流。发出 `true` 表示恢复联网（触发补传的信号）。
  Stream<ConnectivityState> watch() => _connectivity.onConnectivityChanged.map(
        (List<ConnectivityResult> results) =>
            _isOnline(results) ? ConnectivityState.online : ConnectivityState.offline,
      );

  /// 读取当前 Wi-Fi BSSID。失败返回 `null`。
  Future<String?> wifiBssid() async {
    try {
      final String? bssid = await _networkInfo.getWifiBSSID();
      // 部分 ROM 在未授权定位时返回固定的占位值，这些不是真实 BSSID。
      if (bssid == null || bssid.isEmpty) {
        return null;
      }
      const Set<String> placeholders = <String>{
        '02:00:00:00:00:00',
        '00:00:00:00:00:00',
        'ff:ff:ff:ff:ff:ff',
      };
      if (placeholders.contains(bssid.toLowerCase())) {
        return null;
      }
      return bssid;
    } catch (_) {
      return null;
    }
  }

  /// 读取本机 **Wi-Fi** 的 IPv4（用于校园网命中判定）。
  ///
  /// ## 为什么不能直接用 `NetworkInfo.getWifiIP()`
  ///
  /// 真机实测（Redmi Note 12T Pro / HyperOS，Android 15，同时开了 Wi-Fi 与移动数据）：
  ///
  /// ```
  /// ccmni1  10.176.238.211/8     ← 蜂窝
  /// wlan0   10.3.229.13/16       ← Wi-Fi
  /// ```
  ///
  /// 而 `getWifiIP()` 返回的是 **`10.176.238.211`（蜂窝）**，不是 Wi-Fi 地址。
  /// 后果很严重，而且是静默的：
  ///
  /// * 发布者"用当前网络"录到的网段是 `10.176.`，与场地 Wi-Fi 无关；
  /// * 志愿者上报的 `sourceIp` 同样是蜂窝地址，两者"恰好"一致，
  ///   看起来能用 —— 实际上任何一个同运营商网段的校外人员都能命中；
  /// * 一旦有人只开 Wi-Fi 不开数据，他上报的是 `10.3.`，
  ///   就永远命中不了 `10.176.`，于是这个人**每次签到都要人工确认**。
  ///
  /// 这个 bug 单测抓不到（测试机没有双链路），只有真机上两网并存才暴露。
  ///
  /// ## 修法
  ///
  /// 直接按**接口名**取地址：Wi-Fi 在 Android 上是 `wlan0`（热点是 `ap0`/`swlan0`），
  /// 蜂窝是 `ccmni*`/`rmnet*`。按名字选比问插件可靠，且纯 Dart 可测。
  /// 找不到 Wi-Fi 接口时才退回插件（老设备/权限受限场景）。
  Future<String?> localIp() async {
    final String? byInterface = await wifiIpFromInterfaces();
    if (byInterface != null) {
      return byInterface;
    }
    try {
      final String? ip = await _networkInfo.getWifiIP();
      if (ip == null || ip.isEmpty || ip == '0.0.0.0') {
        return null;
      }
      return ip;
    } catch (_) {
      return null;
    }
  }

  /// 从网络接口列表里挑出 Wi-Fi 的 IPv4。
  ///
  /// 抽成静态方法是为了**能单独测试**：接口名过滤规则是这个修复的核心，
  /// 而真机复现需要双链路，不能依赖设备。
  static Future<String?> wifiIpFromInterfaces() async {
    try {
      final List<NetworkInterface> ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      return pickWifiAddress(
        <(String, String)>[
          for (final NetworkInterface i in ifaces)
            for (final InternetAddress a in i.addresses) (i.name, a.address),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  /// 纯函数：从（接口名, 地址）列表里按优先级挑出 Wi-Fi 地址。
  ///
  /// 优先级 `wlan` > `ap`/`swlan` > `eth`；
  /// 明确排除蜂窝（`ccmni`/`rmnet`/`pdp`）、热点虚拟口（`p2p`）、
  /// 以及 `tun`/`ppp`（VPN）。
  ///
  /// 为什么不"取第一个非回环地址"：那就是原 bug 的成因 ——
  /// 列表顺序由系统决定，蜂窝常常排在 Wi-Fi 前面。
  static String? pickWifiAddress(List<(String, String)> interfaces) {
    const List<String> preferred = <String>['wlan', 'swlan', 'ap', 'eth'];
    for (final String prefix in preferred) {
      for (final (String name, String ip) in interfaces) {
        final String n = name.toLowerCase();
        if (!n.startsWith(prefix)) {
          continue;
        }
        // `p2p0`（Wi-Fi Direct）不是上网口，排除。
        if (n.startsWith('p2p')) {
          continue;
        }
        if (_isUsableIpv4(ip)) {
          return ip;
        }
      }
    }
    return null;
  }

  /// 排除回环与链路本地地址。
  static bool _isUsableIpv4(String ip) {
    if (ip.isEmpty || ip == '0.0.0.0') {
      return false;
    }
    if (ip.startsWith('127.') || ip.startsWith('169.254.')) {
      return false;
    }
    return true;
  }

  static bool _isOnline(List<ConnectivityResult> results) =>
      results.any((ConnectivityResult r) => r != ConnectivityResult.none);
}

/// 证据采集器：把「服务端评分需要的所有辅证」一次采齐。
///
/// 单独抽出来是因为**离线补传时也要采齐同一组证据**（方案 §6.4：
/// 「本地队列保存原始证据（位置、精度、时间戳、幂等键、模拟定位检测结果）」）。
/// 如果补传路径少采了某一项，服务端的评分就会与在线路径不一致，
/// 而用户只会看到"同一个动作，两次结果不同"。
class EvidenceCollector {
  const EvidenceCollector({
    required ConnectivityService connectivity,
    required DeviceIdentityService deviceIdentity,
  })  : _connectivity = connectivity,
        _deviceIdentity = deviceIdentity;

  final ConnectivityService _connectivity;
  final DeviceIdentityService _deviceIdentity;

  /// 采集一次完整证据。
  ///
  /// [buildIdempotencyKey] 由调用方提供——**重传必须复用同一个键**
  /// （方案 §9），因此键的生成本身要能被持久化，不能每次现算。
  Future<({String? wifiBssid, String? localIp, String deviceId})> collect() async {
    // 并行采集：这三项互不依赖，串行会白等。
    final List<Object?> results = await Future.wait(<Future<Object?>>[
      _connectivity.wifiBssid(),
      _connectivity.localIp(),
      _deviceIdentity.deviceId(),
    ]);
    return (
      wifiBssid: results[0] as String?,
      localIp: results[1] as String?,
      deviceId: results[2] as String,
    );
  }
}
