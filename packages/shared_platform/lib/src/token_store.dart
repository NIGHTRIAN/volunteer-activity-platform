import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_core/shared_core.dart';

import 'models.dart';

/// 令牌与授权的安全存储。
///
/// 方案 §3 本地存储：「令牌（Android Keystore / iOS Keychain，**不落明文**）」。
///
/// 因此**没有任何**令牌会经过 SharedPreferences、文件或 SQLite——
/// 全部走 [FlutterSecureStorage]，由系统密钥库托管。
///
/// 存储的键名与值：
///   * `admin_token`     → 管理端会话 JSON（令牌 + 设备 + 到期）
///   * `volunteer_token` → 志愿者授权 JSON（令牌 + 活动 + 学号 + 到期）
///   * `device_id`       → 设备指纹（需在首次启动时生成并长期保留）
class TokenStore {
  TokenStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // Android：用 EncryptedSharedPreferences，密钥由 Keystore 保护。
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              // iOS：kSecAttrAccessibleAfterFirstUnlock —— 锁屏后仍可补传，
              // 但设备未解锁过一次前不可读。
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  final FlutterSecureStorage _storage;

  // ── 管理端会话 ────────────────────────────────────────────────────────

  /// 保存管理端会话。
  Future<void> saveAdminSession(AdminSession session) =>
      _storage.write(
        key: TokenKind.admin.storageKey,
        value: jsonEncode(session.toJson()),
      );

  /// 读取管理端会话。解析失败时**清理并返回 null**，不抛异常——
  /// 一个损坏的凭证不应该让 App 卡在启动页。
  Future<AdminSession?> readAdminSession() async {
    final Map<String, dynamic>? json = await _readJson(TokenKind.admin.storageKey);
    if (json == null) {
      return null;
    }
    try {
      final AdminSession session = AdminSession.fromJson(json);
      return session.token.isEmpty ? null : session;
    } catch (_) {
      await clearAdminSession();
      return null;
    }
  }

  Future<void> clearAdminSession() => _storage.delete(key: TokenKind.admin.storageKey);

  // ── 志愿者授权 ────────────────────────────────────────────────────────

  /// 保存志愿者授权。
  Future<void> saveVolunteerGrant(VolunteerGrant grant) => _storage.write(
        key: TokenKind.volunteer.storageKey,
        value: jsonEncode(grant.toJson()),
      );

  /// 读取志愿者授权。
  ///
  /// **同时校验有效期**：方案 §5.2 要求「到期后回到绑定页」。
  /// 这里把过期判断集中在一处，避免各个页面各写一遍而漏掉某个入口。
  Future<VolunteerGrant?> readVolunteerGrant({DateTime? now}) async {
    final Map<String, dynamic>? json = await _readJson(TokenKind.volunteer.storageKey);
    if (json == null) {
      return null;
    }
    try {
      final VolunteerGrant grant = VolunteerGrant.fromJson(json);
      if (grant.token.isEmpty) {
        return null;
      }
      final DateTime reference = now ?? DateTime.now();
      if (!grant.isValid(reference)) {
        // 过期即清理，避免界面拿着一个必然被服务端拒绝的令牌继续请求。
        await clearVolunteerGrant();
        return null;
      }
      return grant;
    } catch (_) {
      await clearVolunteerGrant();
      return null;
    }
  }

  Future<void> clearVolunteerGrant() => _storage.delete(key: TokenKind.volunteer.storageKey);

  // ── 设备指纹 ──────────────────────────────────────────────────────────

  /// 保存设备指纹（首次生成后长期保留）。
  Future<void> saveDeviceId(String deviceId) =>
      _storage.write(key: _deviceIdKey, value: deviceId);

  /// 读取设备指纹。
  Future<String?> readDeviceId() => _storage.read(key: _deviceIdKey);

  // ── 批量 ──────────────────────────────────────────────────────────────

  /// 清空全部凭证。用于 401/403 处理（方案 §9：「清理失效令牌并跳转登录/绑定」）。
  ///
  /// 注意**不清除 `device_id`**：设备指纹与身份无关，清掉会让服务端认为
  /// 换了一台设备，从而触发不必要的重新绑定。
  Future<void> clearAllSessions() async {
    await clearAdminSession();
    await clearVolunteerGrant();
  }

  static const String _deviceIdKey = 'device_id';

  Future<Map<String, dynamic>?> _readJson(String key) async {
    final String? raw = await _storage.read(key: key);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      // 内容损坏：直接删掉，让调用方走"未登录"分支。
      await _storage.delete(key: key);
      return null;
    }
  }
}
