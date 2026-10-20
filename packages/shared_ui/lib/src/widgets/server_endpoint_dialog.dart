import 'package:flutter/material.dart';

import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/src/status_visuals.dart';
import 'package:shared_ui/src/tokens.dart';
import 'package:shared_ui/src/widgets/app_button.dart';
import 'package:shared_ui/src/widgets/platform_intro_dialog.dart';

/// 「服务器地址」设置对话框。
///
/// ## 为什么需要它（用户没有云服务器）
///
/// 服务端地址原本只能由 `--dart-define=API_BASE_URL=...` 在**打包时**写死。
/// 但真实情况是：
///
///   * 用户没有云服务器 —— 服务端跑在他自己电脑上，地址是局域网 IP；
///   * 局域网 IP 会变（换网络、路由器重新分配）；
///   * 以后租了服务器，地址还要再换一次。
///
/// 每换一次就重新出包，普通用户做不到。真机测试期间 IP 从
/// `10.3.215.117` 变成 `192.168.72.34`，旧包装上去**只显示"连不上服务器"**，
/// 完全看不出是地址错了 —— 这正是这个对话框要消灭的问题。
///
/// ## 为什么不自己读写存储
///
/// `shared_ui` 只负责外观与交互，不碰平台能力（那是 `shared_platform` 的事）。
/// 所以「测试连接」和「保存」都以回调注入，由各 App 的界面层接线。
///
/// 这样也便于测试：widget 测试里传假回调即可验证全部交互。
class ServerEndpointDialog extends StatefulWidget {
  const ServerEndpointDialog({
    required this.currentUrl,
    required this.defaultUrl,
    required this.onTest,
    required this.onSave,
    required this.isDemoMode,
    required this.onUseDemo,
    required this.onUseServer,
    super.key,
  });

  /// 当前是否处于本机演示模式。
  final bool isDemoMode;

  /// 切到本机演示模式（不需要任何服务器）。
  final Future<void> Function() onUseDemo;

  /// 切回连接服务器。
  final Future<void> Function() onUseServer;

  /// 当前实际生效的地址（`ApiClient.effectiveBaseUrl`）。
  final String currentUrl;

  /// 编译期默认地址（用于「恢复默认」与对比提示）。
  final String defaultUrl;

  /// 测试连通性。返回 `null` 表示成功；返回字符串表示给用户看的失败原因。
  final Future<String?> Function(String normalizedUrl) onTest;

  /// 保存。传 `null` 表示恢复编译期默认。
  final Future<void> Function(String? normalizedUrl) onSave;

  @override
  State<ServerEndpointDialog> createState() => _ServerEndpointDialogState();
}

class _ServerEndpointDialogState extends State<ServerEndpointDialog> {
  late final TextEditingController _controller;

  /// 内联错误（格式校验或连通性测试失败）。
  String? _error;

  /// 测试结果的中性提示（例如"连接成功：volunteer-mock-server"）。
  String? _okHint;

  bool _testing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentUrl);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final String? invalid = validateBaseUrlInput(_controller.text);
    if (invalid != null) {
      setState(() {
        _error = invalid;
        _okHint = null;
      });
      return;
    }
    final String normalized = normalizeBaseUrl(_controller.text)!;
    setState(() {
      _testing = true;
      _error = null;
      _okHint = null;
    });
    final String? failure = await widget.onTest(normalized);
    if (!mounted) {
      return;
    }
    setState(() {
      _testing = false;
      if (failure == null) {
        _okHint = '连接成功：$normalized';
      } else {
        _error = failure;
      }
    });
  }

  Future<void> _save() async {
    final String? invalid = validateBaseUrlInput(_controller.text);
    if (invalid != null) {
      setState(() {
        _error = invalid;
        _okHint = null;
      });
      return;
    }
    final String normalized = normalizeBaseUrl(_controller.text)!;
    setState(() {
      _saving = true;
      _error = null;
    });
    await widget.onSave(normalized);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  Future<void> _restoreDefault() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    await widget.onSave(null);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool usingOverride = widget.currentUrl != widget.defaultUrl;

    return AlertDialog(
      title: const Text('服务器地址'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 先讲清楚"这是什么、为什么会有这个问题"，否则用户看到
            // 一个 IP 输入框会一头雾水。
            //
            // ⚠️ 界面文案里不要用 Markdown 记号（`**粗体**` 之类）——
            // Text 不解析它们，会原样显示出星号。真机上一眼就看出来了。
            Text(
              '本平台没有固定的公网服务器。请填写正在运行服务端的那台设备的地址：'
              '同一个 Wi-Fi 下通常是电脑的局域网 IP，端口 8080。',
              style: text.bodySmall,
            ),
            const SizedBox(height: Spacing.md),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: '192.168.1.5:8080',
                prefixIcon: Icon(Icons.dns_outlined),
                helperText: '只写 IP 和端口即可，会自动补 /api',
              ),
            ),
            const SizedBox(height: Spacing.sm),

            if (_error != null)
              _Banner(
                tone: StatusTone.danger,
                icon: Icons.error_outline,
                text: _error!,
              ),
            if (_okHint != null)
              _Banner(
                tone: StatusTone.success,
                icon: Icons.check_circle_outline,
                text: _okHint!,
              ),

            const SizedBox(height: Spacing.xs),
            Text(
              '当前生效：${widget.currentUrl}'
              '${usingOverride ? '（已手动设置）' : '（构建时默认）'}',
              style: text.labelSmall,
            ),

            const SizedBox(height: Spacing.md),
            // 一行两个次级操作：先测再存。顺序上"测"在前，
            // 因为绝大多数失败是地址写错，先测能立刻暴露。
            Row(
              children: <Widget>[
                Expanded(
                  child: AppButton(
                    label: _testing ? '测试中' : '测试连接',
                    variant: AppButtonVariant.secondary,
                    icon: Icons.wifi_tethering,
                    loading: _testing,
                    loadingLabel: '正在连接…',
                    onPressed: _testing || _saving ? null : _test,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: AppButton(
                    label: '保存',
                    icon: Icons.save_outlined,
                    loading: _saving,
                    loadingLabel: '保存中…',
                    onPressed: _testing || _saving ? null : _save,
                  ),
                ),
              ],
            ),

            if (usingOverride) ...<Widget>[
              const SizedBox(height: Spacing.xs),
              TextButton(
                onPressed: _saving ? null : _restoreDefault,
                child: const Text('恢复构建时默认地址'),
              ),
            ],

            // 随时可重看"App / 网页 / 服务器"的关系说明 ——
            // 首次启动会弹一次，但很多人当时不会细看，回头找不到就很麻烦。
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _saving
                    ? null
                    : () => showPlatformIntro(context, force: true),
                icon: const Icon(Icons.info_outline, size: Sizes.iconSm),
                label: const Text('怎么开始用？（含 App / 网页 / 服务器关系）'),
              ),
            ),

            /*
              ── 本机演示模式 ──────────────────────────────────────────────

              用户**没有云服务器**，但 App 要能直接装到手机上给别人验收。
              演示模式在报文层替换掉网络（见 `ApiTransport`），
              界面与判定逻辑完全复用 —— 所以"离线验过的"就是"接服务器后的"。

              这里必须把话说清楚：演示数据只在本机、不产生任何真实服务端记录。
              否则验收者会误以为这就是正式行为。
            */
            Divider(height: Spacing.xl, color: Theme.of(context).dividerColor),
            Text(
              widget.isDemoMode
                  ? '当前：本机演示模式（数据只在这台手机上，未连接任何服务器）'
                  : '没有服务器？可以先用「本机演示模式」把流程走完。',
              style: text.bodySmall,
            ),
            const SizedBox(height: Spacing.xs),
            AppButton(
              label: widget.isDemoMode ? '切回连接服务器' : '使用本机演示模式（无需服务器）',
              variant: AppButtonVariant.secondary,
              icon: widget.isDemoMode ? Icons.cloud_outlined : Icons.phone_android,
              onPressed: _saving || _testing
                  ? null
                  : () async {
                      // 先拿好 Navigator，避免 await 之后再用 context
                      //（`use_build_context_synchronously` 会在编译期就拦住）。
                      final NavigatorState nav = Navigator.of(context);
                      setState(() => _saving = true);
                      if (widget.isDemoMode) {
                        await widget.onUseServer();
                      } else {
                        await widget.onUseDemo();
                      }
                      nav.pop(true);
                    },
            ),
            if (widget.isDemoMode) ...<Widget>[
              const SizedBox(height: Spacing.xxs),
              Text(
                '演示模式里管理端邀请码固定为 1111；'
                '两端 App 的数据互相独立（手机系统隔离），各演示各的一侧。',
                style: text.labelSmall,
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 对话框内的小提示条（复用状态色语义，不另造颜色）。
class _Banner extends StatelessWidget {
  const _Banner({required this.tone, required this.icon, required this.text});

  final StatusTone tone;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final StatusVisual v = StatusVisual(label: text, tone: tone);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: Spacing.xs),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: v.background,
        borderRadius: Radii.cardRadius,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: Sizes.iconSm, color: v.foreground),
          const SizedBox(width: Spacing.xs),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: v.onBackground),
            ),
          ),
        ],
      ),
    );
  }
}
