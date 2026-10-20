import 'dart:async';

import 'package:flutter/material.dart';

import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/src/app/app_scope.dart';
import 'package:shared_ui/src/tokens.dart';
import 'package:shared_ui/src/widgets/server_endpoint_dialog.dart';

/// 打开「服务器地址」设置对话框。
///
/// 把「测试连接」和「保存」的接线收在一处，两端 App 只需调用这一个函数，
/// 避免各写一遍、行为跑偏。
///
/// 返回 `true` 表示保存了新的地址（调用方通常要据此提示"已切换，请刷新"）。
Future<bool?> showServerEndpointDialog(BuildContext context) {
  final AppServices services = AppScope.of(context);
  final String defaultUrl = ApiConfig.fromEnvironment().normalizedBaseUrl;

  return showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => ServerEndpointDialog(
      currentUrl: services.api.effectiveBaseUrl,
      defaultUrl: defaultUrl,
      isDemoMode: services.api.transport != null,
      // 切到演示模式：本机引擎接管报文层，一条网络请求都不发。
      //
      // 这条路径与"连服务器"共用同一个 ApiClient，所以界面、错误码、
      // 离线队列的行为完全一致 —— 这是离线版能当验收材料的前提。
      onUseDemo: () async {
        final bool wasDemo = services.api.transport != null;
        await services.offlineDemo.setDemoMode(true);
        if (!wasDemo) {
          final OfflineDemoState demo =
              OfflineDemoState.fromJsonString(await services.offlineDemo.load());
          demo.onChanged = () {
            unawaited(services.offlineDemo.save(demo.toJsonString()));
          };
          services.api.transport = OfflineDemoTransport(state: demo);
        }
      },
      // 切回服务器：清掉演示标记，恢复真实 HTTP。
      onUseServer: () async {
        services.api.transport = null;
        await services.offlineDemo.setDemoMode(false);
      },
      // 连通性测试用**独立的临时客户端**：
      // 不动当前 client 的在途请求，也不把测试请求写进令牌/幂等状态。
      onTest: (String url) async {
        final ApiClient probe = ApiClient(
          config: ApiConfig(baseUrl: url, timeout: const Duration(seconds: 6)),
        );
        try {
          final ApiResult<Map<String, Object?>> r =
              await probe.get<Map<String, Object?>>(
            '/health',
            authorized: false,
            // ⚠️ 测试连接**不能带重试**。
            //
            // 默认策略是网络类失败重试 5 次（退避 1+2+4+8+16 秒）。
            // 地址写错时（最常见的情况）用户要干等 30 秒以上才看到"连不上"，
            // 而且还会误以为 App 卡死了 —— 真机测试时就是这么卡住的。
            // 这里一次失败立刻报，配合 6 秒超时，最多 6 秒给结论。
            retryable: false,
            decode: (Object? d) => (d! as Map<Object?, Object?>).cast<String, Object?>(),
          );
          if (r.isSuccess) {
            return null;
          }
          final ApiFailure<Map<String, Object?>>? f = r.failureOrNull;
          if (f == null) {
            return '连接失败';
          }
          if (f.isTimeout) {
            return '连接超时。请确认服务端已启动、手机与它同一 Wi-Fi、防火墙放行。';
          }
          if (f.isOffline) {
            return '连不上这个地址。请检查 IP 与端口是否正确、服务端是否已启动。';
          }
          return '服务端返回 ${f.rawCode}：${f.message}';
        } finally {
          probe.dispose();
        }
      },
      onSave: (String? url) async {
        services.api.setBaseUrlOverride(url);
        await services.serverEndpoint.save(url);
      },
    ),
  );
}

/// 「服务器地址」入口行。
///
/// 外观是一个普通的设置条目，右侧显示**当前生效地址**——
/// 这一点很重要：用户遇到"连不上"时，第一件要确认的事就是
/// "App 现在到底连的是哪个地址"。
class ServerEndpointEntry extends StatelessWidget {
  const ServerEndpointEntry({this.onChanged, super.key});

  /// 地址变更后的回调（通常是"刷新数据"）。
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final AppServices services = AppScope.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String url = services.api.effectiveBaseUrl;
    final bool overridden = services.api.hasBaseUrlOverride;

    return InkWell(
      onTap: () async {
        final bool? saved = await showServerEndpointDialog(context);
        if (saved == true) {
          onChanged?.call();
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xs,
          vertical: Spacing.sm,
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.dns_outlined, size: Sizes.iconMd),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('服务器地址', style: text.titleSmall),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    url,
                    style: text.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (overridden)
                    Text('（已手动设置）', style: text.labelSmall),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: Sizes.iconMd),
          ],
        ),
      ),
    );
  }
}
