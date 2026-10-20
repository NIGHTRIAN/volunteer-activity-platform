/// 志愿活动信息平台 · 端能力封装。
///
/// 这一层是 `shared_core`（纯 Dart 领域层）与 Flutter 平台能力之间的桥。
/// 拆开的理由：领域模型要保持零 Flutter 依赖，而定位、密钥库、设备信息
/// 本质上是平台相关的。
///
/// 三条与方案直接对应的约束：
///   * **定位只按需采集**（§7）→ [LocationService] 里没有任何 stream 或后台订阅；
///   * **令牌不落明文**（§3）→ 只有 [TokenStore] 一条写路径，走系统密钥库；
///   * **日志不含完整手机号/学号**（README §3.3 底线②）→ 出站日志统一经
///     [TelemetrySanitizer]（定义在 `shared_core`，保证只有一条出口）。
library;

export 'src/app_flag_store.dart';
export 'src/device_service.dart';
export 'src/location_service.dart';
export 'src/models.dart';
export 'src/offline_demo_store.dart';
export 'src/participation_store.dart';
export 'src/queue_store.dart';
export 'src/server_endpoint_store.dart';
export 'src/roster_import.dart';
export 'src/spreadsheet_import.dart';
export 'src/token_store.dart';
