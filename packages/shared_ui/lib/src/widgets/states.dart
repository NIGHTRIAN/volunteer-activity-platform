import 'package:flutter/material.dart';

import 'package:shared_ui/src/tokens.dart';

/// 空状态。
///
/// ## 文案要求（很重要）
///
/// 空状态最常见的错误是只说"暂无数据"——用户不知道**这是正常的**
/// 还是**出问题了**，也不知道下一步该做什么。
///
/// 因此 [title] 要说明"现在是什么情况"，[message] 要给出下一步。
/// 例如：
/// * 好：标题"还没有进行中的活动"，说明"活动开始时，发布者会通知你。"
/// * 坏：标题"暂无数据"
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.compact = false,
    super.key,
  });

  final String title;
  final String? message;
  final IconData icon;
  final Widget? action;

  /// 紧凑模式：嵌在页面局部而不是占满整屏。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: Spacing.xl,
          vertical: compact ? Spacing.lg : Spacing.xxxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: compact ? Sizes.iconXl : 48,
              color: AppColors.textTertiary,
            ),
            SizedBox(height: compact ? Spacing.sm : Spacing.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: text.titleSmall?.copyWith(color: AppColors.textSecondary),
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: Spacing.xs),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: text.bodySmall,
              ),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: Spacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 加载态。
///
/// [SkeletonList] 用**骨架屏**而不是转圈：列表页用转圈会出现
/// "转圈→突然出现一屏内容"的跳变，而骨架屏能提前告诉用户
/// "这里将出现几行东西"，感知等待更短。
class LoadingView extends StatelessWidget {
  const LoadingView({this.message, super.key});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          if (message != null) ...<Widget>[
            const SizedBox(height: Spacing.md),
            Text(message!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// 列表骨架屏。
class SkeletonList extends StatefulWidget {
  const SkeletonList({this.rows = 4, this.height = 96, super.key});

  final int rows;
  final double height;

  @override
  State<SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<SkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '正在加载',
      // 骨架屏对读屏没有意义，屏蔽掉内部元素，只播报一次"正在加载"。
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? _) {
          final double t = 0.45 + _controller.value * 0.35;
          return Column(
            children: List<Widget>.generate(
              widget.rows,
              (int i) => Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: Container(
                  height: widget.height,
                  decoration: BoxDecoration(
                    color: AppColors.neutralContainer.withValues(alpha: t),
                    borderRadius: Radii.cardRadius,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 错误态。
///
/// [onRetry] 存在时给出重试按钮——**这是"不死路"原则的一部分**
/// （方案 §7）：任何失败都必须给用户一个可执行的下一步。
class ErrorView extends StatelessWidget {
  const ErrorView({
    required this.message,
    this.title = '加载失败',
    this.onRetry,
    this.detail,
    this.compact = false,
    super.key,
  });

  final String title;
  final String message;

  /// 可选的诊断信息（traceId、错误码）。默认折叠，便于反馈问题时附上。
  final String? detail;

  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: Spacing.xl,
          vertical: compact ? Spacing.lg : Spacing.xxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.error_outline,
              size: 44,
              color: AppColors.danger,
            ),
            const SizedBox(height: Spacing.md),
            Text(title, textAlign: TextAlign.center, style: text.titleSmall),
            const SizedBox(height: Spacing.xs),
            Text(message, textAlign: TextAlign.center, style: text.bodySmall),
            if (detail != null) ...<Widget>[
              const SizedBox(height: Spacing.md),
              _DiagnosticBox(detail: detail!),
            ],
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: Spacing.lg),
              AppButtonRetry(onRetry: onRetry!),
            ],
          ],
        ),
      ),
    );
  }
}

/// 重试按钮（单独抽出来是为了避免 ErrorView 依赖 AppButton 造成循环导入）。
class AppButtonRetry extends StatelessWidget {
  const AppButtonRetry({required this.onRetry, super.key});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onRetry,
      icon: const Icon(Icons.refresh, size: Sizes.iconMd),
      label: const Text('重试'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(120, Sizes.buttonHeightCompact),
        side: const BorderSide(color: AppColors.outlineStrong),
        foregroundColor: AppColors.textPrimary,
      ),
    );
  }
}

class _DiagnosticBox extends StatelessWidget {
  const _DiagnosticBox({required this.detail});

  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xs,
      ),
      decoration: const BoxDecoration(
        color: AppColors.neutralContainer,
        borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
      ),
      child: SelectableText(
        detail,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontFamily: 'monospace',
              color: AppColors.textSecondary,
            ),
      ),
    );
  }
}
