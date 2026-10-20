/// 志愿活动信息平台 · 两端 App 共享内核。
///
/// 分层：
///   * `contract/` —— 与服务端约定的**不可协商**部分：错误码、响应信封、
///     字段字典、时间与坐标系口径。改动必须走《接口契约》变更规则。
///   * `domain/` —— 领域模型与纯函数校验。**零 Flutter 依赖**，可在服务端
///     Mock 与单元测试中直接复用。
///
/// 设计约束（来自方案）：
///   * 客户端不判定签到（§2）→ 本包只做证据采集的载体与结果展示，无判定逻辑；
///   * 坐标一律 WGS-84（§6.1）→ 转换集中在 `GeoTransform`；
///   * 时间统一 `yyyy-MM-dd HH:mm`（§8）→ 格式化集中在 `TimeFormat`；
///   * 日志不含完整手机号/学号（README §3.3）→ 脱敏集中在
///     `ParticipantImportValidator.maskPhone / maskUserNo`。
library;

// ── contract ────────────────────────────────────────────────────────────
export 'src/contract/api_envelope.dart';
export 'src/contract/api_paths.dart';
export 'src/contract/error_codes.dart';
export 'src/contract/field_dictionary.dart';
export 'src/contract/time_and_geo.dart';

// ── domain ──────────────────────────────────────────────────────────────
export 'src/domain/activity.dart';
export 'src/domain/invite_share.dart';
export 'src/domain/participation_history.dart';
export 'src/domain/attendance.dart';
export 'src/domain/attendance_report.dart';
export 'src/domain/checkin.dart';
export 'src/domain/enums.dart';
export 'src/domain/json_utils.dart';
export 'src/domain/paging.dart';
export 'src/domain/validation.dart';

// ── logging ─────────────────────────────────────────────────────────────
export 'src/logging/sanitizer.dart';

// ── network ─────────────────────────────────────────────────────────────
export 'src/network/api_client.dart';
export 'src/network/api_transport.dart';
export 'src/offline/offline_demo_transport.dart';
export 'src/network/offline_queue.dart';
