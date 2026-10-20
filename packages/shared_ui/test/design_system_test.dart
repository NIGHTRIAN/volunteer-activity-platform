import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';
import 'package:shared_ui/shared_ui.dart';

/// 设计系统测试。
///
/// 重点不在"颜色对不对"（那是审美），而在**两条会静默失效的规则**：
///   1. 每个领域状态都必须在映射表里有条目（漏一个不会编译失败，
///      只会在某个页面显示成"未知"）；
///   2. 每个状态标签的文字与底色必须有足够对比度（不达标只能靠肉眼看出来，
///      而户外强光下正是最容易看不清的场景）。
void main() {
  group('状态映射覆盖完整', () {
    // ⚠️ 这几条测试的价值：方案每次新增一个状态值时，
    // 如果忘了同步映射表，界面会悄悄显示"未知"而不是报错。
    // 这里把"忘了"变成"测试失败"。

    test('活动状态全部有映射', () {
      for (final ActivityStatus s in ActivityStatus.values) {
        expect(
          StatusVisuals.activity.containsKey(s),
          isTrue,
          reason: '活动状态 $s 缺少视觉映射，界面会显示成"未知"',
        );
      }
    });

    test('报名状态全部有映射', () {
      for (final SignupStatus s in SignupStatus.values) {
        expect(
          StatusVisuals.signup.containsKey(s),
          isTrue,
          reason: '报名状态 $s 缺少视觉映射',
        );
      }
    });

    test('名单签到状态全部有映射', () {
      for (final ParticipantCheckinStatus s in ParticipantCheckinStatus.values) {
        expect(
          StatusVisuals.participantCheckin.containsKey(s),
          isTrue,
          reason: '名单签到状态 $s 缺少视觉映射',
        );
      }
    });

    test('签到结果全部有映射', () {
      for (final CheckinStatus s in CheckinStatus.values) {
        expect(
          StatusVisuals.checkin.containsKey(s),
          isTrue,
          reason: '签到结果 $s 缺少视觉映射',
        );
      }
    });

    test('在岗任务状态全部有映射', () {
      for (final AttendanceTaskStatus s in AttendanceTaskStatus.values) {
        expect(
          StatusVisuals.attendanceTask.containsKey(s),
          isTrue,
          reason: '在岗任务状态 $s 缺少视觉映射',
        );
      }
    });

    test('考勤汇总全部有映射', () {
      for (final AttendanceSummary s in AttendanceSummary.values) {
        expect(
          StatusVisuals.attendanceSummary.containsKey(s),
          isTrue,
          reason: '考勤汇总 $s 缺少视觉映射',
        );
      }
    });

    test('同步状态全部有映射', () {
      for (final SyncState s in SyncState.values) {
        expect(
          StatusVisuals.sync.containsKey(s),
          isTrue,
          reason: '同步状态 $s 缺少视觉映射',
        );
      }
    });

    test('所有标签文案非空', () {
      final Iterable<StatusVisual> all = <StatusVisual>[
        ...StatusVisuals.activity.values,
        ...StatusVisuals.signup.values,
        ...StatusVisuals.participantCheckin.values,
        ...StatusVisuals.checkin.values,
        ...StatusVisuals.attendanceTask.values,
        ...StatusVisuals.attendanceSummary.values,
        ...StatusVisuals.sync.values,
      ];
      for (final StatusVisual v in all) {
        expect(v.label.trim(), isNotEmpty, reason: '状态标签不能为空');
      }
    });
  });

  group('文案不得出现"处罚"暗示（方案 §4.8 / §6.4.7）', () {
    test('在岗超时说明必须写明"不自动扣减时长"', () {
      final StatusVisual v = StatusVisuals.ofAttendanceTask(
        AttendanceTaskStatus.missed,
      );
      // 方案 §4.8 要求考勤只作现场管理参考。如果界面只说"已超时"，
      // 志愿者会以为自己被扣了时长——这是最容易引发争议的误解。
      expect(
        v.description,
        contains('不自动扣减'),
        reason: '「已超时」的说明必须明确不扣减时长，否则会引发争议',
      );
    });

    test('考勤汇总的"证据不足"不得等同于缺席', () {
      final StatusVisual insufficient =
          StatusVisuals.ofAttendanceSummary(AttendanceSummary.insufficient);
      expect(insufficient.label, '证据不足');
      expect(
        insufficient.tone,
        isNot(StatusTone.danger),
        reason: '证据不足不是坏结果，用红色会让志愿者以为被处罚了',
      );
      expect(insufficient.description, contains('不定性为缺席'));
    });

    test('待确认类状态一律用 warning 而不是 danger', () {
      expect(
        StatusVisuals.ofCheckin(CheckinStatus.pendingReview).tone,
        StatusTone.warning,
      );
      expect(
        StatusVisuals.ofParticipantCheckin(ParticipantCheckinStatus.pendingReview).tone,
        StatusTone.warning,
      );
      expect(
        StatusVisuals.ofAttendanceTask(AttendanceTaskStatus.pending).tone,
        StatusTone.warning,
      );
    });

    test('未签到用 danger（进行中需要行动），而不是中性灰', () {
      expect(
        StatusVisuals.ofParticipantCheckin(ParticipantCheckinStatus.notCheckedIn).tone,
        StatusTone.danger,
        reason: '活动进行中「未签到」是需要行动的状态，灰色会被忽略',
      );
    });
  });

  group('对比度达标（WCAG AA）', () {
    /// 相对亮度。
    double luminance(Color c) {
      double channel(double v) =>
          v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
    }

    /// 对比度。
    double contrast(Color a, Color b) {
      final double la = luminance(a);
      final double lb = luminance(b);
      final double hi = math.max(la, lb);
      final double lo = math.min(la, lb);
      return (hi + 0.05) / (lo + 0.05);
    }

    test('深色文字配浅色底 ≥ 4.5:1', () {
      final Iterable<StatusVisual> all = <StatusVisual>[
        ...StatusVisuals.activity.values,
        ...StatusVisuals.signup.values,
        ...StatusVisuals.participantCheckin.values,
        ...StatusVisuals.checkin.values,
        ...StatusVisuals.attendanceTask.values,
        ...StatusVisuals.attendanceSummary.values,
        ...StatusVisuals.sync.values,
      ];
      for (final StatusVisual v in all) {
        final double ratio = contrast(v.onBackground, v.background);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason: '「${v.label}」的文字/底色对比度只有 '
              '${ratio.toStringAsFixed(2)}:1，低于 AA 要求的 4.5:1',
        );
      }
    });

    test('正文色对比度达标', () {
      expect(
        contrast(AppColors.textPrimary, AppColors.surfaceCard),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(AppColors.textSecondary, AppColors.surfaceCard),
        greaterThanOrEqualTo(4.5),
      );
    });
  });

  group('主题构建', () {
    test('两端主题都能构建，且密度不同', () {
      final ThemeData userTheme = AppTheme.build();
      final ThemeData adminTheme = AppTheme.build(compact: true);

      expect(userTheme.useMaterial3, isTrue);
      expect(adminTheme.useMaterial3, isTrue);

      // 管理端更紧凑
      expect(adminTheme.visualDensity.vertical, lessThan(userTheme.visualDensity.vertical));

      // 但按钮高度**不得**因为紧凑而低于无障碍最小值
      expect(
        adminTheme.filledButtonTheme.style?.minimumSize?.resolve(<WidgetState>{})?.height,
        greaterThanOrEqualTo(Sizes.buttonHeightCompact),
      );
      expect(Sizes.buttonHeightCompact, greaterThanOrEqualTo(44));
    });

    test('圆角与间距令牌是 4 的倍数（保证视觉一致）', () {
      for (final double v in <double>[
        Spacing.xxs,
        Spacing.xs,
        Spacing.sm,
        Spacing.md,
        Spacing.lg,
        Spacing.xl,
        Spacing.xxl,
        Spacing.xxxl,
      ]) {
        expect(v % 4, 0, reason: '间距 $v 不是 4 的倍数');
      }
    });
  });

  group('AppResult 语义', () {
    test('加载态保留上一次的值（避免刷新时闪骨架屏）', () {
      const AppResult<int> r = AppResult<int>.loading(previous: 42);
      expect(r.hasValue, isTrue);
      expect(r.valueOrPrevious, 42);
      expect(r.isLoading, isTrue);
      expect(r.errorOrNull, isNull);
    });

    test('失败态也保留上一次的值（弱网时继续显示旧数据）', () {
      const AppResult<int> r = AppResult<int>.failure(
        AppError(title: 'x', message: 'y'),
        previous: 7,
      );
      expect(r.hasValue, isTrue, reason: '有旧数据时不该显示整页错误');
      expect(r.valueOrPrevious, 7);
      expect(r.errorOrNull, isNotNull);
    });

    test('首次加载失败时没有值', () {
      const AppResult<int> r = AppResult<int>.failure(
        AppError(title: 'x', message: 'y'),
      );
      expect(r.hasValue, isFalse);
      expect(r.valueOrPrevious, isNull);
    });

    test('没有旧值时加载态 hasValue 为 false（该显示骨架屏）', () {
      const AppResult<int> r = AppResult<int>.loading();
      expect(r.hasValue, isFalse);
      expect(r.valueOrPrevious, isNull);
    });
  });

  group('AppError 翻译', () {
    ApiFailure<Object?> fail(
      ApiErrorCode code, {
      String message = '',
      bool offline = false,
      bool timeout = false,
    }) =>
        ApiFailure<Object?>(
          code: code,
          message: message,
          isOffline: offline,
          isTimeout: timeout,
        );

    test('离线 → 明确告知已保存、稍后自动上传', () {
      final AppError e = AppError.fromApi(fail(ApiErrorCode.offlineQueued, offline: true));
      expect(e.title, '网络不可用');
      expect(e.message, contains('已保存到本机'));
      expect(e.canRetry, isTrue);
    });

    test('认证失败 → 不可重试（必须重新登录，重试无意义）', () {
      final AppError e = AppError.fromApi(fail(ApiErrorCode.grantExpired));
      expect(e.title, '需要重新登录');
      expect(e.canRetry, isFalse);
    });

    test('越权 → 不猜具体原因，引导找发布者', () {
      // 40301 同时代表越权/不在名单/设备不符/二次校验失败。
      // 客户端无法区分，因此**不能**断言"你不在名单里"。
      final AppError e = AppError.fromApi(fail(ApiErrorCode.notInParticipantList));
      expect(e.title, '没有权限');
      expect(e.canRetry, isFalse);
      expect(e.actionHint, contains('发布者'));
    });

    test('服务端文案优先（服务端知道具体原因）', () {
      final AppError e = AppError.fromApi(
        fail(ApiErrorCode.notInParticipantList, message: '该学号不在本次名单中，请联系带队老师'),
      );
      expect(e.message, '该学号不在本次名单中，请联系带队老师');
    });

    test('404 三种细分都识别为"内容不存在"', () {
      for (final ApiErrorCode c in <ApiErrorCode>[
        ApiErrorCode.activityNotFound,
        ApiErrorCode.exportNotFound,
        ApiErrorCode.attendanceTaskNotFound,
      ]) {
        expect(AppError.fromApi(fail(c)).title, '内容不存在', reason: '$c 应识别为不存在');
      }
    });

    test('状态冲突 → 可重试且提示刷新', () {
      final AppError e = AppError.fromApi(fail(ApiErrorCode.versionConflict));
      expect(e.title, '状态已变化');
      expect(e.canRetry, isTrue);
      expect(e.actionHint, contains('刷新'));
    });

    test('诊断信息带错误码与 traceId，便于反馈', () {
      const ApiFailure<Object?> f = ApiFailure<Object?>(
        code: ApiErrorCode.serverError,
        message: 'boom',
        traceId: 't-abc123',
      );
      final AppError e = AppError.fromApi(f);
      expect(e.diagnostic, contains('50001'));
      expect(e.diagnostic, contains('t-abc123'));
    });
  });

  group('AppController', () {
    test('首次加载：loading → data', () async {
      int calls = 0;
      final AppController<String> c = AppController<String>(
        load: () async {
          calls += 1;
          return 'v$calls';
        },
      );
      addTearDown(c.dispose);

      expect(c.isInitialLoad, isTrue);
      await c.load();
      expect(c.value, 'v1');
      expect(c.isLoading, isFalse);
      expect(c.error, isNull);
    });

    test('刷新失败时保留旧值并提供错误', () async {
      bool shouldFail = false;
      final AppController<String> c = AppController<String>(
        load: () async {
          if (shouldFail) {
            throw const AppError(title: '失败', message: '网络错误');
          }
          return 'ok';
        },
      );
      addTearDown(c.dispose);

      await c.load();
      expect(c.value, 'ok');

      shouldFail = true;
      await c.refresh();
      expect(c.value, 'ok', reason: '刷新失败不该丢掉已有数据');
      expect(c.error, isNotNull);
    });

    test('静默刷新失败时连错误都不暴露（轮询抖动不该打扰用户）', () async {
      bool shouldFail = false;
      final AppController<String> c = AppController<String>(
        load: () async {
          if (shouldFail) {
            throw const AppError(title: '失败', message: '网络错误');
          }
          return 'ok';
        },
      );
      addTearDown(c.dispose);

      await c.load();
      shouldFail = true;
      await c.refreshSilently();

      expect(c.value, 'ok');
      expect(
        c.error,
        isNull,
        reason: '前台轮询偶发失败不该把已看到的看板换成错误页',
      );
    });

    test('并发保护：同时多次 load 只发一次请求', () async {
      int calls = 0;
      final AppController<String> c = AppController<String>(
        load: () async {
          calls += 1;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return 'v';
        },
      );
      addTearDown(c.dispose);

      await Future.wait(<Future<void>>[c.load(), c.load(), c.load()]);
      expect(calls, 1, reason: '在途请求期间重复调用不应产生第二次网络请求');
    });

    test('dispose 之后不再通知（避免 setState after dispose）', () async {
      final AppController<String> c = AppController<String>(
        load: () async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 'v';
        },
      );
      int notifications = 0;
      c.addListener(() => notifications += 1);

      final Future<void> pending = c.load();
      // 首次 load 会在**发起前**同步进入加载态并通知一次。
      // 这是合理的：界面要立刻显示"加载中"。
      final int beforeDispose = notifications;

      c.dispose();
      await pending;

      expect(
        notifications,
        beforeDispose,
        reason: '请求返回后不得再通知——此时界面可能已经销毁，'
            '再通知会触发 setState after dispose',
      );
      // 而且值也不该被写入（销毁后写入会让下一次挂载读到陈旧状态）。
      expect(c.value, isNull);
    });
  });

  group('FakeClock', () {
    test('可推进时间，便于测试倒计时', () {
      final FakeClock clock = FakeClock(DateTime(2026, 10, 16, 9, 0));
      expect(clock.now(), DateTime(2026, 10, 16, 9, 0));
      clock.advance(const Duration(minutes: 30));
      expect(clock.now(), DateTime(2026, 10, 16, 9, 30));
    });
  });
}
