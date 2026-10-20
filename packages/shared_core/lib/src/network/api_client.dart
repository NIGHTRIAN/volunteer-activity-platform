import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:shared_core/src/contract/api_envelope.dart';
import 'package:shared_core/src/contract/error_codes.dart';
import 'package:shared_core/src/contract/field_dictionary.dart';
import 'package:shared_core/src/contract/time_and_geo.dart';
import 'package:shared_core/src/logging/sanitizer.dart';
import 'package:shared_core/src/network/api_transport.dart';

/// 环境标识。服务端地址来自构建配置，**代码中不得硬编码**（方案 §1.4）。
enum ApiEnvironment {
  /// 开发：本机 Mock。Android 模拟器用 `10.0.2.2` 访问宿主机。
  dev('dev'),

  /// 联调：局域网或内网穿透地址（真机）。
  test('test'),

  /// 生产：租用服务器后填入，**只改配置不改代码**。
  prod('prod');

  const ApiEnvironment(this.wire);

  final String wire;

  static ApiEnvironment fromWire(String? value) {
    for (final ApiEnvironment e in ApiEnvironment.values) {
      if (e.wire == value) {
        return e;
      }
    }
    return ApiEnvironment.dev;
  }
}

/// API 客户端配置。
///
/// 由 `--dart-define` 注入，不落代码：
/// ```
/// flutter run --dart-define=ENV=dev --dart-define=API_BASE_URL=http://10.0.2.2:8080
/// ```
@immutable
class ApiConfig {
  const ApiConfig({
    required this.baseUrl,
    this.environment = ApiEnvironment.dev,
    this.clientVersion = '0.0.0',
    this.apiVersion = ContractDefaults.apiVersion,
    this.timeout = ContractDefaults.requestTimeout,
    this.enableLogging = false,
  });

  /// 从编译期常量读取。
  ///
  /// ⚠️ 默认值是**本机 Mock**，只用于开发。生产环境必须显式传入 `API_BASE_URL`，
  /// 否则 App 会在真机上连自己都连不上——这是刻意的失败方式：
  /// 让它明显连不上，好过悄悄连到一个错的地址。
  ///
  /// 注意默认值**带 `/api` 前缀**（网页方案 §6.1 的 Base URL 约定）。
  factory ApiConfig.fromEnvironment() => ApiConfig(
        baseUrl: const String.fromEnvironment(
          'API_BASE_URL',
          defaultValue: 'http://127.0.0.1:8080/api',
        ),
        environment: ApiEnvironment.fromWire(
          const String.fromEnvironment('ENV', defaultValue: 'dev'),
        ),
        clientVersion: const String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0'),
        enableLogging: const bool.fromEnvironment('API_LOGGING', defaultValue: false),
      );

  /// 服务端根地址，不带结尾斜杠。
  ///
  /// **应包含 `/api` 前缀**（网页方案 §6.1：Base URL 为 `https://{domain}/api`）。
  /// 例如 `http://10.0.2.2:8080/api`。
  final String baseUrl;

  /// 当前环境。
  final ApiEnvironment environment;

  /// 客户端版本，随请求头发送（`X-Client-Version`）。
  final String clientVersion;

  /// 接口版本（`X-Api-Version`）。
  final String apiVersion;

  /// 单次请求超时。
  final Duration timeout;

  /// 是否打印请求日志。
  ///
  /// ⚠️ 即使打开，日志也必须经过 [TelemetrySanitizer] —— 方案 §7 / README §3.3
  /// 底线②要求日志不含完整手机号/学号。
  final bool enableLogging;

  /// 规范化后的基地址（去掉结尾斜杠，避免拼出 `//activities`）。
  String get normalizedBaseUrl =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  /// 当前配置是否指向本机（用于界面提示"你连的是开发环境"）。
  bool get isLocalhost =>
      normalizedBaseUrl.contains('127.0.0.1') || normalizedBaseUrl.contains('localhost');

  @override
  String toString() => 'ApiConfig(${environment.wire}, $normalizedBaseUrl)';
}

/// 把用户输入的服务器地址规范化成可用的 Base URL。
///
/// ## 为什么需要这个函数
///
/// **用户没有服务器。** 他会在自己的电脑上跑一个，或者以后租一台。
/// 地址必然是**运行时**才知道的，而且会变（局域网 DHCP 换个网络就变，
/// 租了服务器又换域名）。如果地址只能在打包时用 `--dart-define` 写死，
/// 那每换一次就要重新出包 —— 真机测试期间已经因此吃过两次亏。
///
/// 所以 App 内必须能改地址。而"人手动输入 URL"必然会出现各种写法，
/// 这里统一收口：
///
/// | 输入 | 输出 |
/// |---|---|
/// | `192.168.1.5:8080` | `http://192.168.1.5:8080/api` |
/// | `http://192.168.1.5:8080` | `http://192.168.1.5:8080/api` |
/// | `http://192.168.1.5:8080/` | `http://192.168.1.5:8080/api` |
/// | `http://1.2.3.4/api/` | `http://1.2.3.4/api` |
/// | `https://vol.example.com/api` | 原样保留 |
/// | `''` / `null` | `null`（表示"回到编译期默认"） |
///
/// 补 `/api` 的依据：本平台的接口约定 Base URL 一律带 `/api` 前缀
/// （网页方案 §6.1）。用户在地址栏里通常只写"主机:端口"。
/// 只有路径为空或就是 `/` 时才补，避免毁掉用户刻意写的别的前缀。
String? normalizeBaseUrl(String? raw) {
  if (raw == null) {
    return null;
  }
  String s = raw.trim();
  if (s.isEmpty) {
    return null;
  }

  // 没写协议就默认 http：局域网的服务器几乎都是 http，
  // 强行要求用户写 `http://` 只会增加出错机会。
  if (!s.contains('://')) {
    s = 'http://$s';
  }

  final Uri? uri = Uri.tryParse(s);
  if (uri == null || uri.host.isEmpty) {
    // 解析不出主机名 → 视为非法输入，交给调用方提示。
    return null;
  }

  // 去掉结尾斜杠，并统一按 `/api` 收口。
  String path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.isEmpty) {
    path = '/api';
  }

  final Uri normalized = Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path,
  );
  return normalized.toString();
}

/// 校验一段用户输入是否是可用的服务器地址。
///
/// 返回 `null` 表示可用；否则返回给用户看的原因。
/// 单独抽出来是为了让设置界面能逐条给出**具体**错在哪，
/// 而不是笼统的"地址格式不正确"。
String? validateBaseUrlInput(String raw) {
  final String s = raw.trim();
  if (s.isEmpty) {
    return '请填写服务器地址，例如 192.168.1.5:8080';
  }
  final String withScheme = s.contains('://') ? s : 'http://$s';
  final Uri? uri = Uri.tryParse(withScheme);
  if (uri == null || uri.host.isEmpty) {
    return '地址格式不对。示例：192.168.1.5:8080';
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return '只支持 http 或 https';
  }
  // Dart 的 Uri.parse 很宽容，'http://my server/api' 这种也能解析出 host，
  // 于是会把一个必然连不上的地址放过去。这里按主机名允许的字符做白名单校验。
  // 允许：字母/数字/点/连字符/下划线（内网机器名常见）/IPv6 的方括号与冒号。
  if (!RegExp(r'^[A-Za-z0-9._\-\[\]:]+$').hasMatch(uri.host)) {
    return '主机名里有不合法字符。示例：192.168.1.5:8080';
  }
  return null;
}

/// 请求方法。
enum HttpMethod { get, post, patch, put, delete }

/// 一次 API 调用的结果。
///
/// 用 `sealed` 而不是抛异常：方案 §9 列出的每一种失败（离线、超时、5xx、
/// 401/403、409、429）都有**不同的界面表现**，调用方必须逐个处理，
/// 编译器帮忙强制这件事。
@immutable
sealed class ApiResult<T> {
  const ApiResult();

  /// 是否成功。
  bool get isSuccess => this is ApiSuccess<T>;

  /// 成功时的数据；失败时为 `null`。
  T? get dataOrNull => switch (this) {
        ApiSuccess<T>(:final T value) => value,
        ApiFailure<T>() => null,
      };

  /// 失败时的错误；成功时为 `null`。
  ApiFailure<T>? get failureOrNull => switch (this) {
        ApiSuccess<T>() => null,
        final ApiFailure<T> f => f,
      };

  /// 成功则返回数据，否则返回兜底值。
  T dataOr(T fallback) => dataOrNull ?? fallback;
}

/// 调用成功。
final class ApiSuccess<T> extends ApiResult<T> {
  const ApiSuccess(this.value, {this.serverTime, this.traceId});

  final T value;

  /// 服务端时间，用于校正倒计时（方案 §6.3、§9）。
  final DateTime? serverTime;

  /// 追踪号，便于把用户截图与后端日志对上。
  final String? traceId;
}

/// 调用失败。
final class ApiFailure<T> extends ApiResult<T> {
  const ApiFailure({
    required this.code,
    required this.message,
    this.fieldErrors = const <FieldError>[],
    this.httpStatus,
    this.traceId,
    this.isOffline = false,
    this.isTimeout = false,
    this.retryable = false,
  });

  /// 平台错误码。
  final ApiErrorCode code;

  /// 面向用户的提示。
  final String message;

  /// 字段级错误，供表单定位（方案 §8）。
  final List<FieldError> fieldErrors;

  /// HTTP 状态码（若拿到了响应）。
  final int? httpStatus;

  /// 追踪号。
  final String? traceId;

  /// 是否因为离线而失败（方案 §9：此时应入本地队列）。
  final bool isOffline;

  /// 是否超时（已用尽退避重试）。
  final bool isTimeout;

  /// 是否值得重试。
  final bool retryable;

  /// 数值错误码（便于日志与契约核对）。
  int get rawCode => code.value;

  /// 是否需要清理令牌并跳转登录/绑定（方案 §9 的 401/403 口径）。
  bool get shouldClearToken => code.shouldClearToken;

  /// 是否应提示"稍后重试"。
  bool get isRateLimited => code == ApiErrorCode.tooManyRequests;

  /// 是否状态冲突（方案 §9：刷新活动状态并提示"状态已更新，请重试"）。
  bool get isConflict => code == ApiErrorCode.versionConflict;

  /// 指定字段的错误文案。
  String? errorFor(String field) {
    for (final FieldError e in fieldErrors) {
      if (e.field == field) {
        return e.message;
      }
    }
    return null;
  }

  /// 转为可展示的异常（在 UI 层统一 throw 时使用）。
  ApiException toException() => ApiException(
        code: code,
        message: message,
        fieldErrors: fieldErrors,
        traceId: traceId,
      );
}

/// 供 UI 层使用的异常包装。
///
/// 只在"确实无法继续"时才抛（例如表单提交失败要中断流程）；
/// 能用 [ApiResult] 表达的一律不抛。
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.fieldErrors = const <FieldError>[],
    this.traceId,
  });

  final ApiErrorCode code;
  final String message;
  final List<FieldError> fieldErrors;
  final String? traceId;

  @override
  String toString() => 'ApiException(${code.name}: $message)';
}

/// 令牌提供者。由 App 注入（管理端令牌 / 志愿者令牌）。
typedef TokenProvider = Future<String?> Function();

/// 设备标识提供者。
typedef DeviceIdProvider = Future<String?> Function();

/// 退避等待器。测试时可注入零延迟版本。
typedef BackoffWaiter = Future<void> Function(Duration);

/// 幂等键生成器。
typedef IdempotencyKeyFactory = String Function();

/// 平台信息（本机 IP / BSSID），用于校园网辅证。
typedef NetworkEvidenceProvider = Future<({String? wifiBssid, String? localIp})> Function();

/// 轻量 JSON HTTP 客户端。
///
/// 设计要点，逐条对应方案 §9「弱网与异常」：
///
/// | 场景 | 处理 |
/// |---|---|
/// | 完全离线 | 返回 `isOffline: true`，调用方把证据入本地队列 |
/// | 上报超时 | 复用**同一幂等键**，指数退避 1s/2s/4s/8s/16s，上限 5 次 |
/// | 服务端 5xx | 提示服务不可用，**不丢弃本地数据** |
/// | 401/403 | `shouldClearToken` 为真，调用方清理令牌并跳转 |
/// | 409 | `isConflict` 为真，调用方刷新后重试 |
/// | 429 | `isRateLimited` 为真 |
/// | 设备时间不准 | 每个响应都带回 `serverTime`，由 [ClockSkewMonitor] 比对 |
///
/// 另外：
///   * 统一注入令牌、幂等键、设备标识、接口版本头；
///   * **日志一律脱敏**（[TelemetrySanitizer]），令牌只出前 4 位。
class ApiClient {
  ApiClient({
    required this.config,
    http.Client? httpClient,
    this.tokenProvider,
    this.deviceIdProvider,
    this.networkEvidenceProvider,
    BackoffWaiter? waiter,
    IdempotencyKeyFactory? idempotencyKeyFactory,
    this.transport,
  })  : _http = httpClient ?? http.Client(),
        _wait = waiter ?? _defaultWait,
        _newIdempotencyKey = idempotencyKeyFactory ?? _defaultIdempotencyKey;

  /// 配置。
  final ApiConfig config;

  /// 运行时覆盖的服务端地址。`null` 表示用 [config] 里的编译期地址。
  ///
  /// ## 为什么要有这个（用户没有服务器）
  ///
  /// 服务端地址原本只能由 `--dart-define=API_BASE_URL=...` 在**打包时**写死。
  /// 但用户的现实是：
  ///
  ///   * 没有云服务器 —— 服务端跑在自己电脑上，地址是局域网 IP；
  ///   * 局域网 IP 会变（换网络、路由器重新分配）；
  ///   * 以后租了服务器，地址又要换一次。
  ///
  /// 如果每次都要重新出包，那 App 就是不可用的 ——
  /// 真机测试期间 IP 从 `10.3.215.117` 变成 `192.168.72.34`，
  /// 打好的包装上去只会显示"连不上服务器"，普通用户根本无从判断。
  ///
  /// 所以地址必须能在 App 内改、并且能持久化。这里存运行时覆盖值，
  /// 由 `ServerEndpointStore` 负责落盘、由启动流程注入。
  String? _baseUrlOverride;

  /// 当前**实际生效**的基地址（不含结尾斜杠）。
  ///
  /// 界面要显示"我现在连的是哪个服务器"，应该读这个而不是 [config]。
  String get effectiveBaseUrl => _baseUrlOverride ?? config.normalizedBaseUrl;

  /// 是否正在使用运行时覆盖的地址（而不是编译期默认）。
  bool get hasBaseUrlOverride => _baseUrlOverride != null;

  /// 设置运行时地址覆盖。
  ///
  /// [rawUrl] 会先经 [normalizeBaseUrl] 规范化；传 `null` 或空串表示
  /// **清除覆盖**、回到编译期地址。
  ///
  /// ⚠️ 必须在没有在途请求时调用 —— 换地址后旧请求仍会打到旧服务器。
  /// 设置界面保存前会先让用户确认，正常情况下不会撞上。
  void setBaseUrlOverride(String? rawUrl) {
    _baseUrlOverride = normalizeBaseUrl(rawUrl);
  }

  final http.Client _http;

  /// 报文层。为 `null` 时走真实 HTTP；否则交给它（本机演示引擎）。
  ///
  /// 这是离线模式与真服务器**唯一的**分界点 —— 详见 [ApiTransport]。
  /// 它之上的重试、幂等、令牌注入、信封解析、错误码归一全部共用一份代码，
  /// 所以"离线验过的界面"与"接上服务器的界面"行为不会分叉。
  ///
  /// **可变**：演示模式与否要到启动时读本地设置才知道，而 `ApiClient`
  /// 在 `bootstrap()`（同步）里就建好了。做成可变就不用把整条装配链改成异步。
  ApiTransport? transport;

  final BackoffWaiter _wait;
  final IdempotencyKeyFactory _newIdempotencyKey;

  /// 取当前令牌。
  TokenProvider? tokenProvider;

  /// 取设备标识。
  DeviceIdProvider? deviceIdProvider;

  /// 取网络辅证（Wi-Fi BSSID / 本机 IP），用于签到评分。
  NetworkEvidenceProvider? networkEvidenceProvider;

  /// 最近一次拿到的服务端时间，供 [ClockSkewMonitor] 使用。
  DateTime? lastServerTime;

  /// 释放底层连接。
  void dispose() => _http.close();

  /// 发送请求。
  ///
  /// [idempotencyKey] 若提供，会随请求头发送并在**重试时复用**——
  /// 这是"重传不产生重复记录"的唯一保障（方案 §9、验收 A23）。
  /// **调用方必须在重试之间复用同一个键**，所以不要把键的生成本身放进重试循环。
  Future<ApiResult<T>> send<T>({
    required HttpMethod method,
    required String path,
    Map<String, String>? query,
    Object? body,
    T Function(Object? data)? decode,
    String? idempotencyKey,
    bool retryable = true,
    bool authorized = true,
    bool includeNetworkEvidence = false,
  }) async {
    final Uri uri = _buildUri(path, query);
    final int maxAttempts = retryable ? ContractDefaults.retryBackoff.length + 1 : 1;

    ApiFailure<T>? lastFailure;

    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        // 指数退避。索引 attempt-1 对应第一次重试前的等待。
        await _wait(ContractDefaults.retryBackoff[attempt - 1]);
      }

      final _AttemptOutcome<T> outcome = await _attempt<T>(
        method: method,
        uri: uri,
        body: body,
        decode: decode,
        idempotencyKey: idempotencyKey,
        authorized: authorized,
        includeNetworkEvidence: includeNetworkEvidence,
      );

      switch (outcome) {
        case _AttemptSuccess<T>(:final ApiSuccess<T> result):
          return result;
        case _AttemptFailure<T>(:final ApiFailure<T> failure):
          lastFailure = failure;
          // 不可重试的错误立即返回：
          //   * 业务性失败（参数错、越权、状态冲突）重试多少次都一样；
          //   * 只有网络类问题与 5xx 值得重试。
          if (!failure.retryable || !retryable) {
            return failure;
          }
      }
    }

    // 重试用尽。把最后一次的失败标记为"已重试过"，便于界面区分
    // "刚失败"和"重试了好几遍还是失败"。
    final ApiFailure<T> f = lastFailure!;
    return ApiFailure<T>(
      code: f.code,
      message: f.message,
      fieldErrors: f.fieldErrors,
      httpStatus: f.httpStatus,
      traceId: f.traceId,
      isOffline: f.isOffline,
      isTimeout: f.isTimeout,
      retryable: false,
    );
  }

  /// 便捷方法。
  Future<ApiResult<T>> get<T>(
    String path, {
    Map<String, String>? query,
    T Function(Object? data)? decode,
    bool authorized = true,
    // 查询默认可以安全重试（幂等）。但"测试连通性"这类场景需要一次定论：
    // 地址写错时让用户干等 5 轮退避（约 31 秒）才报错，体验很差。
    bool retryable = true,
  }) =>
      send<T>(
        method: HttpMethod.get,
        path: path,
        query: query,
        decode: decode,
        authorized: authorized,
        retryable: retryable,
      );

  Future<ApiResult<T>> post<T>(
    String path, {
    Object? body,
    T Function(Object? data)? decode,
    String? idempotencyKey,
    bool authorized = true,
    bool retryable = true,
    bool includeNetworkEvidence = false,
  }) =>
      send<T>(
        method: HttpMethod.post,
        path: path,
        body: body,
        decode: decode,
        idempotencyKey: idempotencyKey,
        authorized: authorized,
        retryable: retryable,
        includeNetworkEvidence: includeNetworkEvidence,
      );

  Future<ApiResult<T>> patch<T>(
    String path, {
    Object? body,
    T Function(Object? data)? decode,
    bool authorized = true,
  }) =>
      send<T>(
        method: HttpMethod.patch,
        path: path,
        body: body,
        decode: decode,
        authorized: authorized,
      );

  Future<ApiResult<T>> delete<T>(
    String path, {
    Map<String, String>? query,
    T Function(Object? data)? decode,
    bool authorized = true,
  }) =>
      send<T>(
        method: HttpMethod.delete,
        path: path,
        query: query,
        decode: decode,
        authorized: authorized,
      );

  /// 生成并返回一个新幂等键。调用方应在**入队时**生成一次并持久化，
  /// 重传时复用，而不是每次请求现算。
  String newIdempotencyKey() => _newIdempotencyKey();

  // ── 内部实现 ──────────────────────────────────────────────────────────

  Future<_AttemptOutcome<T>> _attempt<T>({
    required HttpMethod method,
    required Uri uri,
    required Object? body,
    required T Function(Object? data)? decode,
    required String? idempotencyKey,
    required bool authorized,
    required bool includeNetworkEvidence,
  }) async {
    try {
      final Map<String, String> headers = await _buildHeaders(
        authorized: authorized,
        idempotencyKey: idempotencyKey,
        hasBody: body != null,
      );

      // 签到类请求需要带上网络辅证（+20 / +10 分），在请求前采集。
      Object? payload = body;
      if (includeNetworkEvidence) {
        final ({String? wifiBssid, String? localIp})? evidence =
            await networkEvidenceProvider?.call();
        if (evidence != null && body is Map<String, Object?>) {
          payload = <String, Object?>{
            ...body,
            if (evidence.wifiBssid != null) 'wifiBssid': evidence.wifiBssid,
            if (evidence.localIp != null) 'localIp': evidence.localIp,
          };
        }
      }

      _logRequest(method, uri, headers, payload);

      final http.Response response = await _dispatch(method, uri, headers, payload);
      return _interpret<T>(response, decode);
    } on TimeoutException {
      return _AttemptFailure<T>(
        ApiFailure<T>(
          code: ApiErrorCode.networkTimeout,
          message: ApiErrorCode.networkTimeout.defaultMessage,
          isTimeout: true,
          retryable: true,
        ),
      );
    } catch (e) {
      // 连接类异常（DNS 失败、连接被拒、无网络）都归为"离线"，
      // 因为对用户来说下一步动作是一样的：证据入队，等联网后补传。
      return _AttemptFailure<T>(
        ApiFailure<T>(
          code: ApiErrorCode.offlineQueued,
          message: ApiErrorCode.offlineQueued.defaultMessage,
          isOffline: true,
          retryable: true,
        ),
      );
    }
  }

  Future<http.Response> _dispatch(
    HttpMethod method,
    Uri uri,
    Map<String, String> headers,
    Object? payload,
  ) async {
    final ApiTransport? transport = this.transport;

    /*
      ── 报文层分叉点（离线模式的全部秘密就在这里）──────────────────

      有 `_transport` 就把请求交给它（本机演示引擎），否则走真实 HTTP。

      关键设计：即使走本机引擎，也**包装成一个 http.Response** 再返回，
      让上面那条 `_interpret` 通道完全不变。于是：

        * 信封解析、`decode`、错误码归一、traceId、serverTime
          —— 两种来源共用同一份代码；
        * 不会出现"离线模式里 401 表现和真服务器不一样"这种分叉 bug。

      代价是每次本机请求多一次 JSON 编码/解码。本机请求量很小，
      换来的是"只有一条解释路径"，很划算。
    */
    if (transport != null) {
      // 把完整 URL 还原成接口相对路径（`/activities/xxx`），
      // 这样本机引擎的路由表可以和真实服务端的路径一一对应。
      final Uri baseUri = Uri.parse(effectiveBaseUrl);
      final String relativePath = uri.path.startsWith(baseUri.path)
          ? uri.path.substring(baseUri.path.length)
          : uri.path;
      final TransportResponse r = await transport.send(
        method: method.name.toUpperCase(),
        path: relativePath.isEmpty ? '/' : relativePath,
        query: uri.queryParameters.isEmpty ? null : uri.queryParameters,
        headers: headers,
        body: payload,
      );
      return http.Response(
        r.body,
        r.statusCode,
        headers: const <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );
    }

    final String? encoded = payload == null ? null : jsonEncode(payload);
    final Duration timeout = config.timeout;

    switch (method) {
      case HttpMethod.get:
        return _http.get(uri, headers: headers).timeout(timeout);
      case HttpMethod.post:
        return _http.post(uri, headers: headers, body: encoded).timeout(timeout);
      case HttpMethod.patch:
        return _http.patch(uri, headers: headers, body: encoded).timeout(timeout);
      case HttpMethod.put:
        return _http.put(uri, headers: headers, body: encoded).timeout(timeout);
      case HttpMethod.delete:
        return _http.delete(uri, headers: headers, body: encoded).timeout(timeout);
    }
  }

  _AttemptOutcome<T> _interpret<T>(http.Response response, T Function(Object? data)? decode) {
    Map<String, dynamic> json;
    try {
      final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('响应不是 JSON 对象');
      }
      json = decoded;
    } catch (_) {
      // 响应体不可解析：退回按 HTTP 状态码判断。
      // 这一分支在 **Mock 没启动但端口被别的服务占用** 时会走到，
      // 所以提示要说"服务暂时不可用"而不是"数据错误"。
      final ApiErrorCode code = response.statusCode >= 500
          ? ApiErrorCode.serverError
          : mapHttpStatusToErrorCode(response.statusCode);
      return _AttemptFailure<T>(
        ApiFailure<T>(
          code: code,
          message: code.defaultMessage,
          httpStatus: response.statusCode,
          retryable: response.statusCode >= 500,
        ),
      );
    }

    // 服务端时间是倒计时基准（方案 §6.3），每次都刷新。
    final DateTime? serverTime = TimeFormat.tryParse(json['serverTime']);
    if (serverTime != null) {
      lastServerTime = serverTime;
    }

    final ApiResponse<T> envelope = ApiResponse<T>.fromJson(
      json,
      decode,
      fallbackStatusCode: response.statusCode,
    );

    if (envelope.isSuccess) {
      if (envelope.data == null) {
        // 成功但没有数据：对 `T` 非空的情况来说这是契约违约。
        // 明确报出来，好过让界面拿到一个"看起来成功但没内容"的结果。
        return _AttemptFailure<T>(
          ApiFailure<T>(
            code: ApiErrorCode.unknown,
            message: '服务端返回成功但缺少数据',
            httpStatus: response.statusCode,
            traceId: envelope.traceId,
          ),
        );
      }
      return _AttemptSuccess<T>(
        ApiSuccess<T>(envelope.data as T, serverTime: serverTime, traceId: envelope.traceId),
      );
    }

    return _AttemptFailure<T>(
      ApiFailure<T>(
        code: envelope.errorCode,
        message: envelope.message,
        fieldErrors: envelope.fieldErrors,
        httpStatus: response.statusCode,
        traceId: envelope.traceId,
        // 5xx 值得重试；其余业务性失败重试无意义。
        retryable: response.statusCode >= 500,
      ),
    );
  }

  Future<Map<String, String>> _buildHeaders({
    required bool authorized,
    required String? idempotencyKey,
    required bool hasBody,
  }) async {
    final Map<String, String> headers = <String, String>{
      'Accept': 'application/json',
      // 方案 §1.4 预留的版本协商头。
      HeaderFields.apiVersion: config.apiVersion,
      HeaderFields.clientVersion: config.clientVersion,
    };
    if (hasBody) {
      headers['Content-Type'] = 'application/json; charset=utf-8';
    }
    if (idempotencyKey != null) {
      headers[HeaderFields.idempotencyKey] = idempotencyKey;
    }

    final String? deviceId = await deviceIdProvider?.call();
    if (deviceId != null && deviceId.isNotEmpty) {
      headers[HeaderFields.deviceId] = deviceId;
    }

    if (authorized) {
      final String? token = await tokenProvider?.call();
      if (token != null && token.isNotEmpty) {
        headers[HeaderFields.authorization] = 'Bearer $token';
      }
    }
    return headers;
  }

  Uri _buildUri(String path, Map<String, String>? query) {
    final String p = path.startsWith('/') ? path : '/$path';
    // 用 effectiveBaseUrl：运行时覆盖优先，否则用编译期配置。
    final Uri base = Uri.parse('$effectiveBaseUrl$p');
    if (query == null || query.isEmpty) {
      return base;
    }
    return base.replace(queryParameters: <String, String>{
      ...base.queryParameters,
      ...query,
    });
  }

  void _logRequest(
    HttpMethod method,
    Uri uri,
    Map<String, String> headers,
    Object? payload,
  ) {
    if (!config.enableLogging) {
      return;
    }
    // ⚠️ 令牌只出前 4 位；请求体可能含学号/手机号，整体走文本脱敏。
    final Map<String, String> safeHeaders = <String, String>{
      ...headers,
      if (headers.containsKey(HeaderFields.authorization))
        HeaderFields.authorization:
            'Bearer ${TelemetrySanitizer.maskToken(headers[HeaderFields.authorization]!.replaceFirst('Bearer ', ''))}',
    };
    // ignore: avoid_print
    print(
      '[api] ${method.name.toUpperCase()} $uri\n'
      '      头: $safeHeaders\n'
      '      体: ${payload == null ? '(空)' : TelemetrySanitizer.sanitizeText(jsonEncode(payload))}',
    );
  }

  static Future<void> _defaultWait(Duration d) => Future<void>.delayed(d);

  /// 默认幂等键：时间戳 + 随机数。
  ///
  /// 不追求不可预测（它不是凭证），只要求**在重试之间稳定**——
  /// 稳定性由调用方负责持久化实现。
  static String _defaultIdempotencyKey() {
    final int ms = DateTime.now().microsecondsSinceEpoch;
    final int rnd = DateTime.now().hashCode;
    return 'k${ms.toRadixString(36)}${rnd.abs().toRadixString(36)}';
  }
}

/// 一次尝试的结果（内部使用）。
sealed class _AttemptOutcome<T> {
  const _AttemptOutcome();
}

final class _AttemptSuccess<T> extends _AttemptOutcome<T> {
  const _AttemptSuccess(this.result);
  final ApiSuccess<T> result;
}

final class _AttemptFailure<T> extends _AttemptOutcome<T> {
  const _AttemptFailure(this.failure);
  final ApiFailure<T> failure;
}

/// 时钟偏差监控。
///
/// ## 为什么需要
///
/// 签到窗口与在岗响应窗口都是**时间敏感**的：窗口未开或已关时，
/// 服务端会直接拒绝。如果手机时间偏了 5 分钟，用户会看到
/// "明明到点了却签不上"——现场极难排查，而且会被归咎于"系统不准"。
///
/// 因此客户端持续观测服务端时间，并用它校正倒计时；
/// 偏差过大时明确提示用户校准系统时间。
///
/// ⚠️ 客户端校正**只影响界面倒计时**，不影响判定：
/// 服务端一律以自己的时间为准（方案 §2、§9）。
class ClockSkewMonitor {
  ClockSkewMonitor({this.maxSkew = ContractDefaults.maxClockSkew});

  /// 允许的最大偏差。超过就提示用户校准。
  final Duration maxSkew;

  Duration? _skew;

  /// 当前偏差（设备时间 − 服务端时间）。未观测到服务端时间时为 `null`。
  Duration? get skew => _skew;

  /// 是否偏差过大，需要提示用户校准。
  bool get isSkewed {
    final Duration? s = _skew;
    return s != null && s.abs() > maxSkew;
  }

  /// 用一次响应的服务端时间更新偏差估计。
  ///
  /// 取**历史最小值**而不是最新值：网络往返会给 `now - serverTime` 引入
  /// 一个正向的延迟量，因此观测到的最小偏差最接近真实偏差。
  void observe(DateTime serverTime, {DateTime? deviceNow}) {
    final DateTime now = deviceNow ?? DateTime.now();
    final Duration sample = now.difference(serverTime);
    final Duration? current = _skew;
    _skew = current == null
        ? sample
        : (sample.abs() < current.abs() ? sample : current);
  }

  /// 按偏差校正后的时间，用于签到码倒计时。
  DateTime correctedNow({DateTime? deviceNow}) {
    final DateTime now = deviceNow ?? DateTime.now();
    final Duration? s = _skew;
    return s == null ? now : now.subtract(s);
  }

  /// 面向用户的提示；无偏差时返回 `null`。
  String? get userHint {
    if (!isSkewed) {
      return null;
    }
    final int minutes = _skew!.inMinutes;
    final String direction = minutes > 0 ? '快' : '慢';
    return '本机时间比服务器$direction约 ${minutes.abs()} 分钟，'
        '可能影响签到码与在岗确认的倒计时，建议在系统设置中开启「自动设置时间」。';
  }

  void reset() => _skew = null;
}
