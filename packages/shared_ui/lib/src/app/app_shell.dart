import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_platform/shared_platform.dart';
import 'package:shared_ui/shared_ui.dart';

/// 应用外壳：把全局横条、页面与轮询接起来。
///
/// ## 职责
///
/// 1. **弱网横条**：订阅网络状态与离线队列，在全屏顶部显示"离线/待上传"。
///    放在外壳而不是各页面，是为了保证**任何页面都能看到自己的上传状态**——
///    这正是方案 §9 的要点（用户必须随时知道证据有没有上传）。
/// 2. **离线队列自动补传**：联网恢复时自动 flush。
/// 3. **不承担任何判定**：服务端才是判定的唯一来源（方案 §2）。
class AppShell extends StatefulWidget {
  const AppShell({
    required this.child,
    this.showSyncBanner = true,
    super.key,
  });

  final Widget child;

  /// 是否显示弱网横条（管理端也显示，理由同上）。
  final bool showSyncBanner;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  ConnectivityState _connectivity = ConnectivityState.online;
  StreamSubscription<ConnectivityState>? _connSub;
  AppServices? _services;
  bool _flushing = false;

  /// 队列里"已用尽重试"的任务数。
  ///
  /// `OfflineQueue` 目前只暴露 `outstandingCount`（待同步数），
  /// 没有"永久失败"的计数。因此这里跟踪上一次 flush 的失败数——
  /// flush 的 `FlushReport.failed` 正是这个含义（重试已用尽）。
  /// 它会在下一次成功 flush 时归零。
  int _failedCount = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final AppServices services = AppScope.of(context);
    if (identical(_services, services)) {
      return;
    }
    _services = services;
    _connSub?.cancel();
    _connSub = services.connectivity.watch().listen(_onConnectivity);

    // 启动时探一次，并尝试补传上次没传完的证据。
    unawaited(_bootstrap(services));
  }

  Future<void> _bootstrap(AppServices services) async {
    final ConnectivityState s = await services.connectivity.state();
    if (mounted) {
      setState(() => _connectivity = s);
    }
    if (s.isOnline) {
      await _tryFlush();
    }
  }

  void _onConnectivity(ConnectivityState s) {
    if (!mounted) {
      return;
    }
    // 只在"离线 → 在线"这个**边沿**触发补传。
    // 每次状态回调都 flush 会在网络抖动时反复发请求。
    final bool cameOnline = !_connectivity.isOnline && s.isOnline;
    setState(() => _connectivity = s);
    if (cameOnline) {
      unawaited(_tryFlush());
    }
  }

  Future<void> _tryFlush() async {
    final AppServices? services = _services;
    if (services == null || _flushing || services.queue.isEmpty) {
      return;
    }
    _flushing = true;
    try {
      // 用带退避的补传：弱网下连续快重试只会耗电。
      // 返回类型不写出来：`FlushReport` 在 shared_core 里是公开类型，
      // 但这里只用到 `failed`，让类型推断处理即可（也避免多一处导入）。
      final report = await services.queue.flushWithBackoff();
      if (mounted) {
        _failedCount = report.failed;
      }
    } finally {
      _flushing = false;
      if (mounted) {
        // 队列长度变了，横条要更新。
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    _connSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppServices? services = AppScope.maybeOf(context);

    // 队列长度变化时横条要更新。
    //
    // `OfflineQueue` 不是 `Listenable`（它属于纯 Dart 的 shared_core，
    // 不能依赖 Flutter 的 ChangeNotifier），因此这里靠两处 `setState` 驱动：
    // 网络状态变化、以及 flush 结束。入队发生在页面里，页面本身会重建，
    // 而横条读的是队列的当前值，所以不会显示过期数字。
    return Column(
      children: <Widget>[
        if (widget.showSyncBanner && services != null)
          SyncBanner(
            connectivity: _connectivity,
            pendingCount: services.queue.outstandingCount,
            failedCount: _failedCount,
            onRetry: _tryFlush,
          ),
        Expanded(child: widget.child),
      ],
    );
  }
}
