import 'package:flutter/widgets.dart';
import 'package:shared_core/shared_core.dart';

/// 一次异步操作的结果。
///
/// ## 为什么不用 `FutureBuilder`
///
/// 页面需要的状态比 `FutureBuilder` 能表达的多一样：**"有数据但要重新加载"**。
/// 管理端看板是轮询的，用户端列表下拉刷新时也希望**保留旧数据**而不是
/// 变回骨架屏——否则每次刷新界面都闪一下，现场用起来很糟。
///
/// 因此这里把"加载中"与"已有数据"分开表示：[AppResult.loading] 可以带
/// 上一次的值（[previous]）。
@immutable
sealed class AppResult<T> {
  const AppResult();

  /// 请求中。
  const factory AppResult.loading({T? previous}) = AppLoading<T>;

  /// 成功，带数据。
  const factory AppResult.data(T value, {DateTime? at}) = AppData<T>;

  /// 失败。
  const factory AppResult.failure(AppError error, {T? previous}) = AppFailure<T>;

  /// 是否有可用数据（含"刷新中但保留旧值"）。
  ///
  /// 三个子类型已穷尽，因此不需要兜底分支（加了反而会被判为不可达）。
  bool get hasValue => switch (this) {
        AppData<T>() => true,
        AppFailure<T>(:final T? previous) => previous != null,
        AppLoading<T>(:final T? previous) => previous != null,
      };

  /// 当前可显示的数据（可能是上次的旧值）。
  T? get valueOrPrevious => switch (this) {
        AppData<T>(:final T value) => value,
        AppFailure<T>(:final T? previous) => previous,
        AppLoading<T>(:final T? previous) => previous,
      };

  /// 错误（仅失败态）。
  AppError? get errorOrNull => switch (this) {
        AppFailure<T>(:final AppError error) => error,
        _ => null,
      };

  /// 是否正在加载。
  bool get isLoading => this is AppLoading<T>;
}

/// 加载中。
final class AppLoading<T> extends AppResult<T> {
  const AppLoading({this.previous});

  /// 上一次的数据。若有，界面应继续显示它而不是显示骨架屏。
  final T? previous;

  @override
  bool operator ==(Object other) =>
      other is AppLoading<T> && other.previous == previous;

  @override
  int get hashCode => Object.hash(AppLoading<T>, previous);
}

/// 成功。
final class AppData<T> extends AppResult<T> {
  const AppData(this.value, {this.at});

  final T value;

  /// 数据取得的时间（用于"更新于 N 分钟前"）。
  final DateTime? at;

  @override
  bool operator ==(Object other) =>
      other is AppData<T> && other.value == value && other.at == at;

  @override
  int get hashCode => Object.hash(AppData<T>, value, at);
}

/// 失败。
final class AppFailure<T> extends AppResult<T> {
  const AppFailure(this.error, {this.previous});

  final AppError error;
  final T? previous;

  @override
  bool operator ==(Object other) =>
      other is AppFailure<T> && other.error == error && other.previous == previous;

  @override
  int get hashCode => Object.hash(AppFailure<T>, error, previous);
}

/// 面向界面的错误。
///
/// ## 为什么要把 [ApiFailure] 再包一层
///
/// 界面需要的是"**给用户看什么、能做什么**"，不是原始错误码。
/// 这个类把 `shared_core` 的技术性错误翻译成三样东西：
///
/// * [title] / [message] —— 说人话的文案；
/// * [canRetry] —— 重试有没有意义（参数错误重试一百次也没用）；
/// * [actionHint] —— 用户可以做什么（这是"不死路"原则的落点）。
@immutable
class AppError {
  const AppError({
    required this.title,
    required this.message,
    this.canRetry = true,
    this.actionHint,
    this.diagnostic,
  });

  final String title;
  final String message;

  /// 重试是否有意义。
  final bool canRetry;

  /// 用户可以采取的下一步（例如"请联系发布者现场核实"）。
  final String? actionHint;

  /// 诊断信息（错误码 + traceId），反馈问题时附上。
  final String? diagnostic;

  /// 从网络层失败翻译过来。
  ///
  /// ## 文案取向
  ///
  /// * **越权（40301）不解释细节**。因为线码值只有 8 个，
  ///   `40301` 同时表示"越权/不在名单/设备不符/二次校验失败"，
  ///   客户端无法区分——贸然说"你不在名单里"可能是错的。
  ///   所以一律用"你没有这项权限"，并引导找发布者。
  /// * **服务端文案优先**。服务端知道具体原因（`msg`），
  ///   客户端不该用自己的话覆盖它。
  factory AppError.fromApi(ApiFailure<Object?> f) {
    final ApiErrorCode code = f.code;

    if (f.isOffline) {
      return AppError(
        title: '网络不可用',
        message: '已保存到本机，联网后会自动上传。',
        canRetry: true,
        actionHint: '也可以稍后在「我的记录」里手动重试。',
        diagnostic: _diag(f),
      );
    }
    if (f.isTimeout) {
      return AppError(
        title: '网络超时',
        message: f.message.isNotEmpty ? f.message : '服务端没有及时响应。',
        canRetry: true,
        actionHint: '请检查网络后重试。',
        diagnostic: _diag(f),
      );
    }
    if (code.isAuthFailure) {
      return AppError(
        title: '需要重新登录',
        message: f.message.isNotEmpty ? f.message : '登录状态已失效。',
        // ⚠️ 认证失败重试没有意义：必须先拿到新令牌。
        canRetry: false,
        actionHint: '请重新登录。',
        diagnostic: _diag(f),
      );
    }
    if (code.isForbidden) {
      return AppError(
        title: '没有权限',
        // 保留服务端文案（它知道具体原因），并补一句通用解释。
        message: f.message.isNotEmpty ? f.message : '你没有执行该操作的权限。',
        canRetry: false,
        actionHint: '如果你认为这是误判，请联系活动发布者核实。',
        diagnostic: _diag(f),
      );
    }
    // `40401` 有三种细分（活动 / 导出 / 在岗任务），语义一致，合并处理。
    if (code == ApiErrorCode.activityNotFound ||
        code == ApiErrorCode.exportNotFound ||
        code == ApiErrorCode.attendanceTaskNotFound) {
      return AppError(
        title: '内容不存在',
        message: f.message.isNotEmpty ? f.message : '该内容可能已被删除，或已过 7 天留存期。',
        canRetry: false,
        diagnostic: _diag(f),
      );
    }
    if (code.isConflict) {
      return AppError(
        title: '状态已变化',
        message: f.message.isNotEmpty ? f.message : '数据已被其他人更新。',
        canRetry: true,
        actionHint: '请刷新后重试。',
        diagnostic: _diag(f),
      );
    }
    if (code == ApiErrorCode.badRequest) {
      return AppError(
        title: '填写有误',
        message: f.message.isNotEmpty ? f.message : '提交的内容不符合要求。',
        canRetry: false,
        // 字段级错误由调用方从 `errors[]` 取（这里只给总体文案）。
        diagnostic: _diag(f),
      );
    }
    if (code.isRateLimited) {
      return AppError(
        title: '操作过于频繁',
        message: f.message.isNotEmpty ? f.message : '请稍等片刻再试。',
        canRetry: true,
        diagnostic: _diag(f),
      );
    }
    if (code.isServerError) {
      return AppError(
        title: '服务暂时不可用',
        message: f.message.isNotEmpty ? f.message : '服务端出现问题，请稍后重试。',
        canRetry: true,
        actionHint: '如果持续失败，请联系管理员。',
        diagnostic: _diag(f),
      );
    }

    return AppError(
      title: '出了点问题',
      message: f.message.isNotEmpty ? f.message : '操作没有完成。',
      canRetry: true,
      diagnostic: _diag(f),
    );
  }

  /// 本地准备失败（定位失败、权限拒绝等），不由服务端返回。
  factory AppError.local({
    required String title,
    required String message,
    String? actionHint,
    bool canRetry = true,
  }) =>
      AppError(
        title: title,
        message: message,
        actionHint: actionHint,
        canRetry: canRetry,
      );

  static String? _diag(ApiFailure<Object?> f) {
    final StringBuffer b = StringBuffer('code=${f.rawCode}');
    if (f.traceId != null && f.traceId!.isNotEmpty) {
      b.write(' · trace=${f.traceId}');
    }
    return b.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is AppError &&
      other.title == title &&
      other.message == message &&
      other.canRetry == canRetry;

  @override
  int get hashCode => Object.hash(title, message, canRetry);
}
