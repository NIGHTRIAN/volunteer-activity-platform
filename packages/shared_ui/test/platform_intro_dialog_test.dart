import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/shared_ui.dart';

/// 「怎么开始用」引导弹窗。
///
/// ## 这组测试守的是什么
///
/// 真机测试反馈的第一条问题是：**对测试人员的引导没做好**。
/// 具体表现是读完弹窗仍不知道点哪里，尤其
/// "绑定要填哪三样" 和 "演示模式该填什么" 这两步几乎每个人都要问一次。
///
/// 所以这个弹窗的职责变了：从"介绍架构"变成"给可照做的步骤"。
/// 测试也就从"三部分是否讲到"扩成：
///
///   * 有没有**按角色**给出具体步骤；
///   * 有没有点出最容易漏的那一步（建活动要配「用当前网络」）——
///     漏了它志愿者每次签到都会转人工；
///   * 演示模式能不能**一键复制凭据**（`demo-act-library` 抄不了）；
///   * 三部分关系与"判定权在服务器"是否仍然讲清楚 ——
///     这条不能因为改成教程就丢掉，否则验收者会误以为演示数据是真的。
void main() {
  Future<void> pumpDialog(
    WidgetTester tester, {
    required bool isDemo,
    String serverUrl = 'http://192.168.1.5:8080/api',
  }) async {
    tester.view.physicalSize = const Size(1000, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        home: Scaffold(
          body: PlatformIntroDialog(
            isDemoMode: isDemo,
            serverUrl: serverUrl,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('引导：可照做', () {
    testWidgets('标题是「怎么开始用」，不是"关于本平台"', (WidgetTester tester) async {
      await pumpDialog(tester, isDemo: false);
      expect(find.text('怎么开始用'), findsOneWidget);
    });

    testWidgets('按角色给路径：志愿者与发布者都能对号入座', (WidgetTester tester) async {
      await pumpDialog(tester, isDemo: false);
      expect(find.textContaining('你是志愿者'), findsOneWidget);
      expect(find.textContaining('你是发布者'), findsOneWidget);
    });

    testWidgets('志愿者步骤里写明"粘贴邀请信息"（否则还是要手填三样）',
        (WidgetTester tester) async {
      await pumpDialog(tester, isDemo: false);
      expect(find.textContaining('粘贴邀请信息'), findsWidgets);
      expect(find.textContaining('去签到'), findsWidgets);
    });

    testWidgets('发布者步骤里点出最容易漏的一步「用当前网络」', (WidgetTester tester) async {
      await pumpDialog(tester, isDemo: false);
      expect(find.textContaining('用当前网络'), findsWidgets);
      // 并解释后果（不配就会一直转人工）
      expect(find.textContaining('待确认'), findsWidgets);
    });

    testWidgets('提到 Excel 导入与生成邀请码', (WidgetTester tester) async {
      await pumpDialog(tester, isDemo: false);
      expect(find.textContaining('Excel'), findsWidgets);
      expect(find.textContaining('生成邀请码'), findsWidgets);
    });
  });

  group('口径：架构关系不能因为改成教程就丢掉', () {
    testWidgets('三部分都讲到，且写明"判定权在服务器、App 不下结论"',
        (WidgetTester tester) async {
      await pumpDialog(tester, isDemo: false);
      expect(find.textContaining('手机 App'), findsWidgets);
      expect(find.textContaining('网页端'), findsWidgets);
      expect(find.textContaining('服务器'), findsWidgets);
      expect(find.textContaining('判定'), findsWidgets);
      expect(find.textContaining('不自己下结论'), findsWidgets);
    });

    testWidgets('网页端只读这一点要写明', (WidgetTester tester) async {
      await pumpDialog(tester, isDemo: false);
      expect(find.textContaining('只读'), findsOneWidget);
    });
  });

  group('模式识别', () {
    testWidgets('连服务器时显示实际地址（排查"连不上"第一眼要看这个）',
        (WidgetTester tester) async {
      await pumpDialog(
        tester,
        isDemo: false,
        serverUrl: 'http://10.3.215.117:8080/api',
      );
      expect(find.textContaining('http://10.3.215.117:8080/api'), findsOneWidget);
    });

    testWidgets('演示模式必须说明"数据只在这台手机上、不会上传"',
        (WidgetTester tester) async {
      await pumpDialog(tester, isDemo: true);
      expect(find.textContaining('本机演示模式'), findsOneWidget);
      expect(find.textContaining('不会上传'), findsOneWidget);
      expect(find.textContaining('另一台手机'), findsWidgets);
    });

    testWidgets('演示模式提供「复制演示凭据」并真的写入剪贴板',
        (WidgetTester tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await pumpDialog(tester, isDemo: true);
      await tester.tap(find.text('复制演示凭据'));
      await tester.pumpAndSettle();

      expect(copied, isNotNull, reason: '点按钮必须真的写剪贴板');
      // 复制出来的必须是**可被绑定页解析**的整段文本
      expect(copied, contains('活动编号'));
      expect(copied, contains('学号'));
      expect(copied, contains('邀请码'));
    });

    testWidgets('非演示模式不显示「复制演示凭据」（避免误导）',
        (WidgetTester tester) async {
      await pumpDialog(tester, isDemo: false);
      expect(find.text('复制演示凭据'), findsNothing);
    });
  });

  group('交互', () {
    testWidgets('点「知道了」返回勾选状态', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await showDialog<bool>(
                      context: context,
                      builder: (_) => const PlatformIntroDialog(
                        isDemoMode: true,
                        serverUrl: 'http://x/api',
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      expect(result, isTrue, reason: '勾了不再提示应返回 true（宿主据此落标记）');
    });
  });
}
