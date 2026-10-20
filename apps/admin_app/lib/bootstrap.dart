import 'package:shared_core/shared_core.dart';
import 'package:shared_platform/shared_platform.dart';
import 'package:shared_ui/shared_ui.dart';

/// 启动结果。
class BootstrapResult {
  const BootstrapResult({
    required this.services,
    required this.serverEndpointStore,
    required this.offlineDemoStore,
    required this.flags,
    this.configProblems = const <String>[],
  });

  final AppServices services;

  /// 运行时服务器地址的持久化。启动时用它恢复用户上次设置的地址。
  final ServerEndpointStore serverEndpointStore;

  /// 本机演示模式的开关与数据存储。
  ///
  /// 用户没有云服务器，因此提供"无需服务器也能完整演示"的模式；
  /// 开关与演示数据都要跨启动保留，否则演示时一重启就回到初始状态。
  final OfflineDemoStore offlineDemoStore;

  /// 一次性标记（首次公告只弹一次）。
  final AppFlagStore flags;

  /// 配置自检发现的问题（非致命，但必须在界面上明确告诉开发者）。
  ///
  /// 管理端尤其需要这条：它是"发布者工作台"，如果 Base URL 配错，
  /// 表现是"登录失败"，很容易被误判成邀请码问题而白白排查很久。
  final List<String> configProblems;
}

/// 构建管理端的所有服务。
///
/// 与用户端的差别只有两点：
///   * `tokenProvider` 读的是**管理端会话**（admin session），不是志愿者授权；
///   * 管理端不使用离线补传队列做签到（它没有"签到证据"要补传），
///     但仍保留队列实例，因为"现场点名补录"同样可能在弱网下发生。
BootstrapResult bootstrapAdminApp() {
  final ApiConfig config = ApiConfig.fromEnvironment();
  final TokenStore tokens = TokenStore();
  final DeviceIdentityService device = DeviceIdentityService(tokenStore: tokens);
  final ConnectivityService connectivity = ConnectivityService();
  final LocationService location = LocationService();
  const Clock clock = Clock();

  final ApiClient api = ApiClient(
    config: config,
    deviceIdProvider: device.deviceId,
    tokenProvider: () async {
      // 管理端会话（邀请码登录 + 设备指纹绑定，方案 §5.2）。
      final AdminSession? session = await tokens.readAdminSession();
      return session?.token;
    },
    networkEvidenceProvider: () async {
      final String? bssid = await connectivity.wifiBssid();
      final String? ip = await connectivity.localIp();
      return (wifiBssid: bssid, localIp: ip);
    },
  );

  final OfflineQueue queue = OfflineQueue(client: api);

  /*
    运行时服务器地址。

    用户没有云服务器：服务端跑在他自己电脑上，局域网 IP 会变；
    以后租了服务器又要换域名。地址只能在运行时决定，
    因此必须能在 App 内修改并持久化 —— 见 `ServerEndpointStore`。
    这里只建实例，**恢复动作放在启动流程里**（需要 await，且失败不能白屏）。
  */
  final ServerEndpointStore serverEndpointStore = ServerEndpointStore();
  final OfflineDemoStore offlineDemoStore = OfflineDemoStore();
  final ParticipationStore participation = ParticipationStore();
  final AppFlagStore flags = AppFlagStore();

  final AppServices services = AppServices(
    api: api,
    tokens: tokens,
    device: device,
    connectivity: connectivity,
    location: location,
    queue: queue,
    clock: clock,
    serverEndpoint: serverEndpointStore,
    offlineDemo: offlineDemoStore,
    participation: participation,
    flags: flags,
  );

  return BootstrapResult(
    services: services,
    serverEndpointStore: serverEndpointStore,
    offlineDemoStore: offlineDemoStore,
    flags: flags,
    configProblems: services.selfCheck(),
  );
}
