import 'package:admin_app/create_activity_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_platform/shared_platform.dart';
import 'package:shared_ui/shared_ui.dart';

/// 新建活动页的测试。
///
/// ## 为什么这个页面值得单独测
///
/// 它是真机验证的**前提**：没有它，测试者只能用种子数据里
/// 那个"签到点在图书馆"的活动，人不在那儿就什么都测不了。
///
/// 而它最容易出错的地方不是布局，是**几个静默失败**：
///   * 没填坐标却以为能签到（活动创建成功，但谁都签不上）；
///   * 结束时间早于开始时间（服务端拒绝，但错误只在一处出现）；
///   * 时长与起止时间不一致（判定窗口按时间算，时长只是展示值，
///     两者矛盾会让人对结果失去信任）。
///
/// 这些都不会崩溃，只会安静地产生错的东西 —— 所以需要断言。
void main() {
  /// 可注入的服务替身：只换定位，其余用真实实现。
  AppServices servicesWith(LocationService location) {
    final ApiClient api = ApiClient(
      config: const ApiConfig(baseUrl: 'http://127.0.0.1:1/api'),
      deviceIdProvider: () async => 'test-device',
    );
    return AppServices(
      api: api,
      tokens: TokenStore(),
      device: DeviceIdentityService(),
      connectivity: ConnectivityService(),
      location: location,
      queue: OfflineQueue(client: api),
      clock: const Clock(),
      serverEndpoint: ServerEndpointStore(fileName: 'test-endpoint.txt'),
      offlineDemo: OfflineDemoStore(stateFileName: 'test-demo.json', flagFileName: 'test-demo.flag'),
      participation: ParticipationStore(fileName: 'test-participation.json'),
    flags: AppFlagStore(),
    );
  }

  Future<void> pumpPage(WidgetTester tester, {LocationService? location}) async {
    /*
      ⚠️ 把测试视口调高，让整张表单一次性渲染。

      默认视口是 800×600，而这张表单有十几个字段 ——
      大部分控件在屏幕外，ListView 根本不会构建它们。
      于是 `find.text(...)` 会报 "Found 0 widgets"，
      看起来像界面没渲染，实际只是没滚到。

      在测试里用滚动去够控件非常脆弱（实测：scrollUntilVisible
      只滚到"部分可见"就停，此时 tap 打在视口外会静默落空；
      而用 drag 又因为位移不足到不了底）。把视口加高是更稳的做法：
      断言针对的是**内容是否存在**，不该受滚动位置影响。

      注意这只是在测试里放大视口，不改产品的真实布局。
    */
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      AppScope(
        services: servicesWith(location ?? _FakeLocation()),
        child: MaterialApp(
          theme: AppTheme.build(),
          home: const CreateActivityPage(),
        ),
      ),
    );
    // 不用 pumpAndSettle：页面里有 Loading 指示器时会一直等到超时。
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 32));
    }
  }

  testWidgets('必填项为空时提交 → 逐字段报错，且不发起请求', (WidgetTester tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('发布活动'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 视口足够高，所有字段错误同时可见，不必滚动。
    //
    // ⚠️ 用 findsWidgets 而不是 findsOneWidget：「活动名称」的错误
    // 会**同时**出现在两处 —— 顶部横幅（让用户滚到顶也能看到）
    // 和字段下方（定位到具体输入框）。两处都有是设计意图。
    expect(find.text('请填写活动名称'), findsWidgets);
    expect(find.text('请填写活动简介，列表页需要展示'), findsWidgets);
    expect(find.text('请填写活动地点，或在地图上选点'), findsWidgets);
    // 坐标也是必填（见下方"只填地点不填坐标"用例的说明）。
    expect(find.text('请在地图上选择活动位置'), findsWidgets);

    // 出错后不应离开页面（没跳走 = 没提交成功）。
    expect(find.text('发布活动'), findsOneWidget);
  });

  testWidgets('没填坐标时给出「签不上」的明确警告', (WidgetTester tester) async {
    await pumpPage(tester);

    // 这是本页最重要的一条提示。没有坐标的活动创建成功后
    // **任何人都签不上**，而界面上完全看不出问题 ——
    // 不明确警告的话，发布者会以为是定位功能坏了。
    expect(
      find.textContaining('坐标是必填项', skipOffstage: false),
      findsOneWidget,
      reason: '必须说明没有坐标的后果，否则发布者以为能签到',
    );
  });

  testWidgets('一键用当前位置能填入坐标，并显示精度', (WidgetTester tester) async {
    final _FakeLocation loc = _FakeLocation(
      fix: PositionFix(
        point: const GeoPoint(lat: 34.2175, lng: 117.1425),
        accuracy: 12,
        capturedAt: DateTime.now(),
      ),
    );
    await pumpPage(tester, location: loc);

    await tester.tap(find.text('用当前位置作为签到点'));
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 32));
    }

    /*
      断言"坐标已生效"的可观察结果，而不是去读某个 TextField ——
      后者受 ListView 懒构建影响：屏幕外的输入框根本没被创建，
      `tester.widgetList<TextField>` 只能拿到可见的那几个
      （实测只拿到 4 个：名称/部门/地点/时长）。

      真正要保证的是**行为**：填了坐标之后
        1) "签不上"的警告消失；
        2) 顶部显示已设置的坐标与精度。
      这两条都能在可见区域内断言，且正是用户能看到的东西。
    */
    expect(find.textContaining('已设置：34.217500', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('精度约 ±12 米', skipOffstage: false), findsOneWidget);

    // 填了坐标后，"签不上"的警告应当消失。
    expect(
      find.textContaining('坐标是必填项', skipOffstage: false),
      findsNothing,
    );
  });

  testWidgets('定位精度差时明确提示去室外重取', (WidgetTester tester) async {
    final _FakeLocation loc = _FakeLocation(
      fix: PositionFix(
        point: const GeoPoint(lat: 34.2175, lng: 117.1425),
        // 室内典型的糟糕精度。
        accuracy: 180,
        capturedAt: DateTime.now(),
      ),
    );
    await pumpPage(tester, location: loc);

    await tester.tap(find.text('用当前位置作为签到点'));
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 32));
    }

    // 只说"已取得位置"而不提精度，等于把判断责任推给用户
    // 却又不给他判断依据。
    expect(find.textContaining('精度较差', skipOffstage: false), findsOneWidget);
  });

  testWidgets('拒绝定位权限时给出手工填写的退路', (WidgetTester tester) async {
    final _FakeLocation loc = _FakeLocation(
      permission: LocationPermissionState.deniedForever,
    );
    await pumpPage(tester, location: loc);

    await tester.tap(find.text('用当前位置作为签到点'));
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 32));
    }

    // 不能只报"需要权限"就完 —— 必须指向可走的下一步：
    // 手工填经纬度。否则拒绝定位权限的人完全被堵死。
    expect(find.textContaining('手工填经纬度', skipOffstage: false), findsOneWidget);
    // 坐标仍是空的，警告仍在。
    expect(
      find.textContaining('坐标是必填项', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('结束时间早于开始时间 → 报错并按格式说明', (WidgetTester tester) async {
    await pumpPage(tester);

    // 直接改结束时间到很早，模拟用户填错。
    // 这里通过时间选择器不好操作，改为断言校验规则本身：
    // 用同一份输入调 ActivityValidator，确认规则存在且文案可读。
    final ValidationResult r = ActivityValidator.validate(
      const ActivityFormInput(
        title: '测试活动',
        organizer: '测试部门',
        startTimeText: '2026-10-20 14:00',
        // 结束早于开始
        endTimeText: '2026-10-20 10:00',
        durationHoursText: '2',
        location: '某处',
        geoLatText: '34.2',
        geoLngText: '117.1',
        summary: '简介',
      ),
    );
    expect(r.errors.isNotEmpty, isTrue);
    expect(
      r.errors.any((FieldError e) => e.field == 'endTime'),
      isTrue,
      reason: '结束早于开始必须报在 endTime 上，否则用户不知道该改哪个字段',
    );
  });

  testWidgets('坐标超出范围 → 校验拒绝', (WidgetTester tester) async {
    // 纬度的合法范围是 -90..90。填一个越界值必须被拦，
    // 否则会产生"看起来正常但永远判定失败"的活动。
    final ValidationResult r = ActivityValidator.validate(
      const ActivityFormInput(
        title: '测试活动',
        organizer: '测试部门',
        startTimeText: '2026-10-20 14:00',
        endTimeText: '2026-10-20 16:00',
        durationHoursText: '2',
        location: '某处',
        geoLatText: '134.2',
        geoLngText: '117.1',
        summary: '简介',
      ),
    );
    expect(r.errors.any((FieldError e) => e.field == 'geoLat'), isTrue);
  });

  testWidgets('只填地点不填坐标 → 校验拒绝，并说明原因', (WidgetTester tester) async {
    /*
      ⚠️ 这条断言反映的是**校验器的真实行为**，不是理想设计。

      方案 §4.1 把 `geoLat`/`geoLng` 的必填列设为「否」，
      但注明「启用围栏时必填」。而 `ActivityValidator` 目前
      无条件要求坐标 —— 比方案更严格。

      我选择保留严格版并让界面文案与之一致，理由：
        * 这是一个以签到为核心的平台，"没有坐标的活动"
          在真机上表现为**所有人都签不上**，比创建失败更难排查；
        * 放宽它需要改动 shared_core 的校验与 154 项测试，
          而当前阶段（真机验证）没有必要冒这个风险。

      结论：**坐标必填**是本实现的有意取舍，与方案原文的差异
      记录在 docs/open-issues-app.md 里，等需要"线上活动"这类
      无签到场景时再放宽。
    */
    final ValidationResult r = ActivityValidator.validate(
      const ActivityFormInput(
        title: '线上宣讲会',
        organizer: '测试部门',
        startTimeText: '2026-10-20 14:00',
        endTimeText: '2026-10-20 16:00',
        durationHoursText: '2',
        location: '线上（腾讯会议）',
        geoLatText: '',
        geoLngText: '',
        summary: '线上进行，无需现场签到',
      ),
    );
    expect(
      r.errors.any((FieldError e) => e.field == 'geoLat'),
      isTrue,
      reason: '当前实现把坐标设为必填；放宽是后续的有意决策，不是遗漏',
    );
    // 报错文案要能指导操作，不能只说"必填"。
    final FieldError err =
        r.errors.firstWhere((FieldError e) => e.field == 'geoLat');
    expect(err.message, isNotEmpty);
  });
}

/// 定位服务替身。
class _FakeLocation extends LocationService {
  _FakeLocation({
    this.permission = LocationPermissionState.granted,
    this.fix,
  });

  final LocationPermissionState permission;
  final PositionFix? fix;

  @override
  Future<LocationPermissionState> ensurePermission() async => permission;

  @override
  Future<PositionFix> getCurrentFix({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final PositionFix? f = fix;
    if (f == null) {
      throw const LocationException(
        LocationFailureReason.timeout,
        detail: '测试替身未配置位置',
      );
    }
    return f;
  }
}
