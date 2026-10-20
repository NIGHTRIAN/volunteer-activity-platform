import 'package:flutter/material.dart';
import 'package:shared_platform/shared_platform.dart';
import 'package:shared_ui/src/status_visuals.dart';
import 'package:shared_ui/src/tokens.dart';

/// 网络与同步状态横条。
///
/// ## 存在理由（方案 §9 弱网与异常）
///
/// 志愿者在图书馆书架间、地下车库、体育场看台下签到——**弱网是常态，不是异常**。
/// 关键是让用户**随时知道自己的证据有没有上传**，否则会出现两种坏结果：
///
/// * 用户以为签上了，其实在队列里，事后被记未签到 → 争议；
/// * 用户不放心，反复点签到 → 重复记录（虽有幂等键兜底，但体验很差）。
///
/// 因此这条横条**只在有必要时出现**（离线 / 有待上传 / 同步失败），
/// 在线且队列为空时完全隐藏——常驻的"网络正常"提示只会变成噪音。
class SyncBanner extends StatelessWidget {
  const SyncBanner({
    required this.connectivity,
    required this.pendingCount,
    this.failedCount = 0,
    this.onRetry,
    this.onTapDetails,
    super.key,
  });

  /// 当前网络状态。
  final ConnectivityState connectivity;

  /// 待补传任务数。
  final int pendingCount;

  /// 补传失败（已用尽重试）的任务数。
  final int failedCount;

  /// 手动重试（仅失败时出现）。
  final VoidCallback? onRetry;

  /// 查看详情（点开看每条任务的状态）。
  final VoidCallback? onTapDetails;

  /// 是否需要显示。
  bool get isVisible =>
      !connectivity.isOnline || pendingCount > 0 || failedCount > 0;

  @override
  Widget build(BuildContext context) {
    if (!isVisible) {
      return const SizedBox.shrink();
    }

    final TextTheme text = Theme.of(context).textTheme;

    // 优先级：失败 > 离线 > 待上传。
    //
    // 顺序很重要：如果既离线又有失败任务，"失败"更需要用户注意
    //（离线是暂时的，失败是需要人介入的）。
    final (StatusVisual visual, String message) = switch ((
      failedCount > 0,
      connectivity.isOnline,
      pendingCount > 0,
    )) {
      (true, _, _) => (
          const StatusVisual(
            label: '同步失败',
            tone: StatusTone.danger,
            icon: Icons.cloud_off,
          ),
          '$failedCount 条记录上传失败。已保存在本机，不会丢失。',
        ),
      (false, false, true) => (
          const StatusVisual(
            label: '离线',
            tone: StatusTone.warning,
            icon: Icons.wifi_off,
          ),
          '当前离线，$pendingCount 条记录待联网后自动上传。',
        ),
      (false, false, false) => (
          const StatusVisual(
            label: '离线',
            tone: StatusTone.warning,
            icon: Icons.wifi_off,
          ),
          '当前离线。签到可以在联网后补传，但会转人工确认。',
        ),
      _ => (
          const StatusVisual(
            label: '待上传',
            tone: StatusTone.info,
            icon: Icons.cloud_upload_outlined,
          ),
          '$pendingCount 条记录正在上传…',
        ),
    };

    return Material(
      color: visual.background,
      child: InkWell(
        onTap: onTapDetails,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm,
          ),
          child: Row(
            children: <Widget>[
              Icon(visual.icon ?? Icons.info_outline, size: Sizes.iconMd, color: visual.foreground),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  message,
                  style: text.bodySmall?.copyWith(color: visual.onBackground),
                ),
              ),
              if (failedCount > 0 && onRetry != null)
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    foregroundColor: visual.onBackground,
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
                  ),
                  child: const Text('重试'),
                )
              else if (onTapDetails != null)
                Icon(
                  Icons.chevron_right,
                  size: Sizes.iconMd,
                  color: visual.onBackground,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一行"最后更新时间 + 手动刷新"。
///
/// 管理端看板是**前台轮询**（方案 §6.2 不启用推送），因此让用户
/// 知道"这份数据是几分钟前的"很重要——否则现场两个人看同一块看板
/// 会得到不同结论。
class RefreshIndicatorRow extends StatelessWidget {
  const RefreshIndicatorRow({
    required this.lastUpdated,
    this.onRefresh,
    this.isRefreshing = false,
    this.pollInterval = const Duration(seconds: 20),
    super.key,
  });

  final DateTime? lastUpdated;
  final VoidCallback? onRefresh;
  final bool isRefreshing;
  final Duration pollInterval;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final String label = lastUpdated == null
        ? '尚未更新'
        : '更新于 ${_ago(lastUpdated!)}';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: text.labelSmall,
        ),
        const SizedBox(width: Spacing.xxs),
        if (isRefreshing)
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          )
        else if (onRefresh != null)
          InkWell(
            onTap: onRefresh,
            borderRadius: Radii.pillRadius,
            child: const Padding(
              padding: EdgeInsets.all(Spacing.xxs),
              child: Icon(Icons.refresh, size: Sizes.iconSm, color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }

  /// 相对时间。
  ///
  /// 刻意**不显示绝对时间戳**：现场看板关心的是"数据新不新"，
  /// "16:42:07" 需要用户自己减一下才能判断。
  String _ago(DateTime t) {
    final Duration d = DateTime.now().difference(t);
    if (d.inSeconds < 20) {
      return '刚刚';
    }
    if (d.inMinutes < 1) {
      return '${d.inSeconds} 秒前';
    }
    if (d.inMinutes < 60) {
      return '${d.inMinutes} 分钟前';
    }
    if (d.inHours < 24) {
      return '${d.inHours} 小时前';
    }
    return '${d.inDays} 天前';
  }
}
