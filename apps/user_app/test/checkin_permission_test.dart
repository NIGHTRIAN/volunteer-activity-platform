import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_platform/shared_platform.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:user_app/checkin_page.dart';

/// 拒绝定位权限时的行为（方案 §7：**不得出现死路**；验收 A16）。
///
/// ## 为什么这一组测试值得单独存在
///
/// "不得出现死路"是一条容易在实现里被漏掉的规则：写代码时很自然地会
/// `if (!permissionGranted) return;` —— 于是权限被拒时界面**什么都不发生**。
/// 用户看到的是"点按钮没反应"，而不是"你需要给权限，或者找发布者"。
///
/// 本平台**不启用动态签到码**（决策 D-2），所以拒权限时没有"扫码"这条退路，
/// 只剩「发布者现场核实 + 人工补录」。**界面必须把这一点说清楚**，
/// 否则志愿者会以为这个 App 根本用不了。
void main() {
  Activity ongoing() {
    final DateTime now = DateTime.now();
    return Activity(
      id: 'act-1',
      externalId: 'ACT-1',
      title: '图书馆书架整理',
      organizer: '校团委',
      durationHours: 3,
      startTime: now.subtract(const Duration(minutes: 10)),
      endTime: now.add(const Duration(hours: 2)),
      location: '南湖校区图书馆三层',
      geoLat: 34.2175,
      geoLng: 117.1425,
      status: ActivityStatus.ongoing,
    );
  }

  /// 可注入的定位服务替身。
  ///
  /// 直接继承而不是做接口：`LocationService` 的方法都是虚的，
  /// 覆盖需要的那几个即可，不必为测试改动生产代码的结构。
  Future<void> pumpPage(
    WidgetTester tester, {
    required LocationService location,
  }) async {
    await tester.pumpWidget(
      AppScope(
        services: _services(location),
        child: MaterialApp(
          theme: AppTheme.build(),
          home: CheckinPage(activity: ongoing()),
        ),
      ),
    );
    await _settle(tester);
  }

  testWidgets('永久拒绝权限 → 给出"找发布者"的出路，而不是死路（验收 A16）',
      (WidgetTester tester) async {
    final _FakeLocation loc = _FakeLocation(
      permission: LocationPermissionState.deniedForever,
    );
    await pumpPage(tester, location: loc);

    await tester.tap(find.text('开始签到'));
    await _settle(tester);

    // ⚠️ 核心断言：必须**指明出路**。
    // 方案 §7「不得出现死路」；验收 A16 要求降级路径可用。
    // 点名"发布者现场核实"而不是笼统的"联系管理员"——
    // 本平台不启用签到码（决策 D-2），这是唯一真正可走的降级路径。
    expect(find.textContaining('发布者现场核实'), findsWidgets,
        reason: '拒权限时必须指向降级路径，否则志愿者会以为 App 用不了');
    // 并且要有"打开系统设置"这个可执行动作。
    expect(find.text('打开系统设置'), findsOneWidget);
  });

  testWidgets('永久拒绝时点「打开系统设置」会调起系统设置页', (WidgetTester tester) async {
    final _FakeLocation loc = _FakeLocation(
      permission: LocationPermissionState.deniedForever,
    );
    await pumpPage(tester, location: loc);

    await tester.tap(find.text('开始签到'));
    await _settle(tester);

    await tester.tap(find.text('打开系统设置'));
    await _settle(tester);

    expect(loc.openedSettings, isTrue, reason: '按钮必须真的跳设置页，不能只是装饰');
  });

  testWidgets('可再次询问的拒绝 → 提供重试，且不宣称失败原因不可解',
      (WidgetTester tester) async {
    final _FakeLocation loc = _FakeLocation(
      permission: LocationPermissionState.denied,
    );
    await pumpPage(tester, location: loc);

    await tester.tap(find.text('开始签到'));
    await _settle(tester);

    expect(find.text('需要定位权限'), findsOneWidget);
    // 临时拒绝时不该给"打开系统设置"——那会引导用户做多余的操作，
    // 而正确的动作是**再点一次**（系统会重新弹授权框）。
    expect(find.text('打开系统设置'), findsNothing);
    // 按钮应回到可点状态（而不是永久卡在"正在采集"）。
    expect(find.text('开始签到'), findsOneWidget);
  });

  testWidgets('定位服务未开启 → 明确说明去系统设置打开定位开关',
      (WidgetTester tester) async {
    final _FakeLocation loc = _FakeLocation(
      permission: LocationPermissionState.granted,
    );
    loc.throwOnSamples = const LocationException(
      LocationFailureReason.serviceDisabled,
      detail: '定位服务未开启',
    );
    await pumpPage(tester, location: loc);

    await tester.tap(find.text('开始签到'));
    await _settle(tester);

    expect(find.text('定位服务未开启'), findsOneWidget);
    expect(find.textContaining('定位'), findsWidgets);
    // 仍可重试（用户去开了开关再回来）。
    expect(find.text('开始签到'), findsOneWidget);
  });

  testWidgets('定位超时 → 提示换位置重试，并指向发布者兜底',
      (WidgetTester tester) async {
    final _FakeLocation loc = _FakeLocation(
      permission: LocationPermissionState.granted,
    );
    loc.throwOnSamples = const LocationException(
      LocationFailureReason.timeout,
      detail: '定位超时',
    );
    await pumpPage(tester, location: loc);

    await tester.tap(find.text('开始签到'));
    await _settle(tester);

    expect(find.text('定位超时'), findsOneWidget);
    expect(find.textContaining('开阔'), findsWidgets, reason: '应给出可执行的下一步');
  });

  testWidgets('未取得有效坐标（0,0）→ 不提交，并请发布者兜底',
      (WidgetTester tester) async {
    // (0,0) 通常表示"没定位到"，而不是"在几内亚湾"。
    // 客户端在这一层粗筛，与服务端 hasFix 同口径。
    final _FakeLocation loc = _FakeLocation(
      permission: LocationPermissionState.granted,
      samples: <PositionFix>[
        PositionFix(
          point: const GeoPoint(lat: 0, lng: 0),
          accuracy: 10,
          capturedAt: DateTime.now(),
        ),
      ],
    );
    await pumpPage(tester, location: loc);

    await tester.tap(find.text('开始签到'));
    await _settle(tester);

    expect(find.text('未取得有效定位'), findsOneWidget);
    expect(find.textContaining('发布者'), findsWidgets);
  });

  testWidgets('采集成功后显示证据（精度与距离），且距离标注"仅供参考"',
      (WidgetTester tester) async {
    final _FakeLocation loc = _FakeLocation(
      permission: LocationPermissionState.granted,
      samples: <PositionFix>[
        PositionFix(
          point: const GeoPoint(lat: 34.21754, lng: 117.14254),
          accuracy: 12,
          capturedAt: DateTime.now(),
        ),
      ],
    );
    await pumpPage(tester, location: loc);

    await tester.tap(find.text('开始签到'));
    // 只 pump 到"已采集"这一步，不等提交完成（提交需要网络）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('已采集的证据'), findsOneWidget);
    expect(find.textContaining('±12 米'), findsOneWidget);
    // ⚠️ 本地距离是**辅助信息**，措辞必须与"服务端判定"区分开。
    expect(find.textContaining('仅供参考'), findsOneWidget);
  });
}

/// 推进若干帧，直到页面进入稳定状态。
///
/// ## 为什么既不用 `pumpAndSettle` 也不只 pump 固定次数
///
/// * **不能用 `pumpAndSettle`**：签到按钮在「采集 / 提交」阶段内含
///   `CircularProgressIndicator`（无限动画），它会一直等到超时。
/// * **只 pump 固定几次也不够**：`_collect()` 是一串 `await`
///   （权限 → 采样 → 辅证 → 提交），每次 await 都要跨一次微任务，
///   少量 pump 会停在中途那一帧（实测停在"正在采集"）。
/// * **不能用 `Future.delayed`**：测试跑在 fake async 区里，
///   墙钟延迟永远不会触发，会直接挂死。
///
/// 因此用 `pump` 显式推进虚拟时间——`tester.pump(duration)` 会同时
/// 推进 fake clock 并冲刷微任务队列，这正是需要的行为。
Future<void> _settle(WidgetTester tester, {int frames = 24}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 32));
  }
}

/// 构造只换掉端能力的 `AppServices`。
///
/// ⚠️ **连通性也必须替身**：`ConnectivityService.wifiBssid()` 会调
/// `network_info_plus` 的平台通道，在 widget 测试里**永不返回**——
/// 实测表现为页面卡在"正在采集定位"，而真实原因是等 Wi-Fi 查询。
/// 这类"假测试挂死"很容易被误判成业务 bug，值得写清楚。
AppServices _services(LocationService location) {
  final ApiClient api = ApiClient(
    config: const ApiConfig(baseUrl: 'http://127.0.0.1:1/api'),
    deviceIdProvider: () async => 'test-device-0001',
  );
  return AppServices(
    api: api,
    tokens: TokenStore(),
    // ⚠️ 设备指纹同样必须替身：`DeviceIdentityService.deviceId()` 会调
    // `device_info_plus` 的平台通道，在 widget 测试里同样不会返回。
    // 这三处（定位 / 连通性 / 设备信息）是签到流程依赖的全部平台能力，
    // 不换掉任何一个，测试都会卡在"正在采集定位"，而看不出真正原因。
    device: _FakeDevice(),
    connectivity: _FakeConnectivity(),
    location: location,
    queue: OfflineQueue(client: api),
    clock: const Clock(),
    serverEndpoint: ServerEndpointStore(fileName: 'test-endpoint.txt'),
    offlineDemo: OfflineDemoStore(stateFileName: 'test-demo.json', flagFileName: 'test-demo.flag'),
    participation: ParticipationStore(fileName: 'test-participation.json'),
    flags: AppFlagStore(),
  );
}

/// 设备指纹替身。
class _FakeDevice extends DeviceIdentityService {
  @override
  Future<String> deviceId() async => 'test-device-0001';

  @override
  Future<DeviceFingerprint> get() async => const DeviceFingerprint(
        deviceId: 'test-device-0001',
        platform: 'android',
      );
}

/// 连通性替身：固定在线、无 Wi-Fi 辅证。
///
/// 返回 `null` 辅证是**合理**的（辅证是加分项，取不到不影响提交），
/// 正好也覆盖了"没有 Wi-Fi 信息也能走完流程"这条路径。
class _FakeConnectivity extends ConnectivityService {
  @override
  Future<ConnectivityState> state() async => ConnectivityState.online;

  @override
  Stream<ConnectivityState> watch() =>
      Stream<ConnectivityState>.value(ConnectivityState.online);

  @override
  Future<String?> wifiBssid() async => null;

  @override
  Future<String?> localIp() async => null;
}

/// 定位服务替身。
class _FakeLocation extends LocationService {
  _FakeLocation({
    required this.permission,
    this.samples = const <PositionFix>[],
  });

  final LocationPermissionState permission;
  final List<PositionFix> samples;

  /// 设了就让 `collectSamples` 抛这个异常。
  LocationException? throwOnSamples;

  /// 是否调用过"打开应用设置页"。
  bool openedSettings = false;

  @override
  Future<LocationPermissionState> ensurePermission() async => permission;

  @override
  Future<List<PositionFix>> collectSamples({
    int count = 3,
    Duration interval = const Duration(seconds: 1),
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final LocationException? e = throwOnSamples;
    if (e != null) {
      throw e;
    }
    return samples;
  }

  @override
  Future<bool> openAppSettings() async {
    openedSettings = true;
    return true;
  }
}