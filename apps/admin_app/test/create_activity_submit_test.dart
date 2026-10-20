import 'dart:convert';

import 'package:admin_app/create_activity_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_platform/shared_platform.dart';
import 'package:shared_ui/shared_ui.dart';

/// 提交路径的回归测试。
///
/// ## 这条测试守的是什么
///
/// 真机测试时发现：**活动创建成功了**（服务端查得到），
/// 但界面报「服务端返回成功但缺少数据」并停在表单上。
/// 再点一次发布就会产生**重复活动**（externalId 每次新生成）。
///
/// 根因在 `ApiResponse.fromJson`：
///
/// ```dart
/// data: rawData == null || fromData == null ? null : fromData(rawData),
/// ```
///
/// `fromData`（即调用方传的 `decode`）为 null 时，**data 恒为 null**，
/// 于是 ApiClient 把"成功"当成"成功但没数据"而报错。
/// Dart 没有运行时泛型反射，所以每个要读 data 的调用都必须显式传 decode。
///
/// 这个坑单元测试抓不到（除非真的走一遍网络解析），
/// 而真机上表现为"建成功了却提示失败"—— 非常容易误导。
/// 所以这里用 MockClient 注入真实形状的响应，把修复锁住。
void main() {
  /// 造一个只换 HTTP 层的服务集合。
  AppServices servicesWith(MockClient client) {
    final ApiClient api = ApiClient(
      config: const ApiConfig(baseUrl: 'http://test.invalid/api'),
      deviceIdProvider: () async => 'test-device',
      httpClient: client,
    );
    return AppServices(
      api: api,
      tokens: TokenStore(),
      device: DeviceIdentityService(),
      connectivity: ConnectivityService(),
      location: _FakeLocation(),
      queue: OfflineQueue(client: api),
      clock: const Clock(),
      serverEndpoint: ServerEndpointStore(fileName: 'test-endpoint.txt'),
      offlineDemo: OfflineDemoStore(stateFileName: 'test-demo.json', flagFileName: 'test-demo.flag'),
      participation: ParticipationStore(fileName: 'test-participation.json'),
    flags: AppFlagStore(),
    );
  }

  /// 放大测试视口，让整张表单一次性渲染。
  ///
  /// ⚠️ **必须在 pumpWidget 之前调用**。
  ///
  /// 一开始我是在页面已经渲染后才改视口，结果 ListView 仍然只按
  /// 800×600 布局，屏幕外的输入框根本没被创建 ——
  /// `find.byType(TextField)` 只能拿到前几个，按索引去填后两个
  /// （纬度/经度）就静默越界，导致校验失败、页面不关闭，
  /// 而失败现象看起来像"提交功能坏了"。
  Future<void> enlargeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// 填满必填项，让表单能通过本地校验。
  Future<void> fillForm(WidgetTester tester) async {
    final List<TextField> fields =
        tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.length, greaterThanOrEqualTo(7),
        reason: '视口太小会导致部分输入框未构建，索引填充会静默失效');

    // 顺序（实测）：0 名称、1 部门、2 简介、3 时长、4 地点、
    // 5 纬度、6 经度、7 半径、8 说明、9 联系方式、10 人数
    final Map<int, String> fill = <int, String>{
      0: 'Test Activity',
      2: 'Test summary',
      4: 'Test place',
      5: '34.2181',
      6: '117.1375',
    };
    for (final MapEntry<int, String> e in fill.entries) {
      fields[e.key].controller?.text = e.value;
    }
    await tester.pump();
  }

  testWidgets('服务端成功返回时：页面关闭并带回活动编号（不报「缺少数据」）',
      (WidgetTester tester) async {
    await enlargeViewport(tester);

    /*
      模拟 mock_server 的**真实**响应形状：
        { code: 0, msg: "成功", data: { accepted: 1, created: [...], rejected: [] } }

      关键是 data 非空 —— 如果代码忘了传 decode，
      这里就会走到"服务端返回成功但缺少数据"的失败分支。
    */
    final MockClient client = MockClient((http.Request req) async {
      if (req.url.path.endsWith(':upsert')) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'code': 0,
            'msg': '成功',
            'data': <String, Object?>{
              'accepted': 1,
              'created': <String>['act-1'],
              'updated': <String>[],
              'rejected': <Object?>[],
              'note': '全部受理',
            },
            'errors': <Object?>[],
            'traceId': 't-test',
            'serverTime': '2026-10-17T05:39:56.054Z',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 404);
    });

    String? popped;
    await tester.pumpWidget(
      AppScope(
        services: servicesWith(client),
        child: MaterialApp(
          theme: AppTheme.build(),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    popped = await Navigator.of(context).push<String>(
                      MaterialPageRoute<String>(
                        builder: (_) => const CreateActivityPage(),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await fillForm(tester);

    await tester.tap(find.text('发布活动'));
    // 提交要走真实异步链路，多 pump 几次让它完成。
    for (int i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 成功时页面应已关闭。
    expect(
      find.text('发布活动'),
      findsNothing,
      reason: '创建成功后应关闭页面；停在页面上说明被判成了失败',
    );
    // 并且带回一个活动编号。
    expect(popped, isNotNull, reason: '应把活动编号带回上一页');
    expect(popped!.length, greaterThan(8), reason: '编号不应为空');
  });

  testWidgets('服务端返回 rejected 时：停在页面并显示服务端给的错误',
      (WidgetTester tester) async {
    await enlargeViewport(tester);

    // 部分失败的契约形态：code 仍是 0，但 rejected[] 里有内容。
    // 若只判断 code == 0 就跳走，用户会以为存成功了。
    final MockClient client = MockClient((http.Request req) async {
      if (req.url.path.endsWith(':upsert')) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'code': 0,
            'msg': '成功',
            'data': <String, Object?>{
              'accepted': 0,
              'created': <String>[],
              'updated': <String>[],
              'rejected': <Object?>[
                <String, Object?>{
                  'index': 0,
                  'errors': <Object?>[
                    <String, Object?>{'field': 'title', 'message': '活动名称已存在'},
                  ],
                },
              ],
            },
            'errors': <Object?>[],
            'traceId': 't-test',
            'serverTime': '2026-10-17T05:39:56.054Z',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 404);
    });

    await tester.pumpWidget(
      AppScope(
        services: servicesWith(client),
        child: MaterialApp(
          theme: AppTheme.build(),
          home: const CreateActivityPage(),
        ),
      ),
    );
    await tester.pump();
    await fillForm(tester);

    await tester.tap(find.text('发布活动'));
    for (int i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 应留在页面上，并把服务端的驳回原因显示出来。
    expect(find.text('发布活动'), findsOneWidget, reason: '部分失败时不应离开页面');
    expect(
      find.textContaining('活动名称已存在', skipOffstage: false),
      findsOneWidget,
      reason: '必须显示服务端给出的具体驳回原因',
    );
  });
}

class _FakeLocation extends LocationService {
  @override
  Future<LocationPermissionState> ensurePermission() async =>
      LocationPermissionState.granted;

  @override
  Future<PositionFix> getCurrentFix({
    Duration timeout = const Duration(seconds: 12),
  }) async =>
      PositionFix(
        point: const GeoPoint(lat: 34.2181, lng: 117.1375),
        accuracy: 12,
        capturedAt: DateTime.now(),
      );
}
