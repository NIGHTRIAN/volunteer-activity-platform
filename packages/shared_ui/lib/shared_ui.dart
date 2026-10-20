/// 志愿活动信息平台 · 设计系统与两端共用组件。
///
/// 两端 App 都**只应从这里取视觉与通用交互**，页面里不得自造颜色、
/// 间距或业务状态文案（理由见 `status_visuals.dart` 与 `tokens.dart`）。
library;

// ── 令牌与主题 ──────────────────────────────────────────────────────────
export 'src/app_theme.dart';
export 'src/status_visuals.dart';
export 'src/tokens.dart';

// ── 应用级基础设施 ──────────────────────────────────────────────────────
export 'src/app/app_controller.dart';
export 'src/app/app_info.dart';
export 'src/app/app_result.dart';
export 'src/app/app_router.dart';
export 'src/app/app_scope.dart';
export 'src/app/app_shell.dart';

// ── 通用组件 ────────────────────────────────────────────────────────────
export 'src/widgets/app_button.dart';
export 'src/widgets/platform_intro_dialog.dart';
export 'src/widgets/server_endpoint_dialog.dart';
export 'src/widgets/server_endpoint_entry.dart';
export 'src/widgets/app_card.dart';
export 'src/widgets/states.dart';
export 'src/widgets/status_chip.dart';
export 'src/widgets/sync_banner.dart';
