import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_core/shared_core.dart';

/// 本机参与记录的磁盘存储。
///
/// ## 为什么需要（真机报障）
///
/// > 参加完一个活动，还有另一个活动要参加，就得重新登录输入活动编码；
/// > 重新登录后，**之前那个活动的记录就看不到了**。
///
/// 记录本身还在服务端，但用户端一次只持有一个活动的授权：
/// 拿到新邀请码后，旧活动的接口再也调不到，界面上就等于"记录没了"。
///
/// 所以每次看到参与记录就存一份在本机，**解绑/切换活动都不清除**。
///
/// ## 为什么不放进 TokenStore
///
/// `TokenStore` 走的是 Keystore 加密存储，那是给**令牌**用的。
/// 参与记录里没有令牌（只有活动标题、学号、签到状态），
/// 塞进加密存储既没必要、每次读写也更慢；而且它需要按"整份列表"读写，
/// 与令牌的"单键单值"用法不同。
///
/// ## 写入策略
///
/// 与 `QueueStore` 一致：先写 `.tmp` 再 `rename`（同目录内原子），
/// 读写失败一律**不抛异常** —— 这是本机缓存，坏了不能让 App 用不了。
class ParticipationStore {
  ParticipationStore({this.fileName = 'participation-history.json'});

  /// 文件名（测试可注入不同名字以隔离）。
  final String fileName;

  File? _cached;

  Future<File> _resolve() async {
    final File? cached = _cached;
    if (cached != null) {
      return cached;
    }
    final Directory dir = await getApplicationSupportDirectory();
    final File file = File('${dir.path}${Platform.pathSeparator}$fileName');
    _cached = file;
    return file;
  }

  /// 读取本机参与记录。没有文件或读取失败 → 空历史。
  Future<ParticipationHistory> load() async {
    try {
      final File file = await _resolve();
      if (!await file.exists()) {
        return const ParticipationHistory.empty();
      }
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return const ParticipationHistory.empty();
      }
      return ParticipationHistory.fromJson(jsonDecode(raw));
    } catch (_) {
      // 缓存坏了就当作没有：绝不因此让记录页打不开。
      return const ParticipationHistory.empty();
    }
  }

  /// 整份保存。失败静默（内存里的数据仍然可用）。
  Future<void> save(ParticipationHistory history) async {
    try {
      final File file = await _resolve();
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(history.toJsonList()), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // 落盘失败不阻断使用
    }
  }

  /// 新增或更新一条记录（读 → upsert → 写），返回更新后的历史。
  ///
  /// 直接返回新历史，调用方不用再读一次盘。
  Future<ParticipationHistory> upsert(ParticipationRecord record) async {
    final ParticipationHistory current = await load();
    final ParticipationHistory next = current.upsert(record);
    await save(next);
    return next;
  }

  /// 清空本机记录（仅在用户明确要求时调用；解绑**不**清除）。
  Future<void> clear() => save(const ParticipationHistory.empty());
}
