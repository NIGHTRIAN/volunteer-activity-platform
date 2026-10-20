import 'package:http/http.dart' as http;
import 'package:shared_core/shared_core.dart';
import 'package:test/test.dart';

/// 服务器地址的运行时配置。
///
/// ## 背景：用户没有云服务器
///
/// 服务端会跑在他自己的电脑上（局域网 IP），以后也可能租一台换域名。
/// 地址只能运行时决定、而且会变。如果只能通过 `--dart-define` 在打包时写死，
/// 每换一次就要重新出包 —— 真机测试期间已经因此吃过两次亏
/// （IP 从 `10.3.215.117` 变成 `192.168.72.34`，旧包装上去只显示"连不上"）。
///
/// 这组测试锁住两件事：
///   1. 人手动输入的各种写法都能被规范化成可用的 Base URL；
///   2. `ApiClient` 真的会用运行时覆盖值拼请求，而不是仍用编译期配置。
void main() {
  group('normalizeBaseUrl', () {
    test('只写主机和端口 → 自动补 http:// 与 /api', () {
      expect(normalizeBaseUrl('192.168.1.5:8080'), 'http://192.168.1.5:8080/api');
    });

    test('带 http:// 但没 /api → 补齐', () {
      expect(normalizeBaseUrl('http://192.168.1.5:8080'), 'http://192.168.1.5:8080/api');
    });

    test('结尾斜杠被去掉', () {
      expect(normalizeBaseUrl('http://192.168.1.5:8080/'), 'http://192.168.1.5:8080/api');
      expect(normalizeBaseUrl('http://192.168.1.5:8080/api/'), 'http://192.168.1.5:8080/api');
    });

    test('已经带 /api → 原样保留', () {
      expect(normalizeBaseUrl('http://192.168.1.5:8080/api'), 'http://192.168.1.5:8080/api');
      expect(normalizeBaseUrl('https://vol.example.com/api'), 'https://vol.example.com/api');
    });

    test('刻意写的其他前缀不被破坏', () {
      // 只在该补 /api 的时候补；用户写死了别的前缀就尊重他。
      expect(normalizeBaseUrl('https://example.com/svc'), 'https://example.com/svc');
    });

    test('空输入 → null（表示回到编译期默认）', () {
      expect(normalizeBaseUrl(''), isNull);
      expect(normalizeBaseUrl('   '), isNull);
      expect(normalizeBaseUrl(null), isNull);
    });

    test('非法输入 → null（由界面负责提示，不抛异常）', () {
      expect(normalizeBaseUrl('http://'), isNull);
      expect(normalizeBaseUrl('://bad'), isNull);
    });

    test('localhost 与 127.0.0.1 都能识别', () {
      expect(normalizeBaseUrl('127.0.0.1:8080'), 'http://127.0.0.1:8080/api');
      expect(normalizeBaseUrl('localhost:8080'), 'http://localhost:8080/api');
    });
  });

  group('validateBaseUrlInput', () {
    test('合法输入返回 null', () {
      expect(validateBaseUrlInput('192.168.1.5:8080'), isNull);
      expect(validateBaseUrlInput('http://1.2.3.4/api'), isNull);
      expect(validateBaseUrlInput('https://vol.example.com/api'), isNull);
    });

    test('空输入给出可照抄的示例', () {
      final String? err = validateBaseUrlInput('');
      expect(err, isNotNull);
      expect(err, contains('192.168.1.5:8080'));
    });

    test('非 http/https 协议被拒', () {
      expect(validateBaseUrlInput('ftp://1.2.3.4'), '只支持 http 或 https');
    });

    test('主机名含空格被拒', () {
      expect(validateBaseUrlInput('http://my server/api'), isNotNull);
    });
  });

  group('ApiClient 运行时地址覆盖', () {
    test('默认用编译期配置', () {
      final ApiClient c = ApiClient(
        config: const ApiConfig(baseUrl: 'http://10.0.0.1:8080/api'),
      );
      expect(c.effectiveBaseUrl, 'http://10.0.0.1:8080/api');
      expect(c.hasBaseUrlOverride, isFalse);
    });

    test('设置覆盖后 effectiveBaseUrl 立刻生效', () {
      final ApiClient c = ApiClient(
        config: const ApiConfig(baseUrl: 'http://10.0.0.1:8080/api'),
      );
      c.setBaseUrlOverride('192.168.72.34:8080');
      expect(c.effectiveBaseUrl, 'http://192.168.72.34:8080/api');
      expect(c.hasBaseUrlOverride, isTrue);
    });

    test('请求真的打到覆盖后的地址（不是只用 getter 好看）', () async {
      /*
        这条是真正关键的一条：如果只改了 getter 而 `_buildUri` 仍读
        `config.normalizedBaseUrl`，界面上显示的地址会变、请求却打到老地址，
        表现为"设置保存了但还是连不上" —— 最难排查的那种。
      */
      final List<Uri> seen = <Uri>[];
      final ApiClient c = ApiClient(
        config: const ApiConfig(baseUrl: 'http://10.0.0.1:8080/api'),
        httpClient: _RecordingClient(seen),
        waiter: (Duration _) async {},
      );
      c.setBaseUrlOverride('192.168.72.34:8080');

      await c.get<Map<String, Object?>>(
        '/activities',
        decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, Object?>(),
        authorized: false,
      );

      expect(seen, hasLength(1));
      expect(seen.single.host, '192.168.72.34');
      expect(seen.single.port, 8080);
      expect(seen.single.path, '/api/activities');
    });

    test('清除覆盖后回到编译期地址', () {
      final ApiClient c = ApiClient(
        config: const ApiConfig(baseUrl: 'http://10.0.0.1:8080/api'),
      );
      c.setBaseUrlOverride('192.168.72.34:8080');
      c.setBaseUrlOverride(null);
      expect(c.effectiveBaseUrl, 'http://10.0.0.1:8080/api');
      expect(c.hasBaseUrlOverride, isFalse);
    });
  });
}

/// 记录请求 URL 的假 HTTP 客户端，永远返回一个成功的空信封。
class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.seen);

  final List<Uri> seen;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seen.add(request.url);
    final String body =
        '{"code":0,"msg":"成功","data":{},"errors":[],"traceId":"t-test"}';
    return http.StreamedResponse(
      Stream<List<int>>.value(body.codeUnits),
      200,
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );
  }
}
