import 'dart:async';

import 'package:shared_core/shared_core.dart';
import 'package:shared_platform/shared_platform.dart';
import 'package:shared_ui/shared_ui.dart';

/// 启动结果。
class BootstrapResult {
  const BootstrapResult({
    required this.services,
    required this.queueStore,
    required this.serverEndpointStore,
    required this.offlineDemoStore,
    required this.flags,
    this.configProblems = const <String>[],
  });

  final AppServices services;

  /// 离线队列的磁盘存储。启动时用它恢复上次没传完的证据。
  final QueueStore queueStore;

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
  /// 典型场景：忘了传 `--dart-define=API_BASE_URL=...`，于是 App 去连
  /// `127.0.0.1`。在真机上那必然是连接失败，而错误提示会指向"网络问题"，
  /// 完全看不出真正原因是构建参数没给。因此把它当作启动期可见的问题。
  final List<String> configProblems;
}

/// 构建用户端的所有服务。
///
/// ## 接线顺序说明
///
/// `ApiClient` 的 `tokenProvider` / `deviceIdProvider` 是**回调**而不是值，
/// 这是刻意的：令牌会变（绑定、过期、重新绑定），设备指纹要在密钥库
/// 就绪后才能读到。如果传值，就必须在启动时把所有异步依赖全部 await 完，
/// 而那正是我们想避免的（见 `main.dart` 里对白屏的说明）。
BootstrapResult bootstrapUserApp() {
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
      // 用户端只用志愿者授权（管理端令牌由 admin_app 管理）。
      final VolunteerGrant? grant = await tokens.readVolunteerGrant();
      return grant?.token;
    },
    // 网络辅证由 ConnectivityService 提供（Wi-Fi BSSID、本机 IP）。
    //
    // ⚠️ 这些值服务端**只用于加分**，不作为判定依据——客户端上报什么
    // 都不能决定签到是否通过（方案 §2 明确判定在服务端）。
    //
    // 而且是惰性的：只有真正发请求时才去读 Wi-Fi 与 IP，
    // 避免每次启动都触发一次系统查询（也少一次权限相关的意外）。
    networkEvidenceProvider: () async {
      final String? bssid = await connectivity.wifiBssid();
      final String? ip = await connectivity.localIp();
      return (wifiBssid: bssid, localIp: ip);
    },
  );

  // ── 离线队列 + 磁盘持久化 ─────────────────────────────────────────
  //
  // ⚠️ 真机测试发现的丢数据：`OfflineQueue` 一直是**纯内存**的 ——
  // `persist()` / `restore()` 存在，但宿主从未调用。
  // 用户离线签到后看到「已保存到本机」，随手划掉 App 就全没了，
  // 而他以为自己已经交上去了。
  //
  // 现在：任何队列变更都异步落盘（`onChanged`），启动时再恢复。
  // 落盘是 fire-and-forget —— 不能因为写文件慢就卡住入队。
  final QueueStore queueStore = QueueStore();
  final OfflineQueue queue = OfflineQueue(client: api);
  queue.onChanged = () {
    unawaited(queueStore.save(queue.persist()));
  };

  // ── 运行时服务器地址 ──────────────────────────────────────────────
  //
  // 用户没有云服务器：服务端跑在他自己电脑上，局域网 IP 会变；
  // 以后租了服务器又要换域名。地址只能在运行时决定，
  // 必须能在 App 内改并记住 —— 见 `ServerEndpointStore`。
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
    queueStore: queueStore,
    serverEndpointStore: serverEndpointStore,
    offlineDemoStore: offlineDemoStore,
    flags: flags,
    configProblems: services.selfCheck(),
  );
}
