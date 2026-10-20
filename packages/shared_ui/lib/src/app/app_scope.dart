import 'package:flutter/widgets.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_platform/shared_platform.dart';

/// 应用级服务集合（依赖注入容器）。
///
/// ## 为什么用手写 DI 而不是 get_it / provider
///
/// 本项目要注入的服务是**固定的一小组**（见下），且两端结构相同。
/// 手写一个不可变的容器带来三个好处：
///   * 零外部依赖（方案 §1.3 要求环境可复现）；
///   * 编译期就能发现"忘了注入某个服务"；
///   * 测试里可以整体替换（`AppServices` 是不可变的，构造一份假的即可）。
///
/// 服务生命周期为**整个 App**（在 `main()` 里建一次），
/// 不做页面级注入——它们都是无状态或有自己持久化的。
class AppServices {
  AppServices({
    required this.api,
    required this.tokens,
    required this.device,
    required this.connectivity,
    required this.location,
    required this.queue,
    required this.clock,
    required this.serverEndpoint,
    required this.offlineDemo,
    required this.participation,
    required this.flags,
  });

  /// HTTP 客户端（含令牌注入、重试、时钟偏差监控）。
  final ApiClient api;

  /// 令牌安全存储（Android Keystore / iOS Keychain）。
  final TokenStore tokens;

  /// 设备指纹。
  final DeviceIdentityService device;

  /// 网络状态。
  final ConnectivityService connectivity;

  /// 定位服务（按需单次取点，**不订阅持续定位**）。
  final LocationService location;

  /// 离线证据队列。
  final OfflineQueue queue;

  /// 时钟（便于测试注入固定时间）。
  final Clock clock;

  /// 运行时服务器地址的持久化。
  ///
  /// 用户没有云服务器，服务端跑在他自己电脑上（局域网 IP，会变），
  /// 因此地址必须能在 App 内修改并记住 —— 详见 [ServerEndpointStore]。
  final ServerEndpointStore serverEndpoint;

  /// 本机演示模式的开关与数据存储（没有服务器时的演示通道）。
  final OfflineDemoStore offlineDemo;

  /// 本机参与记录（跨活动保留历史）。
  ///
  /// 用户端一次只绑定一个活动，换活动要重新输邀请码；
  /// 有了这份本机缓存，**切换/解绑都不会丢掉之前参加过的记录**。
  final ParticipationStore participation;

  /// 一次性标记（首次公告等）。
  final AppFlagStore flags;

  /// 校验：开发期的自检，确保接线没漏。
  ///
  /// 之所以要一个显式方法而不是靠断言：`main()` 里调一次，
  /// 问题会在启动时立刻暴露，而不是等到用户点到某个页面才崩。
  List<String> selfCheck() {
    final List<String> problems = <String>[];
    // ⚠️ 用 effectiveBaseUrl 而不是 config.baseUrl：
    // 用户在 App 内改过地址之后，真正生效的是覆盖值。
    // 若这里仍校验编译期值，会出现"设置里明明填对了，启动时却一直报配置问题"。
    final String url = api.effectiveBaseUrl;
    if (url.isEmpty) {
      problems.add('服务器地址未配置');
    }
    if (!url.contains('/api')) {
      // 契约要求 Base URL 含 /api 前缀（网页方案 §6.1）。
      // 少了它所有请求都会 404，而症状会是"接口不存在"这种误导性提示。
      problems.add(
        '服务器地址应以 /api 结尾（当前 $url）；'
        '契约的 Base URL 形如 https://host/api',
      );
    }
    return problems;
  }
}

/// 把 [AppServices] 提供给整棵子树。
///
/// 用法（在 `main()` 里）：
/// ```dart
/// runApp(AppScope(services: services, child: const MyApp()));
/// ```
/// 页面里取：`AppScope.of(context).api`。
class AppScope extends InheritedWidget {
  const AppScope({
    required this.services,
    required super.child,
    super.key,
  });

  final AppServices services;

  /// 取服务。找不到时**抛异常而不是返回 null**：
  /// 忘记包 [AppScope] 是接线错误，应该在开发期立刻炸掉，
  /// 而不是让页面带着 null 一路跑到某个难以定位的地方。
  static AppServices of(BuildContext context) {
    final AppScope? scope =
        context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(
      scope != null,
      'AppScope.of(context) 失败：这棵子树没有被 AppScope 包裹。'
      '请在 main() 用 AppScope(services: ..., child: ...) 包住整个 App。',
    );
    return scope!.services;
  }

  /// 可选取（用于可能在 App 之外渲染的组件，例如测试里的单独组件）。
  static AppServices? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()?.services;

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      !identical(services, oldWidget.services);
}

/// 可注入的时钟。
///
/// 存在的唯一理由是**测试**：倒计时、在岗响应窗口、"N 分钟前"
/// 这些逻辑若直接调 `DateTime.now()`，就只能在测试里靠 `sleep`
/// 或改真实时间，两者都不可靠。
class Clock {
  const Clock();

  /// 当前时间。测试子类可覆盖。
  DateTime now() => DateTime.now();

  /// 当前 UTC 时间。
  DateTime nowUtc() => DateTime.now().toUtc();
}

/// 固定时钟（测试用）。
class FakeClock extends Clock {
  FakeClock(this._now);

  DateTime _now;

  /// 推进时间。
  void advance(Duration d) => _now = _now.add(d);

  /// 设定时间。
  void set(DateTime t) => _now = t;

  @override
  DateTime now() => _now;

  @override
  DateTime nowUtc() => _now.toUtc();
}
