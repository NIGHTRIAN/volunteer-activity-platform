/// 一次接口往返的报文层抽象。
///
/// ## 为什么在这一层做接缝
///
/// 用户**没有服务器**，但必须能给别人验收 App。于是需要一个"没有服务端
/// 也能跑通全部流程"的离线模式；同时**必须完整保留接未来服务器的能力**。
///
/// 如果把离线模式做成"另一个 App"或"界面里到处 if (offline)"，
/// 那两套代码必然分叉：离线能跑通的路径，接上服务器就可能跑不通，
/// 而且以后每加一个功能都要写两遍。
///
/// 所以在**报文层**做接缝：
///
/// ```
///   页面  →  ApiClient（重试 / 幂等键 / 令牌 / 信封解析 / 错误码）
///                    ↓
///            ApiTransport  ← 只有这一层被替换
///              ├── HttpTransport      （真服务器）
///              └── OfflineTransport   （本机演示引擎）
/// ```
///
/// `ApiClient` 之上的所有逻辑（`ApiResult`、`decode`、错误码映射、
/// 离线判定、时钟偏差）**完全不感知**数据来自网络还是本机。
///
/// 页面代码因此一行都不用改 —— 这一点很关键，它保证了
/// "离线验过的界面"与"接上服务器的界面"是同一份代码。
abstract class ApiTransport {
  /// 发送一次请求，返回与真实 HTTP 服务端**完全一致**的响应：
  /// 状态码 + JSON 报文（信封格式 `{code, msg, data, errors, traceId, serverTime}`）。
  ///
  /// 返回报文而不是解析后的对象，是刻意的：
  /// 这样 `ApiClient` 现有的信封解析、错误码归一、`decode` 逻辑
  /// 对两种来源都走同一条路径，不会出现"离线模式错误码行为不一致"。
  Future<TransportResponse> send({
    required String method,
    required String path,
    Map<String, String>? query,
    required Map<String, String> headers,
    Object? body,
  });
}

/// 报文层返回的原始响应。
class TransportResponse {
  const TransportResponse({required this.statusCode, required this.body});

  /// HTTP 语义的状态码（200 / 400 / 401 / 403 / 404 / 409 / 429 / 500）。
  final int statusCode;

  /// JSON 响应体（信封）。
  final String body;
}
