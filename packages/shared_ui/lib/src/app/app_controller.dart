import 'package:flutter/foundation.dart';
import 'package:shared_ui/src/app/app_result.dart';

/// 异步数据控制器。
///
/// ## 为什么不用第三方状态管理
///
/// 本项目的状态需求很窄：**每个页面一个（或几个）异步请求**，
/// 加上"下拉刷新"和"前台轮询"。引入 Riverpod/Bloc 会带来
/// 学习成本与版本风险（方案 §1.3 要求开发环境可复现），
/// 而 `ChangeNotifier` 足以覆盖，且零外部依赖。
///
/// ## 关键行为
///
/// * **刷新时保留旧数据**：`refresh()` 不会先清空 value，
///   而是进入 `AppLoading(previous: ...)`，界面继续显示旧值。
///   这避免了"每次轮询看板都闪一下"的问题。
/// * **并发保护**：同一时刻只允许一个在途请求（[inFlight]），
///   重复调用直接返回，不做第二次网络请求。
/// * **`mounted` 保护**：页面销毁后不 `notifyListeners()`，
///   否则会在 Flutter 里抛 "setState called after dispose"。
class AppController<T> extends ChangeNotifier {
  // 泛型控制器不能构造 `const AppResult<T>.loading()`（Dart 不允许在常量
  // 创建里用类型参数），因此初值用非常量的 AppLoading。
  AppController({required this._load, AppResult<T>? initial})
      : _state = initial ?? AppLoading<T>();

  final Future<T> Function() _load;

  AppResult<T> _state;

  /// 当前状态。
  AppResult<T> get state => _state;

  /// 当前数据（可能是上次的旧值）。
  T? get value => _state.valueOrPrevious;

  /// 当前错误。
  AppError? get error => _state.errorOrNull;

  /// 是否正在加载。
  bool get isLoading => _state.isLoading;

  /// 是否首次加载（没有旧数据）。
  bool get isInitialLoad => _state.isLoading && !_state.hasValue;

  bool _disposed = false;

  /// 是否有在途请求。
  bool get inFlight => _inFlight;
  bool _inFlight = false;

  /// 加载（首次或刷新）。
  ///
  /// [silent] 为 `true` 时**不进入加载态**——用于前台轮询：
  /// 轮询不该让界面出现任何闪烁，也不该覆盖用户正在看的错误提示。
  Future<void> load({bool silent = false}) async {
    if (_disposed || _inFlight) {
      return;
    }
    _inFlight = true;

    final T? previous = _state.valueOrPrevious;
    if (!silent || previous == null) {
      _set(AppLoading<T>(previous: previous));
    }

    try {
      final T value = await _load();
      if (_disposed) {
        return;
      }
      _set(AppResult<T>.data(value, at: DateTime.now()));
    } catch (e) {
      if (_disposed) {
        return;
      }
      final AppError err = e is AppError
          ? e
          : AppError.local(
              title: '操作失败',
              message: e.toString(),
            );
      // 静默轮询失败时**保留原状态**：一次网络抖动不该把已经看到的数据
      // 换成错误页——现场看板正在用，闪成错误页会让人以为活动出问题了。
      if (silent && previous != null) {
        _inFlight = false;
        return;
      }
      _set(AppResult<T>.failure(err, previous: previous));
    } finally {
      _inFlight = false;
    }
  }

  /// 仅在有数据时刷新（供轮询调用）。
  Future<void> refreshSilently() => load(silent: true);

  /// 强制刷新（下拉刷新、点重试）。
  Future<void> refresh() => load();

  /// 直接写入一个新值（本地操作后乐观更新）。
  void setValue(T value) => _set(AppResult<T>.data(value, at: DateTime.now()));

  /// 直接写入一个错误（本地校验失败）。
  void setError(AppError error) =>
      _set(AppResult<T>.failure(error, previous: _state.valueOrPrevious));

  void _set(AppResult<T> next) {
    if (_disposed) {
      return;
    }
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 多个控制器的集合，便于页面一次刷新。
///
/// 典型用法：管理端看板同时有"统计"和"名单"两个请求，
/// 下拉刷新应一次刷两个，而不是各刷一次（浪费一次往返）。
class ControllerGroup extends ChangeNotifier {
  ControllerGroup(this._members);

  final List<AppController<Object?>> _members;

  bool get isLoading => _members.any((AppController<Object?> c) => c.isLoading);

  /// 并行刷新全部成员。
  Future<void> refreshAll() async {
    await Future.wait(_members.map((AppController<Object?> c) => c.refresh()));
  }
}
