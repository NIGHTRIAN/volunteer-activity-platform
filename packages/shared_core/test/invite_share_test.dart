import 'package:shared_core/shared_core.dart';
import 'package:test/test.dart';

/// 邀请信息（活动编号 + 学号 + 邀请码）的分享文本与解析。
///
/// ## 为什么这组测试重要
///
/// 真机测试反馈：发布者要把三样东西手工告诉志愿者，志愿者要往三个框里分别填，
/// **极易填串**（活动编号填进学号框 → 报"活动不存在"，看起来像系统坏了）。
///
/// 于是加了"一键复制整段 / 一键粘贴自动填"。这个功能一旦解析错，
/// 会把**错误的值**填进输入框 —— 比让用户自己填更糟。所以各种真实文本形态都要测。
void main() {
  group('生成分享文本', () {
    test('带活动名与姓名时都写进去，且包含三个必要标签', () {
      const InviteShare s = InviteShare(
        activityId: '12',
        userNo: '2021001',
        inviteCode: 'BMJSL7XE',
        activityTitle: '图书馆书架整理志愿服务',
        studentName: '张伟',
      );
      final String text = s.toText();
      expect(text, contains('图书馆书架整理志愿服务'));
      expect(text, contains('活动编号：12'));
      expect(text, contains('学号：2021001'));
      expect(text, contains('邀请码：BMJSL7XE'));
      // 末尾要有操作提示，否则志愿者不知道该拿它干什么
      expect(text, contains('粘贴邀请信息'));
    });

    test('生成后能被自己完整解析回来（往返一致）', () {
      const InviteShare s = InviteShare(
        activityId: 'demo-act-library',
        userNo: '2021001',
        inviteCode: 'DEMO0001',
        activityTitle: '图书馆书架整理志愿服务',
        studentName: '张伟',
      );
      final InviteShare? back = InviteShare.tryParse(s.toText());
      expect(back, isNotNull);
      expect(back!.activityId, s.activityId);
      expect(back.userNo, s.userNo);
      expect(back.inviteCode, s.inviteCode);
    });
  });

  group('解析：真实可能出现的文本形态', () {
    test('标准三段（带中文冒号）', () {
      final InviteShare? s = InviteShare.tryParse('活动编号：12\n学号：2021001\n邀请码：BMJSL7XE');
      expect(s, isNotNull);
      expect(s!.activityId, '12');
      expect(s.userNo, '2021001');
      expect(s.inviteCode, 'BMJSL7XE');
    });

    test('半角冒号 / 没冒号（只有空格）', () {
      expect(InviteShare.tryParse('活动编号: 12\n学号: 2021001\n邀请码: BMJSL7XE')?.inviteCode,
          'BMJSL7XE');
      expect(InviteShare.tryParse('活动编号 12\n学号 2021001\n邀请码 BMJSL7XE')?.activityId, '12');
    });

    test('顺序打乱也能解析（不依赖行序）', () {
      final InviteShare? s = InviteShare.tryParse('邀请码：A1B2C3D4\n活动编号：12\n学号：2021001');
      expect(s, isNotNull);
      expect(s!.activityId, '12');
      expect(s.inviteCode, 'A1B2C3D4');
    });

    test('多余内容（标题、空行、说明文字）不影响', () {
      const String messy = '''
        【志愿活动】图书馆书架整理志愿服务

        活动编号：12
        学号：2021001

        邀请码：BMJSL7XE
        打开 App 后点粘贴邀请信息即可。
        ''';
      final InviteShare? s = InviteShare.tryParse(messy);
      expect(s, isNotNull, reason: '多余的标题与说明不该让解析失败');
      expect(s!.activityId, '12');
      expect(s.userNo, '2021001');
      expect(s.inviteCode, 'BMJSL7XE');
      expect(s.activityTitle, contains('图书馆'));
    });

    test('Windows 换行（\\r\\n）与全角空格', () {
      final InviteShare? s = InviteShare.tryParse('活动编号：12\r\n学号：2021001\r\n邀请码：BMJSL7XE');
      expect(s, isNotNull);
      expect(s!.userNo, '2021001');
    });

    test('别名：活动码 / 工号 / 邀请代码', () {
      final InviteShare? s = InviteShare.tryParse('活动码：12\n工号：T2021009\n邀请代码：XYZ23456');
      expect(s, isNotNull);
      expect(s!.activityId, '12');
      expect(s.userNo, 'T2021009');
      expect(s.inviteCode, 'XYZ23456');
    });

    test('含连字符/下划线的活动编号（demo 模式就是这种）', () {
      final InviteShare? s =
          InviteShare.tryParse('活动编号：demo-act-library\n学号：2021001\n邀请码：DEMO0001');
      expect(s, isNotNull);
      expect(s!.activityId, 'demo-act-library', reason: '不能被空格或连字符截断');
    });

    test('纯数字学号不会被当成活动编号（标签优先于形状）', () {
      final InviteShare? s = InviteShare.tryParse('活动编号：12\n学号：2021001\n邀请码：ABCD2345');
      expect(s!.activityId, '12');
      expect(s.userNo, '2021001');
    });
  });

  group('解析：应当拒绝的输入', () {
    test('缺任一字段 → 返回 null（宁可让用户自己填，也不要填错）', () {
      expect(InviteShare.tryParse('活动编号：12\n学号：2021001'), isNull);
      expect(InviteShare.tryParse('活动编号：12\n邀请码：BMJSL7XE'), isNull);
      expect(InviteShare.tryParse('学号：2021001\n邀请码：BMJSL7XE'), isNull);
    });

    test('空文本 / null / 完全无关的文字', () {
      expect(InviteShare.tryParse(null), isNull);
      expect(InviteShare.tryParse(''), isNull);
      expect(InviteShare.tryParse('   \n\n  '), isNull);
      expect(InviteShare.tryParse('今天天气不错'), isNull);
    });

    test('只有标签没有值', () {
      expect(InviteShare.tryParse('活动编号：\n学号：\n邀请码：'), isNull);
    });
  });
}
