import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 轻量的「一次性标记」存储。
///
/// 用途：**首次启动公告只弹一次**这类"看过就不再打扰"的标记。
///
/// ## 为什么不让每个功能自己读写文件
///
/// 这类标记会越来越多（首次公告、隐私说明、更新提示……）。
/// 如果每个都自己拼路径、自己处理异常，代码会散落各处，
/// 而且迟早有人忘记 Flutter 的 API 是异步的。集中一个类，
/// 调用方只需 `isSet('key')` / `set('key')`。
///
/// ## 设计取舍
///
/// * 一个 key 一个空文件 —— 比维护一个 JSON 简单，也不会因为
///   并发写同一个 JSON 而互相覆盖；
/// * 读写失败一律**不抛异常**：标记坏了顶多多弹一次公告，
///   绝不能因此让 App 起不来。
class AppFlagStore {
  AppFlagStore({this.prefix = 'flag-'});

  /// 文件名前缀，便于在应用目录里辨认。
  final String prefix;

  Directory? _dir;

  Future<Directory> _dirPath() async {
    final Directory? cached = _dir;
    if (cached != null) {
      return cached;
    }
    final Directory d = await getApplicationSupportDirectory();
    _dir = d;
    return d;
  }

  /// 文件名里只允许安全字符，避免 key 里带路径分隔符。
  String _safe(String key) => key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  Future<File> _fileFor(String key) async {
    final Directory d = await _dirPath();
    return File('${d.path}${Platform.pathSeparator}$prefix${_safe(key)}');
  }

  /// 是否已标记。
  Future<bool> isSet(String key) async {
    try {
      return await (await _fileFor(key)).exists();
    } catch (_) {
      return false;
    }
  }

  /// 写入标记。
  Future<void> set(String key) async {
    try {
      await (await _fileFor(key)).writeAsString('1', flush: true);
    } catch (_) {
      // 忽略：顶多下次再提示一次
    }
  }

  /// 清除标记（例如"重置引导"）。
  Future<void> clear(String key) async {
    try {
      final File f = await _fileFor(key);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {
      // 忽略
    }
  }
}
